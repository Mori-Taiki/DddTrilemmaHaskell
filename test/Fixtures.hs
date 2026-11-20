module Fixtures (testUserId, testStoryId, withDatabase) where

import Data.Text (Text)
import qualified Data.Text as T
import Story.Domain (StoryId, UserId, storyId, userId)
import Story.Store (initialize, withStore)
import System.IO.Temp (withSystemTempDirectory)

testUserId :: Text -> UserId
testUserId value = case userId value of
  Just valid -> valid
  Nothing -> error ("Invalid user ID in test fixture: " ++ show (T.unpack value))

testStoryId :: Text -> StoryId
testStoryId value = case storyId value of
  Just valid -> valid
  Nothing -> error ("Invalid story ID in test fixture: " ++ show (T.unpack value))

withDatabase :: (FilePath -> IO a) -> IO a
withDatabase action = withSystemTempDirectory "story-test" $ \directory -> do
  let database = directory ++ "/story.db"
  withStore database initialize
  action database
