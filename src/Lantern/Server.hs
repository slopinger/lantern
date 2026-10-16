{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lantern.Server (runServer, checkConfig) where
import Control.Concurrent
import Control.Concurrent.Async (withAsync, link)
import Control.Exception
import Control.Monad (forever, unless, when, void, forM_)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IORef
import Data.List (find)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds, posixSecondsToUTCTime, POSIXTime)
import Crypto.Random (getRandomBytes)
import Numeric (showHex)
import qualified System.Posix.Files as F
import Network.Mime (defaultMimeLookup)
import Network.Socket hiding (listen)
import Lantern.TLS (Credentials)
import System.IO
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.Posix.Signals
import System.Timeout (timeout)
import Lantern.Config
import Lantern.Files
import Lantern.HTTP
import qualified Lantern.HTTP.Representation as R
import qualified Lantern.TLS.Crypto as Crypto
import Lantern.Transport
import Lantern.Client (parseURL)
import qualified Lantern.TLS as TLS
import qualified Lantern.ACME as ACME

-- One immutable snapshot per request. No routing lookup races during reload.
data Snapshot = Snapshot Config (Maybe Credentials) (Maybe TLS.TrustStore) StaticCache
type StaticIdentity = (Integer,Integer,Integer,POSIXTime,POSIXTime,B.ByteString,Headers)
data StaticCache = StaticCache
  (IORef (M.Map StaticIdentity (R.EntityTag,B.ByteString)))
  (IORef (Maybe (Integer,B.ByteString)))
newStaticCache :: IO StaticCache
newStaticCache=StaticCache <$> newIORef M.empty <*> newIORef Nothing
type Registry = MVar (Bool, M.Map ThreadId Socket)

checkConfig :: FilePath -> IO ()
checkConfig file = do
  c <- loadConfig file
  probeConfinement
  case tlsMode c of
    Automatic{} -> do
      _ <- either fail pure (parseURL (acmeCA c))
      forM_ (acmeTrust c) (void . TLS.trustFile)
    _ -> pure ()
  _ <- prepare c
  putStrLn "configuration valid"

prepare :: Config -> IO Snapshot
prepare c = do
  creds <- case tlsMode c of
    Plain -> pure Nothing
    Manual cert key -> Just <$> loadCredentials cert key
    Automatic{} -> ACME.cachedCredentials c
  trust <- prepareProxyTrust c
  cache <- newStaticCache
  pure (Snapshot c creds trust cache)

prepareProxyTrust :: Config -> IO (Maybe TLS.TrustStore)
prepareProxyTrust c
  | any secure (sites c) = Just <$> maybe TLS.systemTrust TLS.trustFile (proxyTrust c)
  | otherwise = do
      forM_ (proxyTrust c) (void . TLS.trustFile)
      pure Nothing
  where secure site=case siteAction site of Proxy (HTTPS _) -> True; _ -> False

runServer :: FilePath -> IO ()
runServer file = do
  hSetBuffering stderr LineBuffering
  cfg <- loadConfig file
  probeConfinement
  registry <- newMVar (False,M.empty)
  bodyBudget <- newIORef 0
  trust <- prepareProxyTrust cfg
  cache <- newStaticCache
  state <- newIORef (Snapshot cfg Nothing trust cache)
  case tlsMode cfg of
    Automatic{} -> ACME.withStateLock cfg $ do
      challenges <- ACME.newChallenges
      let httpEndpoint=(listen cfg) {endpointPort=acmeHTTPPort cfg}
      bracket (openListener httpEndpoint) close $ \httpListener ->
        withAsync (acceptSafely httpListener cfg state registry (Just challenges) bodyBudget) $ \httpWorker -> do
          link httpWorker
          cached <- ACME.cachedCredentials cfg
          creds <- case cached of
            Just c -> pure c
            Nothing -> do
              hPutStrLn stderr "ACME: acquiring initial certificate"
              ACME.acquire cfg challenges
          atomicWriteIORef state (Snapshot cfg (Just creds) trust cache)
          renewNow <- newEmptyMVar
          withAsync (renewCertificates cfg challenges state renewNow) $ \renewWorker -> do
            link renewWorker
            runCore cfg state registry bodyBudget [httpListener] (Just renewNow)
    _ -> do
      prepare cfg >>= atomicWriteIORef state
      runCore cfg state registry bodyBudget [] Nothing
  where
    runCore cfg state registry bodyBudget additionalListeners renewalQueue = do
      reload <- newEmptyMVar
      bracket (openListener (listen cfg)) close $ \listener -> do
        let stop = do
              modifyMVar_ registry (\(_,m) -> pure (True,m))
              mapM_ close (listener:additionalListeners)
            queueReload=void (tryPutMVar reload ())
        _ <- installHandler sigTERM (Catch stop) Nothing
        _ <- installHandler sigINT (Catch stop) Nothing
        _ <- installHandler sigHUP (Catch queueReload) Nothing
        forM_ renewalQueue $ \q -> void (installHandler sigUSR1 (Catch (void (tryPutMVar q ()))) Nothing)
        withAsync (forever (takeMVar reload >> reloadConfig file cfg state)) $ \worker -> do
          link worker
          hPutStrLn stderr ("lantern listening on " ++ show (listen cfg))
          acceptSafely listener cfg state registry Nothing bodyBudget
          _ <- timeout 10000000 (waitEmpty registry)
          remaining <- snd <$> readMVar registry
          forM_ (M.keys remaining) killThread
          waitEmpty registry
    waitEmpty registry = do
      empty <- M.null . snd <$> readMVar registry
      unless empty (threadDelay 10000 >> waitEmpty registry)

renewCertificates :: Config -> ACME.Challenges -> IORef Snapshot -> MVar () -> IO ()
renewCertificates cfg challenges state queue = loop False
  where
    loop force = do
      result <- try $ do
        due <- ACME.needsRenewal cfg
        when (due || force) $ do
          hPutStrLn stderr "ACME: renewing certificate"
          credentials <- ACME.acquire cfg challenges
          atomicModifyIORef' state (\(Snapshot current _ roots cache) -> (Snapshot current (Just credentials) roots cache,()))
          hPutStrLn stderr "ACME: renewed certificate activated"
      delay <- case result of
        Left (e :: SomeException) -> case fromException e :: Maybe AsyncException of
          Just async -> throwIO async
          Nothing -> do
            hPutStrLn stderr ("ACME renewal failed; retaining active credentials: "++displayException e)
            pure (case fromException e of
              Just (ACME.ACMEError _ retry) -> max 1800 retry
              Nothing -> 1800)
        Right () -> pure 21600
      forced <- timeout (delay*1000000) (takeMVar queue)
      loop (case forced of Just () -> True; Nothing -> False)

acceptSafely :: Socket -> Config -> IORef Snapshot -> Registry -> Maybe ACME.Challenges -> IORef Integer -> IO ()
acceptSafely listener cfg state registry challenges bodyBudget =
  acceptLoop listener cfg state registry challenges bodyBudget `catch` \(e :: IOException) -> do
    stopped <- fst <$> readMVar registry
    unless stopped (throwIO e)

reloadConfig :: FilePath -> Config -> IORef Snapshot -> IO ()
reloadConfig file original state = do
  result <- try $ do
    cfg <- loadConfig file
    unless (immutable cfg original) $ fail "listener/TLS mode/resource changes require a restart"
    next <- prepare cfg
    atomicWriteIORef state next
  case result of
    Left (e :: SomeException) -> case fromException e :: Maybe AsyncException of
      Just async -> throwIO async
      Nothing -> hPutStrLn stderr ("reload rejected: " ++ displayException e)
    Right () -> hPutStrLn stderr "configuration reloaded"

acceptLoop :: Socket -> Config -> IORef Snapshot -> Registry -> Maybe ACME.Challenges -> IORef Integer -> IO ()
acceptLoop listener cfg state registry challenges bodyBudget = forever $ mask $ \restore -> do
  (socket',peer) <- restore (accept listener)
  (stopped,clients) <- readMVar registry
  if stopped || M.size clients >= maxConnections cfg then close socket' else do
    gate <- newEmptyMVar
    tid <- forkIOWithUnmask $ \unmask -> do
      takeMVar gate
      self <- myThreadId
      let cleanup = close socket' `finally` modifyMVar_ registry (\(s,m) -> pure (s,M.delete self m))
          task = do
            setSocketOption socket' NoDelay 1
            Snapshot _ creds _ _ <- readIORef state
            transport <- case (challenges,creds) of
              (Just _,_) -> pure (plainTransport socket')
              (_,Nothing) -> pure (plainTransport socket')
              (_,Just _) -> tlsTransport (do
                Snapshot _ c _ _ <- readIORef state
                maybe (fail "missing TLS credentials") pure c) socket'
            serveConnection cfg state peer transport challenges bodyBudget `finally` finish transport
      (unmask task `catch` quietConnection) `finally` cleanup
    modifyMVar_ registry (\(s,m) -> pure (s,M.insert tid socket' m))
    putMVar gate ()
  where
    quietConnection e = case fromException e :: Maybe AsyncException of
      Just async -> throwIO async
      Nothing -> pure () -- No request paths, credentials, or client data in default logs.

serveConnection :: Config -> IORef Snapshot -> SockAddr -> Transport -> Maybe ACME.Challenges -> IORef Integer -> IO ()
serveConnection limits state peer transport challenges bodyBudget = do
  reader <- newReader (receive transport)
  let loop count = when (count < 100) $ do
        started <- newIORef False
        headRequest <- newIORef False
        let rawSend = transmit transport
            send = deadline (writeSeconds limits) 408 . rawSend
            headOut status hs = writeIORef started True >> writeHead send status hs
            errorOut code = do
              sent <- readIORef started
              isHead <- readIORef headRequest
              let extra=if code == 405 then [("allow","GET, HEAD")] else []
              unless sent $ simple headOut send isHead True code extra "request failed\n"
            handleError (e :: SomeException) = case fromException e of
              Just (ProtocolError code _) -> errorOut code >> pure False
              Nothing -> case fromException e :: Maybe AsyncException of
                Just async -> throwIO async
                Nothing -> errorOut 500 >> pure False
        continue <- (do
          req <- deadline (headerSeconds limits) 408 (readRequest reader)
          writeIORef headRequest (reqMethod req == "HEAD")
          let hs = reqHeaders req
              closeAfter = connectionClose req || count == 99
              isHead = reqMethod req == "HEAD"
          when (header "upgrade" hs /= Nothing || reqMethod req == "CONNECT" || reqMethod req == "TRACE") $
            failHTTP 501 "method or upgrade unsupported"
          case reqFraming req of
            Fixed n | n > bodyLimit limits -> failHTTP 413 "body too large"
            _ -> pure ()
          let reservation=case reqFraming req of Fixed n -> n; Chunked -> bodyLimit limits; _ -> 0
          bracket (reserveBody bodyBudget reservation) (releaseBody bodyBudget) $ \_ -> do
            case values "expect" hs of
              [] -> pure ()
              [v] | lower v == "100-continue" && reqVersion req == "HTTP/1.1" -> send "HTTP/1.1 100 Continue\r\n\r\n"
              _ -> failHTTP 417 "unsupported expectation"
            body <- deadline (bodySeconds limits) 408 (collectBody reader (reqFraming req) (bodyLimit limits))
            Snapshot current _ roots cache <- readIORef state
            host <- either (const (failHTTP 400 "invalid Host")) pure (requestHost hs)
            site <- maybe (failHTTP 421 "unknown host") pure (find ((==host) . siteHost) (sites current))
            case challenges of
              Nothing -> let code=case siteAction site of Proxy{} -> 504; _ -> 408
                         in deadline (writeSeconds limits) code (dispatch current roots cache site req body peer transport isHead closeAfter headOut send)
              Just table -> do
                unless (reqMethod req `elem` ["GET","HEAD"]) $ failHTTP 405 "HTTP-01 requires GET or HEAD"
                answer <- ACME.challengeResponse table host (reqTarget req)
                case answer of
                  Just token -> simple headOut send isHead closeAfter 200 [] token
                  Nothing | "/.well-known/acme-challenge/" `B.isPrefixOf` reqTarget req -> failHTTP 404 "unknown ACME token"
                  Nothing -> do
                    let port=endpointPort (listen current)
                        authority=siteHost site <> if port == 443 then "" else ":" <> C.pack (show port)
                    simple headOut send isHead closeAfter 308 [("location","https://"<>authority<>reqTarget req)] "redirecting\n"
            pure (not closeAfter)
          ) `catch` handleError
        when continue (loop (count+1))
  loop (0 :: Int)

-- A global admission budget prevents the connection limit times body limit from
-- becoming an attacker-controlled heap bound. Chunked bodies reserve their cap.
reserveBody :: IORef Integer -> Integer -> IO Integer
reserveBody budget amount = do
  allowed <- atomicModifyIORef' budget (\used ->
    if used+amount <= 67108864 then (used+amount,True) else (used,False))
  unless allowed (failHTTP 503 "request body memory budget exhausted")
  pure amount
releaseBody :: IORef Integer -> Integer -> IO ()
releaseBody budget amount=atomicModifyIORef' budget (\used -> (used-amount,()))

requestHost :: Headers -> Either String B.ByteString
requestHost hs = case header "host" hs of
  Nothing -> Left "missing host"
  Just raw -> case C.split ':' raw of
    [h] -> hostName h
    [h,p] -> do
      _ <- maybe (Left "bad port") Right (decimal p >>= \n -> if n >= 1 && n <= 65535 then Just n else Nothing)
      hostName h
    _ -> Left "invalid Host"

type HeadOut = Int -> Headers -> IO ()
type Send = B.ByteString -> IO ()

common :: Bool -> Headers -> IO Headers
common closeAfter hs = do
  now <- getCurrentTime
  pure (commonFields (R.formatHTTPDate now) closeAfter hs)
commonFields :: B.ByteString -> Bool -> Headers -> Headers
commonFields date closeAfter hs = ("date",date) :
  ("server","lantern") : ("connection",if closeAfter then "close" else "keep-alive") :
  ("x-content-type-options","nosniff") : hs

mergeDefaults :: Headers -> Headers -> Headers
mergeDefaults defaults extras=filter (\(k,_) -> k `notElem` map fst extras) defaults ++ extras

simple :: HeadOut -> Send -> Bool -> Bool -> Int -> Headers -> B.ByteString -> IO ()
simple headOut send isHead closeAfter status hs body = do
  headers <- common closeAfter (("content-length",C.pack (show (B.length body))) :
             mergeDefaults [("content-type","text/plain; charset=utf-8")] hs)
  headOut status headers
  unless isHead (send body)

dispatch :: Config -> Maybe TLS.TrustStore -> StaticCache -> Site -> Request -> B.ByteString -> SockAddr -> Transport -> Bool -> Bool -> HeadOut -> Send -> IO ()
dispatch cfg roots cache site req body peer _transport isHead closeAfter headOut send =
  case siteAction site of
    Respond text -> simple headOut send isHead closeAfter 200 extra text
    Redirect url -> simple headOut send isHead closeAfter 308 (("location",url):extra) "redirecting\n"
    Root root -> do
      unless (reqMethod req `elem` ["GET","HEAD"]) $ failHTTP 405 "static files require GET or HEAD"
      relative <- either (const (failHTTP 400 "unsafe path")) pure (pathFromTarget (reqTarget req))
      let serve = withFileBelow root relative $ \h status ->
            serveStatic cache req relative extra h status isHead closeAfter headOut send
      serve `catch` \(e :: IOException) ->
        if isDoesNotExistError e || isPermissionError e then failHTTP 404 "file not found" else throwIO e
    Proxy upstream -> proxyRequest cfg roots upstream site req body peer isHead closeAfter headOut send
  where
    extra = siteHeaders site

-- Metadata and body come from the same confined descriptor. Atomic publication
-- keeps an open representation stable; an in-place truncation still poisons I/O.
serveStatic :: StaticCache -> Request -> FilePath -> Headers -> Handle -> F.FileStatus -> Bool -> Bool -> HeadOut -> Send -> IO ()
serveStatic cache req relative extra file status isHead closeAfter headOut send = do
  now <- getCurrentTime
  let size=fromIntegral (F.fileSize status)
      seconds=min (floor (F.modificationTimeHiRes status)) (floor (utcTimeToPOSIXSeconds now)) :: Integer
      modified=posixSecondsToUTCTime (fromInteger seconds)
      contentType=maybe (defaultMimeLookup (T.pack relative)) id (header "content-type" extra)
  (tag,cachedModified,date) <- cachedStaticFields cache now status contentType extra
  let validators=R.Validators (Just tag) (Just modified) False
      encoded=header "content-encoding" extra /= Nothing
      metadata=[("etag",R.renderEntityTag tag),("last-modified",if F.modificationTimeHiRes status>utcTimeToPOSIXSeconds now then R.formatHTTPDate modified else cachedModified),
                ("accept-ranges",if encoded then "none" else "bytes")]
      other=filter ((/="content-type") . fst) extra
      output code fields=let selected=if code `elem` [412,416]
                               then filter (\(key,_) -> key `notElem` ["content-encoding","content-language","content-location"]) other
                               else other
                         in headOut code (commonFields date closeAfter (metadata++fields++selected))
      errorResponse code fields body=do
        output code (("content-length",C.pack (show (B.length body))):("content-type","text/plain; charset=utf-8"):fields)
        unless isHead (send body)
  condition <- either (const (failHTTP 400 "invalid conditional request")) pure (R.preconditions now (reqMethod req) (reqHeaders req) validators)
  case condition of
    R.NotModified -> output 304 []
    R.PreconditionFailed -> errorResponse 412 [] "precondition failed\n"
    R.Proceed -> case if encoded then R.FullRepresentation else R.selectRanges now (reqMethod req) (reqHeaders req) validators size of
      R.FullRepresentation -> do
        output 200 [("content-length",C.pack (show size)),("content-type",contentType)]
        unless isHead (fileLoop file size)
      R.RejectedRanges -> errorResponse 416 [("content-range","bytes */"<>C.pack (show size))] "range not satisfiable\n"
      R.PartialRepresentation [range] -> do
        output 206 [("content-length",C.pack (show (R.rangeLength range))),("content-type",contentType),
                    ("content-range",R.contentRange size range)]
        streamRange range
      R.PartialRepresentation ranges -> do
        entropy <- getRandomBytes 16 :: IO B.ByteString
        let boundary="lantern_"<>hexBytes entropy
        (parts,end,total) <- either (const (failHTTP 500 "invalid multipart metadata")) pure (R.multipartParts boundary contentType size ranges)
        output 206 [("content-length",C.pack (show total)),("content-type","multipart/byteranges; boundary="<>boundary)]
        forM_ parts $ \(range,prefix) -> send prefix >> streamRange range >> send "\r\n"
        send end
  where
    streamRange range=hSeek file AbsoluteSeek (R.rangeStart range) >> fileLoop file (R.rangeLength range)
    fileLoop h left = when (left > 0) $ do
      bytes <- B.hGetSome h (fromInteger (min 65536 left))
      when (B.null bytes) $ failHTTP 500 "file changed during transfer"
      send bytes
      fileLoop h (left - fromIntegral (B.length bytes))

-- Cache only pure derived fields. Every request still performs confined open and
-- fstat first. A full cache is replaced on a miss; no file bytes or FDs are held.
cachedStaticFields :: StaticCache -> UTCTime -> F.FileStatus -> B.ByteString -> Headers
                   -> IO (R.EntityTag,B.ByteString,B.ByteString)
cachedStaticFields (StaticCache fieldsRef dateRef) now status mediaType extra = do
  let identity=(fromIntegral (F.deviceID status),fromIntegral (F.fileID status),fromIntegral (F.fileSize status),
                F.modificationTimeHiRes status,F.statusChangeTimeHiRes status,mediaType,extra)
  current <- readIORef fieldsRef
  (tag,modified) <- case M.lookup identity current of
    Just cached -> pure cached
    Nothing -> do
      let fields=(R.Weak (hexBytes (Crypto.sha256 (C.pack (show identity)))),
                  R.formatHTTPDate (posixSecondsToUTCTime (fromInteger (floor (F.modificationTimeHiRes status)))))
      atomicModifyIORef' fieldsRef $ \entries -> case M.lookup identity entries of
        Just cached -> (entries,cached)
        Nothing -> (M.insert identity fields (if M.size entries<256 then entries else M.empty),fields)
  let second=floor (utcTimeToPOSIXSeconds now) :: Integer
  oldDate <- readIORef dateRef
  date <- case oldDate of
    Just (previous,value) | previous==second -> pure value
    _ -> do
      let value=R.formatHTTPDate now
      writeIORef dateRef (Just (second,value))
      pure value
  pure (tag,modified,date)

hexBytes :: B.ByteString -> B.ByteString
hexBytes=C.pack . concatMap (\byte -> let text=showHex byte "" in if length text==1 then '0':text else text) . B.unpack

proxyRequest :: Config -> Maybe TLS.TrustStore -> Upstream -> Site -> Request -> B.ByteString -> SockAddr -> Bool -> Bool -> HeadOut -> Send -> IO ()
proxyRequest cfg roots upstream site req body peer isHead closeAfter headOut send = do
  -- The deadline covers connect, request write, headers, and the complete response.
  deadline (writeSeconds cfg) 504 (withUpstream roots upstream exchange)
    `catches` [Handler (\(_ :: IOException) -> failHTTP 502 "upstream I/O failed"),
               Handler (\(_ :: TLS.TLSError) -> failHTTP 502 "upstream TLS failed")]
  where
    endpoint=case upstream of HTTP ep -> ep; HTTPS ep -> ep
    exchange transport = do
      let original = reqHeaders req
          safe = filter (\(k,_) -> k `notElem` ["host","forwarded","x-forwarded-for","x-forwarded-host",
                    "x-forwarded-proto","x-real-ip","expect"]) (stripHop original)
          authority = C.pack (if ':' `elem` endpointHost endpoint
            then "[" ++ endpointHost endpoint ++ "]:" ++ show (endpointPort endpoint)
            else endpointHost endpoint ++ ":" ++ show (endpointPort endpoint))
          headers = [("host",authority),("connection","close"),("content-length",C.pack (show (B.length body))),
            ("x-forwarded-for",peerIP peer),("x-real-ip",peerIP peer),
            ("x-forwarded-host",maybe "" id (header "host" original)),
            ("x-forwarded-proto",if tlsMode cfg == Plain then "http" else "https")] ++ safe
      transmit transport (reqMethod req <> " " <> reqTarget req <> " HTTP/1.1\r\n" <>
        B.concat [k <> ": " <> v <> "\r\n" | (k,v) <- headers] <> "\r\n")
      unless (B.null body) (transmit transport body)
      reader <- newReader (receive transport)
      response <- readResponse reader (reqMethod req) `catch` \(_ :: ProtocolError) -> failHTTP 502 "invalid upstream response"
      case resFraming response of
        Fixed n | n > 1073741824 -> failHTTP 502 "upstream body exceeds 1 GiB cap"
        _ -> pure ()
      let status = resStatus response
          mode = resFraming response
          base = filter (\(k,_) -> k `notElem` ["date","server","x-content-type-options"] &&
                 k `notElem` map fst (siteHeaders site)) (stripHop (resHeaders response)) ++ siteHeaders site
          sizeHeaders = case mode of
            Fixed n -> [("content-length",C.pack (show n))]
            NoBody | status /= 204 -> maybe [] (\v -> [("content-length",v)]) (header "content-length" (resHeaders response))
            NoBody -> []
            _ | reqVersion req == "HTTP/1.0" -> []
              | otherwise -> [("transfer-encoding","chunked")]
      hs <- common closeAfter (sizeHeaders ++ base)
      headOut status hs
      unless isHead $ do
        let emit = case mode of
              Fixed _ -> send
              NoBody -> const (pure ())
              _ | reqVersion req == "HTTP/1.0" -> send
                | otherwise -> chunk send
        readBody reader mode 1073741824 emit
        when (reqVersion req /= "HTTP/1.0" && mode `elem` [Chunked,UntilClose]) (send "0\r\n\r\n")
