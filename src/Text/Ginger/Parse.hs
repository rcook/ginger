-- | Ginger parser.
module Text.Ginger.Parse
( parseGinger
, parseGingerFile
, ParserError (..)
, IncludeResolver
, Source, SourceName
)
where

import Text.Parsec ( ParseError
                   , sourceLine
                   , sourceColumn
                   , sourceName
                   , ParsecT
                   , runParserT
                   , try, lookAhead
                   , manyTill, oneOf, string, notFollowedBy, between
                   , eof, spaces, anyChar, char
                   , option
                   , unexpected
                   , (<?>)
                   )
import Text.Parsec.Error ( errorMessages
                         , errorPos
                         , showErrorMessages
                         )
import Text.Ginger.AST
import Text.Ginger.Html ( unsafeRawHtml )
import Control.Monad.Reader ( ReaderT
                            , runReaderT
                            , ask, asks
                            )
import Control.Monad.Trans.Class ( lift )
import Control.Applicative
import Data.Text (Text)
import Data.Maybe ( fromMaybe )
import System.FilePath ( takeDirectory, (</>) )
import qualified Data.Text as Text

-- | Input type for the parser (source code).
type Source = String

-- | A source identifier (typically a filename).
type SourceName = String

-- | Used to resolve includes. Ginger will call this function whenever it
-- encounters an {% include %}, {% import %}, or {% extends %} directive.
-- If the required source code is not available, the resolver should return
-- @Nothing@, else @Just@ the source.
type IncludeResolver m = SourceName -> m (Maybe Source)


-- | Error information for Ginger parser errors.
data ParserError =
    ParserError
        { peErrorMessage :: String -- ^ Human-readable error message
        , peSourceName :: Maybe SourceName -- ^ Source name, if any
        , peSourceLine :: Maybe Int -- ^ Line number, if available
        , peSourceColumn :: Maybe Int -- ^ Column number, if available
        }
        deriving (Show)

-- | Helper function to create a Ginger parser error from a Parsec error.
fromParsecError :: ParseError -> ParserError
fromParsecError e =
    let pos = errorPos e
        sourceFilename =
            let sn = sourceName pos
            in if null sn then Nothing else Just sn
    in ParserError
        (dropWhile (== '\n') .
            showErrorMessages
            "or"
            "unknown parse error"
            "expecting"
            "unexpected"
            "end of input"
            $ errorMessages e)
        sourceFilename
        (Just $ sourceLine pos)
        (Just $ sourceColumn pos)
-- | Parse Ginger source from a file.
parseGingerFile :: Monad m => IncludeResolver m -> SourceName -> m (Either ParserError Template)
parseGingerFile resolve fn = do
    srcMay <- resolve fn
    case srcMay of
        Nothing -> return . Left $
            ParserError
                { peErrorMessage = "Template source not found: " ++ fn
                , peSourceName = Nothing
                , peSourceLine = Nothing
                , peSourceColumn = Nothing
                }
        Just src -> parseGinger resolve (Just fn) src


data ParseContext m
    = ParseContext
        { pcResolve :: IncludeResolver m
        , pcCurrentSource :: Maybe SourceName
        }

-- | Parse Ginger source from memory.
parseGinger :: Monad m => IncludeResolver m -> Maybe SourceName -> Source -> m (Either ParserError Template)
parseGinger resolve sn src = do
    result <- runReaderT (runParserT templateP () (fromMaybe "<<unknown>>" sn) src) (ParseContext resolve sn)
    case result of
        Right t -> return . Right $ t
        Left e -> return . Left $ fromParsecError e

type Parser m a = ParsecT String () (ReaderT (ParseContext m) m) a

ignore :: Monad m => m a -> m ()
ignore = (>> return ())

templateP :: Monad m => Parser m Template
templateP = do
    t <- Template <$> statementsP
    eof
    return t

getResolver :: Monad m => Parser m (IncludeResolver m)
getResolver = asks pcResolve

include :: Monad m => SourceName -> Parser m Statement
include sourceName = do
    resolver <- getResolver
    currentSource <- fromMaybe "" <$> asks pcCurrentSource
    let includeSourceName = takeDirectory currentSource </> sourceName
    pres <- lift . lift $ parseGingerFile resolver includeSourceName
    case pres of
        Right (Template s) -> return s
        Left err -> fail (show err)

statementsP :: Monad m => Parser m Statement
statementsP = do
    stmts <- many (try statementP)
    case stmts of
        [] -> return NullS
        x:[] -> return x
        xs -> return $ MultiS xs

statementP :: Monad m => Parser m Statement
statementP = interpolationStmtP
           <|> ifStmtP
           <|> forStmtP
           <|> includeP
           <|> literalStmtP

interpolationStmtP :: Monad m => Parser m Statement
interpolationStmtP = do
    try $ string "{{"
    spaces
    expr <- expressionP
    spaces
    string "}}"
    return $ InterpolationS expr

literalStmtP :: Monad m => Parser m Statement
literalStmtP = do
    txt <- manyTill anyChar endOfLiteralP

    case txt of
        [] -> unexpected "{{"
        _ -> return . LiteralS . unsafeRawHtml . Text.pack $ txt

endOfLiteralP :: Monad m => Parser m ()
endOfLiteralP =
    (ignore . lookAhead . try . string $ "{{") <|>
    (ignore . lookAhead $ openTagP) <|>
    eof

ifStmtP :: Monad m => Parser m Statement
ifStmtP = do
    condExpr <- startTagP "if" expressionP
    trueStmt <- statementsP
    falseStmt <- option NullS $ do
        try $ simpleTagP "else"
        statementsP
    simpleTagP "endif"
    return $ IfS condExpr trueStmt falseStmt

forStmtP :: Monad m => Parser m Statement
forStmtP = do
    (iteree, varName) <- startTagP "for" forHeadP
    body <- statementsP
    simpleTagP "endfor"
    return $ ForS varName iteree body

includeP :: Monad m => Parser m Statement
includeP = do
    sourceName <- startTagP "include" stringLiteralP
    include sourceName

forHeadP :: Monad m => Parser m (Expression, VarName)
forHeadP = try forHeadInP <|> forHeadAsP

forHeadInP :: Monad m => Parser m (Expression, VarName)
forHeadInP = do
    varName <- Text.pack <$> identifierP
    spaces
    string "in"
    notFollowedBy identCharP
    spaces
    iteree <- expressionP
    return (iteree, varName)

forHeadAsP :: Monad m => Parser m (Expression, VarName)
forHeadAsP = do
    iteree <- expressionP
    spaces
    string "as"
    notFollowedBy identCharP
    spaces
    varName <- Text.pack <$> identifierP
    return (iteree, varName)

startTagP :: Monad m => String -> Parser m a -> Parser m a
startTagP tagName inner =
    between
        (try $ do
            openTagP
            string tagName
            spaces)
        closeTagP
        inner

simpleTagP :: Monad m => String -> Parser m ()
simpleTagP tagName = openTagP >> string tagName >> closeTagP

openTagP :: Monad m => Parser m ()
openTagP = try openTagWP <|> try openTagNWP

openTagWP :: Monad m => Parser m ()
openTagWP = ignore (spaces >> string "{%-" >> spaces)

openTagNWP :: Monad m => Parser m ()
openTagNWP = ignore (string "{%" >> spaces)

closeTagP :: Monad m => Parser m ()
closeTagP = try closeTagWP <|> try closeTagNWP <?> "Closing tag ('%}')"

closeTagWP :: Monad m => Parser m ()
closeTagWP = ignore (spaces >> string "-%}" >> spaces)

closeTagNWP :: Monad m => Parser m ()
closeTagNWP = ignore (spaces >> string "%}" >> (optional . ignore . char) '\n')

expressionP :: Monad m => Parser m Expression
expressionP = parenthesizedExprP <|> varExprP <|> stringLiteralExprP

parenthesizedExprP :: Monad m => Parser m Expression
parenthesizedExprP =
    between
        (try . ignore $ char '(' >> spaces)
        (ignore $ char ')' >> spaces)
        expressionP

varExprP :: Monad m => Parser m Expression
varExprP = do
    litName <- identifierP
    spaces
    return . VarE . Text.pack $ litName

identifierP :: Monad m => Parser m String
identifierP =
    (:)
        <$> oneOf (['a'..'z'] ++ ['A'..'Z'] ++ ['_'])
        <*> many identCharP

stringLiteralP :: Monad m => Parser m String
stringLiteralP = do
    d <- oneOf [ '\'', '\"' ]
    manyTill stringCharP (char d)

identCharP :: Monad m => Parser m Char
identCharP = oneOf (['a'..'z'] ++ ['A'..'Z'] ++ ['_'] ++ ['0'..'9'])

stringLiteralExprP :: Monad m => Parser m Expression
stringLiteralExprP = do
    StringLiteralE . Text.pack <$> stringLiteralP

stringCharP :: Monad m => Parser m Char
stringCharP = do
    c1 <- anyChar
    case c1 of
        '\\' -> do
            c2 <- anyChar
            case c2 of
                'n' -> return '\n'
                'b' -> return '\b'
                'v' -> return '\v'
                '0' -> return '\0'
                't' -> return '\t'
                _ -> return c2
        _ -> return c1
