{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module Lantern.Files (RegularFile, readFileChunk, seekFile, withFileBelow, pathFromTarget, directoryRedirect, probeConfinement) where
import Control.Exception (bracket, onException)
import Control.Monad (unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.C.Error (getErrno, eNOSYS, eMFILE, eNFILE, eISDIR, throwErrno)
import System.IO (SeekMode(AbsoluteSeek))
import qualified Data.ByteString.Internal as BI
import System.Posix.IO (closeFd, fdReadBuf, fdSeek)
import System.Posix.Files (FileStatus, getFdStatus)
import System.Posix.Types (Fd(..), FileOffset)
import Lantern.HTTP (failHTTP)

foreign import ccall safe "lantern_open" confinedOpen :: CString -> CString -> IO CInt

pathFromTarget :: B.ByteString -> Either String FilePath
pathFromTarget target = do
  let raw = C.takeWhile (/= '?') target
  decoded <- decode raw
  unless (not (B.null decoded) && B.head decoded == 47) $ Left "absolute path required"
  text <- either (const (Left "invalid UTF-8 path")) Right (TE.decodeUtf8' decoded)
  let parts = T.splitOn "/" text
  unless (all safe parts) $ Left "unsafe path component"
  let p = T.unpack (T.intercalate "/" (drop 1 parts))
  pure (if B.isSuffixOf "/" raw then p ++ "index.html" else p)
  where
    safe p = p /= "." && p /= ".." && not ("." `T.isPrefixOf` p) &&
      not (T.any (\c -> c < ' ' || c == '\DEL' || c == '\\' || c == '\0') p)
    decode b = B.pack <$> go (B.unpack b)
    go [] = Right []
    go (37:a:b:xs) = case (hex a,hex b) of
      (Just x,Just y) -> ((x*16+y):) <$> go xs
      _ -> Left "invalid percent escape"
    go (37:_) = Left "truncated percent escape"
    go (x:xs) = (x:) <$> go xs
    hex c | c >= 48 && c <= 57 = Just (c-48)
          | c >= 65 && c <= 70 = Just (c-55)
          | c >= 97 && c <= 102 = Just (c-87)
          | otherwise = Nothing

-- A directory redirect preserves the original escaped path/query. It must stay
-- an origin-relative URI, including if used independently of the HTTP parser.
directoryRedirect :: B.ByteString -> Maybe B.ByteString
directoryRedirect target
  | B.null path || B.take 1 path /= "/" || "//" `B.isPrefixOf` path || B.isSuffixOf "/" path = Nothing
  | not (B.all (\c -> c>32 && c<127 && c/=35 && c/=92) target) = Nothing
  | otherwise = Just (path<>"/"<>query)
  where (path,query)=C.break (=='?') target

-- Borrowed only within withFileBelow; no handle conversion or descriptor cache.
newtype RegularFile = RegularFile Fd

readFileChunk :: RegularFile -> Int -> IO B.ByteString
readFileChunk (RegularFile fd) count = do
  unless (count > 0 && count <= 65536) (failHTTP 500 "invalid file read bound")
  BI.createAndTrim count $ \buffer -> fromIntegral <$> fdReadBuf fd buffer (fromIntegral count)

seekFile :: RegularFile -> Integer -> IO ()
seekFile (RegularFile fd) offset = do
  let target = fromInteger offset :: FileOffset
  unless (offset >= 0 && fromIntegral target == offset) (failHTTP 500 "invalid file offset")
  _ <- fdSeek fd AbsoluteSeek target
  pure ()

-- Nothing means the confined open observed a directory, not a regular file.
-- The shim closes directory descriptors; Haskell brackets every regular FD.
withFileBelow :: FilePath -> FilePath -> (RegularFile -> FileStatus -> IO a) -> IO (Maybe a)
withFileBelow root relative action = bracket acquire (maybe (pure ()) (\(RegularFile fd,_) -> closeFd fd)) $
  maybe (pure Nothing) (\(h,status) -> Just <$> action h status)
  where
    acquire = withUTF8Path root $ \r -> withUTF8Path relative $ \p -> do
      raw <- confinedOpen r p
      if raw<0 then openFailure else do
        let fd=Fd raw
        status <- getFdStatus fd `onException` closeFd fd
        pure (Just (RegularFile fd,status))
    openFailure = do
      err <- getErrno
      if err==eISDIR then pure Nothing
        else if err == eMFILE || err == eNFILE then failHTTP 503 "file descriptor limit"
        else if err == eNOSYS then throwErrno "openat2 unavailable"
        else failHTTP 404 "file not found"

-- HTTP paths and Lanternfiles are UTF-8. Locale-dependent C-string conversion
-- can silently discard non-ASCII characters, changing a validated path.
withUTF8Path :: FilePath -> (CString -> IO a) -> IO a
withUTF8Path path action = do
  unless ('\0' `notElem` path) (ioError (userError "NUL in filesystem path"))
  B.useAsCString (TE.encodeUtf8 (T.pack path)) action

-- Fail before opening a public listener if the kernel lacks our required primitive.
probeConfinement :: IO ()
probeConfinement = withCString "/" $ \r -> withCString "dev/null" $ \p -> do
  fd <- confinedOpen r p
  if fd >= 0 then closeFd (Fd fd) else do
    err <- getErrno
    if err == eNOSYS then failHTTP 500 "openat2 unavailable: require Linux 5.6+ and a permitting syscall policy" else pure ()
