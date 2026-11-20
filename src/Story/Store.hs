{-# LANGUAGE GADTs #-}
module Story.Store (withStore, initialize, listStories, viewStory, updateVisibility) where

import Control.Monad (when)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.SQLite.Simple
import Story.Decision
import Story.Domain
import Story.Labels

withStore :: FilePath -> (Connection -> IO a) -> IO a
withStore path action = withConnection path $ \db -> do
  execute_ db "PRAGMA busy_timeout = 5000"
  action db

initialize :: Connection -> IO ()
initialize db = withImmediateTransaction db $ do
  execute_ db "CREATE TABLE IF NOT EXISTS stories (id TEXT PRIMARY KEY NOT NULL, author TEXT NOT NULL, visibility TEXT NOT NULL, price TEXT NOT NULL)"
  execute_ db "CREATE TABLE IF NOT EXISTS follows (viewer TEXT NOT NULL, author TEXT NOT NULL, PRIMARY KEY (viewer, author))"
  execute_ db "CREATE TABLE IF NOT EXISTS vip_members (viewer TEXT PRIMARY KEY NOT NULL)"
  execute_ db "CREATE TABLE IF NOT EXISTS purchases (viewer TEXT NOT NULL, story TEXT NOT NULL, PRIMARY KEY (viewer, story))"
  existing <- query_ db "SELECT id FROM stories LIMIT 1" :: IO [Only Text]
  when (null existing) $ do
    let seeds = [ ("public-free", Public, Free), ("public-paid", Public, Paid)
                , ("followers-free", FollowersOnly, Free), ("followers-paid", FollowersOnly, Paid) ]
    executeMany db "INSERT INTO stories VALUES (?, 'author', ?, ?)"
      [(key :: Text, visibilityLabel scope, priceLabel fee) | (key, scope, fee) <- seeds]
    execute_ db "INSERT INTO follows VALUES ('follower','author'), ('vip','author'), ('buyer','author')"
    execute_ db "INSERT INTO vip_members VALUES ('vip')"
    execute_ db "INSERT INTO purchases VALUES ('buyer','public-paid'), ('buyer','followers-paid')"

decodeStory :: (Text, Text, Text, Text) -> IO Story
decodeStory (key, owner, scope, fee) =
  maybe (fail "Invalid story row in SQLite") pure $
    Story <$> storyId key <*> userId owner <*> parseVisibility scope <*> parsePrice fee

listStories :: Connection -> IO [Story]
listStories db = query_ db "SELECT id, author, visibility, price FROM stories ORDER BY id" >>= traverse decodeStory

load :: Connection -> StoryId -> IO (Maybe Story)
load db key = do
  rows <- query db "SELECT id, author, visibility, price FROM stories WHERE id = ?" (Only (storyIdText key))
  traverse decodeStory (listToMaybe rows)

-- Each request issues exactly one indexed existence query.
fetch :: Connection -> Fact a -> IO a
fetch db fact = case fact of
  Follows viewer owner -> do
    yes <- exists "SELECT 1 FROM follows WHERE viewer = ? AND author = ?" (userIdText viewer, userIdText owner)
    pure (if yes then Following else NotFollowing)
  Member viewer -> do
    yes <- exists "SELECT 1 FROM vip_members WHERE viewer = ?" (Only (userIdText viewer))
    pure (if yes then Vip else Standard)
  Purchased viewer key -> do
    yes <- exists "SELECT 1 FROM purchases WHERE viewer = ? AND story = ?" (userIdText viewer, storyIdText key)
    pure (if yes then Owned else NotOwned)
  where
    exists :: ToRow params => Query -> params -> IO Bool
    exists sql params = not . null <$> (query db sql params :: IO [Only Int])

viewStory :: Connection -> StoryId -> UserId -> IO (Maybe Report)
viewStory db key viewer = withTransaction db $ do
  stored <- load db key
  traverse (\story -> interpret (fetch db) (decide story viewer)) stored

updateVisibility :: Connection -> StoryId -> UserId -> Visibility -> IO (Maybe (Either ChangeError Story))
updateVisibility db key actor target = withImmediateTransaction db $ do
  stored <- load db key
  traverse apply stored
  where
    apply story = case changeVisibility actor target story of
      Left reason -> pure (Left reason)
      Right changed -> do
        execute db "UPDATE stories SET visibility = ? WHERE id = ?"
          (visibilityLabel (visibility changed), storyIdText key)
        pure (Right changed)
