module Main (main) where
import Control.Exception (SomeException, catch, displayException)
import System.Environment (getArgs)
import System.Exit (die)
import GHC.IO.Encoding (setFileSystemEncoding, utf8)
import Lantern.Server (runServer, checkConfig)

main :: IO ()
main = (do
  setFileSystemEncoding utf8
  args <- getArgs
  case args of
    ["run"] -> runServer "Lanternfile"
    ["run",file] -> runServer file
    ["check"] -> checkConfig "Lanternfile"
    ["check",file] -> checkConfig file
    ["version"] -> putStrLn "lantern 0.1.0"
    ["--help"] -> usage
    [] -> usage
    _ -> die "usage: lantern run|check [Lanternfile] | version") `catch` failure
  where
    usage = putStrLn "lantern run|check [Lanternfile]\nlantern version\nReload: send SIGHUP. Stop gracefully: send SIGTERM."
    failure :: SomeException -> IO ()
    failure e = die (displayException e)
