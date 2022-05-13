{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module TestCase.LogWarnNS.MetadataYesThreadContextNo
  ( testCase
  ) where

import Control.Monad.Logger.Aeson ((.@), Loc(..), LogLevel(..), LoggedMessage(..), Message(..), logWarnNS)
import Data.Aeson.QQ.Simple (aesonQQ)
import Data.Time (UTCTime(..))
import TestCase (TestCase(..))
import qualified Data.Time as Time

testCase :: FilePath -> TestCase
testCase logFilePath =
  TestCase
    { actionUnderTest = do
        logWarnNS "tests" $ "With metadata" :#
          [ "a" .@ (42 :: Int)
          , "b" .@ ("x" :: String)
          ]
    , logFilePath
    , expectedValue =
        [aesonQQ|
          {
            "time": "2022-05-07T20:03:54.0000000Z",
            "level": "warn",
            "location": {
              "package": "main",
              "module": "TestCase.LogWarnNS.MetadataYesThreadContextNo",
              "file": "test-suite/TestCase/LogWarnNS/MetadataYesThreadContextNo.hs",
              "line": 18,
              "char": 9
            },
            "source": "tests",
            "context": {
              "tid": "ThreadId 1"
            },
            "message": {
              "text": "With metadata",
              "meta": {
                "a": 42,
                "b": "x"
              }
            }
          }
        |]
    , expectedPatch =
        [aesonQQ|
          [
            { "op": "replace", "path": "/context/tid", "value": "ThreadId 1" },
            { "op": "replace", "path": "/time", "value": "2022-05-07T20:03:54.0000000Z" }
          ]
        |]
    , expectedLoggedMessage =
        LoggedMessage
          { loggedMessageTimestamp =
              UTCTime
                { utctDay = Time.fromGregorian 2022 05 07
                , utctDayTime = 72234
                }
          , loggedMessageLevel = LevelWarn
          , loggedMessageLoc =
              Just Loc
                { loc_package = "main"
                , loc_module = "TestCase.LogWarnNS.MetadataYesThreadContextNo"
                , loc_filename = "test-suite/TestCase/LogWarnNS/MetadataYesThreadContextNo.hs"
                , loc_start = (18, 9)
                , loc_end = (0, 0)
                }
          , loggedMessageLogSource = Just "tests"
          , loggedMessageThreadContext = ["tid" .@ ("ThreadId 1" :: String)]
          , loggedMessageMessage = "With metadata" :#
              [ "a" .@ (42 :: Int)
              , "b" .@ ("x" :: String)
              ]
          }
    }
