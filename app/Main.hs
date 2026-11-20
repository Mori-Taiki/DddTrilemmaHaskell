module Main (main) where

import Network.Wai.Handler.Warp (run)
import Story.Http (application)
import Story.Store (initialize, withStore)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  path <- case args of
    [] -> pure "app.db"
    [file] -> pure file
    _ -> die "usage: story-api [database-file]"
  withStore path initialize
  putStrLn ("http://localhost:5080 (SQLite: " ++ path ++ ")")
  run 5080 (application path)
