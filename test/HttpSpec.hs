module HttpSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (forM_)
import Data.Aeson (Value(..), eitherDecode, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (sort)
import Data.Text (Text)
import Fixtures (withDatabase)
import Network.HTTP.Types
import Network.Wai (requestHeaders, requestMethod)
import Network.Wai.Test
import Story.Http (application)
import Story.Store (initialize, withStore)
import Test.Hspec

spec :: Spec
spec = describe "HTTP" $ around withDatabase $ do
  describe "GET /stories/{id}/view" $ do
    it "フォロー済みVIPに200と購入確認を省いた判定経路を返す" $ \db -> do
      response <- get db "/stories/followers-paid/view?viewer=vip"
      simpleStatus response `shouldBe` status200
      let expected = object
            [ "allowed" .= True
            , "reason" .= Null
            , "factQueries" .= (2 :: Int)
            , "trace" .= (["フォロー確認が必要", "会員確認が必要", "許可"] :: [Text])
            ]
      eitherDecode (simpleBody response) `shouldBe` Right expected

    it "有料作品を未購入の一般会員に403と購入が必要な理由を返す" $ \db -> do
      response <- get db "/stories/public-paid/view?viewer=guest"
      simpleStatus response `shouldBe` status403
      let expected = object
            [ "allowed" .= False
            , "reason" .= String "購入が必要"
            , "factQueries" .= (2 :: Int)
            , "trace" .= (["会員確認が必要", "購入確認が必要", "拒否"] :: [Text])
            ]
      eitherDecode (simpleBody response) `shouldBe` Right expected

    it "閲覧者の指定がなければ400を返す" $ \db -> do
      response <- get db "/stories/public-free/view"
      simpleStatus response `shouldBe` status400

    it "閲覧者IDが空白だけなら400を返す" $ \db -> do
      response <- get db "/stories/public-free/view?viewer=%20"
      simpleStatus response `shouldBe` status400

    it "作品が存在しなければ404を返す" $ \db -> do
      response <- get db "/stories/missing/view?viewer=guest"
      simpleStatus response `shouldBe` status404

  describe "PUT /stories/{id}/visibility" $ do
    it "作品が存在しなければ404を返す" $ \db -> do
      response <- putJson db "/stories/missing/visibility" (change "author" "全体公開")
      simpleStatus response `shouldBe` status404

    describe "不正な入力には400を返し、公開範囲を保つ" $
      forM_ invalidChanges $ \(description, body) ->
        it description $ \db -> do
          response <- putJson db visibilityUrl body
          simpleStatus response `shouldBe` status400

          viewing <- get db guestViewUrl
          simpleStatus viewing `shouldBe` status200

    it "作者以外の変更を403で拒否し、元の公開範囲を保つ" $ \db -> do
      response <- putJson db visibilityUrl (change "guest" "フォロワー限定")
      simpleStatus response `shouldBe` status403
      eitherDecode (simpleBody response) `shouldBe` Right (object ["reason" .= String "作者ではない"])

      viewing <- get db guestViewUrl
      simpleStatus viewing `shouldBe` status200

    it "同じ公開範囲を指定した作者には409と理由を返す" $ \db -> do
      response <- putJson db visibilityUrl (change "author" "全体公開")
      simpleStatus response `shouldBe` status409
      eitherDecode (simpleBody response) `shouldBe` Right (object ["reason" .= String "既にその公開範囲"])

    it "同じ変更が同時に届いたら、一方だけが成功する" $ \db -> do
      let restrict = putJson db visibilityUrl (change "author" "フォロワー限定")
      (first, second) <- concurrently restrict restrict
      sort [simpleStatus first, simpleStatus second] `shouldBe` [status200, status409]

    it "作者の変更は再初期化後も作品一覧と閲覧判定に反映される" $ \db -> do
      updated <- putJson db visibilityUrl (change "author" "フォロワー限定")
      simpleStatus updated `shouldBe` status200
      withStore db initialize

      listing <- get db "/stories"
      simpleStatus listing `shouldBe` status200
      let savedStory = object
            [ "id" .= String "public-free"
            , "authorId" .= String "author"
            , "visibility" .= String "フォロワー限定"
            , "price" .= String "無料"
            ]
      case eitherDecode (simpleBody listing) of
        Left message -> expectationFailure message
        Right stories -> stories `shouldContain` [savedStory]

      viewing <- get db guestViewUrl
      simpleStatus viewing `shouldBe` status403

visibilityUrl, guestViewUrl :: BS.ByteString
visibilityUrl = "/stories/public-free/visibility"
guestViewUrl = "/stories/public-free/view?viewer=guest"

invalidChanges :: [(String, LBS.ByteString)]
invalidChanges =
  [ ("JSONを解析できない", "{")
  , ("必須項目がない", "{}")
  , ("実行者IDが空白だけ", change " " "全体公開")
  , ("未定義の公開範囲", change "author" "作者限定")
  , ("公開範囲が数値", encode (object ["actor" .= String "author", "visibility" .= (99 :: Int)]))
  ]

change :: Text -> Text -> LBS.ByteString
change actor scope = encode (object ["actor" .= actor, "visibility" .= scope])

get :: FilePath -> BS.ByteString -> IO SResponse
get db url = runSession (request (setPath defaultRequest url)) (application db)

putJson :: FilePath -> BS.ByteString -> LBS.ByteString -> IO SResponse
putJson db url body = do
  let req = (setPath defaultRequest url)
        { requestMethod = methodPut
        , requestHeaders = [(hContentType, "application/json")]
        }
  runSession (srequest (SRequest req body)) (application db)
