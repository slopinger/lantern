module Main (main) where
import Control.Exception (SomeException(..), SomeAsyncException, AsyncException(UserInterrupt), IOException,
                          catch, displayException, fromException, throwIO)
import Data.List (stripPrefix)
import System.Environment (getArgs)
import System.Exit (ExitCode(..), die, exitWith)
import System.IO (hSetEncoding, stdout, stderr)
import System.IO.Error (isUserError, ioeGetErrorString)
import GHC.IO.Encoding (setFileSystemEncoding, utf8)
import Lantern.Server (runServer, checkConfig)

main :: IO ()
main = (do
  setFileSystemEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  getArgs >>= dispatch) `catch` failure

dispatch :: [String] -> IO ()
dispatch [] = usage
dispatch [flag] | flag `elem` ["--help","-h","help"] = usage
dispatch [flag] | flag `elem` ["version","--version"] = putStrLn "lantern 0.1.0"
dispatch ["help",command] | command `elem` ["run","check"] = commandUsage command
dispatch ["help",topic] = cliError ("unknown help topic " ++ show topic)
dispatch (command:arguments) | command `elem` ["run","check"] =
  let action = if command == "run" then runServer else checkConfig
  in case arguments of
    [] -> action "Lanternfile"
    [flag] | flag `elem` ["--help","-h"] -> commandUsage command
    ["--config"] -> cliError "--config requires a configuration file"
    [argument] | Just file <- stripPrefix "--config=" argument ->
      if null file then cliError "--config requires a configuration file" else action file
    [file] | take 1 file /= "-" -> action file
    ["--config",file] -> action file
    ["--",file] -> action file
    _ -> cliError ("invalid arguments for " ++ command)
dispatch (command:_) | command `elem` ["version","--version"] = cliError "version does not accept arguments"
dispatch (command:_) = cliError ("unknown command or option " ++ show command)

cliError :: String -> IO a
cliError message = die ("lantern: " ++ message ++ "\nRun 'lantern --help' for usage.")

usage :: IO ()
usage = putStrLn $ unlines
  [ "Lantern — experimental webserver with automatic HTTPS"
  , "Usage: lantern COMMAND"
  , ""
  , "  run [FILE]               Serve a Lanternfile (default: ./Lanternfile)"
  , "  check [FILE]             Validate without binding ports or contacting a CA"
  , "  run|check --config FILE  Select a configuration explicitly"
  , "  version                  Print the version"
  , "  help [run|check]          Show help (-h and --help also work)"
  , ""
  , "Minimal Lanternfile:"
  , "  site localhost { respond \"hello\" }"
  , "Save it as Lanternfile, run 'lantern run', then open http://localhost:8080/"
  , "The default listener is loopback-only (127.0.0.1:8080)."
  , "Configuration paths are relative to the Lanternfile."
  , "Reload: SIGHUP. Graceful stop: SIGTERM. ACME renewal: SIGUSR1."
  ]

commandUsage :: String -> IO ()
commandUsage command = putStrLn $ unlines
  [ "Usage: lantern " ++ command ++ " [FILE]"
  , "       lantern " ++ command ++ " --config FILE"
  , "       lantern " ++ command ++ " -- FILE  (for a filename beginning with '-')"
  , ""
  , if command == "run"
      then "Serve HTTP/HTTPS using FILE, or ./Lanternfile when omitted."
      else "Check syntax, document roots, credentials and trust configuration."
  , if command == "run"
      then "Send SIGHUP to reload; invalid reloads preserve the working configuration."
      else "Does not bind listeners, contact a CA or create an ACME account/state."
  , "Paths inside the configuration are relative to its directory."
  ]

-- ExitCode is control flow, and asynchronous cancellation must stay asynchronous.
-- Unwrap SomeException for ordinary diagnostics: GHC attaches exception contexts
-- (including backtraces) to that wrapper, not to the concrete user-facing cause.
failure :: SomeException -> IO ()
failure exception = case fromException exception :: Maybe ExitCode of
  Just code -> exitWith code
  Nothing -> case fromException exception :: Maybe AsyncException of
    Just UserInterrupt -> exitWith (ExitFailure 130)
    _ -> case fromException exception :: Maybe SomeAsyncException of
      Just _ -> throwIO exception
      Nothing -> case fromException exception :: Maybe IOException of
        Just cause -> die ("lantern: " ++ if isUserError cause then ioeGetErrorString cause else displayException cause)
        Nothing -> case exception of SomeException cause -> die ("lantern: " ++ displayException cause)
