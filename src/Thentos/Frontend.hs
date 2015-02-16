{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TemplateHaskell                          #-}

module Thentos.Frontend (runFrontend) where

import Control.Applicative ((<$>), (<*>))
import Control.Concurrent.MVar (MVar)
import Control.Exception (assert)
import Control.Lens (makeLenses, view, (^.))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Class (gets)
import Crypto.Random (SystemRNG)
import Data.Acid (AcidState)
import Data.ByteString (ByteString)
import Data.Functor.Infix ((<$$>))
import Data.Monoid ((<>))
import Data.String.Conversions (cs)
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Snap.Blaze (blaze)
import Snap.Core (getResponse, finishWith, method, Method(GET, POST), ifTop)
import Snap.Core (rqURI, getParam, getsRequest, redirect', parseUrlEncoded, printUrlEncoded, modifyResponse, setResponseStatus)
import Snap.Http.Server (defaultConfig, setBind, setPort)
import Snap.Snaplet.AcidState (Acid, acidInitManual, HasAcid(getAcidStore), getAcidState, update, query)
import Snap.Snaplet (Snaplet, SnapletInit, snapletValue, makeSnaplet, nestSnaplet, addRoutes, Handler)
import Text.Digestive.Snap (runForm)

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map as M

import Thentos.Api
import Thentos.Config
import Thentos.DB
import Thentos.Types
import Thentos.Util

import Thentos.Frontend.Pages (mainPage, addUserPage, userForm, userAddedPage, loginForm, loginPage, errorPage, addServicePage, serviceAddedPage)
import Thentos.Frontend.Util (serveSnaplet)
import Thentos.Frontend.Mail (sendUserConfirmationMail)


data FrontendApp =
    FrontendApp
      { _db :: Snaplet (Acid DB)
      , _rng :: MVar SystemRNG
      , _cfg :: ThentosConfig
      , _fecfg :: FrontendConfig
      }

makeLenses ''FrontendApp

instance HasAcid FrontendApp DB where
    getAcidStore = view (db . snapletValue)

runFrontend :: ByteString -> Int -> ActionStateGlobal (MVar SystemRNG) -> IO ()
runFrontend host port asg = serveSnaplet (setBind host $ setPort port defaultConfig) (frontendApp asg)

frontendApp :: ActionStateGlobal (MVar SystemRNG) -> SnapletInit FrontendApp FrontendApp
frontendApp (st, rn, _cfg) = makeSnaplet "Thentos" "The Thentos universal user management system" Nothing $ do
    addRoutes routes
    FrontendApp <$>
        (nestSnaplet "acid" db $ acidInitManual st) <*>
        (return rn) <*>
        (return _cfg) <*>
        (case frontendConfig _cfg of
            Just x -> return x
            Nothing -> assert False $ error "frontendApp: internal error")

routes :: [(ByteString, Handler FrontendApp FrontendApp ())]
routes = [ ("", ifTop $ mainPageHandler)
         , ("login", loginHandler)
         , ("create_user", userAddHandler)
         , ("signup_confirm", userAddConfirmHandler)
         , ("create_service", method GET addServiceHandler)
         , ("create_service", method POST serviceAddedHandler)
         ]

mainPageHandler :: Handler FrontendApp FrontendApp ()
mainPageHandler = blaze $ mainPage

userAddHandler :: Handler FrontendApp FrontendApp ()
userAddHandler = do
    (_view, result) <- runForm "create_user" userForm
    case result of
        Nothing -> blaze $ addUserPage _view
        Just user -> do
            result' <- snapRunAction' allowEverything $ addUnconfirmedUser user
            case result' of
                Right (_, ConfirmationToken token) -> do
                    config :: FrontendConfig <- gets (^. fecfg)
                    let url = "http://localhost:" <> (cs . show $ frontendPort config)
                                <> "/signup_confirm?token=" <> encodeUtf8 token
                    liftIO $ sendUserConfirmationMail user url
                    blaze "Please check your email!"
                Left e -> blaze . errorPage $ show e

userAddConfirmHandler :: Handler FrontendApp FrontendApp ()
userAddConfirmHandler = do
    Just tokenBS <- getParam "token" -- FIXME: error handling
    case ConfirmationToken <$> decodeUtf8' tokenBS of
        Right token -> do
            result <- update $ FinishUserRegistration token allowEverything
            case result of
                Right uid -> blaze $ userAddedPage uid
                Left e -> blaze . errorPage $ show e
        Left unicodeError -> blaze . errorPage $ show unicodeError

addServiceHandler :: Handler FrontendApp FrontendApp ()
addServiceHandler = blaze addServicePage

serviceAddedHandler :: Handler FrontendApp FrontendApp ()
serviceAddedHandler = do
    result <- snapRunAction' allowEverything addService
    case result of
        Right (sid, key) -> blaze $ serviceAddedPage sid key
        Left e -> blaze . errorPage $ show e

loginHandler :: Handler FrontendApp FrontendApp ()
loginHandler = do
    uri <- getsRequest rqURI
    mSid <- ServiceId . cs <$$> getParam "sid"
    (_view, result) <- runForm (cs uri) loginForm
    case (result, mSid) of
        (_, Nothing)                      -> blaze "No service id"
        (Nothing, Just sid)               -> blaze $ loginPage sid _view uri
        (Just (name, password), Just sid) -> do
            eUser <- query $ LookupUserByName name allowEverything
            case eUser of
                Right (uid, user) ->
                    if verifyPass password user
                        then loginSuccess uid sid
                        else loginFail
                Left NoSuchUser -> loginFail
                Left e -> blaze . errorPage $ show e
  where
    loginFail :: Handler FrontendApp FrontendApp ()
    loginFail = blaze "Bad username / password combination"

    loginSuccess :: UserId -> ServiceId -> Handler FrontendApp FrontendApp ()
    loginSuccess uid sid = do
        mCallback <- getParam "redirect"
        case mCallback of
            Nothing -> do
                modifyResponse $ setResponseStatus 400 "Bad Request"
                blaze "400 Bad Request"
                r <- getResponse
                finishWith r
            Just callback -> do
                eSessionToken :: Either DbError SessionToken
                    <- snapRunAction' allowEverything $ do
                        tok <- startSessionNow (UserA uid)
                        addServiceLogin tok sid
                        return tok
                case eSessionToken of
                    Left e -> blaze . errorPage $ show e
                    Right sessionToken ->
                        redirect' (redirectUrl callback sessionToken) 303

    redirectUrl :: ByteString -> SessionToken -> ByteString
    redirectUrl serviceProvidedUrl sessionToken =
        let (base_url, _query) = BC.break (== '?') serviceProvidedUrl in
        let params = parseUrlEncoded $ B.drop 1 _query in
        let params' = M.insert "token" [cs $ fromSessionToken sessionToken] params in
        base_url <> "?" <> printUrlEncoded params'


snapRunAction :: (DB -> TimeStamp -> Either DbError ThentosClearance) -> Action (MVar SystemRNG) a
      -> Handler FrontendApp FrontendApp (Either DbError a)
snapRunAction clearanceAbs action = do
    rn :: MVar SystemRNG <- gets (^. rng)
    st :: AcidState DB <- getAcidState
    _cfg :: ThentosConfig <- gets (^. cfg)
    runAction ((st, rn, _cfg), clearanceAbs) action

snapRunAction' :: ThentosClearance -> Action (MVar SystemRNG) a
      -> Handler FrontendApp FrontendApp (Either DbError a)
snapRunAction' clearance = snapRunAction (\ _ _ -> Right clearance)