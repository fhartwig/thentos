{-# LANGUAGE DataKinds                                #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE TypeOperators                            #-}

{-# OPTIONS  #-}

module Thentos.DB.Protect
  ( makeThentosClearance
  , allowEverything
  , allowReadEverything
  , allowNothing
  , (*%%)
  , createDefaultUser
  ) where

import Control.Monad (when)
import Data.Acid (AcidState)
import Data.Acid.Advanced (query', update')
import Data.Either (isLeft, isRight)
import Data.String.Conversions (ST)
import LIO.DCLabel (ToCNF, toCNF, (%%), (/\), (\/))
import System.Log (Priority(DEBUG, ERROR))
import Text.Show.Pretty

import Thentos.DB.Core
import Thentos.DB.Trans
import System.Log.Missing (logger)
import Thentos.Types
import Thentos.Util


-- | If password cannot be verified, or if only password or only
-- principal is provided, throw an error explaining the problem.  If
-- none are provided, set clearance level to 'allowNothing'.  If both
-- are provided, look up roles of principal, and set clearance level
-- to that of the principal aka agent and all its roles.
--
-- Note: Both 'Role's and 'Agent's can be used in authorization
-- policies.  ('User' can be used, but it must be wrapped into an
-- 'UserA'.)
makeThentosClearance :: Maybe ST -> DB -> TimeStamp -> Either ThentosError ThentosClearance
makeThentosClearance Nothing    _  _   = Right allowNothing
makeThentosClearance (Just tok) db now = authenticateSession db now (SessionToken tok)

-- | The counter part to 'makeThentosLabel'.  (The argument types are
-- much more specific becaues there is only one use case so far.  The
-- names of the two counterparts are not symmetrical because
-- 'makeThentosClearance' was already taken.)
makeClearance_ :: Agent -> [Role] -> ThentosClearance
makeClearance_ agent roles = s *%% i
  where
    s = foldr (/\) (toCNF agent) roles
    i = foldr (\/) (toCNF agent) roles

authenticateSession :: DB -> TimeStamp -> SessionToken -> Either ThentosError ThentosClearance
authenticateSession db now tok = do
    agent <- case pure_lookupSession db (Just (now, False)) tok of
        LookupSessionUnchanged (_, Session agent _ _ _) -> Right agent
        _ -> Left NoSuchSession

    case agent of
        UserA    uid -> Right $ makeClearance_ (UserA uid)    (pure_lookupAgentRoles db $ UserA    uid)
        ServiceA sid -> Right $ makeClearance_ (ServiceA sid) (pure_lookupAgentRoles db $ ServiceA sid)


-- | Clearance for everything.
allowEverything :: ThentosClearance
allowEverything = False *%% True

-- | Clearance to read everything, but write / create nothing.
allowReadEverything :: ThentosClearance
allowReadEverything = False *%% False

-- | Clearance only for things labeled 'thentosPublic'.
allowNothing :: ThentosClearance
allowNothing = True *%% False


(*%%) :: (ToCNF a, ToCNF b) => a -> b -> ThentosClearance
(*%%) a b = ThentosClearance $ a %% b
infix 6 *%%


-- * default user from config file

-- | If default user is 'Nothing' or user with 'UserId 0' exists, do
-- nothing.  Otherwise, create default user.
createDefaultUser :: AcidState DB -> Maybe (UserFormData, [Role]) -> IO ()
createDefaultUser _ Nothing = return ()
createDefaultUser st (Just (userData, roles)) = do
    eq <- query' st (LookupUser (UserId 0) allowEverything)
    when (isLeft eq) $ do
        -- user
        user <- makeUserFromFormData userData
        logger DEBUG $ "No users.  Creating default user: " ++ ppShow (UserId 0, user)
        eu <- update' st (AddUser user allowEverything)

        if eu == Right (UserId 0)
            then logger DEBUG $ "[ok]"
            else logger ERROR $ "failed to create default user: " ++ ppShow (UserId 0, eu, user)

        -- roles
        logger DEBUG $ "Adding default user to roles: " ++ ppShow roles
        result <- mapM (\ role -> update' st (AssignRole (UserA (UserId 0)) role allowEverything)) roles

        if all isRight result
            then logger DEBUG $ "[ok]"
            else logger ERROR $ "failed to assign default user to roles: " ++ ppShow (UserId 0, result, user, roles)
