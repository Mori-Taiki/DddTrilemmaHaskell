{-# LANGUAGE GADTs #-}
module Story.Decision
  ( Follow(..), Membership(..), Purchase(..), Fact(..), Decision(..)
  , Denial(..), Verdict(..), Check(..), Report(..), decide, interpret
  ) where

import Story.Domain

data Follow = Following | NotFollowing deriving (Eq, Show)
data Membership = Standard | Vip deriving (Eq, Show)
data Purchase = Owned | NotOwned deriving (Eq, Show)

-- The index is the only answer type the continuation will accept.
data Fact a where
  Follows :: UserId -> UserId -> Fact Follow
  Member :: UserId -> Fact Membership
  Purchased :: UserId -> StoryId -> Fact Purchase

data Denial = FollowRequired | PurchaseRequired deriving (Eq, Show)
data Verdict = Allow | Deny Denial deriving (Eq, Show)

data Decision where
  Done :: Verdict -> Decision
  Need :: Fact a -> (a -> Decision) -> Decision

decide :: Story -> UserId -> Decision
decide story viewer
  | viewer == author story = Done Allow
  | otherwise = case visibility story of
      Public -> checkPrice
      FollowersOnly -> Need (Follows viewer (author story)) afterFollow
  where
    afterFollow NotFollowing = Done (Deny FollowRequired)
    afterFollow Following = checkPrice

    checkPrice = case price story of
      Free -> Done Allow
      Paid -> Need (Member viewer) afterMembership

    afterMembership Vip = Done Allow
    afterMembership Standard = Need (Purchased viewer (identifier story)) afterPurchase

    afterPurchase Owned = Done Allow
    afterPurchase NotOwned = Done (Deny PurchaseRequired)

data Check = CheckFollow | CheckMembership | CheckPurchase deriving (Eq, Show)
data Report = Report { verdict :: Verdict, checks :: [Check] } deriving (Eq, Show)

kind :: Fact a -> Check
kind (Follows _ _) = CheckFollow
kind (Member _) = CheckMembership
kind (Purchased _ _) = CheckPurchase

interpret :: Monad m => (forall a. Fact a -> m a) -> Decision -> m Report
interpret fetch = go []
  where
    go seen (Done result) = pure (Report result (reverse seen))
    go seen (Need fact resume) = do
      answer <- fetch fact
      go (kind fact : seen) (resume answer)
