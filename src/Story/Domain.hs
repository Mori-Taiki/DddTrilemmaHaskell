module Story.Domain
  ( UserId, userId, userIdText, StoryId, storyId, storyIdText
  , Visibility(..), Price(..), Story(..), ChangeError(..), changeVisibility
  ) where

import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T

newtype UserId = UserId Text deriving (Eq, Show)
newtype StoryId = StoryId Text deriving (Eq, Show)

userId :: Text -> Maybe UserId
userId = fmap UserId . nonBlank

storyId :: Text -> Maybe StoryId
storyId = fmap StoryId . nonBlank

nonBlank :: Text -> Maybe Text
nonBlank value
  | T.all isSpace value = Nothing
  | otherwise = Just value

userIdText :: UserId -> Text
userIdText (UserId value) = value

storyIdText :: StoryId -> Text
storyIdText (StoryId value) = value

data Visibility = Public | FollowersOnly deriving (Eq, Show)
data Price = Free | Paid deriving (Eq, Show)

data Story = Story
  { identifier :: StoryId
  , author :: UserId
  , visibility :: Visibility
  , price :: Price
  } deriving (Eq, Show)

data ChangeError = NotAuthor | AlreadySet deriving (Eq, Show)

changeVisibility :: UserId -> Visibility -> Story -> Either ChangeError Story
changeVisibility actor target story
  | actor /= author story = Left NotAuthor
  | target == visibility story = Left AlreadySet
  | otherwise = Right story { visibility = target }
