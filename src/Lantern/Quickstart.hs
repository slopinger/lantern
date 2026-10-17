module Lantern.Quickstart (runQuickstart, quickstartUsage) where
import Control.Monad (unless, when, forM_)
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath, getCurrentDirectory, getXdgDirectory, XdgDirectory(XdgData))
import System.FilePath ((</>), addTrailingPathSeparator)
import System.IO (hPutStrLn, stderr)
import Lantern.Config (Config(..), Site(..), Action(..), TLSMode(..), parseConfig, resolveConfig, leafActions)
import Lantern.Server (runConfigured)

-- Build through the ordinary validated configuration path, without creating a
-- temporary Lanternfile. Quoting preserves spaces, Unicode, quotes and slashes.
runQuickstart :: String -> [String] -> IO ()
runQuickstart command args = do
  (position,options) <- either fail pure (arguments Nothing [] args)
  let get key = lookup key options
      automatic = get "--domain" /= Nothing
      staging = get "--staging" /= Nothing
      domain = maybe "*" id (get "--domain")
      listener = maybe (if automatic then "[::]:443" else "127.0.0.1:8080") id (get "--listen")
  unless automatic $ when (any ((`elem` ["--email","--state-dir","--staging"]) . fst) options) $
    fail "--email, --state-dir and --staging require --domain"
  when (command=="proxy" && get "--precompressed" /= Nothing) (fail "--precompressed is for file serving")
  action <- case (command,position) of
    ("serve",root) -> pure ("root " ++ quoted (maybe "." id root) ++ if get "--precompressed" /= Nothing then " precompressed" else "")
    ("proxy",Just upstream) -> pure ("reverse_proxy " ++ quoted upstream)
    _ -> fail "proxy requires an upstream URL, for example http://127.0.0.1:3000"
  tls <- if not automatic then pure "" else do
    let email = maybe "" id (get "--email")
    state <- maybe (getXdgDirectory XdgData ("lantern" </> if staging then "staging" else "production")) pure (get "--state-dir")
    pure ("auto_https " ++ quoted email ++ " " ++ quoted state ++ "\n" ++
          if staging then "acme_ca https://acme-staging-v02.api.letsencrypt.org/directory\n" else "")
  cwd <- getCurrentDirectory
  let text = (if get "--access-log" /= Nothing then "access_log on\n" else "") ++ "listen " ++ quoted listener ++ "\n" ++ tls ++ "site " ++ quoted domain ++ " { " ++ action ++ " }\n"
  parsed <- either fail pure (parseConfig "command line" text)
  config <- resolveConfig (cwd </> "Lanternfile") parsed
  case tlsMode config of
    Automatic _ directory -> do
      state <- canonicalizePath directory
      let roots=[root | action' <- concatMap (leafActions . siteAction) (sites config),
                        root <- case action' of Root p -> [p]; Precompressed p -> [p]; _ -> []]
      forM_ roots $ \root -> when (addTrailingPathSeparator root `isPrefixOf` addTrailingPathSeparator state) $
        fail "certificate state must be outside the served directory; choose --state-dir"
    _ -> pure ()
  hPutStrLn stderr (if automatic
    then "Automatic HTTPS for " ++ domain ++ if staging then " (Let's Encrypt staging)" else " (Let's Encrypt production)"
    else "Serving HTTP on " ++ listener ++ "; use --domain for automatic HTTPS")
  runConfigured config
  where
    arguments position options [] = Right (position,options)
    arguments position options ("--":rest) = case (position,rest) of
      (Nothing,[value]) -> Right (Just value,options)
      _ -> Left "expected one directory or upstream after --"
    arguments position options (flag:rest)
      | flag `elem` ["--staging","--access-log","--precompressed"] = option position options flag "" rest
      | flag `elem` ["--listen","--domain","--email","--state-dir"] = case rest of
          value:remaining | not ("--" `isPrefixOf` value) -> option position options flag value remaining
          _ -> Left (flag ++ " requires a value")
      | "-" `isPrefixOf` flag = Left ("unknown option " ++ flag)
      | otherwise = case position of
          Nothing -> arguments (Just flag) options rest
          Just _ -> Left "expected only one directory or upstream"
    option position options key value remaining
      | key `elem` map fst options = Left ("duplicate option " ++ key)
      | otherwise = arguments position ((key,value):options) remaining
    quoted value = '"' : concatMap escape value ++ "\""
    escape '\\' = "\\\\"
    escape '"' = "\\\""
    escape c = [c]

quickstartUsage :: String -> String
quickstartUsage command = unlines
  [ "Usage: lantern " ++ command ++ if command == "serve" then " [DIRECTORY] [OPTIONS]" else " UPSTREAM_URL [OPTIONS]"
  , ""
  , if command == "serve" then "Serve a directory (default: current directory), without a Lanternfile."
      else "Reverse proxy to an HTTP or authenticated HTTPS upstream, without a Lanternfile."
  , "  --listen ADDRESS:PORT  Bind address (default: 127.0.0.1:8080, or [::]:443 with --domain)"
  , "  --precompressed        Serve Brotli/gzip sidecars (serve only)"
  , "  --access-log           Emit JSON access events to stdout (queries omitted)"
  , "  --domain HOST          Enable automatic HTTPS for a public DNS hostname"
  , "  --email ADDRESS        Optional ACME account contact email"
  , "  --state-dir DIRECTORY  Certificate state (default: XDG data/lantern/production or staging)"
  , "  --staging              Use Let's Encrypt testing CA (requires --domain)"
  , ""
  , "Automatic HTTPS requires public DNS and reachable ports 80/443; using ACME agrees"
  , "to the CA's terms. Staging certificates are not trusted by browsers."
  , "Paths are relative to the current directory. Ctrl-C stops gracefully."
  ]
