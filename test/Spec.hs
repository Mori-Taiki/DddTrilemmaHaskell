{-# LANGUAGE GADTs #-}
module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (forM_)
import Data.Aeson (decode, encode, object, (.=), Value(..))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Functor.Identity (Identity(..))
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Network.HTTP.Types
import Network.Wai (requestMethod)
import Network.Wai.Test
import Story.Decision
import Story.Domain
import Story.Http
import Story.Store
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

uid :: Text -> UserId
uid = maybe (error "invalid test user") id . userId

sid :: Text -> StoryId
sid = maybe (error "invalid test story") id . storyId

answers :: Follow -> Membership -> Purchase -> Fact a -> Identity a
answers follow member purchase fact = Identity $ case fact of
  Follows _ _ -> follow
  Member _ -> member
  Purchased _ _ -> purchase

withDatabase :: (FilePath -> IO a) -> IO a
withDatabase action = withSystemTempDirectory "story-test" $ \dir -> do
  let path = dir ++ "/story.db"
  withStore path initialize
  action path

call :: FilePath -> B.ByteString -> B.ByteString -> L.ByteString -> IO SResponse
call path verb url body =
  let req = (setPath defaultRequest url) { requestMethod = verb }
  in runSession (srequest (SRequest req body)) (application path)

change :: Text -> Text -> L.ByteString
change actor scope = encode (object ["actor" .= actor, "visibility" .= scope])

main :: IO ()
main = hspec $ do
  describe "純粋な業務仕様" $ do
    it "公開範囲・料金・作者本人・3つの事実の全64通りが閲覧条件を満たす" $
      forM_ [(v,p,own,f,m,b) | v <- [Public,FollowersOnly], p <- [Free,Paid],
              own <- [False,True], f <- [NotFollowing,Following],
              m <- [Standard,Vip], b <- [NotOwned,Owned]] $ \(v,p,own,f,m,b) -> do
        let viewer = uid (if own then "author" else "reader")
            story = Story (sid "story") (uid "author") v p
            report = runIdentity (interpret (answers f m b) (decide story viewer))
            audienceOk = v == Public || f == Following
            paymentOk = p == Free || m == Vip || b == Owned
        (verdict report == Allow) `shouldBe` (own || (audienceOk && paymentOk))
        if own then checks report `shouldBe` [] else
          case verdict report of
            Deny FollowRequired -> audienceOk `shouldBe` False
            Deny PurchaseRequired -> (audienceOk, paymentOk) `shouldBe` (True, False)
            Allow -> pure ()
    it "未回答の事実を取得できなければ業務判定を返さない" $ do
      let story = Story (sid "s") (uid "author") Public Paid
      interpret (const (Left "offline")) (decide story (uid "reader"))
        `shouldBe` (Left "offline" :: Either String Report)
    it "空白だけのIDを拒否し、有効な値はそのまま保つ" $ do
      forM_ ["", "  ", "\t\n", "　"] $ \value -> do
        storyId value `shouldBe` Nothing
        userId value `shouldBe` Nothing
      fmap userIdText (userId " vip ") `shouldBe` Just " vip "

  around withDatabase $ do
    describe "SQLite" $ do
      forM_ [("author", Allow, []), ("guest", Deny FollowRequired, [CheckFollow]),
             ("vip", Allow, [CheckFollow, CheckMembership]),
             ("buyer", Allow, [CheckFollow, CheckMembership, CheckPurchase]),
             ("follower", Deny PurchaseRequired, [CheckFollow, CheckMembership, CheckPurchase])] $
        \(viewer, result, path) -> it ("限定・有料の判定経路と実SELECT数 " ++ T.unpack viewer) $ \file ->
          withStore file $ \db -> do
            statements <- newIORef []
            setTrace db (Just (\sql -> modifyIORef' statements (sql :)))
            viewStory db (sid "followers-paid") (uid viewer) `shouldReturn` Just (Report result path)
            sql <- readIORef statements
            length (filter ("SELECT" `T.isPrefixOf`) sql) `shouldBe` (1 + length path)
      it "他人・別の作者・別作品の事実は使わない" $ \file -> withStore file $ \db -> do
        execute_ db "INSERT INTO follows VALUES ('guest','someone-else')"
        execute_ db "INSERT INTO purchases VALUES ('guest','followers-paid')"
        viewStory db (sid "public-paid") (uid "guest") `shouldReturn`
          Just (Report (Deny PurchaseRequired) [CheckMembership, CheckPurchase])
        viewStory db (sid "followers-paid") (uid "guest") `shouldReturn`
          Just (Report (Deny FollowRequired) [CheckFollow])
      it "取得失敗を未購入として扱わない" $ \file -> withStore file $ \db -> do
        execute_ db "DROP TABLE purchases"
        viewStory db (sid "public-paid") (uid "guest") `shouldThrow` (\(_ :: SQLError) -> True)
      it "保存済みの未知の料金を検出する" $ \file -> withStore file $ \db -> do
        execute_ db "UPDATE stories SET price = 'unknown'"
        listStories db `shouldThrow` anyIOException

    describe "HTTP" $ do
      it "VIPの短絡経路をJSONで返す" $ \file -> do
        res <- call file "GET" "/stories/followers-paid/view?viewer=vip" ""
        simpleStatus res `shouldBe` status200
        decode (simpleBody res) `shouldBe` Just (object
          [ "allowed" .= True, "reason" .= Null, "factQueries" .= (2 :: Int)
          , "trace" .= (["フォロー確認が必要","会員確認が必要","許可"] :: [Text]) ])
      it "拒否理由、入力不足、存在しない作品を区別する" $ \file -> do
        let get path = call file "GET" path ""
        denied <- get "/stories/public-paid/view?viewer=guest"
        simpleStatus denied `shouldBe` status403
        decode (simpleBody denied) `shouldBe` Just (object
          [ "allowed" .= False, "reason" .= String "購入が必要", "factQueries" .= (2 :: Int)
          , "trace" .= (["会員確認が必要","購入確認が必要","拒否"] :: [Text]) ])
        forM_ ["/stories/public-free/view", "/stories/public-free/view?viewer=%20"] $ \path ->
          simpleStatus <$> get path `shouldReturn` status400
        simpleStatus <$> get "/stories/missing/view?viewer=guest" `shouldReturn` status404
        simpleStatus <$> call file "PUT" "/stories/missing/visibility" (change "author" "全体公開")
          `shouldReturn` status404
      it "不正な入力と作者以外の更新は作品を変えない" $ \file -> do
        let put = call file "PUT" "/stories/public-free/visibility"
        forM_ ["{", "{}", change " " "全体公開", change "author" "作者限定",
               encode (object ["actor" .= String "a", "visibility" .= (99 :: Int)])] $ \body ->
          simpleStatus <$> put body `shouldReturn` status400
        denied <- put (change "guest" "フォロワー限定")
        simpleStatus denied `shouldBe` status403
        decode (simpleBody denied) `shouldBe` Just (object ["reason" .= String "作者ではない"])
        simpleStatus <$> call file "GET" "/stories/public-free/view?viewer=guest" "" `shouldReturn` status200
      it "同じ変更が競合しても一度だけ成功し、再初期化後の一覧と閲覧に反映する" $ \file -> do
        let put = call file "PUT" "/stories/public-free/visibility" (change "author" "フォロワー限定")
        (a,b) <- concurrently put put
        sort (map (statusCode . simpleStatus) [a,b]) `shouldBe` [200,409]
        let conflict = if simpleStatus a == status409 then a else b
        decode (simpleBody conflict) `shouldBe` Just (object ["reason" .= String "既にその公開範囲"])
        withStore file initialize
        listing <- call file "GET" "/stories" ""
        let expected = object ["id" .= String "public-free", "authorId" .= String "author",
                               "visibility" .= String "フォロワー限定", "price" .= String "無料"]
        fmap (elem expected) (decode (simpleBody listing) :: Maybe [Value]) `shouldBe` Just True
        res <- call file "GET" "/stories/public-free/view?viewer=guest" ""
        simpleStatus res `shouldBe` status403
