{-# LANGUAGE DataKinds                                #-}
{-# LANGUAGE DeriveDataTypeable                       #-}
{-# LANGUAGE DeriveGeneric                            #-}
{-# LANGUAGE ExistentialQuantification                #-}
{-# LANGUAGE FlexibleContexts                         #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE GADTs                                    #-}
{-# LANGUAGE InstanceSigs                             #-}
{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE RankNTypes                               #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TupleSections                            #-}
{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE TypeOperators                            #-}
{-# LANGUAGE TypeSynonymInstances                     #-}

{-# OPTIONS  #-}

-- | This is an implementation of
-- git@github.com:liqd/adhocracy3.git:/docs/source/api/authentication_api.rst
module Thentos.Backend.Api.Adhocracy3 where

import Control.Applicative ((<$>), (<*>), pure)
import Control.Concurrent.MVar (MVar)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Either (left)
import Control.Monad.Trans.Reader (ask)
import Control.Monad (when, unless, mzero)
import Crypto.Random (SystemRNG)
import Data.Aeson (Value(Object), ToJSON, FromJSON, (.:), (.:?), (.=), object, withObject)
import Data.Functor.Infix ((<$$>))
import Data.Maybe (catMaybes)
import Data.Monoid ((<>))
import Data.Proxy (Proxy(Proxy))
import Data.String.Conversions (SBS, ST, cs)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import Safe (readMay, fromJustNote)
import Servant.API ((:<|>)((:<|>)), (:>), Post, ReqBody)
import Servant.Server.Internal (Server)
import Servant.Server (serve)
import Snap (urlEncode)  -- (not sure if this dependency belongs to backend?)
import System.Log (Priority(DEBUG))
import Text.Printf (printf)

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as ST

import System.Log.Missing
import Thentos.Api
import Thentos.Backend.Api.Proxy
import Thentos.Backend.Core
import Thentos.Config
import Thentos.DB
import Thentos.Smtp
import Thentos.Types
import Thentos.Util


-- * data types

-- ** basics

newtype Path = Path ST
  deriving (Eq, Ord, Show, Read, Typeable, Generic)

instance ToJSON Path
instance FromJSON Path

data ContentType =
      CTUser
  deriving (Eq, Ord, Enum, Bounded, Typeable, Generic)

instance Show ContentType where
    show CTUser = "adhocracy_core.resources.principal.IUser"

instance Read ContentType where
    readsPrec = readsPrecEnumBoundedShow

instance ToJSON ContentType where
    toJSON = Aeson.String . cs . show

instance FromJSON ContentType where
    parseJSON = Aeson.withText "content type string" $ maybe mzero return . readMay . cs

data PropertySheet =
      PSUserBasic
    | PSPasswordAuthentication
  deriving (Eq, Enum, Bounded, Typeable)

instance Show PropertySheet where
    show PSUserBasic              = "adhocracy_core.sheets.principal.IUserBasic"
    show PSPasswordAuthentication = "adhocracy_core.sheets.principal.IPasswordAuthentication"

instance Read PropertySheet where
    readsPrec = readsPrecEnumBoundedShow


-- ** resource

data A3Resource a = A3Resource (Maybe Path) (Maybe ContentType) (Maybe a)
  deriving (Eq, Show, Typeable, Generic)

instance ToJSON a => ToJSON (A3Resource a) where
    toJSON (A3Resource p ct r) =
        object $ "path" .= p : "content_type" .= ct : case Aeson.toJSON <$> r of
            Just (Object v) -> HashMap.toList v
            Nothing -> []
            Just _ -> []

instance FromJSON a => FromJSON (A3Resource a) where
    parseJSON = withObject "resource object" $ \ v -> do
        A3Resource <$> (v .:? "path") <*> (v .:? "content_type") <*>
            if "data" `HashMap.member` v
                then Just <$> Aeson.parseJSON (Object v)
                else pure Nothing


-- ** individual resources

newtype A3UserNoPass = A3UserNoPass { fromA3UserNoPass :: UserFormData }
  deriving (Eq, Show, Typeable, Generic)

newtype A3UserWithPass = A3UserWithPass { fromA3UserWithPass :: UserFormData }
  deriving (Eq, Show, Typeable, Generic)

instance ToJSON A3UserNoPass where
    toJSON (A3UserNoPass user) = a3UserToJSON False user

instance ToJSON A3UserWithPass where
    toJSON (A3UserWithPass user) = a3UserToJSON True user

instance FromJSON A3UserNoPass where
    parseJSON value = A3UserNoPass <$> a3UserFromJSON False value

instance FromJSON A3UserWithPass where
    parseJSON value = A3UserWithPass <$> a3UserFromJSON True value

a3UserToJSON :: Bool -> UserFormData -> Aeson.Value
a3UserToJSON withPass (UserFormData name password email) = object
    [ "content_type" .= CTUser
    , "data" .= object (catMaybes
        [ Just $ cshow PSUserBasic .= object
            [ "name" .= name
            , "email" .= email
            ]
        , if withPass
            then Just $ cshow PSPasswordAuthentication .= object ["password" .= password]
            else Nothing
        ])
    ]

a3UserFromJSON :: Bool -> Aeson.Value -> Aeson.Parser UserFormData
a3UserFromJSON withPass = withObject "resource object" $ \ v -> do
    content_type :: ContentType <- v .: "content_type"
    when (content_type /= CTUser) $
        fail $ "wrong content type: " ++ show content_type
    name         <- v .: "data" >>= (.: cshow PSUserBasic) >>= (.: "name")
    email        <- v .: "data" >>= (.: cshow PSUserBasic) >>= (.: "email")
    password     <- if withPass
        then v .: "data" >>= (.: cshow PSPasswordAuthentication) >>= (.: "password")
        else pure ""
    when (not $ userNameValid name) $
        fail $ "malformed user name: " ++ show name
    when (not $ emailValid name) $
        fail $ "malformed email address: " ++ show email
    when (withPass && not (passwordGood name)) $
        fail $ "bad password: " ++ show password
    return $ UserFormData (UserName name) (UserPass password) (UserEmail email)

-- | constraints on user name: The "name" field in the "IUserBasic"
-- schema is a non-empty string that can contain any characters except
-- '@' (to make user names distinguishable from email addresses). The
-- username must not contain any whitespace except single spaces,
-- preceded and followed by non-whitespace (no whitespace at begin or
-- end, multiple subsequent spaces are forbidden, tabs and newlines
-- are forbidden).
--
-- FIXME: not implemented.
userNameValid :: ST -> Bool
userNameValid _ = True

-- | RFC 5322 (sections 3.2.3 and 3.4.1) and RFC 5321
--
-- FIXME: not implemented.
emailValid :: ST -> Bool
emailValid _ = True

-- | Only an empty password is a bad password.
passwordGood :: ST -> Bool
passwordGood "" = False
passwordGood _ = True


-- ** other types

data ActivationRequest =
    ActivationRequest Path
  deriving (Eq, Show, Typeable, Generic)

data LoginRequest =
    LoginByName UserName UserPass
  | LoginByEmail UserEmail UserPass
  deriving (Eq, Show, Typeable, Generic)

data RequestResult =
    RequestSuccess Path SessionToken
  | RequestError [ST]
  deriving (Eq, Show, Typeable, Generic)

instance ToJSON ActivationRequest where
    toJSON (ActivationRequest p) = object ["path" .= p]

instance FromJSON ActivationRequest where
    parseJSON = withObject "activation request" $ \ v -> do
        p :: ST <- v .: "path"
        unless ("/activate/" `ST.isPrefixOf` p) $
            fail $ "ActivationRequest with malformed path: " ++ show p
        return . ActivationRequest . Path $ p

instance ToJSON LoginRequest where
    toJSON (LoginByName  n p) = object ["name"  .= n, "password" .= p]
    toJSON (LoginByEmail e p) = object ["email" .= e, "password" .= p]

instance FromJSON LoginRequest where
    parseJSON = withObject "login request" $ \ v -> do
        n <- UserName  <$$> v .:? "name"
        e <- UserEmail <$$> v .:? "email"
        p <- UserPass  <$>  v .: "password"
        case (n, e) of
          (Just x,  Nothing) -> return $ LoginByName x p
          (Nothing, Just x)  -> return $ LoginByEmail x p
          (_,       _)       -> fail $ "malformed login request body: " ++ show v

instance ToJSON RequestResult where
    toJSON (RequestSuccess p t) = object $
        "status" .= ("success" :: ST) :
        "user_path" .= p :
        "token" .= t :
        []
    toJSON (RequestError es) = object $
        "status" .= ("error" :: ST) :
        "errors" .= map (\ d -> object ["description" .= d, "location" .= (), "name" .= ()]) es :
        []

instance FromJSON RequestResult where
    parseJSON = withObject "request result" $ \ v -> do
        n :: ST <- v .: "status"
        case n of
            "success" -> RequestSuccess <$> v .: "user_path" <*> v .: "token"
            "error" -> RequestError <$> v .: "errors"
            _ -> mzero


-- * main

runBackend :: Int -> ActionStateGlobal (MVar SystemRNG) -> IO ()
runBackend port = run port . serveApi

serveApi :: ActionStateGlobal (MVar SystemRNG) -> Application
serveApi = serve (Proxy :: Proxy App) . app


-- * api

-- | Note: login_username and login_email have identical behavior.  In
-- particular, it is not an error to send username and password to
-- @/login_email@.  This makes implementing all sides of the protocol
-- a lot easier without sacrificing security.
type App =
       "principals" :> "users" :> ReqBody A3UserWithPass :> Post (A3Resource A3UserNoPass)
  :<|> "activate_account"      :> ReqBody ActivationRequest :> Post RequestResult
  :<|> "login_username"        :> ReqBody LoginRequest :> Post RequestResult
  :<|> "login_email"           :> ReqBody LoginRequest :> Post RequestResult
  :<|> ServiceProxy

app :: ActionStateGlobal (MVar SystemRNG) -> Server App
app asg = p $
       addUser
  :<|> activate
  :<|> login
  :<|> login
  :<|> serviceProxy
  where
    p = pushAction (asg, \ _ _ -> Right allowEverything)  -- FIXME: this is kinda bad security.


-- * handler

addUser :: A3UserWithPass -> RestAction (A3Resource A3UserNoPass)
addUser (A3UserWithPass user) = logActionError $ do
    logger DEBUG . ("route addUser:" <>) . cs . Aeson.encodePretty $ A3UserWithPass user
    ((_, _, config :: ThentosConfig), _) <- ask
    (uid :: UserId, tok :: ConfirmationToken) <- addUnconfirmedUser user
    let activationUrl = "http://localhost:" <> cs (show feport) <> "/signup_confirm/" <> enctok
        feport :: Int = frontendPort . fromJustNote "addUser: frontend not configured!" . frontendConfig $ config
        enctok :: SBS = urlEncode . cs . fromConfimationToken $ tok
    liftIO $ sendUserConfirmationMail (smtpConfig config) user activationUrl
    return $ A3Resource (Just $ userIdToPath uid) (Just CTUser) (Just $ A3UserNoPass user)


activate :: ActivationRequest -> RestAction RequestResult
activate (ActivationRequest p) = logActionError $ do
    logger DEBUG . ("route activate:" <>) . cs . Aeson.encodePretty $ ActivationRequest p
    ctok :: ConfirmationToken <- confirmationTokenFromPath p
    uid  :: UserId            <- updateAction $ FinishUserRegistration ctok
    stok :: SessionToken      <- startSessionNoPass (UserA uid)
    return $ RequestSuccess (userIdToPath uid) stok


-- | FIXME: check password!
login :: LoginRequest -> RestAction RequestResult
login r = logActionError $ do
    logger DEBUG $ "route login:" <> show r
    (uid, _) <- case r of
        LoginByName  uname _  -> queryAction $ LookupUserByName  uname
        LoginByEmail uemail _ -> queryAction $ LookupUserByEmail uemail
    stok :: SessionToken <- startSessionNoPass (UserA uid)
    return $ RequestSuccess (userIdToPath uid) stok


-- * aux

userIdToPath :: UserId -> Path
userIdToPath (UserId i) = Path . cs $ (printf "/princicpals/users/%7.7i" i :: String)

userIdFromPath :: Path -> RestAction UserId
userIdFromPath (Path s) = maybe (lift . left $ NoSuchUser) return $
    case ST.splitAt (ST.length prefix) s of
        (prefix', s') | prefix' == prefix -> fmap UserId . readMay . cs $ s'
        _ -> Nothing
  where
    prefix = "/principals/users/"

confirmationTokenFromPath :: Path -> RestAction ConfirmationToken
confirmationTokenFromPath (Path p) = case ST.splitAt (ST.length prefix) p of
    (s, s') | s == prefix -> return $ ConfirmationToken s'
    _ -> lift . left $ MalformedConfirmationToken p
  where
    prefix = "/activate/"
