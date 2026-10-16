{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless,forM_)
import Data.List (isInfixOf)
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import qualified Lantern.Client as Client
import Lantern.Config
import qualified Lantern.JSON as J
import Lantern.ACME (retryDelay)
import System.Exit (exitFailure)
import Test.QuickCheck

check :: String -> Bool -> IO ()
check name ok=unless ok (fail name)
main :: IO ()
main=do
  cfg <- either fail pure (parseConfig "test" "listen 127.0.0.1:8080 site localhost { respond \"hello world\" }")
  check "listen parsed" (listen cfg==Endpoint "127.0.0.1" 8080)
  check "body default" (bodyLimit cfg==1048576)
  httpsCfg<-either fail pure (parseConfig "test" "site localhost { reverse_proxy https://upstream:443 }")
  check "HTTPS upstream parsed" (map siteAction (sites httpsCfg)==[Proxy (HTTPS (Endpoint "upstream" 443))])
  forM_ ["", "unknown x", "site localhost { nonsense x }", "site localhost { respond a root b }",
      "site localhost { }", "site localhost { respond x } site localhost { respond y }",
      "site LOCALHOST { respond x } site localhost { respond y }",
      "site localhost { header Content-Length 5 respond x }", "listen 0.0.0.0:99999 site a { respond x }",
      "site a { reverse_proxy https://upstream:443/path }",
      "site a { root public header ETag x }", "site a { root public header Content-Range x }", "site a { reverse_proxy http://user@upstream:80 }",
      "site bad/host { respond x }", "site a { header X-A a header X-A b respond c }",
      "max_connections 99999 site a { respond x }", "body_limit 999999999 site a { respond x }",
      "site localhost { respond a } tls a b auto_https a@b c", "auto_https a@b c site localhost { respond x }"] $ \bad ->
    check "invalid configuration accepted" (case parseConfig "test" bad of Left _ -> True;Right _ -> False)
  forM_ ["192.0.2.1","0.0.0.0","255.255.255.255","127.1","01.2.3.4","999.999.999.999"] $ \name -> do
    let site = "site " ++ name ++ " { respond ok }"
    check "numeric automatic site accepted" (case parseConfig "test" ("auto_https a@b ./state " ++ site) of
      Left message -> "DNS names" `isInfixOf` message
      Right _ -> False)
    check "plain numeric site rejected" (case parseConfig "test" site of Right _ -> True; Left _ -> False)
    check "manual numeric site rejected" (case parseConfig "test" ("tls cert.pem key.pem " ++ site) of Right _ -> True; Left _ -> False)
  forM_ ["123.example.org","1.2.example.org","example2026.org"] $ \name ->
    check "numeric DNS label rejected" (case parseConfig "test" ("auto_https a@b ./state site " ++ name ++ " { respond ok }") of
      Right _ -> True; Left _ -> False)
  forM_ [("localhost:8080",Endpoint "localhost" 8080),
      ("EXAMPLE.org:443",Endpoint "EXAMPLE.org" 443),
      ("192.0.2.1:80",Endpoint "192.0.2.1" 80),
      ("[::]:443",Endpoint "::" 443),
      ("[2001:db8::1]:8443",Endpoint "2001:db8::1" 8443),
      ("[::ffff:192.0.2.1]:443",Endpoint "::ffff:192.0.2.1" 443)] $ \(raw,expected) ->
    check "valid endpoint rejected" (parseEndpoint raw == Right expected)
  forM_ ["[localhost]:443","[127.0.0.1]:443","[:::1]:443","[2001:db8::g]:443",
      "[1:2:3:4:5:6:7:8:9]:443","[fe80::1%eth0]:443","[v1.example]:443",
      "bad..example:443","-bad.example:443","bad-.example:443","example.org.:443",
      replicate 64 'a' ++ ".example:443", "[::1]:0", "[::1]:65536"] $ \raw ->
    check "invalid endpoint accepted" (case parseEndpoint raw of Left _ -> True; Right _ -> False)
  forM_ ["{\"a\":1,\"a\":2}", "[01]", "[1.]", "{\"a\":true,}", "\"\\ud800\"", "\"\\udc00\"", "[NaN]",
      "\"a\n\"", "[true] trailing", B.replicate 33 91<>B.replicate 33 93] $ \bad ->
    check "invalid JSON accepted" (case J.decode bad of Left _ -> True;Right _ -> False)
  check "surrogate pair" (J.decode "\"\\ud83d\\ude00\""==Right (J.String "😀"))
  forM_ [("https://EXAMPLE.org?nonce=a%2Fb", "example.org",443,"/?nonce=a%2Fb","example.org"),
      ("https://[::1]", "::1",443,"/","[::1]"),
      ("https://[::1]:8443/a?q=x", "::1",8443,"/a?q=x","[::1]:8443")] $ \(raw,host,port,target,hostHeader) -> do
    url<-either fail pure (Client.parseURL raw)
    check "HTTPS URL components" (Client.urlHost url==host && Client.urlPort url==port &&
      Client.urlTarget url==target && Client.authority url==hostHeader && Client.urlOriginal url==raw)
  first<-either fail pure (Client.parseURL "https://EXAMPLE.org/a")
  second<-either fail pure (Client.parseURL "https://example.org:443/b")
  check "case insensitive HTTPS origin" (Client.sameOrigin first second)
  forM_ ["https://example.org/%", "https://example.org/%xy", "https://user@example.org/a",
      "https://example.org/#fragment", "https://[::1", "https://example.org?x=%0", "https://[localhost]", "https://[:::1]",
      "https://bad..example/a"] $ \raw ->
    check "invalid HTTPS URL accepted" (case Client.parseURL raw of Left _ -> True; Right _ -> False)
  delay<-retryDelay [("retry-after","120")]
  check "Retry-After delta" (delay==120)
  past<-retryDelay [("retry-after","Wed, 01 Jan 2020 00:00:00 GMT")]
  check "Retry-After past" (past==0)
  result<-quickCheckWithResult stdArgs {maxSuccess=1000,maxSize=50} propJSON
  unless (isSuccess result) exitFailure
  putStrLn "configuration, bounded JSON and Retry-After checks passed"

newtype Sample = Sample J.JSON deriving Show
instance Arbitrary Sample where
  arbitrary=Sample <$> sized (gen . min 4)
    where
      gen n=oneof (leaves++if n<=0 then [] else
        [J.Array <$> resize 5 (listOf (gen (n-1))),
         J.Object . M.fromList <$> resize 5 (listOf ((,) <$> (T.pack <$> arbitrary) <*> gen (n-1)))])
      leaves=[pure J.Null,J.Bool <$> arbitrary,J.String . T.pack <$> arbitrary,pure (J.Number "123.5e-2")]
propJSON :: Sample -> Bool
propJSON (Sample value)=J.decode (J.encode value)==Right value
