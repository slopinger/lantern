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
import Data.Time.Format
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
import Lantern.Transport
import Lantern.Client (parseURL)
import qualified Lantern.TLS as TLS
import qualified Lantern.ACME as ACME

-- One immutable snapshot per request. No routing lookup races during reload.
data Snapshot = Snapshot Config (Maybe Credentials)
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
  pure (Snapshot c creds)

runServer :: FilePath -> IO ()
runServer file = do
  hSetBuffering stderr LineBuffering
  cfg <- loadConfig file
  probeConfinement
  registry <- newMVar (False,M.empty)
  bodyBudget <- newIORef 0
  state <- newIORef (Snapshot cfg Nothing)
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
          atomicWriteIORef state (Snapshot cfg (Just creds))
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
          atomicModifyIORef' state (\(Snapshot current _) -> (Snapshot current (Just credentials),()))
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
            Snapshot _ creds <- readIORef state
            transport <- case (challenges,creds) of
              (Just _,_) -> pure (plainTransport socket')
              (_,Nothing) -> pure (plainTransport socket')
              (_,Just _) -> tlsTransport (do
                Snapshot _ c <- readIORef state
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
            Snapshot current _ <- readIORef state
            host <- either (const (failHTTP 400 "invalid Host")) pure (requestHost hs)
            site <- maybe (failHTTP 421 "unknown host") pure (find ((==host) . siteHost) (sites current))
            case challenges of
              Nothing -> deadline (writeSeconds limits) 408 (dispatch current site req body peer transport isHead closeAfter headOut send)
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
  pure (("date", C.pack (formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT" now)) :
    ("server","lantern") : ("connection",if closeAfter then "close" else "keep-alive") :
    ("x-content-type-options","nosniff") : hs)

mergeDefaults :: Headers -> Headers -> Headers
mergeDefaults defaults extras=filter (\(k,_) -> k `notElem` map fst extras) defaults ++ extras

simple :: HeadOut -> Send -> Bool -> Bool -> Int -> Headers -> B.ByteString -> IO ()
simple headOut send isHead closeAfter status hs body = do
  headers <- common closeAfter (("content-length",C.pack (show (B.length body))) :
             mergeDefaults [("content-type","text/plain; charset=utf-8")] hs)
  headOut status headers
  unless isHead (send body)

dispatch :: Config -> Site -> Request -> B.ByteString -> SockAddr -> Transport -> Bool -> Bool -> HeadOut -> Send -> IO ()
dispatch cfg site req body peer _transport isHead closeAfter headOut send =
  case siteAction site of
    Respond text -> simple headOut send isHead closeAfter 200 extra text
    Redirect url -> simple headOut send isHead closeAfter 308 (("location",url):extra) "redirecting\n"
    Root root -> do
      unless (reqMethod req `elem` ["GET","HEAD"]) $ failHTTP 405 "static files require GET or HEAD"
      relative <- either (const (failHTTP 400 "unsafe path")) pure (pathFromTarget (reqTarget req))
      let serve = withFileBelow root relative $ \h -> do
            size <- hFileSize h
            headers <- common closeAfter (("content-length",C.pack (show size)):
              mergeDefaults [("content-type",defaultMimeLookup (T.pack relative))] extra)
            headOut 200 headers
            unless isHead (fileLoop h size)
      serve `catch` \(e :: IOException) ->
        if isDoesNotExistError e || isPermissionError e then failHTTP 404 "file not found" else throwIO e
    Proxy endpoint -> proxyRequest cfg endpoint site req body peer isHead closeAfter headOut send
  where
    extra = siteHeaders site
    fileLoop h left = when (left > 0) $ do
      bytes <- B.hGetSome h (fromInteger (min 65536 left))
      when (B.null bytes) $ failHTTP 500 "file changed during transfer"
      send bytes
      fileLoop h (left - fromIntegral (B.length bytes))

proxyRequest :: Config -> Endpoint -> Site -> Request -> B.ByteString -> SockAddr -> Bool -> Bool -> HeadOut -> Send -> IO ()
proxyRequest cfg endpoint site req body peer isHead closeAfter headOut send = do
  -- The deadline covers connect, request write, headers, and the complete response.
  deadline (writeSeconds cfg) 504 (withUpstream endpoint exchange)
    `catch` \(_ :: IOException) -> failHTTP 502 "upstream I/O failed"
  where
    exchange upstream = do
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
      transmit upstream (reqMethod req <> " " <> reqTarget req <> " HTTP/1.1\r\n" <>
        B.concat [k <> ": " <> v <> "\r\n" | (k,v) <- headers] <> "\r\n")
      unless (B.null body) (transmit upstream body)
      reader <- newReader (receive upstream)
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
