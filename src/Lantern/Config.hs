{-# LANGUAGE OverloadedStrings #-}
module Lantern.Config
  ( Config(..), Site(..), Action(..), TLSMode(..), Endpoint(..), Upstream(..)
  , loadConfig, parseConfig, parseEndpoint, hostName, immutable
  ) where
import GHC.IO.Encoding (setFileSystemEncoding, utf8)
import Control.Monad (unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Char (isAscii, isAlphaNum, toLower)
import Data.List (nub)
import Data.IP (IPv6)
import Text.Read (readMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (canonicalizePath, doesDirectoryExist, makeAbsolute)
import System.FilePath ((</>), isAbsolute, takeDirectory)
import System.IO (withBinaryFile, IOMode(ReadMode))
import qualified Network.Socket as N
import Text.Parsec hiding (lower, labels)
import Text.Parsec.String (Parser)
import Lantern.HTTP (validToken, lower)

data Endpoint = Endpoint { endpointHost :: String, endpointPort :: Int } deriving (Eq, Show)
data TLSMode = Plain | Manual FilePath FilePath | Automatic String FilePath deriving (Eq, Show)
data Upstream = HTTP Endpoint | HTTPS Endpoint deriving (Eq, Show)
data Action = Root FilePath | Proxy Upstream | Respond B.ByteString | Redirect B.ByteString deriving (Eq, Show)
data Site = Site { siteHost :: B.ByteString, siteAction :: Action, siteHeaders :: [(B.ByteString,B.ByteString)] } deriving (Eq, Show)
data Config = Config
  { listen :: Endpoint, tlsMode :: TLSMode, sites :: [Site]
  , maxConnections :: Int, headerSeconds :: Int, bodySeconds :: Int
  , writeSeconds :: Int, bodyLimit :: Integer
  , acmeCA :: B.ByteString, acmeHTTPPort :: Int, acmeTrust :: Maybe FilePath, proxyTrust :: Maybe FilePath
  } deriving (Eq, Show)

data Entry = Listen String | TLS String String | Auto String String
  | Connections Int | HeaderTime Int | BodyTime Int | WriteTime Int | BodyLimit Int
  | CA String | HTTPPort Int | Trust String | ProxyTrust String | Virtual Site deriving Show

spaceP :: Parser ()
spaceP = skipMany (skipMany1 (oneOf " \t\r\n") <|> (char '#' *> skipMany (noneOf "\n")))
word :: Parser String
word = (quoted <|> many1 (noneOf " \t\r\n{}#\"")) <* spaceP
  where quoted = char '"' *> many (escaped <|> noneOf "\"\\\r\n") <* char '"'
        escaped = char '\\' *> oneOf "\"\\"
symbol :: String -> Parser ()
symbol s = string s *> spaceP
number :: Parser Int
number = do
  s <- word
  case reads s of [(n,"")] | n > 0 && n <= 1073741824 -> pure n
                  _ -> fail "expected a positive integer <= 1073741824"
entry :: Parser Entry
entry = do
  key <- word
  case key of
    "listen" -> Listen <$> word
    "tls" -> TLS <$> word <*> word
    "auto_https" -> Auto <$> word <*> word
    "max_connections" -> Connections <$> number
    "header_timeout" -> HeaderTime <$> number
    "body_timeout" -> BodyTime <$> number
    "write_timeout" -> WriteTime <$> number
    "body_limit" -> BodyLimit <$> number
    "acme_ca" -> CA <$> word
    "acme_http_port" -> HTTPPort <$> number
    "acme_ca_bundle" -> Trust <$> word
    "proxy_ca_bundle" -> ProxyTrust <$> word
    "site" -> do
      name <- word
      unless (all isAscii name) (fail "site names must use ASCII DNS A-labels")
      symbol "{"
      directives <- many directive
      symbol "}"
      let acts = [a | Left a <- directives]
          hs = [h | Right h <- directives]
      case acts of
        [a] -> pure (Virtual (Site (C.pack (map toLower name)) a hs))
        _ -> fail "each site needs exactly one root, reverse_proxy, respond, or redirect"
    _ -> fail ("unknown directive: " ++ key)
  where
    directive = do
      notFollowedBy (char '}')
      key <- word
      case key of
        "root" -> Left . Root <$> word
        "reverse_proxy" -> do
          url <- word
          case upstream url of
            Left e -> fail e
            Right ep -> pure (Left (Proxy ep))
        "respond" -> Left . Respond . TE.encodeUtf8 . T.pack <$> word
        "redirect" -> Left . Redirect . C.pack <$> word
        "header" -> do
          k <- word; v <- word
          pure (Right (lower (C.pack k),TE.encodeUtf8 (T.pack v)))
        _ -> fail ("unknown site directive: " ++ key)
    upstream s
      | take 7 s == "http://" = HTTP <$> parseEndpoint (drop 7 s)
      | take 8 s == "https://" = HTTPS <$> parseEndpoint (drop 8 s)
      | otherwise = Left "upstreams must be explicit HTTP(S) host:port endpoints (no paths or credentials)"

parseEndpoint :: String -> Either String Endpoint
parseEndpoint s = do
  (host,port) <- case s of
    '[':rest -> case break (== ']') rest of
      (h,']':':':p) | length h <= 45, Just _ <- (readMaybe h :: Maybe IPv6) -> Right (h,p)
      _ -> Left "invalid bracketed IPv6 endpoint"
    _ -> case break (== ':') s of
      (h,':':p) | ':' `notElem` h -> Right (h,p)
      _ -> Left "endpoint must be host:port (IPv6: [address]:port)"
  unless (not (null host) && all (\c -> isAscii c && (isAlphaNum c || c `elem` (".-:" :: String))) host) $
    Left "invalid endpoint host"
  unless (':' `elem` host) $
    either (const (Left "invalid endpoint host (use DNS A-labels or bracketed IPv6)"))
      (const (Right ())) (hostName (C.pack host))
  case reads port of
    [(n,"")] | n >= 1 && n <= 65535 && all (`elem` ['0'..'9']) port -> Right (Endpoint host n)
    _ -> Left "port must be 1..65535"

-- DNS A-labels only, explicit IP literals permitted for local sites.
hostName :: B.ByteString -> Either String B.ByteString
hostName raw = do
  let s = C.unpack (lower raw)
      labels = split '.' s
  unless (length s <= 253 && not (null s) && all valid labels) $ Left "invalid site hostname (use DNS A-labels)"
  pure (C.pack s)
  where
    split c s = case break (== c) s of (a,[]) -> [a]; (a,_:r) -> a : split c r
    valid l = not (null l) && length l <= 63 && take 1 l /= "-" && last l /= '-' &&
      all (\c -> isAscii c && (isAlphaNum c || c == '-')) l

parseConfig :: FilePath -> String -> Either String Config
parseConfig name input = do
  entries <- either (Left . show) Right (parse (spaceP *> many entry <* eof) name input)
  let initial = Config (Endpoint "127.0.0.1" 8080) Plain [] 256 10 30 30 1048576 "https://acme-v02.api.letsencrypt.org/directory" 80 Nothing Nothing
  config <- foldEntries initial [] entries
  when (null (sites config)) $ Left "at least one site is required"
  when (length (sites config) > 100) $ Left "at most 100 sites"
  let names = map siteHost (sites config)
  when (length (nub names) /= length names) $ Left "duplicate site hostname"
  mapM_ validateSite (sites config)
  case tlsMode config of
    Automatic email dir -> do
      when (null dir) $ Left "auto_https needs a state directory"
      unless ('@' `elem` email && all (\c -> c > ' ' && c < '\DEL') email) $ Left "invalid ACME email"
      when (endpointPort (listen config) == acmeHTTPPort config) $ Left "automatic HTTPS needs a TLS port separate from HTTP port 80"
      when (any (\n -> n == "localhost" || not (C.elem '.' n)) names) $ Left "auto_https requires public DNS hostnames"
    _ -> pure ()
  pure config
  where
    foldEntries c _ [] = Right c
    foldEntries c seen (e:rest) = do
      let tag = case e of
            Listen{} -> "listen"; TLS{} -> "tls"; Auto{} -> "tls"
            Connections{} -> "max_connections"; HeaderTime{} -> "header_timeout"
            BodyTime{} -> "body_timeout"; WriteTime{} -> "write_timeout"
            BodyLimit{} -> "body_limit"; CA{} -> "acme_ca"; HTTPPort{} -> "acme_http_port"; Trust{} -> "acme_ca_bundle"; ProxyTrust{} -> "proxy_ca_bundle"; Virtual{} -> "site"
      when (tag /= "site" && tag `elem` seen) $ Left ("duplicate directive: " ++ tag)
      c' <- case e of
        Listen s -> (\ep -> c {listen=ep}) <$> parseEndpoint s
        TLS cert key -> Right c {tlsMode=Manual cert key}
        Auto email dir -> Right c {tlsMode=Automatic email dir}
        Connections n | n <= 4096 -> Right c {maxConnections=n}
                      | otherwise -> Left "max_connections must be <= 4096"
        HeaderTime n | n <= 300 -> Right c {headerSeconds=n}
                     | otherwise -> Left "header_timeout must be <= 300"
        BodyTime n | n <= 3600 -> Right c {bodySeconds=n}
                   | otherwise -> Left "body_timeout must be <= 3600"
        WriteTime n | n <= 3600 -> Right c {writeSeconds=n}
                    | otherwise -> Left "write_timeout must be <= 3600"
        BodyLimit n | n <= 16777216 -> Right c {bodyLimit=fromIntegral n}
                    | otherwise -> Left "body_limit must be <= 16777216"
        CA url | "https://" `B.isPrefixOf` C.pack url && all (\ch -> ch > ' ' && ch < '\DEL') url -> Right c {acmeCA=C.pack url}
               | otherwise -> Left "acme_ca must be an HTTPS URL"
        HTTPPort n | n <= 65535 -> Right c {acmeHTTPPort=n}
                   | otherwise -> Left "acme_http_port must be <= 65535"
        Trust path -> Right c {acmeTrust=Just path}
        ProxyTrust path -> Right c {proxyTrust=Just path}
        Virtual site -> Right c {sites=sites c ++ [site]}
      foldEntries c' (tag:seen) rest
    validateSite s = do
      _ <- hostName (siteHost s)
      mapM_ validateHeader (siteHeaders s)
      when (length (nub (map fst (siteHeaders s))) /= length (siteHeaders s)) $ Left "duplicate site header"
      case siteAction s of
        Root _ -> do
          when (any ((`elem` ["etag","last-modified","accept-ranges","content-range"]) . fst) (siteHeaders s)) $
            Left "static validator and range headers are generated by Lantern"
          when (any (\(key,value) -> key=="content-type" && B.length value>8192) (siteHeaders s)) $
            Left "static Content-Type exceeds 8192 bytes"
        Redirect url -> unless (("https://" `B.isPrefixOf` url || "http://" `B.isPrefixOf` url) &&
                          B.all (\c -> c > 32 && c < 127) url) $ Left "redirect needs an absolute ASCII HTTP(S) URL"
        _ -> pure ()
    validateHeader (k,v) = unless (validToken k && k `notElem` reserved &&
      B.all (\c -> c == 9 || (c >= 32 && c /= 127)) v) $ Left "invalid or reserved site header"
    reserved = ["host","content-length","transfer-encoding","connection","trailer","upgrade",
      "keep-alive","te","proxy-authenticate","proxy-authorization","date","server","x-content-type-options"]

loadConfig :: FilePath -> IO Config
loadConfig file = do
  setFileSystemEncoding utf8
  absolute <- makeAbsolute file
  bytes <- withBinaryFile absolute ReadMode (\h -> B.hGet h 131073)
  when (B.length bytes > 131072) $ fail "configuration exceeds 128 KiB"
  txt <- either (const (fail "configuration must use valid UTF-8")) pure (TE.decodeUtf8' bytes)
  cfg <- either fail pure (parseConfig file (T.unpack txt))
  _ <- (N.getAddrInfo (Just N.defaultHints {N.addrFlags=[N.AI_NUMERICHOST,N.AI_NUMERICSERV],N.addrSocketType=N.Stream})
    (Just (endpointHost (listen cfg))) (Just (show (endpointPort (listen cfg)))) :: IO [N.AddrInfo])
  let resolve p = if isAbsolute p then p else takeDirectory absolute </> p
  resolved <- mapM (\s -> case siteAction s of
    Root p -> do
      root <- canonicalizePath (resolve p)
      ok <- doesDirectoryExist root
      unless ok (fail ("root is not a directory: " ++ p))
      pure s {siteAction=Root root}
    _ -> pure s) (sites cfg)
  mode <- case tlsMode cfg of
    Manual c k -> pure (Manual (resolve c) (resolve k))
    Automatic email dir -> Automatic email <$> makeAbsolute (resolve dir)
    Plain -> pure Plain
  pure cfg {sites=resolved,tlsMode=mode,acmeTrust=resolve <$> acmeTrust cfg,proxyTrust=resolve <$> proxyTrust cfg}

-- Listener and resource limits stay fixed; reload changes immutable route snapshots.
immutable :: Config -> Config -> Bool
immutable a b = a {sites=[]} == b {sites=[]} &&
  case tlsMode a of Automatic{} -> map siteHost (sites a) == map siteHost (sites b); _ -> True
