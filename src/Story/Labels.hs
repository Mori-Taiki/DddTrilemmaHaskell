module Story.Labels where

import Data.Text (Text)
import Story.Domain

visibilityLabel :: Visibility -> Text
visibilityLabel Public = "全体公開"
visibilityLabel FollowersOnly = "フォロワー限定"

parseVisibility :: Text -> Maybe Visibility
parseVisibility "全体公開" = Just Public
parseVisibility "フォロワー限定" = Just FollowersOnly
parseVisibility _ = Nothing

priceLabel :: Price -> Text
priceLabel Free = "無料"
priceLabel Paid = "有料"

parsePrice :: Text -> Maybe Price
parsePrice "無料" = Just Free
parsePrice "有料" = Just Paid
parsePrice _ = Nothing
