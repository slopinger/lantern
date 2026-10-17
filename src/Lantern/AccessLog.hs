{-# LANGUAGE OverloadedStrings #-}
-- Opt-in, bounded, best-effort access output. Request threads never wait for a sink.
module Lantern.AccessLog
  ( Logger, Event, withLogger, newEvent, request, responded, wrote, completed, finish ) where
import Control.Concurrent.MVar
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM
import Control.Exception (IOException, finally, try)
import Control.Monad (unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef
import qualified Data.Text as T
import Data.Time (getCurrentTime, formatTime, defaultTimeLocale)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.IO (stdout, hFlush)
import System.Timeout (timeout)
import Lantern.HTTP (Request(..))
import qualified Lantern.JSON as J

data Message = Line B.ByteString | Flush (MVar ())
newtype Logger = Logger (TBQueue Message)
data Event = Event Logger B.ByteString (IORef Word64) (IORef (Maybe (B.ByteString,B.ByteString,Maybe B.ByteString)))
  (IORef (Maybe Int)) (IORef Integer) (IORef Bool)

withLogger :: (Logger -> IO a) -> IO a
withLogger action = do
  queue <- newTBQueueIO 256
  let writer enabled = do
        message <- atomically (readTBQueue queue)
        case message of
          Flush done -> putMVar done () >> writer enabled
          Line bytes -> do
            result <- if enabled then try (B.hPut stdout bytes >> hFlush stdout) else pure (Right ())
            writer (enabled && either (const False) (const True) (result :: Either IOException ()))
      drain = do
        done <- newEmptyMVar
        _ <- timeout 1000000 (atomically (writeTBQueue queue (Flush done)) >> takeMVar done)
        pure ()
  withAsync (writer True) $ \_ -> action (Logger queue) `finally` drain

newEvent :: Logger -> B.ByteString -> IO Event
newEvent logger peer = Event logger peer <$> (getMonotonicTimeNSec >>= newIORef) <*>
  newIORef Nothing <*> newIORef Nothing <*> newIORef 0 <*> newIORef False

request :: Event -> Request -> Maybe B.ByteString -> IO ()
request (Event _ _ start info _ _ _) req host = do
  getMonotonicTimeNSec >>= writeIORef start
  writeIORef info (Just (reqMethod req,B.take 2048 (B.takeWhile (/=63) (reqTarget req)),host))
responded :: Event -> Int -> IO ()
responded (Event _ _ _ _ status _ _) = writeIORef status . Just
wrote :: Event -> Int -> IO ()
wrote (Event _ _ _ _ _ bytes _) count = modifyIORef' bytes (+ fromIntegral count)
completed :: Event -> IO ()
completed (Event _ _ _ _ _ _ done) = writeIORef done True

finish :: Event -> IO ()
finish (Event (Logger queue) peer start info status bytes done) = do
  details <- readIORef info
  code <- readIORef status
  -- Clean EOF between requests is not a request and produces no event.
  when (details /= Nothing || code /= Nothing) $ do
    end <- getMonotonicTimeNSec
    begin <- readIORef start
    count <- readIORef bytes
    complete <- readIORef done
    now <- getCurrentTime
    let string = J.String . T.pack . C.unpack
        (method,path,host) = maybe (J.Null,J.Null,J.Null) (\(m,p,h) -> (string m,string p,maybe J.Null string h)) details
        line = J.encode (J.object
          [("event",J.String "http_access"),("timestamp",J.String (T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" now))),
           ("remote_ip",string peer),("method",method),("host",host),("path",path),
           ("status",maybe J.Null (J.Number . show) code),("response_bytes",J.Number (show count)),
           ("duration_us",J.Number (show ((end-begin) `div` 1000))),("complete",J.Bool complete)]) <> "\n"
    B.length line `seq` atomically (do
      full <- isFullTBQueue queue
      unless full (writeTBQueue queue (Line line)))
