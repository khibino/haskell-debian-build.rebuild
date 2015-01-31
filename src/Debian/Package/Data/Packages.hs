-- |
-- Module      : Debian.Package.Data.Packages
-- Copyright   : 2014 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- This module provides data types of debian packages meta information.
module Debian.Package.Data.Packages
       ( DebianVersion, versionFromHackageVersion, readDebianVersion, origVersion', isNative'

       , Source, mkSource, sourceName, version, origVersion, isNative

       , origArchiveName, nativeArchiveName, sourceDirName, deriveHackageVersion

       , parseChangeLog

       , PackageType (..), takeChangesType, isSourcePackage, isBinaryPackage

       , HaskellPackage, hackage, package
       , haskellPackageDefault, haskellPackageFromPackage
       ) where

import Control.Applicative ((<$>), pure, (<*>), (*>), (<*), empty, (<|>), many, some, optional)
import Control.Monad.Trans.State (StateT, runStateT, get, put)
import Data.Maybe (listToMaybe, maybeToList, mapMaybe)
import Data.Char (isSpace, isDigit)
import Data.Version (Version (Version, versionBranch), showVersion)
import Data.List.Split (splitOn)
import System.FilePath ((<.>), takeFileName, splitExtension)

import Debian.Package.Data.Hackage
  (HackageVersion, mkHackageVersion', hackageVersionNumbers,
   Hackage, mkHackageDefault, NameRule (Simple), debianNamesFromSourceName)


type Parser = StateT String Maybe

satisfy :: (Char -> Bool) -> Parser Char
satisfy p = do
  s <- get
  case s of
    c:cs -> if p c
            then  put cs *> pure c
            else  empty
    []   ->       empty

_look :: Parser String
_look =  get

eof :: Parser ()
eof =  do
  s <- get
  case s of
    []   -> pure ()
    _:_  -> empty

runParser :: Parser a -> String -> Maybe (a, String)
runParser =  runStateT

anyChar :: Parser Char
anyChar =  satisfy (const True)

char :: Char -> Parser Char
char x = satisfy (== x)

notChar :: Char -> Parser Char
notChar x = satisfy (/= x)

space :: Parser Char
space =  char ' '

digit :: Parser Char
digit =  satisfy isDigit

int :: Parser Int
int =  read <$> some digit

string :: String -> Parser String
string =  mapM char


-- | Version type for Debian
data DebianVersion
  = DebianNative    Version (Maybe Int)
  | DebianNonNative Version String

debianNativeVersion :: [Int] -> Maybe Int -> DebianVersion
debianNativeVersion v =  DebianNative (Version v [])

debianNonNativeVersion :: [Int] -> String -> DebianVersion
debianNonNativeVersion v = DebianNonNative (Version v [])

-- | Make deebian version from hackage version
versionFromHackageVersion :: HackageVersion -> Maybe String -> DebianVersion
versionFromHackageVersion hv = d where
  d (Just rev) = debianNonNativeVersion ns rev
  d Nothing    = debianNativeVersion    ns Nothing
  ns = hackageVersionNumbers hv

-- | Version without debian revision
origVersion' :: DebianVersion -> Version
origVersion' =  d  where
  d (DebianNative    v _) = v
  d (DebianNonNative v _) = v

-- | Is debian-native or not
isNative' :: DebianVersion -> Bool
isNative' = d where
  d (DebianNative    _ _) = True
  d (DebianNonNative _ _) = False

parseVersion' :: Parser Version
parseVersion' =
  Version
  <$> ((:) <$> int <*> many (char '.' *> int))
  <*> pure []

parseDebianVersion :: Parser DebianVersion
parseDebianVersion = do
  v <- parseVersion'
  (DebianNonNative v <$> (char '-' *> some (satisfy (not . isSpace)))
   <|>
   DebianNative    v <$> optional (string "+nmu" *> int))

_testParseDebianVersion :: [Maybe (DebianVersion, String)]
_testParseDebianVersion =
  [ runParser parseDebianVersion s | s <- [ "1.23.3-4", "1.23", "12.3+nmu2" ] ]

instance Show DebianVersion where
  show = d  where
    d (DebianNative    v nr) = showVersion v ++ maybe "" (("+nmu" ++) . show) nr
    d (DebianNonNative v r)  = showVersion v ++ '-': r

instance Read DebianVersion where
  readsPrec _ = maybeToList . runParser parseDebianVersion

readMaybe' :: Read a => String -> Maybe a
readMaybe' =  fmap fst . listToMaybe . filter ((== "") . snd) . reads

-- | Try to read debian package version
readDebianVersion :: String -> Maybe DebianVersion
readDebianVersion =  readMaybe'

-- | Debian source package type, name with version
data Source = Source String DebianVersion  deriving Show

-- | Make 'Source'
mkSource :: String -> DebianVersion -> Source
mkSource =  Source

-- | Source package name of 'Source'
sourceName :: Source -> String
sourceName (Source n _) = n

-- | Debian version of 'Source'
version :: Source -> DebianVersion
version (Source _ v) = v

-- | Version without debian revision
origVersion :: Source -> Version
origVersion =  origVersion' . version

-- | Is debian-native or not
isNative :: Source -> Bool
isNative =  isNative' . version

-- | Original source archive basename
origArchiveName :: Source -> FilePath
origArchiveName pkg = sourceName pkg ++ '_' : showVersion (origVersion pkg) <.> "orig" <.> "tar" <.> "gz"

-- | Debian native archive basename
nativeArchiveName :: Source -> String
nativeArchiveName pkg = sourceName pkg ++ '_' : show (version pkg) <.> "tar" <.> "gz"

-- | Source directory basename
sourceDirName :: Source -> FilePath
sourceDirName pkg = sourceName pkg ++ '-' : showVersion (origVersion pkg)

-- | Try to make 'HackageVersion' from 'Source'
deriveHackageVersion :: Source -> HackageVersion
deriveHackageVersion =  mkHackageVersion' . versionBranch . origVersion where

parseLine :: String -> Maybe (String, String)
parseLine =
  (fmap fst .) . runParser $
  (,) <$> some (notChar ':') <*> (char ':' *> many space *> many anyChar <* eof)

-- | Try to generate 'Source' from debian changelog string
parseChangeLog :: String       -- ^ dpkg-parsechangelog result string
               -> Maybe Source -- ^ Source structure
parseChangeLog log' = do
  deb  <- mayDebSrc
  dver <- mayDebVer
  return $ mkSource deb dver
  where
    pairs = mapMaybe parseLine . lines $ log'
    lookup' = (`lookup` pairs)
    mayDebSrc = lookup' "Source"
    mayDebVer = do
      dverS <- lookup' "Version"
      readDebianVersion dverS

-- | Debian package types
data PackageType
  = PackageArch String
  | PackageAll
  | PackageSource
  deriving (Eq, Show)

-- | Take 'PackageType' from debian .changes file path
takeChangesType :: FilePath -> Maybe PackageType
takeChangesType path = d . splitExtension $ takeFileName path  where
  d (n, ".changes") = case xs of
    [_, _, a] -> case a of
      "all"    -> Just   PackageAll
      "source" -> Just   PackageSource
      _        -> Just $ PackageArch a
    _          -> Nothing
    where xs = splitOn "_" n
  d (_, _)     =  Nothing

-- | Test package type is source package.
isSourcePackage :: PackageType -> Bool
isSourcePackage = d where
  d (PackageArch _) = False
  d  PackageAll     = False
  d  PackageSource  = True

-- | Test package type is binary package.
isBinaryPackage :: PackageType -> Bool
isBinaryPackage = not . isSourcePackage


-- | Debian source package type for Haskell
data HaskellPackage = HaskellPackage Hackage Source deriving Show

-- | 'Hackage' meta-info of 'HaskellPackage'
hackage :: HaskellPackage -> Hackage
hackage (HaskellPackage h _) = h

-- | Debian source package meta-info of 'HaskellPackage'
package :: HaskellPackage -> Source
package (HaskellPackage _ p) = p

-- | Generate 'HaskellPackage' type from debian package name and version
--   using 'NameRule'
haskellPackageDefault :: NameRule
                      -> String         -- ^ Hackage name string
                      -> HackageVersion -- ^ Version of hackage
                      -> Maybe String   -- ^ Debian revision String
                      -> HaskellPackage -- ^ Result structure
haskellPackageDefault rule hname hver mayDevRev =
  HaskellPackage
  (mkHackageDefault rule hname hver)
  (mkSource sn (versionFromHackageVersion hver mayDevRev))
  where
    (sn, _) = debianNamesFromSourceName rule hname

-- | Generate 'HaskellPackage' with hackage name and debian package meta-info
haskellPackageFromPackage :: String         -- ^ Hackage name string
                          -> Source         -- ^ Debian package meta info
                          -> HaskellPackage -- ^ Result
haskellPackageFromPackage hname pkg = HaskellPackage hkg pkg  where
  hv  = deriveHackageVersion pkg
  hkg = mkHackageDefault Simple hname hv
