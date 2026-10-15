{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lantern.ACME
  ( Challenges, newChallenges, challengeResponse, acquire, cachedCredentials, needsRenewal, withStateLock, ACMEError(..), retryDelay ) where
import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad (unless,when,forM_)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Bits ((.&.))
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Clock (getCurrentTime, diffUTCTime, UTCTime)
import Data.Time.Format (parseTimeM, defaultTimeLocale)
import System.Directory hiding (isSymbolicLink)
import System.FilePath ((</>), takeDirectory)
import System.IO
import System.Posix.Files
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import qualified Lantern.TLS as TLS
import Lantern.TLS.Crypto (sha256)
import qualified Lantern.TLS.PKI as P
import Lantern.Config
import Lantern.Client
import qualified Lantern.JSON as J
import Lantern.HTTP (Headers,header)

data ACMEError = ACMEError String Int deriving Show
instance Exception ACMEError

type Challenges = IORef (M.Map (B.ByteString,B.ByteString) B.ByteString)
newChallenges :: IO Challenges
newChallenges = newIORef M.empty
challengeResponse :: Challenges -> B.ByteString -> B.ByteString -> IO (Maybe B.ByteString)
challengeResponse ref host path = do
  current <- readIORef ref
  let prefix="/.well-known/acme-challenge/"
  if prefix `B.isPrefixOf` path then pure (M.lookup (host,B.drop (B.length prefix) path) current) else pure Nothing

require :: Either String a -> IO a
require = either fail pure
jtext :: T.Text -> J.JSON -> IO B.ByteString
jtext key value = E.encodeUtf8 <$> require (J.field key value >>= J.text)
jarray :: T.Text -> J.JSON -> IO [J.JSON]
jarray key value = require (J.field key value >>= J.array)
json :: B.ByteString -> IO J.JSON
json = require . J.decode
str :: B.ByteString -> J.JSON
str = J.String . E.decodeUtf8

stateDirectory :: Config -> IO FilePath
stateDirectory cfg = case tlsMode cfg of
  Automatic _ path -> pure path
  _ -> fail "ACME requires auto_https"
secureDirectory :: FilePath -> IO ()
secureDirectory path = do
  createDirectoryIfMissing True path
  uid <- getEffectiveUserID
  st <- getSymbolicLinkStatus path
  unless (isDirectory st && not (isSymbolicLink st) && fileOwner st == uid) $ fail "ACME state directory must be an owned real directory"
  setFileMode path 0o700

withStateLock :: Config -> IO a -> IO a
withStateLock cfg action = do
  dir <- stateDirectory cfg
  secureDirectory dir
  bracket (openFd (dir</>"lock") ReadWrite (defaultFileFlags {creat=Just 0o600})) closeFd $ \fd -> do
    setLock fd (WriteLock,AbsoluteSeek,0,0)
    action

privateRead :: FilePath -> IO B.ByteString
privateRead path = do
  uid <- getEffectiveUserID
  st <- getSymbolicLinkStatus path
  unless (isRegularFile st && fileOwner st == uid && fileMode st .&. 0o077 == 0 && fileSize st <= 1048576) $
    fail "ACME state file must be owned, regular, <=1 MiB, and private"
  B.readFile path

atomicPrivate :: FilePath -> B.ByteString -> IO ()
atomicPrivate target bytes = bracketOnError
  (openBinaryTempFile (takeDirectory target) ".lantern-tmp")
  (\(path,h) -> (hClose h `catch` \(_ :: IOException) -> pure ()) `finally` removeFile path) $ \(path,h) -> do
    setFileMode path 0o600
    B.hPut h bytes
    hFlush h
    hClose h
    bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise
    renameFile path target
    bracket (openFd (takeDirectory target) ReadOnly defaultFileFlags) closeFd fileSynchronise

loadOrCreateKey :: FilePath -> IO P.Key
loadOrCreateKey path = do
  exists <- doesPathExist path
  if exists then privateRead path >>= require . P.decodeKeyPEM else do
    key <- P.generateKey
    atomicPrivate path (P.encodeKeyPEM key)
    pure key

manifest :: Config -> B.ByteString
manifest cfg = acmeCA cfg <> "\n" <> C.unlines (map siteHost (sites cfg))

cachedCredentials :: Config -> IO (Maybe TLS.Credentials)
cachedCredentials cfg = do
  dir <- stateDirectory cfg
  let cert=dir</>"chain.pem"; key=dir</>"site-key.pem"
  exists <- doesPathExist cert
  if not exists then pure Nothing else do
    identityExists <- doesPathExist (dir</>"identity")
    same <- if identityExists then (==manifest cfg) <$> privateRead (dir</>"identity") else pure False
    if not same then pure Nothing else do
      pem <- privateRead cert
      (_,expiry) <- require (P.certificateTimes pem)
      now <- floor <$> getPOSIXTime
      if expiry <= now then pure Nothing else Just <$> TLS.loadCredentials cert key

needsRenewal :: Config -> IO Bool
needsRenewal cfg = do
  dir <- stateDirectory cfg
  bytes <- privateRead (dir</>"chain.pem")
  (start,end) <- require (P.certificateTimes bytes)
  now <- floor <$> getPOSIXTime
  pure (now >= start+(end-start)*2 `div` 3 || end-now < 86400)

data Session = Session TLS.TrustStore URL URL P.Key B.ByteString (IORef (Maybe B.ByteString))

acquire :: Config -> Challenges -> IO TLS.Credentials
acquire cfg challenges = do
  dir <- stateDirectory cfg
  let backoff=dir</>"retry-until"
  now <- floor <$> getPOSIXTime
  exists <- doesPathExist backoff
  when exists $ do
    bytes <- privateRead backoff
    case reads (C.unpack bytes) of
      [(untilTime,"")] | untilTime > now -> throwIO (ACMEError "ACME persisted backoff is active" (fromInteger (min 604800 (untilTime-now))))
      [(_,"")] -> pure ()
      _ -> fail "invalid ACME backoff state"
  result <- try (acquireCertificate cfg challenges)
  case result of
    Right credentials -> do
      stillExists <- doesPathExist backoff
      when stillExists (removeFile backoff)
      pure credentials
    Left (e :: SomeException) -> case fromException e :: Maybe AsyncException of
      Just async -> throwIO async
      Nothing -> do
        let delay=case fromException e of Just (ACMEError _ requested) -> max 300 requested; Nothing -> 300
        after <- floor <$> getPOSIXTime
        atomicPrivate backoff (C.pack (show (after+fromIntegral delay :: Integer)))
        throwIO e

acquireCertificate :: Config -> Challenges -> IO TLS.Credentials
acquireCertificate cfg challenges = do
  dir <- stateDirectory cfg
  accountKey <- loadOrCreateKey (dir</>"account-key.pem")
  siteKey <- loadOrCreateKey (dir</>"site-key.pem")
  trust <- maybe TLS.systemTrust TLS.trustFile (acmeTrust cfg)
  directoryURL <- require (parseURL (acmeCA cfg))
  (code,_,directoryBytes) <- request trust "GET" directoryURL B.empty
  unless (code == 200) (fail "ACME directory request failed")
  directory <- json directoryBytes
  nonceURL <- checkedURL directoryURL =<< jtext "newNonce" directory
  newAccount <- checkedURL directoryURL =<< jtext "newAccount" directory
  newOrder <- checkedURL directoryURL =<< jtext "newOrder" directory
  nonce <- newIORef Nothing
  let provisional = Session trust directoryURL nonceURL accountKey B.empty nonce
      email=case tlsMode cfg of Automatic mail _ -> C.pack mail; _ -> B.empty
  (accountCode,accountHeaders,_) <- signed provisional True newAccount
    (J.encode (J.object [("termsOfServiceAgreed",J.Bool True),("contact",J.Array [str ("mailto:"<>email)])]))
  unless (accountCode `elem` [200,201]) (fail "ACME account creation failed")
  kid <- maybe (fail "ACME account has no Location") pure (header "location" accountHeaders)
  _ <- checkedURL directoryURL kid
  let session=Session trust directoryURL nonceURL accountKey kid nonce
      names=map siteHost (sites cfg)
      identifiers=J.Array [J.object [("type",str "dns"),("value",str name)] | name<-names]
      orderBody=J.encode (J.object [("identifiers",identifiers)])
  (orderCode,orderHeaders,orderBytes) <- signed session False newOrder orderBody
  unless (orderCode `elem` [200,201]) (fail "ACME order creation failed")
  orderURL <- checkedURL directoryURL =<< maybe (fail "ACME order has no Location") pure (header "location" orderHeaders)
  order <- json orderBytes
  authorizations <- jarray "authorizations" order
  unless (length authorizations <= length names) (fail "ACME returned excessive authorizations")
  forM_ authorizations $ \authorization -> do
    authURL <- checkedURL directoryURL =<< (E.encodeUtf8 <$> require (J.text authorization))
    auth <- signedJSON session authURL B.empty
    identifier <- require (J.field "identifier" auth)
    name <- jtext "value" identifier
    kind <- jtext "type" identifier
    unless (kind == "dns" && name `elem` names) (fail "ACME authorization identifier mismatch")
    status <- jtext "status" auth
    unless (status == "valid") $ do
      unless (status == "pending") (fail "ACME authorization is not pending")
      offered <- jarray "challenges" auth
      matching <- filterMHTTP offered
      challenge <- case matching of c:_ -> pure c; [] -> fail "ACME HTTP-01 challenge unavailable"
      token <- jtext "token" challenge
      unless (B.length token >= 22 && B.length token <= 256 && B.all base64Char token) (fail "invalid ACME challenge token")
      challengeURL <- checkedURL directoryURL =<< jtext "url" challenge
      let keyAuthorization=token<>"."<>P.base64URL (sha256 (jwk accountKey))
          key=(name,token)
      bracket_ (atomicModifyIORef' challenges (\m -> (M.insert key keyAuthorization m,())))
        (atomicModifyIORef' challenges (\m -> (M.delete key m,()))) $ do
          _ <- signedJSON session challengeURL "{}"
          _ <- poll session authURL ["valid"] ["pending","processing"] 90
          pure ()
  _ <- poll session orderURL ["ready"] ["pending"] 90
  finalURL <- checkedURL directoryURL =<< jtext "finalize" order
  csr <- P.createCSR siteKey names
  _ <- signedJSON session finalURL (J.encode (J.object [("csr",str (P.base64URL csr))]))
  completed <- poll session orderURL ["valid"] ["pending","ready","processing"] 90
  certURL <- checkedURL directoryURL =<< jtext "certificate" completed
  (certCode,_,pemBytes) <- signed session False certURL B.empty
  unless (certCode == 200) (fail "ACME certificate download failed")
  (_,expiry) <- require (P.certificateTimes pemBytes)
  now <- floor <$> getPOSIXTime
  unless (expiry > now) (fail "ACME returned an expired certificate")
  -- Validate the complete new chain/key pair before replacing the current chain.
  let temporary=dir</>"pending-chain.pem"
  atomicPrivate temporary pemBytes
  credentials <- TLS.loadCredentials temporary (dir</>"site-key.pem") `onException` removeFile temporary
  renameFile temporary (dir</>"chain.pem")
  atomicPrivate (dir</>"identity") (manifest cfg)
  pure credentials
  where
    base64Char c=(c>=48&&c<=57)||(c>=65&&c<=90)||(c>=97&&c<=122)||c==45||c==95
    filterMHTTP []=pure []
    filterMHTTP (c:cs)=do t<-jtext "type" c; more<-filterMHTTP cs;pure (if t=="http-01" then c:more else more)

checkedURL :: URL -> B.ByteString -> IO URL
checkedURL origin bytes = do
  url <- require (parseURL bytes)
  unless (sameOrigin origin url) (fail "cross-origin ACME URL rejected")
  pure url

jwk :: P.Key -> B.ByteString
jwk key = let (n,e)=P.publicParts key in
  J.encode (J.object [("e",str (P.base64URL e)),("kty",str "RSA"),("n",str (P.base64URL n))])

signed :: Session -> Bool -> URL -> B.ByteString -> IO (Int,Headers,B.ByteString)
signed (Session trust _ nonceURL key kid nonceRef) useJWK url payload = attempt (0 :: Int)
  where
    attempt retries = do
      cached <- atomicModifyIORef' nonceRef (\old -> (Nothing,old))
      nonce <- case cached of
        Just n -> pure n
        Nothing -> do
          (code,hs,_) <- request trust "HEAD" nonceURL B.empty
          unless (code `elem` [200,204]) (fail "ACME nonce request failed")
          maybe (fail "missing ACME nonce") pure (header "replay-nonce" hs)
      unless (B.length nonce <= 256 && not (B.null nonce) && B.all safeNonce nonce) (fail "invalid ACME nonce")
      let identity=if useJWK then ("jwk",either (const J.Null) id (J.decode (jwk key))) else ("kid",str kid)
          protected=P.base64URL (J.encode (J.object ([identity,("alg",str "RS256"),("nonce",str nonce),("url",str (urlOriginal url))])))
          encodedPayload=P.base64URL payload
      signature <- P.signSHA256 key (protected<>"."<>encodedPayload)
      let body=J.encode (J.object [("protected",str protected),("payload",str encodedPayload),("signature",str (P.base64URL signature))])
      result@(status,headers,bytes) <- request trust "POST" url body
      writeIORef nonceRef (header "replay-nonce" headers)
      if status == 400 && retries < 2 && isBadNonce bytes then attempt (retries+1) else do
        when (status >= 400) $ do
          retry <- retryDelay headers
          throwIO (ACMEError ("ACME request failed with HTTP "++show status++problemType bytes) (max 300 retry))
        pure result
    safeNonce c=(c>=48&&c<=57)||(c>=65&&c<=90)||(c>=97&&c<=122)||c==45||c==95
    isBadNonce b=case J.decode b >>= J.field "type" >>= J.text of Right t -> t=="urn:ietf:params:acme:error:badNonce"; _ -> False
    problemType b=case J.decode b >>= J.field "type" >>= J.text of Right t -> " ("++T.unpack (T.take 128 t)++")"; _ -> ""

signedJSON :: Session -> URL -> B.ByteString -> IO J.JSON
signedJSON session url bytes = do
  (_,_,body) <- signed session False url bytes
  json body

poll :: Session -> URL -> [B.ByteString] -> [B.ByteString] -> Int -> IO J.JSON
poll _ _ _ _ 0 = fail "ACME polling deadline exceeded"
poll session url done pending attempts = do
  (_,headers,bytes) <- signed session False url B.empty
  result <- json bytes
  status <- jtext "status" result
  if status `elem` done then pure result else do
    unless (status `elem` pending) (fail "ACME operation entered a failed state")
    wait <- retryDelay headers
    if wait > 60 then throwIO (ACMEError "ACME polling deferred by Retry-After" wait)
      else threadDelay (max 2 wait * 1000000)
    poll session url done pending (attempts-1)

-- Honor both delta-seconds and HTTP-date Retry-After without unbounded sleeps.
retryDelay :: Headers -> IO Int
retryDelay headers = case header "retry-after" headers of
  Nothing -> pure 0
  Just raw -> case reads (C.unpack raw) of
    [(n,"")] | n >= (0 :: Integer) -> pure (fromInteger (min 604800 n))
    _ -> do
      now <- getCurrentTime
      let date=parseTimeM True defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT" (C.unpack raw) :: Maybe UTCTime
      pure (maybe 0 (\d -> max 0 (min 604800 (ceiling (diffUTCTime d now)))) date)
