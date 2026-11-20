module Story.Http (application) where

import Data.Aeson (Value(String), decode, encode, object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8')
import Network.HTTP.Types
import Network.Wai
import Story.Decision
import Story.Domain
import Story.Labels
import Story.Store

application :: FilePath -> Application
application path req respond = route >>= respond
  where
    route = case (requestMethod req, pathInfo req) of
      ("GET", ["stories"]) -> withStore path $ \db ->
        json status200 . toJSON . map storyJson <$> listStories db
      ("GET", ["stories", key, "view"]) -> case (storyId key, viewer) of
        (Just sid, Just uid) -> withStore path $ \db ->
          maybe missing viewResponse <$> viewStory db sid uid
        _ -> pure (bad "viewer is required")
      ("PUT", ["stories", key, "visibility"]) -> do
        body <- strictRequestBody req
        case (storyId key, decode body >>= parseMaybe changeRequest) of
          (Just sid, Just (actor, target)) -> withStore path $ \db ->
            maybe missing changeResponse <$> updateVisibility db sid actor target
          _ -> pure (bad "actor and valid visibility are required")
      _ -> pure missing
    viewer = do
      Just bytes <- lookup "viewer" (queryString req)
      raw <- either (const Nothing) Just (decodeUtf8' bytes)
      userId raw
    changeRequest = withObject "visibility change" $ \obj -> do
      rawActor <- obj .: "actor"
      rawScope <- obj .: "visibility"
      actor <- maybe (fail "invalid actor") pure (userId rawActor)
      scope <- maybe (fail "invalid visibility") pure (parseVisibility rawScope)
      pure (actor, scope)

missing :: Response
missing = responseLBS status404 [] ""

json :: Status -> Value -> Response
json status value = responseLBS status [(hContentType, "application/json; charset=utf-8")] (encode value)

bad :: Text -> Response
bad detail = json status400 (object ["error" .= detail])

storyJson :: Story -> Value
storyJson story = object
  [ "id" .= storyIdText (identifier story), "authorId" .= userIdText (author story)
  , "visibility" .= visibilityLabel (visibility story), "price" .= priceLabel (price story) ]

viewResponse :: Report -> Response
viewResponse (Report result path) = json status $ object
  [ "allowed" .= allowed, "reason" .= reason, "trace" .= (map label path ++ [end])
  , "factQueries" .= length path ]
  where
    (status, allowed, reason, end) = case result of
      Allow -> (status200, True, Nothing, "許可")
      Deny why -> (status403, False, Just (denialLabel why), "拒否")
    denialLabel :: Denial -> Text
    denialLabel FollowRequired = "フォローが必要"
    denialLabel PurchaseRequired = "購入が必要"
    label :: Check -> Text
    label CheckFollow = "フォロー確認が必要"
    label CheckMembership = "会員確認が必要"
    label CheckPurchase = "購入確認が必要"

changeResponse :: Either ChangeError Story -> Response
changeResponse (Left NotAuthor) = json status403 (object ["reason" .= String "作者ではない"])
changeResponse (Left AlreadySet) = json status409 (object ["reason" .= String "既にその公開範囲"])
changeResponse (Right story) = json status200 $ object
  ["id" .= storyIdText (identifier story), "visibility" .= visibilityLabel (visibility story)]
