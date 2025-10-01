{-# LANGUAGE OverloadedStrings #-}
module Utils where

import Control.Monad (when, forM, foldM)
import Data.Char (isSpace)
import Data.List (group, intercalate, sort, isInfixOf, isPrefixOf, isSuffixOf, tails, elemIndices)
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Map as M (keys, filter, fromListWith, empty, fromList, map, Map)
import Data.Containers.ListUtils (nubOrd)
import qualified Data.Set as S (empty, member, insert, Set)
import Data.Text.IO as TIO (readFile, writeFile)
import Network.URI (parseURIReference, uriAuthority, uriPath, uriRegName, parseURI, uriScheme, uriAuthority, uriPath, uriRegName, isURIReference, isRelativeReference, uriToString, escapeURIString, isUnescapedInURI)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile, listDirectory, getModificationTime, doesDirectoryExist, getFileSize)
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO (stderr, hPutStr)
import System.IO.Temp (emptySystemTempFile)
import Text.Show.Pretty (ppShow)
import qualified Data.Text as T (Text, concat, pack, unpack, isInfixOf, isPrefixOf, isSuffixOf, replace, head, append, reverse, takeWhile, strip, dropWhile, elem)
import System.Exit (ExitCode(ExitFailure))
import qualified Data.ByteString.Lazy.UTF8 as U (toString)
import Data.FileStore.Utils (runShellCommand)
import Control.DeepSeq (deepseq, NFData)
-- import System.Posix.Files (touchFile)

import Data.Time.Format (parseTimeM, defaultTimeLocale)
import Data.Time.Calendar (Day, diffDays)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)

import Text.Regex (subRegex, mkRegex) -- WARNING: for Unicode support, this needs to be 'regex-compat-tdfa' package, otherwise, the search-and-replaces will go badly awry!
import Control.Exception (catch, evaluate, try, SomeException)
import System.IO.Unsafe (unsafePerformIO)

import Text.Pandoc (def, nullAttr, nullMeta, runPure,
                    writerColumns, writePlain, Block(Div, RawBlock), Pandoc(Pandoc), Inline(..), MathType(InlineMath), Block(Para), readerExtensions, writerExtensions, readHtml, writeMarkdown, pandocExtensions, WriterOptions, Extension(Ext_shortcut_reference_links), enableExtension, Attr, Format(..), topDown, writeHtml5String)
import Text.Pandoc.Walk (walk)
import Unique (isUniqueList)

import qualified Debug.Trace as DT (trace)

import qualified Data.Map.Strict as Map (fromList, lookup)

-- Helper function to create a map from size to its percentile rank (0–100)
-- Takes the list of all positive sizes found.
calculateSizeToPercentileMap :: [Int] -> M.Map Int Int
calculateSizeToPercentileMap [] = M.empty
calculateSizeToPercentileMap positiveSizes =
    let n = length positiveSizes
    in case n of
        0 -> M.empty
        1 -> M.fromList [(head positiveSizes, 100)] -- Only value is 100th percentile
        _ ->
            let sortedSizes = sort positiveSizes
                -- Create pairs of (value, 0-based rank), handling duplicates correctly for lookup
                -- Example: [50, 100, 100, 150] -> [(50,0), (100,1), (100,2), (150,3)]
                rankedSizes = zip sortedSizes [(0::Int)..]
                -- Create a map from each unique value to its *highest* rank
                -- Example: Map { 50 => 0, 100 => 2, 150 => 3 }
                rankMap = M.fromList rankedSizes
                -- Pre-calculate denominator
                n_minus_1 = fromIntegral (n - 1) :: Double
                -- Function to calculate percentile from rank
                calculatePerc rank = round $ (fromIntegral rank / n_minus_1) * 100.0
            -- Create the final map by applying calculation to each rank in the rankMap
            in M.map calculatePerc rankMap

-- | Calculates the percentile rank (0–100) for each positive integer in a list.
--   Non-positive values (< 1) are ignored.
--
--   The order of the returned percentiles corresponds to the order of the
--   original positive values in the input list.
--   Percentile is calculated as: round( (rank / (count − 1)) · 100 )
--   where 'rank' is the 0-based index in the sorted list (using the highest
--   rank for duplicate values), and 'count' is the total number of positive values.
--
--   Returns an empty list if there are no positive values.
--   Returns [100] if there is exactly one positive value.
calculatePercentilesFromWholeNumbers :: [Int] -> [Int]
calculatePercentilesFromWholeNumbers [] = []
calculatePercentilesFromWholeNumbers fileSizes =
    let -- 1. Filter out non-positive values
        positiveSizes = filter (> 0) fileSizes
        -- 2. Get the count of positive values
        n = length positiveSizes
    in case n of
        -- 3. Handle edge cases
        0 -> [] -- No positive values, result is empty
        1 -> [100] -- Only one value, it's the 100th percentile by definition here
        _ -> -- 4. Main calculation for n > 1
            let -- a. Sort the positive values to determine ranks
                sortedSizes = sort positiveSizes

                -- b. Create pairs of (value, 0-based rank/index)
                -- Example: [50, 100, 150, 200, 200] -> [(50,0), (100,1), (150,2), (200,3), (200,4)]
                rankedSizes = zip sortedSizes [(0::Int)..]

                -- c. Create a map from each unique value to its *highest* rank.
                --    `Map.fromList` handles duplicates by keeping the last entry for a given key.
                -- Example: Map.fromList [(50,0), (100,1), (150,2), (200,3), (200,4)]
                --       -> Map { 50 => 0, 100 => 1, 150 => 2, 200 => 4 }
                rankMap = Map.fromList rankedSizes

                -- d. Pre-calculate the denominator for percentile calculation (as Double)
                --    Using n-1 ensures the smallest value gets 0 and the largest gets 100.
                n_minus_1 = fromIntegral (n - 1) :: Double

                -- e. Function to calculate percentile for a single size using the rank map
                calculatePerc size =
                    -- Look up the highest rank for this size
                    case Map.lookup size rankMap of
                        -- This should ideally not happen if size came from positiveSizes
                        Nothing -> error $ "Utils.calculatePercentilesFromWholeNumbers: Internal error: size " ++ show size ++ " not found in rank map."
                        Just rank ->
                            -- Calculate percentile: (rank / (n-1)) * 100, then round
                            round $ (fromIntegral rank / n_minus_1) * 100.0

            -- f. Map the calculation function over the *original* filtered list
            --    to preserve the order corresponding to the input.
            in map calculatePerc positiveSizes

safeGetFileSize :: FilePath -> IO Integer
safeGetFileSize ""   = error "Utils.safeGetFileSize: passed empty string."
safeGetFileSize path = do
    result <- try (getFileSize path) :: IO (Either SomeException Integer)
    case result of
        Left _  -> return 0
        Right size -> return size

getDirectoryContentsSizeRecursive :: FilePath -> IO Integer
getDirectoryContentsSizeRecursive "" = error "Utils.getDirectoryContentsSizeRecursive: passed empty string."
getDirectoryContentsSizeRecursive dirPath = do
    isDir <- doesDirectoryExist dirPath
    if not isDir then
        return 0
    else do
        listResult <- try (listDirectory dirPath) :: IO (Either SomeException [FilePath])
        case listResult of
            Left _ -> return 0
            Right entries -> do
                let fullPaths = map (dirPath </>) entries
                foldM processEntry 0 fullPaths
  where
    processEntry :: Integer -> FilePath -> IO Integer
    processEntry currentTotal entryPath = do
        isFile <- doesFileExist entryPath
        if isFile then do
            fileSize <- safeGetFileSize entryPath
            return (currentTotal + fileSize)
        else do
            isDirectory <- doesDirectoryExist entryPath
            if isDirectory then do
                subDirSize <- getDirectoryContentsSizeRecursive entryPath
                return (currentTotal + subDirSize)
            else
                return currentTotal

-- Write only when changed, to reduce sync overhead; creates parent directories as necessary; writes
-- to a temp file in /tmp/ (at a specified template name), and does an atomic rename to the final file.
writeUpdatedFile :: String -> FilePath -> T.Text -> IO ()
writeUpdatedFile template target contentsNew
 | "" == template || "" == target || "" == contentsNew = error $ "Utils.writeUpdatedFiles: empty argument passed; this should never happen! Arguments were: " ++ show [template, target, T.unpack contentsNew]
 | otherwise =
  do existsOld <- doesFileExist target
     if not existsOld then do
       createDirectoryIfMissing True (takeDirectory target)
       TIO.writeFile target contentsNew
       else do contentsOld <- TIO.readFile target
               if contentsNew /= contentsOld then do tempPath <- emptySystemTempFile ("hakyll-"++template)
                                                     TIO.writeFile tempPath contentsNew
                                                     renameFile tempPath target
               else return () -- touchFile target -- mark as up to date

trim :: String -> String
trim = reverse . dropWhile badChars . reverse . dropWhile badChars -- . filter (/='\n')
  where badChars :: Char -> Bool
        badChars c = isSpace c || (c=='-')

simplifiedHtmlToString :: String -> String
simplifiedHtmlToString = T.unpack . T.strip . simplifiedDoc . toPandoc

simplifiedString :: String -> String
simplifiedString s = trim $ -- NOTE: 'simplified' will return a trailing newline, which is unhelpful when rendering titles.
                     T.unpack $ simplified $ Para [Str $ T.pack s]

simplified :: Block -> T.Text
simplified i = simplifiedDoc (Pandoc nullMeta [i])

simplifiedDoc :: Pandoc -> T.Text
simplifiedDoc p = let md = runPure $ writePlain def{writerColumns=100000} p in -- NOTE: it is important to make columns ultra-wide to avoid formatting-newlines being inserted to break up lines mid-phrase, which would defeat matches in LinkAuto.hs.
                         case md of
                           Left _ -> error $ "Failed to render: " ++ show md
                           Right md' -> md'

toMarkdown :: String -> String
toMarkdown abst = let clean = runPure $ do
                                   pandoc <- readHtml def{readerExtensions=pandocExtensions} (T.pack abst)
                                   md <- writeMarkdown def{writerExtensions = pandocExtensions, writerColumns=100000} pandoc
                                   return $ T.unpack md
                             in case clean of
                                  Left e -> error $ ppShow e ++ ": " ++ abst
                                  Right output -> output

simplifiedHTMLString :: String -> String
simplifiedHTMLString arg = trim $ T.unpack $ simplified $ parseRawBlock nullAttr (RawBlock (Text.Pandoc.Format "html") (T.pack arg))

-- HACK: this is a workaround for an edge-case: Pandoc reads complex tables as 'grid tables', which then, when written using the default writer options, will break elements arbitrarily at newlines (breaking links in particular). We set the column width *so* wide that it should never need to break, and also enable 'reference links' to shield links by sticking their definition 'outside' the table. See <https://github.com/jgm/pandoc/issues/7641>.
-- This also gives us somewhat cleaner HTML by making Pandoc not insert '\n'.
safeHtmlWriterOptions :: Text.Pandoc.WriterOptions
safeHtmlWriterOptions = def{writerColumns = 9999, writerExtensions = enableExtension Ext_shortcut_reference_links pandocExtensions}

-- write an Inline to a HTML string fragment; strip the `<p></p>` Pandoc wrapper
-- > toHTML $ Span nullAttr [Str "foo"]
-- → "<span>foo</span>"
-- > toHTML $ Str "foo"
-- → "foo"
toHTML :: Inline -> String
toHTML il = let clean = runPure $ do
                                   md <- writeHtml5String def (Pandoc nullMeta [Para [il]])
                                   return $ sed "^<span>(.*)</span>$" "\\1" $ sed "^<p>(.*)</p>$" "\\1" $ replace "\n" " " $ T.unpack md
                             in case clean of
                                  Left e -> error $ ppShow e ++ ": " ++ show il
                                  Right output -> output

toPandoc :: String -> Pandoc
toPandoc abst = let clean = runPure $ readHtml def{readerExtensions=pandocExtensions} $ T.pack abst
                in case clean of
                     Left e -> error $ ppShow e ++ ": " ++ abst
                     Right output -> output

parseRawAllClean :: Pandoc -> Pandoc
parseRawAllClean = topDown cleanUpDivsEmpty .
                   walk cleanUpSpans .
                   -- walk (parseRawInline nullAttr) .
                   walk (parseRawBlock nullAttr)

-- WARNING: this is deliberately `readHtml`, even though that will erase some forms of HTML constructs when Pandoc reads it,
-- because `readMarkdown`, while more permissive in that respect, results in *other* forms of breakage, apparently linked to lingering Raw* blocks
-- which then disable most downstream rewrites (eg. if you switch, the inflation-adjustments will all spontaneously stop working).
parseRawBlock :: Attr -> Block -> Block
parseRawBlock attr x@(RawBlock (Format "html") h) = let pandoc = runPure $ readHtml def{readerExtensions = pandocExtensions} h in
                                          case pandoc of
                                            Left e -> error (show x ++ " : " ++ show e)
                                            Right (Pandoc _ blocks) -> Div attr blocks
parseRawBlock _ x = x
-- WARNING: appears to break some instances of inline HTML, especially subsup instances. I was unable to debug why.
-- parseRawInline :: Attr -> Inline -> Inline
-- parseRawInline attr x@(RawInline (Format "html") h) = let pandoc = runPure $ readHtml def{readerExtensions = pandocExtensions} h in
--                                           case pandoc of
--                                             Left e -> error (show x ++ " : " ++ show e)
--                                             Right (Pandoc _ [Para inlines]) -> Span attr inlines
--                                             Right (Pandoc _ [Plain inlines]) -> Span attr inlines
--                                             Right (Pandoc _ inlines) -> Span attr (extractAndFlattenInlines inlines)
-- parseRawInline _ x = x
-- extractAndFlattenInlines :: [Block] -> [Inline]
-- extractAndFlattenInlines [RawBlock (Format "html") x]  = [RawInline (Format "html") x]
-- extractAndFlattenInlines x = error ("extractAndFlattenInlines: hit a RawBlock which couldn't be parsed? : " ++ show x)

-- we probably want to remove the link-auto-skipped Spans if we are not actively debugging, because they inflate the markup & browser DOM.
-- We can't just remove the Span using a 'Inline -> Inline' walk, because a Span is an Inline with an [Inline] payload, so if we just remove the Span wrapper, it is a type error: we've actually done 'Inline -> [Inline]'.
-- Block elements always have [Inline] (or [[Inline]]) and not Inline arguments if they have Inline at all; likewise, Inline element also have only [Inline] arguments.
-- So, every instance of a Span *must* be inside an [Inline]. Therefore, we can walk an [Inline], and remove the wrapper, and then before++payload++after :: [Inline] and it typechecks and doesn't change the shape.
--
-- > cleanUpSpans [Str "foo", Span ("",["link-auto-skipped"],[]) [Str "Bar", Emph [Str "Baz"]], Str "Quux"]
--                               [Str "foo",                                     Str "Bar", Emph [Str "Baz"],  Str "Quux"]
-- > walk cleanUpSpans $ Pandoc nullMeta [Para [Str "foo", Span ("",["link-auto-skipped"],[]) [Str "Bar", Emph [Str "Baz"]], Str "Quux"]]
-- Pandoc (Meta {unMeta = fromList []}) [Para [Str "foo",Str "Bar",Emph [Str "Baz"],Str "Quux"]]
--
-- NOTE: might need to generalize this to clean up other Span crud?
cleanUpSpans :: [Inline] -> [Inline]
cleanUpSpans [] = []
cleanUpSpans   (Span ("",[],[]) payload : rest)                             = payload ++ rest
cleanUpSpans x@(Span (_,[],_) _ : _)                                        = x
cleanUpSpans   (Span (_,["link-auto-skipped"],_) payload : rest)            = payload ++ rest
cleanUpSpans   (Span (_,["link-auto-first", "link-auto"],_) payload : rest) = payload ++ rest
cleanUpSpans   (Span (a,classes,b) c : rest) = let classes' = filter (\cl -> cl `notElem` ["link-auto","link-auto-first","link-auto-skipped"]) classes in
                                                                              Span (a,classes',b) c : rest
cleanUpSpans (x@Link{} : rest) =  removeClass "link-auto" x : cleanUpSpans rest
cleanUpSpans (r:rest) = r : cleanUpSpans rest

cleanUpDivsEmpty :: [Block] -> [Block]
cleanUpDivsEmpty [] = []
cleanUpDivsEmpty (Div ("",[],[]) payload : rest) = payload ++ rest
cleanUpDivsEmpty (r:rest) = r : cleanUpDivsEmpty rest -- if it is not a nullAttr, then it is important and carrying a class like "abstract" or something, and must be preserved.

-- convert a LaTeX expression to Unicode/HTML/CSS by an OA API script.
-- > Text.Pandoc.Walk.walkM inlineMath2Text [Math InlineMath "a + b = c"]
-- [RawInline (Format "html") "<em>a</em> + <em>b</em> = <em>c</em>"]
inlineMath2Text :: Inline -> IO Inline
inlineMath2Text x@(Math InlineMath a) =
  do (status,_,mb) <- runShellCommand "./" Nothing "python3" ["static/build/latex2unicode.py", T.unpack a]
     let mb' = T.pack $ trim $ U.toString mb
     case status of
       ExitFailure err -> printGreen (intercalate " : " [T.unpack a, T.unpack mb', ppShow status, ppShow err, ppShow mb']) >> printRed "latex2unicode.py failed!" >> return x
       _ -> return $ if mb' == a then x else RawInline (Format "html") mb'
inlineMath2Text x = return x

flattenLinksInInlines :: [Inline] -> [Inline]
flattenLinksInInlines = map flattenLinks
  where flattenLinks :: Inline -> Inline
        flattenLinks x@Link{} = Str (inlinesToText [x])
        flattenLinks x = x

-- | Convert a list of inlines into a string.
inlinesToText :: [Inline] -> T.Text
inlinesToText = -- HACK: dealing with RawInline pairs like [RawInline "<sup>", Text "th", RawInline "</sup>"] is a PITA to do properly (have to process to HTML and then back into AST), so we'll just handle special cases for now...
  deleteManyT ["<sup>", "</sup>", "<sub>","</sub>", "<em>", "</em>", "%3Cem%3", "%3C/em%3E", "<strong>", "</strong>", "%3Cstrong%3", "%3C/strong%3E"] .
                T.concat . map go
  where go x = case x of
               -- reached the literal T.Text:
               Str s    -> s
               -- strip & recurse on the [Inline]:
               Emph        x' -> inlinesToText x'
               Underline   x' -> inlinesToText x'
               Strong      x' -> inlinesToText x'
               Strikeout   x' -> inlinesToText x'
               Superscript x' -> inlinesToText x'
               Subscript   x' -> inlinesToText x'
               SmallCaps   x' -> inlinesToText x'
               -- throw away attributes and recurse on the [Inline]:
               Span _      x' -> inlinesToText x' -- eg. [foo]{.smallcaps} -> foo
               Quoted _    x' -> inlinesToText x'
               Cite _      x' -> inlinesToText x'
               Link _   x' _  -> inlinesToText x'
               Image _  x' _  -> inlinesToText x'
               -- throw away attributes, return the literal T.Text:
               Math _      x' -> x'
               RawInline _ x' -> x'
               Code _      x' -> x'
               -- fall through with a blank:
               _        -> " "::T.Text

inline2Path :: Inline -> T.Text
inline2Path (Link _ _ (path,_)) = path
inline2Path (Image _ _ (path,_)) = path
inline2Path x = error $ "Utils.inline2Path: called on an Inline for which there is no filepath target‽ " ++ show x

-- Add or remove a class to a Link or Span; this is a null op if the class is already present or it is not a Link/Span.
addClass :: T.Text -> Inline -> Inline
addClass clss x@(Code  (i, clsses, ks) code)        = if clss `elem` clsses then x else Code  (i, clss:clsses, ks) code
addClass clss x@(Image (i, clsses, ks) s (url, tt)) = if clss `elem` clsses then x else Image (i, clss:clsses, ks) s (url, tt)
addClass clss x@(Link  (i, clsses, ks) s (url, tt)) = if clss `elem` clsses then x else Link  (i, clss:clsses, ks) s (url, tt)
addClass clss x@(Span  (i, clsses, ks) s)           = if clss `elem` clsses then x else Span  (i, clss:clsses, ks) s
addClass clss x = error $ "Utils.addClass: attempted to add a class of an Inline where that makes no sense? " ++ show clss ++ " : " ++ show x
removeClass :: T.Text -> Inline -> Inline
removeClass clss x@(Code  (i, clsses, ks) code)        = if clss `notElem` clsses then x else Code  (i, filter (/=clss) clsses, ks) code
removeClass clss x@(Image (i, clsses, ks) s (url, tt)) = if clss `notElem` clsses then x else Image (i, filter (/=clss) clsses, ks) s (url, tt)
removeClass clss x@(Link (i, clsses, ks) s (url, tt))  = if clss `notElem` clsses then x else Link  (i, filter (/=clss) clsses, ks) s (url, tt)
removeClass clss x@(Span (i, clsses, ks) s)            = if clss `notElem` clsses then x else Span  (i, filter (/=clss) clsses, ks) s
removeClass clss x = error $ "Utils.removeClass: attempted to remove a class of an Inline where that makes no sense? " ++ show clss ++ " : " ++ show x

hasClass :: T.Text -> Inline -> Bool
hasClass clss (Code  (_, clsses, _) _)   = clss `elem` clsses
hasClass clss (Image (_, clsses, _) _ _) = clss `elem` clsses
hasClass clss (Link (_, clsses, _) _ _)  = clss `elem` clsses
hasClass clss (Span (_, clsses, _) _)    = clss `elem` clsses
hasClass clss x = error $ "Utils.hasClass: attempted to check the class of an Inline where that makes no sense? " ++ show clss ++ " : " ++ show x

removeKey :: T.Text -> Inline -> Inline
removeKey key (Code  (i, cl, ks) code)        = Code  (i, cl, filter (\(k,_) -> k/=key) ks) code
removeKey key (Image (i, cl, ks) s (url, tt)) = Image (i, cl, filter (\(k,_) -> k/=key) ks) s (url, tt)
removeKey key (Link  (i, cl, ks) s (url, tt)) = Link  (i, cl, filter (\(k,_) -> k/=key) ks) s (url, tt)
removeKey key (Span  (i, cl, ks) s)           = Span  (i, cl, filter (\(k,_) -> k/=key) ks) s
removeKey key x = error $ "Utils.removeKey: attempted to remove a key from the key-value dict of an Inline where that makes no sense? " ++ show key ++ " : " ++ show x
addKey :: (T.Text,T.Text) -> Inline -> Inline
addKey key (Code  (i, cl, ks) code)        = Code  (i, cl, nubOrd (key : ks)) code
addKey key (Image (i, cl, ks) s (url, tt)) = Image (i, cl, nubOrd (key : ks)) s (url, tt)
addKey key (Link  (i, cl, ks) s (url, tt)) = Link  (i, cl, nubOrd (key : ks)) s (url, tt)
addKey key (Span  (i, cl, ks) s)           = Span  (i, cl, nubOrd (key : ks)) s
addKey key x = error $ "Utils.addKey: attempted to add a key from the key-value dict of an Inline where that makes no sense? " ++ show key ++ " : " ++ show x

hasKey :: T.Text -> Inline -> Bool
hasKey key (Code  (_, _, kvs) _)   = any (\(k, _) -> k == key) kvs
hasKey key (Image (_, _, kvs) _ _) = any (\(k, _) -> k == key) kvs
hasKey key (Link  (_, _, kvs) _ _)  = any (\(k, _) -> k == key) kvs
hasKey key (Span  (_, _, kvs) _)    = any (\(k, _) -> k == key) kvs
-- For other elements, return False as they don't have key-value attributes.
hasKey _ _ = False

hasExtension :: T.Text -> T.Text -> Bool
hasExtension ext p = extension p == ext

hasExtensionS :: String -> String -> Bool
hasExtensionS ext p = hasExtension (T.pack ext) (T.pack p)

extension :: T.Text -> T.Text
extension = T.pack . maybe "" (System.FilePath.takeExtension . uriPath) . parseURIReference . T.unpack

isLocal :: T.Text -> Bool
isLocal "" = error "Utils.isLocal: Invalid empty string used as link."
isLocal s = T.head s == '/'

-- throw a fatal error if any entry in a list fails a test; uses `NFData`/`deepseq` to guarantee that the test gets evaluated
-- and will kill as soon as possible.
ensure :: (Show a, NFData a) => String -> String -> (a -> Bool) -> [a] -> [a]
ensure location fString f xs = deepseq evaluatedList evaluatedList
  where
    evaluatedList = map (\i -> if f i then i
                               else error (location ++ ": failed property check '" ++ fString ++ "'; input was: " ++ show i)) xs

-- Check if a string is a plausible domain or subdomain
isDomain :: String -> Bool
isDomain domain = case parseURI ("http://" ++ domain) of
    Just uri -> case uriAuthority uri of
        Just auth -> null (uriPath uri) && not (null (uriRegName auth))
        Nothing -> False
    Nothing -> False
isDomainT :: T.Text -> Bool
isDomainT = isDomain . T.unpack

-- Check if a string is a valid remote/external HTTP or HTTPS URL only. To check local paths, use `isURIReference`/`isURIReferenceT`. To check both, use `isURLAny`
isURL :: String -> Bool
isURL "" = error "Utils.isURL: passed an empty string as a URL. This should never happen!"
isURL url = case parseURI (T.unpack $ escapeUnicode $ T.pack url) of
              Just uri -> let scheme = uriScheme uri in
                            scheme == "http:" || scheme == "https:"
              Nothing -> False
isURLT :: T.Text -> Bool
isURLT = isURL . T.unpack

-- check local/external URLs; for weirdo protocols like IRC or email, we default to True.
isURLAny :: String -> Bool
isURLAny "" = error "Utils.isURLAny: passed an empty string as a URL. This should never happen!"
isURLAny url
  | "irc://" `isPrefixOf` url || "mailto:" `isPrefixOf` url || '#' == last url = True
  | head url == '/' = isURILocalT (T.pack url)
  | otherwise       = isURL url
isURLAnyT :: T.Text -> Bool
isURLAnyT = isURLAny . T.unpack

-- check that a local URL like `/doc/foo.pdf` or `/essay` is a valid URI;
-- this is equivalent to checking for the mandatory root slash, and then `isURIReferenceT`.
isURILocalT :: T.Text -> Bool
isURILocalT "" = error "Utils.isURILocalT: passed an empty string as a URL. This should never happen!"
isURILocalT url = T.head url == '/' && isURIReferenceT (escapeUnicode url)

isURIReferenceT :: T.Text -> Bool
isURIReferenceT = isURIReference . T.unpack . escapeUnicode

isHostOrArchive :: T.Text -> T.Text -> Bool
isHostOrArchive domain url = let h = host url in
                                h == domain || ("/doc/www/"`T.append`domain) `T.isPrefixOf` url

-- enable printing of normal vs dangerous log messages to terminal stderr:
green, red :: String -> String
green s = "\x1b[32m" ++ s ++ "\x1b[0m"
red   s = "\x1b[41m" ++ s ++ "\x1b[0m"

-- print normal progress messages to stderr in bold green:
putStrGreen, printGreen :: String -> IO ()
putStrGreen s = putStrStdErr $ green s
printGreen  s = putStrGreen (s ++ "\n")

-- print danger or error messages to stderr in red background:
putStrRed, printRed :: String -> IO ()
putStrRed s = do when (length s > 2048) $ printRed "Warning: following error message was extremely long & truncated at 2048 characters!"
                 putStrStdErr $ red $ take 2048 s
printRed s = putStrRed (s ++ "\n")
-- special-case: the error message, then useful values:
printRed' :: String -> String -> IO ()
printRed' e l = putStrRed e >> printGreen l

putStrStdErr :: String -> IO ()
putStrStdErr = hPutStr stderr

-- Repeatedly apply `f` to an input until the input stops changing. 'Show' constraint is required for better error reporting on the occasional infinite loop, and 'Ord' constraint is required for easy duplicate-checking via Sets. (If necessary, this could be removed with the Floyd tortoise-and-hare cycle detector <https://en.wikipedia.org/wiki/Cycle_detection#Floyd%27s_tortoise_and_hare>, although that is more complicated & probably a bit slower for our uses.)
-- Note: set to 5000 iterations by default. However, if you are using a list of _n_ simple rewrite rules, the limit can be set a priori to _n_+1 rewrites
-- as any more than that implies a cycle/infinite-loop.
fixedPoint :: (Show a, Eq a, Ord a) => (a -> a) -> a -> a
fixedPoint = fixedPoint' 5000 S.empty
 where
  fixedPoint' :: (Show a, Eq a, Ord a) => Int -> S.Set a -> (a -> a) -> a -> a
  fixedPoint' 0 _ _ i = error $ "Hit recursion limit: still changing after 5,000 iterations! Infinite loop? Last result: " ++ show i
  fixedPoint' n seen f i
    | i `S.member` seen = error $ "Cycle detected! Last result: " ++ show i ++ " with iterations left = " ++ show n ++ "; full history: " ++ show seen
    | otherwise =
        let i' = f i
        in if i' == i
           then i
           else fixedPoint' (n-1) (S.insert i seen) f i'

-- because the regex libraries throw fatal exceptions, which are highly uninformative, we have to do a lot of work to catch exceptions and print out useful debug info for identifying *what* regexp went wrong, rather than unhelpfully reporting "Exception 13" or whatever.
sed :: String -> String -> String -> String
sed before after s = unsafePerformIO $ do
  let action = if before == after
                 then error $ "Fatal error in `sed`: before == after: \"" ++ before ++ "\""
                 else do
                   let regex = mkRegex before
                   let result = subRegex regex s after
                   _ <- evaluate (length result)  -- Force full evaluation, so we catch it here and now, rather than it happening later and skipping the debugging info
                   return result
  catch action handleExceptions
    where
      handleExceptions :: SomeException -> IO String
      handleExceptions e = return $ "Error occurred. Exception: " ++ show e ++
                                    "; arguments were: '" ++ before ++
                                    "' : '" ++ after ++ "' : '" ++ s ++ "'"

-- list of regexp string rewrites
sedMany :: [(String,String)] -> (String -> String)
sedMany regexps s = foldr (uncurry sed) s (isUniqueList regexps)

-- (`replace`/`split`/`hasKeyAL` copied from <https://hackage.haskell.org/package/MissingH-1.5.0.1/docs/src/Data.List.Utils.html> to avoid MissingH's dependency on regex-compat)
-- replace requires that the 2 replacements be different, but otherwise does not impose any requirements like non-nullness or that any replacement happened. So it can be used to delete strings without replacement (`replace "foo" ""` or as a shortcut, `delete "foo"`), or 'just in case'.
-- For search-and-replace where you *know* you meant to change the input, use `replaceChecked`.
replace :: (Eq a, Show a) => [a] -> [a] -> [a] -> [a]
replace before after = if before == after then error ("Fatal error in `replace`: identical args (before == after): " ++ show before) else intercalate after . split before
-- NOTE: a `splitT` is unnecessary because Data.Text defines its own `split`/`splitAt`/`splitOn` functions.
split :: Eq a => [a] -> [a] -> [[a]]
split _ [] = []
split delim str =
    let (firstline, remainder) = breakList (isPrefixOf delim) str
        in
        firstline : case remainder of
                                   [] -> []
                                   x -> if x == delim
                                        then [[]]
                                        else split delim
                                                 (drop (length delim) x)
  where
    breakList :: ([a] -> Bool) -> [a] -> ([a], [a])
    breakList func = spanList (not . func)
    spanList :: ([a] -> Bool) -> [a] -> ([a], [a])
    spanList _ [] = ([],[])
    spanList func list@(x:xs) =
        if func list
           then (x:ys,zs)
           else ([],list)
        where (ys,zs) = spanList func xs
hasKeyAL :: Eq a => a -> [(a, b)] -> Bool
hasKeyAL key list = key `elem` map fst list

-- list of fixed string rewrites
replaceMany :: [(String,String)] -> (String -> String)
replaceMany rewrites s = foldr (uncurry replace) s (isUniqueList rewrites)

replaceT :: T.Text -> T.Text -> T.Text -> T.Text
replaceT = T.replace

-- list of fixed string rewrites
replaceManyT :: [(T.Text,T.Text)] -> (T.Text -> T.Text)
replaceManyT rewrites s = foldr (uncurry replaceT) s (isUniqueList rewrites)

-- specialize the `replace` family to deletion, as is the most common usecase:
-- Delete a substring from a list
delete :: String -> String -> String
delete "" = error "Utils.delete: passed an empty string to delete? That makes no sense and should never happen."
delete x = replace x ""

-- Enable prefix & suffix string deletion for the common usecase of space-separated deletion.
--
-- If a string starts with a space, it is removed from the back (as a trailing suffix like "Title - Site name"); if it starts with a space, it is removed from the front (ie. "Site name - Title"); if it starts with neither, it is just removed anywhere it appears (equivalent to `delete`).
deleteMixed :: String -> String -> String
deleteMixed "" _ = error "Utils.deleteMixed: passed an empty string to delete? That makes no sense and should never happen."
deleteMixed target str
    | head target == ' ' = if tail target `isSuffixOf` str
                          then take (length str - length (tail target)) str
                          else str
    | last target == ' ' = if init target `isPrefixOf` str
                          then drop (length (init target)) str
                          else str
    | otherwise = delete target str

-- | Apply multiple mixed deletions in sequence
deleteMixedMany :: [String] -> (String -> String)
deleteMixedMany xs s = foldr deleteMixed s (isUniqueList xs)

-- Delete a substring from a Text
deleteT :: T.Text -> T.Text -> T.Text
deleteT x = replaceT x ""

-- Delete multiple substrings from a list
deleteMany :: [String] -> (String -> String)
deleteMany xs s = foldr delete s (isUniqueList xs)

-- Delete multiple substrings from a Text
deleteManyT :: [T.Text] -> (T.Text -> T.Text)
deleteManyT xs s = foldr deleteT s (isUniqueList xs)

kvLookup :: String -> [(String, String)] -> String
kvLookup key xs = fromMaybe "" (lookup key xs)

kvLookupT :: T.Text -> [(T.Text, T.Text)] -> T.Text
kvLookupT key xs = fromMaybe "" (lookup key xs)

kvDOI :: [(String,String)] -> String
kvDOI = kvLookup "doi"

kvDOIT :: [(T.Text,T.Text)] -> T.Text
kvDOIT = kvLookupT "doi"

replaceExact :: Eq a => [(a, a)] -> [a] -> [a]
replaceExact assoc xs = [fromMaybe x (lookup x assoc) | x <- xs]

-- more rigid `replace`, intended for uses where a replacement is not optional but *must* happen.
-- `replaceChecked` will error out if any of these are violated: all arguments & outputs are non-null, unique, and the replacement happened.
replaceChecked :: (Eq a, Show a) => [a] -> [a] -> [a] -> [a]
replaceChecked before after str
  | any null variables                               = error $ "replaceChecked: some argument or output was null/empty: " ++ variablesS
  | before == after || after == str || str == before = error $ "replaceChecked: arguments were not unique: " ++ variablesS
  | not (after `isInfixOf` result)                   = error $ "replaceChecked: replacement did not happen! " ++ variablesS
  | otherwise                                        = result
  where result = replace before after str
        variables = [before, after, str, result]
        variablesS = show variables
-- TODO: would it be useful to have a 'replaceDeleteStrict' which allows a "" `after` argument, since that's one of the most common use-cases?

-- a count, in ascending order:
frequency :: Ord a => [a] -> [(Int,a)]
frequency list = sort $ map (\l -> (length l, head l)) (group (sort list))

pairs :: [b] -> [(b, b)]
pairs l = [(x,y) | (x:ys) <- tails l, y <- ys]

-- Network.URI-based function to extract the 'host' domain of a URL. Return empty string if not sensible.
-- This additionally enforces the Gwern.net style guide that host root domains (in absolute, rather than relative, URLs) must have the optional trailing slash, and fatally error out if not (ie. "https://example.com" *must* be written "https://example.com/", as that is the root; however this doesn't apply to any URLs with additional paths, because the slash can mean entirely different things).
-- URIs may have a whitelist of known schemes (mailto:, irc:) or may be an anchor fragment ('#foo') but then those are skipped. (Others are assumed to be malformed and fatally error.)
-- WARNING: due to the difficulty of getting Network.URI to accept unescaped Unicode, we attempt to escape it before processing, so `host` is operating on a somewhat different URL than you assume if it contains raw Unicode.
-- (With HTML5, it is valid to have unescaped Unicode in URLs, and Pandoc generates these rather than percent-encode them. However, with older standards, which Network.URI was written against, they are required to be percent-encoded.)
host :: T.Text -> T.Text
host p = if T.head p `elem` ['#', '!'] || isInflationURL p then "" else
  case parseURIReference (T.unpack $ escapeUnicode p) of
    Nothing -> let anchor = T.dropWhile (/='#') p in
                 if '#' `T.elem` anchor then "" else -- we skip this 'bad' URL because it may just be us using the PmWiki range syntax for transcludes, like `/lorem-link#internal-page-links#` or `/doc/fiction/poetry/1963-valek-killingrabbits##`; but if there is no hash in what appears to be the anchor, then we may have a real issue and should complain about it:
                   DT.trace ("Utils.host: Invalid URL; input was: " ++ show p) ""
    Just uri' ->
        let scheme = uriScheme uri'
        in if null scheme || scheme == "mailto:" || scheme == "irc:" then "" -- skip anchor fragments, emails, IRC
           else if not (scheme == "http:" || scheme == "https:")  -- Only process HTTP/HTTPS URLs
           then error $ "Utils.host: Unsupported scheme; input was: " ++ show p ++ "; parsed URI was: " ++ show uri' ++ "; scheme was: " ++ show scheme
           else if isRelativeReference (uriToString id uri' "")  -- Check if it's a relative URL
           then error $ "Utils.host: Relative URL; input was: " ++ show p ++ "; parsed URI was: " ++ show uri'
           else case uriAuthority uri' of
                Nothing -> error $ "Utils.host: No authority in URL; input was: " ++ show p ++ "; parsed URI was: " ++ show uri'
                Just auth ->
                    let path = T.pack $ uriPath uri'
                    in if path == ""  -- If the path is empty, it means the trailing slash is missing
                       then unsafePerformIO (printRed ("Utils.host: Root domain lacks trailing slash; original input was: " ++ show p ++ "; parsed URI was: " ++ show uri') >>
                                              return (T.pack $ uriRegName auth))
                       else T.pack $ uriRegName auth

escapeUnicode :: T.Text -> T.Text
escapeUnicode = T.pack . escapeURIString isUnescapedInURI . T.unpack

anyInfix, anyPrefix, anySuffix :: String -> [String] -> Bool
anyInfix  p = any (`isInfixOf`  p)
anyPrefix p = any (`isPrefixOf` p)
anySuffix p = any (`isSuffixOf` p)

anyInfixT, anyPrefixT, anySuffixT :: T.Text -> [T.Text] -> Bool
anyInfixT  p = any (`T.isInfixOf`  p)
anyPrefixT p = any (`T.isPrefixOf` p)
anySuffixT p = any (`T.isSuffixOf` p)

{- | Returns true if the given list contains any of the elements in the search
list. -}
hasAny :: Eq a => [a]           -- ^ List of elements to look for
       -> [a]                   -- ^ List to search
       -> Bool                  -- ^ Result
hasAny [] _          = False             -- An empty search list: always false
hasAny _ []          = False             -- An empty list to scan: always false
hasAny search (x:xs) = x `elem` search || hasAny search xs

-- Data.Text equivalent of System.FilePath.takeExtension
takeExtension :: T.Text -> T.Text
takeExtension f = T.reverse $
                  T.takeWhile ((/=) '.') $
                  (if '#' `T.elem` f then T.dropWhile (/='#') else id) $
                  T.reverse f

-- | 'repeated' finds only the elements that are present more than once in the list.
-- Example:
--
-- > repeated  "foo bar" == "o"
repeated :: Ord a => [a] -> [a]
repeated xs = M.keys $ M.filter (> (1::Int)) $ M.fromListWith (+) [(x,1) | x <- xs]

-- eg. 'calculateDateSpan "1939-09-01" "1945-05-08"' → 2077
-- or 'calculateDateSpan "1939-09" "1945-05"' → 2070 (where the day is assumed to be the first of the month)
-- or mixed, 'calculateDateSpan "1939-09" "1945-05-02"' → 2071
calculateDateSpan :: String -> String -> Int
calculateDateSpan start end =
    let startDate = parseDate start
        endDate = parseDate end
    in calculateDays startDate endDate

parseDate :: String -> Day
parseDate dateStr
  | length dateStr < 4 || length dateStr > 10 = error $ "Utils.parseDate: passed invalid date which is not YYYY-MM(-DD)? Was " ++ dateStr
  | otherwise =
    case parseTimeM True defaultTimeLocale "%Y-%m-%d" dateStr of -- 'YYYY-MM-DD'
        Just date -> date
        Nothing -> case parseTimeM True defaultTimeLocale "%Y-%m" (take 7 dateStr) of -- retry as 'YYYY-MM-?'
            Just date -> date
            Nothing -> case parseTimeM True defaultTimeLocale "%Y" (take 4 dateStr) of -- retry as 'YYYY?'
                         Just date -> date
                         Nothing   -> error $ "Utils.parseDate: Invalid date format (could not be parsed as YYYY-MM-DD, YYYY-MM, or YYYY): " ++ dateStr

calculateDays :: Day -> Day -> Int
calculateDays start end = fromInteger $ succ $ diffDays end start  -- succ to make it inclusive

-- return the Unix timestamp ('%D') of the most recently modified file in a given directory:
getMostRecentlyModifiedDir :: FilePath -> IO String
getMostRecentlyModifiedDir dir = do
  files <- listDirectory dir
  modTimes <- forM files $ \file -> do
    let path = dir </> file
    isFile <- doesFileExist path
    if isFile
       then Just . round . utcTimeToPOSIXSeconds <$> getModificationTime path
       else return Nothing
  let timestamps = [ t | Just t <- modTimes ]
      mostRecent = if null timestamps then (0::Integer) else maximum timestamps
  return (show mostRecent)

formatIntWithCommas :: Int -> String
formatIntWithCommas = reverse . intercalate "," . chunksOf 3 . reverse . show
 where
   chunksOf :: Int -> [a] -> [[a]]
   chunksOf _ [] = []
   chunksOf n xs = take n xs : chunksOf n (drop n xs)

-- Format an Int number of days by days/months/years.
-- unit-tests: `[(d,e,formatDaysInLargestUnit d) | (d,e) <- [(0, "0d"),(1, "1d"),(29, "29d"),(30, "30d"),(31, "1m"),(45, "1m"),(46, "1m"),(47, "2m"),(59, "2m"),(60, "2m"),(61, "2m"),(89, "3m"),(90, "3m"),(91, "3m"),(180, "6m"),(364, "12m"),(365, "1y"),(366, "1y"),(400, "1y"),(730, "2y"),(1095, "3y"),(3652, "10y")], formatDaysInLargestUnit d /= e]`
formatDaysInLargestUnit :: Int -> String
formatDaysInLargestUnit days
    | days < 0   = error $ "Utils.formatDaysInLargestUnit: passed a negative number of days, which is nonsensical? Was: " ++ show days
    | days < 31  = show days ++ "d"
    | days < 365 = let
                     monthsFloat = (fromIntegral days * 12 :: Double) / 365.25
                     months      = max 1 (floor (monthsFloat + 0.48)) :: Int
                   in  show months ++ "m"
    | otherwise  = let years = days `div` 365
                   in  show years ++ "y"

-- defined here and used elsewhere in Utils, but re-exported from Inflation to avoid circular dependencies
isInflationURL :: T.Text -> Bool
isInflationURL "" = False
isInflationURL u  = T.head u == '$' || T.head u == '₿'

isInflationLink :: Inline -> Bool
isInflationLink (Link _ _ (y, _))         = isInflationURL y
isInflationLink (Span (_, _, [(k, _)]) _) = k == "inflation"
isInflationLink _                         = False

interleave :: [a] -> [a] -> [a]
interleave (a1:a1s) (a2:a2s) = a1:a2:interleave a1s a2s
interleave _        _        = []

-- | Truncates a string to a maximum length, breaking at the last space
--   before or at the limit and appending "…". Returns the original string
--   if it's within the limit. Handles edge cases for short max lengths.
--
--   This is useful for, eg. truncating titles to fit in a certain column length, like on /index, where titles can't be >30 without risking line-wrapping.
truncateString :: Int -> String -> String
truncateString maxLen string
    | null string = error $ "Utils.truncateString called on an empty string; this makes no sense. Truncation length: " ++ show maxLen
    | maxLen < 1 = error $ "Utils.truncateString called with a nonsensical max string length: " ++ show maxLen ++ "; on the string: " ++ show string
    | length string <= maxLen = string         -- Already fits
    | maxLen < 3              = take maxLen string -- Too short for ellipsis
    | otherwise =
        let
            -- Leave space for "…"
            prefixLen = maxLen - 3
            -- Potential prefix where the break might occur
            prefix    = take prefixLen string
            -- Find indices of all spaces within this potential prefix
            spaceIndices = elemIndices ' ' prefix
            -- Get the index of the *last* space found, if any
            maybeLastSpaceIndex = listToMaybe (reverse spaceIndices)
        in case maybeLastSpaceIndex of
            -- No suitable space found, hard truncate the prefix and add "…"
            Nothing      -> prefix ++ "…"
            -- Found a space, truncate the *original* string just before it and add "…"
            Just lastIdx -> take lastIdx string ++ "…"
