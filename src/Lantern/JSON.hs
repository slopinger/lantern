{-# LANGUAGE OverloadedStrings #-}
-- A bounded JSON codec for ACME; no general-purpose JSON package dependency.
module Lantern.JSON (JSON(..), decode, encode, object, field, text, array) where
import Control.Monad (unless,when)
import qualified Data.ByteString as B
import Data.Char (chr,ord)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import Numeric (showHex)
import Text.Parsec
import Text.Parsec.String (Parser)

data JSON = Object (M.Map T.Text JSON) | Array [JSON] | String T.Text | Number String | Bool Bool | Null deriving (Eq,Show)
object :: [(T.Text,JSON)] -> JSON
object = Object . M.fromList
field :: T.Text -> JSON -> Either String JSON
field key (Object m) = maybe (Left ("missing JSON field: "++T.unpack key)) Right (M.lookup key m)
field _ _ = Left "JSON object required"
text :: JSON -> Either String T.Text
text (String t)=Right t
text _=Left "JSON string required"
array :: JSON -> Either String [JSON]
array (Array a)=Right a
array _=Left "JSON array required"

decode :: B.ByteString -> Either String JSON
decode bytes = do
  unless (B.length bytes <= 1048576) $ Left "JSON input too large"
  t <- either (const (Left "invalid JSON UTF-8")) Right (E.decodeUtf8' bytes)
  either (Left . show) Right (parse (ws *> value 0 <* eof) "JSON" (T.unpack t))
  where
    ws=skipMany (oneOf " \r\n\t")
    lexeme p=p<*ws
    value :: Int -> Parser JSON
    value depth = do
      when (depth >= 32) (fail "JSON nesting too deep")
      lexeme $ choice
        [ String . T.pack <$> stringP
        , Object <$> between (char '{' *> ws) (char '}') (do
            pairs <- sepBy ((,) <$> (T.pack <$> lexeme stringP) <* lexeme (char ':') <*> value (depth+1)) (lexeme (char ','))
            let m=M.fromList pairs
            unless (length pairs <= 1000 && length pairs == M.size m) (fail "duplicate or excessive object members")
            pure m)
        , Array <$> between (char '[' *> ws) (char ']') (do
            vals <- sepBy (value (depth+1)) (lexeme (char ','))
            unless (length vals <= 1000) (fail "too many array elements")
            pure vals)
        , Bool True <$ string "true", Bool False <$ string "false", Null <$ string "null"
        , Number <$> numberP ]
    stringP = do
      _ <- char '"'
      chars <- many (escaped <|> satisfy (\c -> c /= '"' && c /= '\\' && ord c >= 32 && (ord c < 0xd800 || ord c > 0xdfff)))
      _ <- char '"'
      unless (length chars <= 65536) (fail "JSON string too long")
      pure chars
    escaped = char '\\' *> (choice
      [char '"' *> pure '"',char '\\' *> pure '\\',char '/' *> pure '/',char 'b' *> pure '\b',
       char 'f' *> pure '\f',char 'n' *> pure '\n',char 'r' *> pure '\r',char 't' *> pure '\t',
       char 'u' *> unicode])
    hex4 = foldl (\n c -> n*16+hex c) 0 <$> count 4 hexDigit
    hex c | c <= '9' = ord c-ord '0'
          | c <= 'F' = ord c-ord 'A'+10
          | otherwise = ord c-ord 'a'+10
    unicode = do
      a <- hex4
      if a >= 0xd800 && a <= 0xdbff then do
        _ <- string "\\u"
        b <- hex4
        unless (b >= 0xdc00 && b <= 0xdfff) (fail "invalid surrogate pair")
        pure (chr (0x10000+(a-0xd800)*1024+b-0xdc00))
      else do
        unless (a < 0xdc00 || a > 0xdfff) (fail "lone low surrogate")
        pure (chr a)
    numberP = do
      sign <- option "" (string "-")
      whole <- string "0" <|> ((:) <$> oneOf ['1'..'9'] <*> many digit)
      fraction <- option "" ((:) <$> char '.' <*> many1 digit)
      expPart <- option "" (do e <- oneOf "eE"; s <- option "" ((:[]) <$> oneOf "+-"); ds <- many1 digit; pure (e:s++ds))
      let n=sign++whole++fraction++expPart
      unless (length n <= 128) (fail "JSON number too long")
      pure n

encode :: JSON -> B.ByteString
encode = E.encodeUtf8 . T.pack . go
  where
    go (Object m)="{"++join [quote (T.unpack k)++":"++go v | (k,v)<-M.toAscList m]++"}"
    go (Array a)="["++join (map go a)++"]"
    go (String t)=quote (T.unpack t)
    go (Number n)=n
    go (Bool True)="true"
    go (Bool False)="false"
    go Null="null"
    join []="";join [x]=x;join (x:xs)=x++","++join xs
    quote s='"':concatMap escape s++"\""
    escape '"'="\\\"";escape '\\'="\\\\"
    escape c | ord c < 32 = let h=showHex (ord c) "" in "\\u"++replicate (4-length h) '0'++h
             | otherwise=[c]
