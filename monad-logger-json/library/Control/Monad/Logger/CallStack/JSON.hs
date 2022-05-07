{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}
module Control.Monad.Logger.CallStack.JSON
  ( Message(..)

  , logDebug
  , logInfo
  , logWarn
  , logError
  , logOther
  , logDebugCS
  , logInfoCS
  , logWarnCS
  , logErrorCS
  , logOtherCS
  , logDebugNS
  , logInfoNS
  , logWarnNS
  , logErrorNS
  , logOtherNS

  , withThreadContext

  , runFileLoggingT
  , runStdoutLoggingT
  , runStderrLoggingT
  , defaultOutput

  , module Log
  ) where

-- N.B. This import is not grouped with the others as this makes it easier to
-- cross-reference with this module's exports.
import Control.Monad.Logger as Log hiding
  ( logDebug
  , logInfo
  , logWarn
  , logError
  , logOther
  , logDebugCS
  , logInfoCS
  , logWarnCS
  , logErrorCS
  , logOtherCS
  , logDebugNS
  , logInfoNS
  , logWarnNS
  , logErrorNS
  , logOtherNS
  , runFileLoggingT
  , runStderrLoggingT
  , runStdoutLoggingT
  , defaultOutput
  , defaultLogStr
  )

import Context (Store)
import Control.Exception.Lifted (bracket)
import Control.Monad.Base (MonadBase(liftBase))
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Control (MonadBaseControl(..))
import Data.Aeson (KeyValue((.=)), Encoding, Value)
import Data.Aeson.Encoding.Internal (Series(..), (><))
import Data.Aeson.Types (Pair)
import Data.ByteString.Char8 (ByteString)
import Data.HashMap.Strict (HashMap)
import Data.String (IsString)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Stack (SrcLoc(..), CallStack, HasCallStack, callStack, getCallStack)
import System.IO
  ( BufferMode(LineBuffering), IOMode(AppendMode), Handle, hClose, hSetBuffering, openFile, stderr
  , stdout
  )
import System.Log.FastLogger.Internal (LogStr(..))
import qualified Context
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encoding as Aeson
import qualified Data.Aeson.Encoding.Internal as Aeson.Internal
import qualified Data.ByteString.Builder as ByteString.Builder
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.ByteString.Lazy as ByteString.Lazy
import qualified Data.ByteString.Lazy.Char8 as ByteString.Lazy.Char8
import qualified Data.Char as Char
import qualified Data.HashMap.Strict as HashMap
import qualified Data.String as String
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import qualified Data.Text.Encoding.Error as Text.Encoding.Error
import qualified Data.Time as Time
import qualified System.IO.Unsafe as IO.Unsafe

#if MIN_VERSION_aeson(2, 0, 0)
import Data.Aeson.Key (Key)
#else
type Key = Text
#endif

-- | Logs a message with the location provided by an implicit 'CallStack'.
--
-- @since 0.1.0.0
logDebug :: (HasCallStack, MonadLogger m) => Message -> m ()
logDebug = logDebugCS callStack

-- | See 'logDebug'
--
-- @since 0.1.0.0
logInfo :: (HasCallStack, MonadLogger m) => Message -> m ()
logInfo = logInfoCS callStack

-- | See 'logDebug'
--
-- @since 0.1.0.0
logWarn :: (HasCallStack, MonadLogger m) => Message -> m ()
logWarn = logWarnCS callStack

-- | See 'logDebug'
--
-- @since 0.1.0.0
logError :: (HasCallStack, MonadLogger m) => Message -> m ()
logError = logErrorCS callStack

-- | See 'logDebug'
--
-- @since 0.1.0.0
logOther :: (HasCallStack, MonadLogger m) => LogLevel -> Message -> m ()
logOther = logOtherCS callStack

-- | Logs a message with location given by 'CallStack'.
--
-- @since 0.1.0.0
logDebugCS :: MonadLogger m => CallStack -> Message -> m ()
logDebugCS cs msg = logCS cs "" LevelDebug msg

-- | See 'logDebugCS'
--
-- @since 0.1.0.0
logInfoCS :: MonadLogger m => CallStack -> Message -> m ()
logInfoCS cs msg = logCS cs "" LevelInfo msg

-- | See 'logDebugCS'
--
-- @since 0.1.0.0
logWarnCS :: MonadLogger m => CallStack -> Message -> m ()
logWarnCS cs msg = logCS cs "" LevelWarn msg

-- | See 'logDebugCS'
--
-- @since 0.1.0.0
logOtherCS :: MonadLogger m => CallStack -> LogLevel -> Message -> m ()
logOtherCS cs lvl msg = logCS cs "" lvl msg

-- | See 'logDebugCS'
--
-- @since 0.1.0.0
logErrorCS :: MonadLogger m => CallStack -> Message -> m ()
logErrorCS cs msg = logCS cs "" LevelError msg

-- | Note that the @monad-logger@ version does not log location info. This
-- @monad-logger-json@ version logs location info via call stack.
logDebugNS :: (HasCallStack, MonadLogger m) => LogSource -> Message -> m ()
logDebugNS src = logCS callStack src LevelDebug

-- | Note that the @monad-logger@ version does not log location info. This
-- @monad-logger-json@ version logs location info via call stack.
logInfoNS :: (HasCallStack, MonadLogger m) => LogSource -> Message -> m ()
logInfoNS src = logCS callStack src LevelInfo

-- | Note that the @monad-logger@ version does not log location info. This
-- @monad-logger-json@ version logs location info via call stack.
logWarnNS :: (HasCallStack, MonadLogger m) => LogSource -> Message -> m ()
logWarnNS src = logCS callStack src LevelWarn

-- | Note that the @monad-logger@ version does not log location info. This
-- @monad-logger-json@ version logs location info via call stack.
logErrorNS :: (HasCallStack, MonadLogger m) => LogSource -> Message -> m ()
logErrorNS src = logCS callStack src LevelError

-- | Note that the @monad-logger@ version does not log location info. This
-- @monad-logger-json@ version logs location info via call stack.
logOtherNS :: (HasCallStack, MonadLogger m) => LogSource -> LogLevel -> Message -> m ()
logOtherNS = logCS callStack

-- | Sneakiness ensues.
logCS :: (MonadLogger m)
      => CallStack
      -> LogSource
      -> LogLevel
      -> Message
      -> m ()
logCS cs src lvl msg =
  monadLoggerLog (locFromCS cs) src lvl $ xonCharLogStr <> messageToLogStr msg

xonCharLogStr :: LogStr
xonCharLogStr = toLogStr $ ByteString.Lazy.Char8.singleton $ xonChar

xonChar :: Char
xonChar = Char.chr 17

-- | Not exported from 'monad-logger', so copied here.
mkLoggerLoc :: SrcLoc -> Loc
mkLoggerLoc loc =
  Loc { loc_filename = srcLocFile loc
      , loc_package  = srcLocPackage loc
      , loc_module   = srcLocModule loc
      , loc_start    = ( srcLocStartLine loc
                       , srcLocStartCol loc)
      , loc_end      = ( srcLocEndLine loc
                       , srcLocEndCol loc)
      }

-- | Not exported from 'monad-logger', so copied here.
locFromCS :: CallStack -> Loc
locFromCS cs = case getCallStack cs of
                 ((_, loc):_) -> mkLoggerLoc loc
                 _            -> defaultLoc

data LogItem = LogItem
  { logItemTimestamp :: UTCTime
  , logItemLoc :: Loc
  , logItemLogSource :: LogSource
  , logItemLevel :: LogLevel
  , logItemMessageEncoding :: Encoding
  }

logItemEncoding :: LogItem -> Encoding
logItemEncoding logItem =
  Aeson.pairs $
    (Aeson.pairStr "time" $ Aeson.toEncoding logItemTimestamp)
      <> (Aeson.pairStr "level" $ levelEncoding logItemLevel)
      <> ( if isDefaultLoc logItemLoc then
             mempty
           else
             Aeson.pairStr "location" $ locEncoding logItemLoc
         )
      <> ( if Text.null logItemLogSource then
             mempty
           else
             Aeson.pairStr "source" $ Aeson.toEncoding logItemLogSource
         )
      <> (Aeson.pairStr "message" logItemMessageEncoding)
  where
  LogItem
    { logItemTimestamp
    , logItemLoc
    , logItemLogSource
    , logItemLevel
    , logItemMessageEncoding
    } = logItem

-- | A 'Message' captures a textual component and a metadata component. The
-- metadata component is a list of 'Pair' to support tacking on arbitrary
-- structured data to a log message.
--
-- With the @OverloadedStrings@ extension enabled, 'Message' values can be
-- constructed without metadata fairly conveniently, just as if we were using
-- 'Text' directly:
--
-- > logDebug "Some log message without metadata"
--
-- Metadata may be included in a 'Message' via the ':#' constructor:
--
-- > logDebug $ "Some log message with metadata" :#
-- >   [ "bloorp" .= (42 :: Int)
-- >   , "bonk" .= ("abc" :: Text)
-- >   ]
--
-- The mneomic for the ':#' constructor is that the @#@ symbol is sometimes
-- referred to as a hash, a JSON object can be thought of as a hash map, and
-- so with @:#@ (and enough squinting), we are @cons@-ing a textual message onto
-- a JSON object. Yes, this mnemonic isn't well-typed, but hopefully it still
-- helps!
data Message = Text :# [Pair]
infixr 5 :#

messageToLogStr :: Message -> LogStr
messageToLogStr = toLogStr . Aeson.encodingToLazyByteString . unsafeMessageEncoding

instance IsString Message where
  fromString string = Text.pack string :# []

-- This is "unsafe" because the encoding here is just a comma-separated
-- list of fields. It is not yet wrapped in curly braces.
unsafeMessageEncoding :: Message -> Encoding
unsafeMessageEncoding  = unsafeRetagSeries . messageSeries

finalizeMessageEncoding :: [Pair] -> Encoding -> Encoding
finalizeMessageEncoding threadContext messageEnc =
  Aeson.Internal.openCurly
    >< messageEnc
    >< ( if null threadContext then
           Aeson.Internal.empty
         else
           Aeson.Internal.comma >< unsafeRetagSeries
             ( Aeson.pairStr "context" $ messageMetaEncoding threadContext
             )
       )
    >< Aeson.Internal.closeCurly

unsafeRetagSeries :: Series -> Encoding
unsafeRetagSeries = \case
  Value seriesEncoding -> Aeson.Internal.retagEncoding seriesEncoding
  Empty -> bug "unsafeRetagSeries"

messageSeries :: Message -> Series
messageSeries message =
  "text" .= messageText
    <> ( if null messageMeta then
           mempty
         else
           Aeson.pairStr "meta" $ messageMetaEncoding messageMeta
       )
  where
  messageText :# messageMeta = message

messageMetaEncoding :: [Pair] -> Encoding
messageMetaEncoding = Aeson.pairs . messageMetaSeries

messageMetaSeries :: [Pair] -> Series
messageMetaSeries = mconcat . fmap (uncurry (.=))

levelEncoding :: LogLevel -> Encoding
levelEncoding = Aeson.text . \case
  LevelDebug -> "debug"
  LevelInfo -> "info"
  LevelWarn -> "warn"
  LevelError -> "error"
  LevelOther t -> t

locEncoding :: Loc -> Encoding
locEncoding loc =
  Aeson.pairs $
    (Aeson.pairStr "package" $ Aeson.string loc_package)
      <> (Aeson.pairStr "module" $ Aeson.string loc_module)
      <> (Aeson.pairStr "file" $ Aeson.string loc_filename)
      <> (Aeson.pairStr "line" $ Aeson.int $ fst loc_start)
      <> (Aeson.pairStr "char" $ Aeson.int $ snd loc_start)
  where
  Loc { loc_filename, loc_package, loc_module, loc_start } = loc

defaultOutput
  :: Handle
  -> Loc
  -> LogSource
  -> LogLevel
  -> LogStr
  -> IO ()
defaultOutput h loc src level msg = do
  now <- Time.getCurrentTime
  threadContext <- Context.mines messageMetaStore HashMap.toList
  ByteString.Char8.hPutStrLn h
    $ defaultLogStrBS now threadContext loc src level msg

defaultLogStrBS
  :: UTCTime
  -> [Pair]
  -> Loc
  -> LogSource
  -> LogLevel
  -> LogStr
  -> ByteString
defaultLogStrBS now threadContext loc logSource logLevel logStr =
  ByteString.Lazy.toStrict
    $ Aeson.encodingToLazyByteString
    $ logItemEncoding logItem
  where
  logItem :: LogItem
  logItem =
    case ByteString.Lazy.Char8.uncons logStrLBS of
      Nothing ->
        mkLogItem
          $ unsafeMessageEncoding
          $ Text.empty :# []
      Just (c, lbs) ->
        -- If the first character of the log string is a XON byte, then we
        -- assume the log string (minus the XON byte) is an encoded 'Message'.
        if c == xonChar then
          mkLogItem
            $ Aeson.unsafeToEncoding
            $ ByteString.Builder.lazyByteString lbs
        -- Otherwise, we make no assumptions of the log string. We simply decode
        -- to text and use this text in a metadata-less 'Message'.
        else
          mkLogItem
            $ unsafeMessageEncoding
            $ decodeLenient logStrLBS :# []

  mkLogItem :: Encoding -> LogItem
  mkLogItem messageEnc =
    LogItem
      { logItemTimestamp = now
      , logItemLoc = loc
      , logItemLogSource = logSource
      , logItemLevel = logLevel
      , logItemMessageEncoding = finalizeMessageEncoding threadContext messageEnc
      }

  decodeLenient =
    Text.Encoding.decodeUtf8With Text.Encoding.Error.lenientDecode
      . ByteString.Lazy.toStrict

  logStrLBS = ByteString.Builder.toLazyByteString logStrBuilder
  LogStr _ logStrBuilder = logStr

-- | Run a block using a @MonadLogger@ instance which appends to the specified
-- file.
--
-- @since 0.1.0.0
runFileLoggingT :: (MonadBaseControl IO m) => FilePath -> LoggingT m a -> m a
runFileLoggingT fp logt =
  bracket (liftBase $ openFile fp AppendMode) (liftBase . hClose) \h -> do
    liftBase $ hSetBuffering h LineBuffering
    runLoggingT logt $ defaultOutput h

-- | Run a block using a @MonadLogger@ instance which prints to stderr.
--
-- @since 0.1.0.0
runStderrLoggingT :: LoggingT m a -> m a
runStderrLoggingT = (`runLoggingT` defaultOutput stderr)

-- | Run a block using a @MonadLogger@ instance which prints to stdout.
--
-- @since 0.1.0.0
runStdoutLoggingT :: LoggingT m a -> m a
runStdoutLoggingT = (`runLoggingT` defaultOutput stdout)

isDefaultLoc :: Loc -> Bool
isDefaultLoc (Loc "<unknown>" "<unknown>" "<unknown>" (0,0) (0,0)) = True
isDefaultLoc _ = False

withThreadContext :: (MonadIO m, MonadMask m) => [Pair] -> m a -> m a
withThreadContext pairs =
  Context.adjust messageMetaStore \pairsMap ->
    HashMap.union (HashMap.fromList pairs) pairsMap

messageMetaStore :: Store (HashMap Key Value)
messageMetaStore =
  IO.Unsafe.unsafePerformIO
    $ Context.newStore Context.defaultPropagation
    $ Just
    $ HashMap.empty
{-# NOINLINE messageMetaStore #-}

bug :: HasCallStack => String -> a
bug detail =
  error $
    "Control.Monad.Logger.CallStack.JSON: " <> detail <>" (if you see this "
      <> "message, please  report it as a bug at "
      <> "https://github.com/jship/monad-logger-json)"
