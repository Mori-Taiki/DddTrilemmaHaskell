{-# LANGUAGE GADTs #-}
module DomainSpec (spec) where

import Control.Monad (forM_)
import Data.Functor.Identity (Identity(..))
import Fixtures (testStoryId, testUserId)
import Story.Decision
import Story.Domain
import Test.Hspec

spec :: Spec
spec = describe "ドメイン" $ do
  describe "閲覧判定" $ do
    describe "作者は事実を取得せずに読める" $
      forM_ [publicFree, publicPaid, followersFree, followersPaid] $ \story ->
        describe (show (visibility story) ++ " / " ++ show (price story)) $
          forM_ allFacts $ \facts ->
            it (show facts) $
              viewAs (author story) story facts `shouldBe` Report Allow []

    describe "作者以外が全体公開の無料作品を読む" $
      checkReaders publicFree allFacts Allow

    describe "作者以外が全体公開の有料作品を読む" $ do
      context "VIPは購入の有無を問わず読める" $
        checkReaders publicPaid (factsFor bothFollowStates [Vip] bothPurchaseStates) Allow
      context "一般会員は購入済みなら読める" $
        checkReaders publicPaid (factsFor bothFollowStates [Standard] [Owned]) Allow
      context "未購入の一般会員には購入を求める" $
        checkReaders publicPaid (factsFor bothFollowStates [Standard] [NotOwned]) (Deny PurchaseRequired)

    describe "作者以外がフォロワー限定の無料作品を読む" $ do
      context "フォロワーは読める" $
        checkReaders followersFree (factsFor [Following] bothMemberships bothPurchaseStates) Allow
      context "非フォロワーにはフォローを求める" $
        checkReaders followersFree (factsFor [NotFollowing] bothMemberships bothPurchaseStates) (Deny FollowRequired)

    describe "作者以外がフォロワー限定の有料作品を読む" $ do
      context "非フォロワーにはVIPや購入済みでもフォローを求める" $
        checkReaders followersPaid (factsFor [NotFollowing] bothMemberships bothPurchaseStates) (Deny FollowRequired)
      context "フォロー済みのVIPは購入の有無を問わず読める" $
        checkReaders followersPaid (factsFor [Following] [Vip] bothPurchaseStates) Allow
      context "フォロー済みの一般会員は購入済みなら読める" $
        checkReaders followersPaid [ReaderFacts Following Standard Owned] Allow
      context "フォロー済みでも未購入の一般会員には購入を求める" $
        checkReaders followersPaid [ReaderFacts Following Standard NotOwned] (Deny PurchaseRequired)

    it "会員情報の取得に失敗したら、そのエラーを返す" $ do
      let decision = decide publicPaid (testUserId "reader")
          offline = Left "offline" :: Either String Report
      interpret (const (Left "offline")) decision `shouldBe` offline

  describe "識別子" $ do
    forM_ ["", "  ", "\t\n", "　"] $ \input ->
      it ("空または空白だけの入力を拒否する " ++ show input) $ do
        storyId input `shouldBe` Nothing
        userId input `shouldBe` Nothing

    it "空白以外を含む利用者IDは前後の空白も保つ" $
      fmap userIdText (userId " vip ") `shouldBe` Just " vip "

publicFree, publicPaid, followersFree, followersPaid :: Story
publicFree = exampleStory Public Free
publicPaid = exampleStory Public Paid
followersFree = exampleStory FollowersOnly Free
followersPaid = exampleStory FollowersOnly Paid

exampleStory :: Visibility -> Price -> Story
exampleStory = Story (testStoryId "story") (testUserId "author")

data ReaderFacts = ReaderFacts Follow Membership Purchase deriving Show

bothFollowStates :: [Follow]
bothFollowStates = [NotFollowing, Following]

bothMemberships :: [Membership]
bothMemberships = [Standard, Vip]

bothPurchaseStates :: [Purchase]
bothPurchaseStates = [NotOwned, Owned]

allFacts :: [ReaderFacts]
allFacts = factsFor bothFollowStates bothMemberships bothPurchaseStates

factsFor :: [Follow] -> [Membership] -> [Purchase] -> [ReaderFacts]
factsFor follows memberships purchases =
  [ ReaderFacts follow membership purchase
  | follow <- follows
  , membership <- memberships
  , purchase <- purchases
  ]

checkReaders :: Story -> [ReaderFacts] -> Verdict -> Spec
checkReaders story scenarios expected =
  forM_ scenarios $ \facts ->
    it (show facts) $
      verdict (viewAs (testUserId "reader") story facts) `shouldBe` expected

viewAs :: UserId -> Story -> ReaderFacts -> Report
viewAs viewer story facts =
  runIdentity (interpret (answer facts) (decide story viewer))

answer :: ReaderFacts -> Fact a -> Identity a
answer (ReaderFacts follow membership purchase) request = Identity $ case request of
  Follows _ _ -> follow
  Member _ -> membership
  Purchased _ _ -> purchase
