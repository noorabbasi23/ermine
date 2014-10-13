{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}
--------------------------------------------------------------------
-- |
-- Copyright :  (c) McGraw Hill Financial 2014
-- License   :  BSD2
-- Maintainer:  Stephen Compall <scompall@nocandysw.com>
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

module Ermine.Loader.Filesystem
  ( filesystemLoader
  , LoadRefusal(..)
  , explainLoadRefusal
  , Freshness()
  ) where

import Control.DeepSeq (NFData, deepseq)
import Control.Exception (handleJust)
import Control.Lens
import Control.Monad.State
import Control.Monad.Trans.Except
import Control.Monad.Writer
import Data.Data
import Data.Functor ((<$>))
import Data.Text hiding (null)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.Lens (text)
import Data.Time.Clock (UTCTime)
import Ermine.Loader.Core
import GHC.Generics
import System.Directory (getModificationTime)
import qualified System.FilePath as P
import System.FilePath.Manip (readAll)
import System.IO (IOMode(ReadMode), withFile)
import System.IO.Error.Lens (errorType, _NoSuchThing)

-- | A 'Loader' that searches an area of the filesystem for modules
-- matching the given module name, and results in the textual contents
-- of that module file.
--
-- Non-IO errors are reported as 'LoadRefusal'.  Use
-- 'Ermine.Loader.Core.loaded' and 'withExceptT' to translate this to
-- a monoidal type (e.g. '[]') for combination with other loaders.
filesystemLoader :: forall m. MonadIO m =>
                    P.FilePath     -- ^ Filesystem root to start the search.
                    -> String      -- ^ File extension.
                    -> Loader Freshness (ExceptT LoadRefusal m) Text Text
filesystemLoader root ext =
  Loader (\n -> do
             pn <- pathName n
             load' pn)
         (\n cv -> do
             pn <- pathName n
             Just `liftM` load' pn)
  where pathName = mapExceptT (return . runIdentity)
                   . fmap (\n -> root P.</> n P.<.> ext)
                   . moduleFileName
        load' :: P.FilePath -> ExceptT LoadRefusal m (Freshness, Text)
        load' pn = (do mtime <- getModificationTime pn
                       Right . (Freshness mtime,) . decodeUtf8
                         <$> loadRaw pn)
                   & handleJust (^? errorType._NoSuchThing)
                                (const . return . Left . FileNotFound $ pn)
                   & liftIO & ExceptT
        loadRaw pn = withFile pn ReadMode (readAll >=> forceM)

-- | Like 'return', but force the argument before the 'm' becomes
-- visible.
forceM :: (Monad m, NFData a) => a -> m a
forceM a = a `deepseq` return a

-- | A recoverable load error that shouldn't prevent alternative
-- loaders from being tried for a given module.
data LoadRefusal =
    FileNotFound P.FilePath -- ^ No file with that name was found.
  | NoFilenameMapping       -- ^ There's no mapping from the module
                            -- name to a valid filesystem name.
  deriving (Eq, Ord, Show, Read, Data, Typeable, Generic)

explainLoadRefusal :: LoadRefusal -> Text
explainLoadRefusal (FileNotFound fp) =
  "There was no file named " <> pack fp
explainLoadRefusal NoFilenameMapping =
  "The module's name has no valid associated filename"

newtype Freshness = Freshness UTCTime
  deriving (Show, Read, Data, Typeable, Generic)

-- | Convert a module name to a relative filename, minus the
-- extension, or fail for some reason.
moduleFileName :: Text -> Except LoadRefusal P.FilePath
moduleFileName modName = do
  let modName' = modName ^.. text
  null (invalidChars modName) `when` throwE NoFilenameMapping
  let relPath = set (mapped.filtered ('.'==)) P.pathSeparator modName'
  P.isValid relPath `when` throwE NoFilenameMapping
  return relPath

-- | Answer the positions of filesystem-invalid characters in the
-- given module name, and explain the problem with each.
invalidChars :: Text -> [(Int, Text)]
invalidChars t = [(0, "Can't start with a dot") | anyOf folded (=='.') (firstOf text t)]
                 ++ checkChars t
                 ++ [(T.length t - 1, "Can't end with a dot")
                     | anyOf folded (=='.') (lastOf text t)]
  where checkChars = flip evalState False . execWriterT
                     . itraverseOf_ text lookAtChar
        lookAtChar :: Int -> Char -> WriterT [(Int, Text)] (State Bool) ()
        lookAtChar i ch = do
          let err s = tell [(i, s)]
              isDot = ch == '.'
          lastDot <- get
          put isDot
          (lastDot && isDot) `when` err "Empty module path components aren't allowed"
          P.isPathSeparator ch `when` err ("Disallowed character: " <> pack [ch])
          ('\NUL' == ch) `when` err "Null characters aren't allowed"
