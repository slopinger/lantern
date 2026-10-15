{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lantern.Client (URL(..), parseURL, sameOrigin, request) where
import Control.Exception (try,SomeException,AsyncException,fromException,throwIO)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Network.Socket.ByteString (recv,sendAll)
import qualified Lantern.TLS as TLS
import Lantern.Config (Endpoint(..),parseEndpoint)
import Lantern.HTTP
import Lantern.Transport (withSocket,deadline)

data URL = URL { urlHost :: String, urlPort :: Int, urlTarget :: B.ByteString, urlOriginal :: B.ByteString } deriving (Eq,Show)
parseURL :: B.ByteString -> Either String URL
parseURL raw = do
  if not ("https://" `B.isPrefixOf` raw) || B.length raw > 8192 ||
     not (B.all (\c -> c > 32 && c < 127 && c /= 35 && c /= 92) raw)
    then Left "ACME URLs must be bounded ASCII HTTPS URLs" else pure ()
  let (authority,target)=C.break (== '/') (B.drop 8 raw)
      endpoint=if C.elem ':' authority then C.unpack authority else C.unpack authority++":443"
  Endpoint host port <- parseEndpoint endpoint
  pure (URL host port (if B.null target then "/" else target) raw)
sameOrigin :: URL -> URL -> Bool
sameOrigin a b=urlHost a==urlHost b && urlPort a==urlPort b

request :: TLS.TrustStore -> B.ByteString -> URL -> B.ByteString -> IO (Int,Headers,B.ByteString)
request trust method url body = deadline 30 504 $ withSocket (Endpoint (urlHost url) (urlPort url)) $ \socket -> do
  context <- TLS.connect trust (urlHost url) (recv socket 16384) (sendAll socket)
  let authority=C.pack (urlHost url ++ if urlPort url == 443 then "" else ":"++show (urlPort url))
      headers=[("host",authority),("connection","close"),("user-agent","lantern/0.1.0"),
        ("accept","application/json, application/pem-certificate-chain"),
        ("content-type","application/jose+json"),("content-length",C.pack (show (B.length body)))]
  TLS.send context (method<>" "<>urlTarget url<>" HTTP/1.1\r\n"<>
    B.concat [k<>": "<>v<>"\r\n" | (k,v)<-headers]<>"\r\n"<>body)
  reader <- newReader (TLS.receive context)
  response <- readResponse reader method
  bytes <- collectBody reader (resFraming response) 1048576
  closeResult <- try (TLS.close context)
  case closeResult of
    Left (e :: SomeException) -> case fromException e :: Maybe AsyncException of
      Just async -> throwIO async
      Nothing -> pure ()
    Right () -> pure ()
  -- The complete framed response is authenticated. Socket closure ends this
  -- one-shot exchange; no connection pool can inherit unread bytes.
  pure (resStatus response,resHeaders response,bytes)
