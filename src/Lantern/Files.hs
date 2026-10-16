{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module Lantern.Files (withFileBelow, pathFromTarget, probeConfinement) where
import Control.Exception (bracket, onException)
import Control.Monad (unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.C.Error (getErrno, eNOSYS, eMFILE, eNFILE, throwErrno)
import System.IO (Handle, hClose, hSetBinaryMode)
import System.Posix.IO (fdToHandle, closeFd)
import System.Posix.Files (FileStatus, getFdStatus)
import System.Posix.Types (Fd(..))
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
  pure (if null p || last p == '/' then p ++ "index.html" else p)
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

withFileBelow :: FilePath -> FilePath -> (Handle -> FileStatus -> IO a) -> IO a
withFileBelow root relative action = bracket acquire (hClose . fst) (uncurry action)
  where
    acquire = withCString root $ \r -> withCString relative $ \p -> do
      raw <- confinedOpen r p
      whenInvalid raw
      let fd=Fd raw
      status <- getFdStatus fd `onException` closeFd fd
      h <- fdToHandle fd `onException` closeFd fd
      hSetBinaryMode h True `onException` hClose h
      pure (h,status)
    whenInvalid raw = if raw >= 0 then pure () else do
      err <- getErrno
      if err == eMFILE || err == eNFILE then failHTTP 503 "file descriptor limit"
        else if err == eNOSYS then throwErrno "openat2 unavailable"
        else failHTTP 404 "file not found"

-- Fail before opening a public listener if the kernel lacks our required primitive.
probeConfinement :: IO ()
probeConfinement = withCString "/" $ \r -> withCString "dev/null" $ \p -> do
  fd <- confinedOpen r p
  if fd >= 0 then closeFd (Fd fd) else do
    err <- getErrno
    if err == eNOSYS then failHTTP 500 "Linux openat2 support is required" else pure ()
