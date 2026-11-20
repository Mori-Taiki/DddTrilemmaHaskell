module Main (main) where

import qualified DomainSpec
import qualified HttpSpec
import qualified StoreSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  DomainSpec.spec
  StoreSpec.spec
  HttpSpec.spec
