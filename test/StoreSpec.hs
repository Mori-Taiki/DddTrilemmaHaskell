module StoreSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection, SQLError, execute_, setTrace)
import Fixtures (testStoryId, testUserId, withDatabase)
import Story.Decision
import Story.Store (listStories, viewStory, withStore)
import Test.Hspec

spec :: Spec
spec = describe "SQLite" $ around withConnection $ do
  describe "フォロワー限定の有料作品で発行するSELECT" $ do
    it "作者なら作品だけを読む" $
      checkLookup "author" Allow []

    it "非フォロワーならフォロー確認で拒否する" $
      checkLookup "guest" (Deny FollowRequired) [CheckFollow]

    it "フォロー済みVIPなら会員確認で許可する" $
      checkLookup "vip" Allow [CheckFollow, CheckMembership]

    it "フォロー済みの購入者なら購入確認まで行って許可する" $
      checkLookup "buyer" Allow [CheckFollow, CheckMembership, CheckPurchase]

    it "フォロー済みでも未購入なら購入確認まで行って拒否する" $
      checkLookup "follower" (Deny PurchaseRequired) [CheckFollow, CheckMembership, CheckPurchase]

  describe "事実を検索する範囲" $ do
    it "別作品の購入履歴は閲覧許可に使わない" $ \db -> do
      execute_ db "INSERT INTO purchases VALUES ('guest','followers-paid')"
      result <- viewStory db (testStoryId "public-paid") (testUserId "guest")
      result `shouldBe` Just (Report (Deny PurchaseRequired) [CheckMembership, CheckPurchase])

    it "別の作者をフォローしていても閲覧を許可しない" $ \db -> do
      execute_ db "INSERT INTO follows VALUES ('guest','someone-else')"
      result <- viewStory db (testStoryId "followers-paid") (testUserId "guest")
      result `shouldBe` Just (Report (Deny FollowRequired) [CheckFollow])

  describe "永続化層のエラー" $ do
    it "購入テーブルが読めないときはSQLエラーを伝える" $ \db -> do
      execute_ db "DROP TABLE purchases"
      viewStory db (testStoryId "public-paid") (testUserId "guest")
        `shouldThrow` (\(_ :: SQLError) -> True)

    it "保存済みの未知の料金を検出する" $ \db -> do
      execute_ db "UPDATE stories SET price = 'unknown'"
      listStories db `shouldThrow` anyIOException

withConnection :: (Connection -> IO a) -> IO a
withConnection action = withDatabase $ \path -> withStore path action

checkLookup :: Text -> Verdict -> [Check] -> Connection -> Expectation
checkLookup viewer expectedVerdict expectedChecks db = do
  statements <- newIORef []
  setTrace db (Just (\sql -> modifyIORef' statements (sql :)))

  result <- viewStory db (testStoryId "followers-paid") (testUserId viewer)
  result `shouldBe` Just (Report expectedVerdict expectedChecks)

  selects <- filter (T.isPrefixOf "SELECT") <$> readIORef statements
  -- One SELECT loads the story. Each requested fact needs one more.
  length selects `shouldBe` 1 + length expectedChecks
