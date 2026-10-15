{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lantern.Transport
  ( Transport(..), plainTransport, tlsTransport, loadCredentials, openListener
  , withUpstream, withSocket, deadline, peerIP
  ) where
import Control.Exception (bracket, bracketOnError, catch, IOException)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Network.Socket
import Numeric (showHex)
import qualified Network.Socket.ByteString as N
import qualified Lantern.TLS as TLS
import Lantern.TLS (Credentials)
import System.Timeout (timeout)
import Lantern.Config (Endpoint(..))
import Lantern.HTTP (failHTTP)

data Transport = Transport { receive :: IO B.ByteString, transmit :: B.ByteString -> IO (), finish :: IO () }
plainTransport :: Socket -> Transport
plainTransport s = Transport (N.recv s 16384) (N.sendAll s) (pure ())

loadCredentials :: FilePath -> FilePath -> IO Credentials
loadCredentials = TLS.loadCredentials

tlsTransport :: IO Credentials -> Socket -> IO Transport
tlsTransport ref s = do
  creds <- ref
  context <- TLS.accept creds ["http/1.1"] (N.recv s 16384) (N.sendAll s)
  pure (Transport (TLS.receive context) (TLS.send context) (deadline 1 408 (TLS.close context)))

openListener :: Endpoint -> IO Socket
openListener (Endpoint host port) = do
  addresses <- getAddrInfo (Just defaultHints
    {addrFlags=[AI_NUMERICHOST,AI_NUMERICSERV],addrSocketType=Stream}) (Just host) (Just (show port))
  case addresses of
    [] -> fail "no listener address"
    a:_ -> bracketOnError (socket (addrFamily a) Stream defaultProtocol) close $ \s -> do
      setSocketOption s ReuseAddr 1
      if addrFamily a == AF_INET6 then setSocketOption s IPv6Only 0 else pure ()
      bind s (addrAddress a)
      listen s 256
      pure s

withUpstream :: Endpoint -> (Transport -> IO a) -> IO a
withUpstream endpoint action = withSocket endpoint (action . plainTransport)

withSocket :: Endpoint -> (Socket -> IO a) -> IO a
withSocket (Endpoint host port) action = do
  addresses <- deadline 5 504 $ getAddrInfo (Just defaultHints {addrSocketType=Stream}) (Just host) (Just (show port))
  -- Try resolved addresses only while connecting; never retry an HTTP request.
  bracket (deadline 5 504 (connectAny (take 16 addresses))) close action
  where
    connectAny [] = failHTTP 502 "all upstream addresses failed"
    connectAny (a:as) = (bracketOnError (socket (addrFamily a) Stream defaultProtocol) close $ \s -> do
      setSocketOption s NoDelay 1
      connect s (addrAddress a)
      pure s) `catch` \(_ :: IOException) -> connectAny as

deadline :: Int -> Int -> IO a -> IO a
deadline seconds code action = do
  result <- timeout (seconds * 1000000) action
  maybe (failHTTP code "deadline exceeded") pure result

peerIP :: SockAddr -> B.ByteString
peerIP (SockAddrInet _ a) = let (x,y,z,w)=hostAddressToTuple a in
  C.pack (show x ++ "." ++ show y ++ "." ++ show z ++ "." ++ show w)
peerIP (SockAddrInet6 _ _ a _) = let (a1,a2,a3,a4,a5,a6,a7,a8)=hostAddress6ToTuple a in
  C.pack (concatWith ":" (map (\w -> showHex w "") [a1,a2,a3,a4,a5,a6,a7,a8]))
  where concatWith _ [] = ""
        concatWith _ [x] = x
        concatWith sep (x:xs) = x ++ sep ++ concatWith sep xs
peerIP _ = "unknown"
