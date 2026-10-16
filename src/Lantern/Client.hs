{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lantern.Client (URL(..), parseURL, sameOrigin, request, authority) where
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
  let (hostPort,target)=C.break (\c -> c == '/' || c == '?') (B.drop 8 raw)
      endpoint=if B.isPrefixOf "[" hostPort
        then if B.isSuffixOf "]" hostPort then C.unpack hostPort++":443" else C.unpack hostPort
        else if C.elem ':' hostPort then C.unpack hostPort else C.unpack hostPort++":443"
  Endpoint host port <- parseEndpoint endpoint
  let path=if B.null target then "/" else if B.head target==63 then "/"<>target else target
  if validEscapes path then pure () else Left "invalid percent escape in HTTPS URL"
  pure (URL (C.unpack (lower (C.pack host))) port path raw)
  where
    validEscapes bytes=case B.uncons bytes of
      Nothing -> True
      Just (37,rest) -> B.length rest>=2 && B.all hex (B.take 2 rest) && validEscapes (B.drop 2 rest)
      Just (_,rest) -> validEscapes rest
    hex c=(c>=48 && c<=57)||(c>=65 && c<=70)||(c>=97 && c<=102)
sameOrigin :: URL -> URL -> Bool
sameOrigin a b=lower (C.pack (urlHost a))==lower (C.pack (urlHost b)) && urlPort a==urlPort b

-- Brackets belong to an IPv6 HTTP authority, but not the TLS reference name.
authority :: URL -> B.ByteString
authority url=C.pack (host ++ if urlPort url == 443 then "" else ":"++show (urlPort url))
  where host=if ':' `elem` urlHost url then "["++urlHost url++"]" else urlHost url

request :: TLS.TrustStore -> B.ByteString -> URL -> B.ByteString -> IO (Int,Headers,B.ByteString)
request trust method url body = deadline 30 504 $ withSocket (Endpoint (urlHost url) (urlPort url)) $ \socket -> do
  context <- TLS.connect trust (urlHost url) (recv socket 16384) (sendAll socket)
  let headers=[("host",authority url),("connection","close"),("user-agent","lantern/0.1.0"),
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
