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
  , FilesystemLoaderFreshness()
  ) where

import Control.Monad.Error.Class
import Control.Monad.IO.Class
import Ermine.Loader.Core

-- | A 'Loader' that searches an area of the filesystem for modules
-- matching the given module name, and results in the textual contents
-- of that module file.  Non-IO errors are reported as 'e' to 'm' via
-- 'MonadError'.
filesystemLoader :: (Error e, MonadError e m, MonadIO m) =>
                    String         -- ^ Filesystem root to start the search.
                    -> String      -- ^ File extension.
                    -> Loader FilesystemLoaderFreshness String m String
filesystemLoader root ext =
  Loader (\n -> undefined) (\n cv -> undefined)

data FilesystemLoaderFreshness = FilesystemLoaderFreshness Int
