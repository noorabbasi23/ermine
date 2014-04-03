{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
module Ermine.Core.Lint
  (
  -- * LintEnv
    LintEnv(..)
  , variables
  , foreignCxt
  , primCxt
  , instanceCxt
  -- * The Lint Monad
  , Lint(..)
  -- * Checking and inference
  , inferCore
  , checkCore
  , with
  ) where

import Bound.Var
import Bound.Scope
import Control.Applicative
import Control.Monad
import Control.Monad.Reader.Class
import Control.Lens
import Data.Data
import Data.Functor.Contravariant
import Data.Hashable
import Data.Map as Map
import Data.Profunctor
import Data.Text hiding (replicate)
import Ermine.Syntax.Convention
import Ermine.Syntax.Core
import Ermine.Syntax.Head
import Ermine.Syntax.Literal
import GHC.Generics

------------------------------------------------------------------------------
-- Form
------------------------------------------------------------------------------

data Form = Form [Convention] Convention
  deriving (Eq,Ord,Show,Read,Data,Typeable,Generic)

instance Hashable Form where
  hashWithSalt n (Form cc r) = n `hashWithSalt` cc `hashWithSalt` r

convention :: Form -> Convention
convention (Form [] r) = r
convention _           = C

------------------------------------------------------------------------------
-- LintEnv
------------------------------------------------------------------------------

data LintEnv a = LintEnv
  { _variables   :: a -> Either String Convention
  , _primCxt     :: Map Text Form
  , _foreignCxt  :: Map Foreign Form
  , _instanceCxt :: Map Head Int     -- # of dictionaries this instance consumes
  } deriving Typeable

makeLenses ''LintEnv

instance Contravariant LintEnv where
  contramap f c = c { _variables = _variables c . f }

------------------------------------------------------------------------------
-- Lint
------------------------------------------------------------------------------

liftEither :: Monad m => Either String b -> m b
liftEither = either fail return

liftMaybe :: Monad m => String -> Maybe b -> m b
liftMaybe e = maybe (fail e) return

newtype Lint a b = Lint { runLint :: LintEnv a -> Either String b }

instance Bifunctor Lint where
  bimap f g = Lint . dimap (contramap f) (fmap g) . runLint

instance Functor (Lint a) where
  fmap f = Lint . fmap (fmap f) . runLint

instance Applicative (Lint a) where
  pure a = Lint $ \_ -> return a
  Lint mf <*> Lint ma = Lint $ \ c -> mf c <*> ma c
  Lint mf <*  Lint ma = Lint $ \ c -> mf c <*  ma c
  Lint mf  *> Lint ma = Lint $ \ c -> mf c  *> ma c

instance Alternative (Lint a) where
  empty = mzero
  (<|>) = mplus

instance Monad (Lint a) where
  return a = Lint $ \_ -> Right a
  fail s = Lint $ \_ -> Left s
  Lint m >>= f = Lint $ \c -> case m c of
    Left e -> Left e
    Right a -> runLint (f a) c

instance MonadPlus (Lint a) where
  mzero = Lint $ \_ -> Left "lint: failed"
  Lint ma `mplus` Lint mb = Lint $ \c -> case ma c of
    Left e -> mb c
    Right a -> Right a

instance MonadReader (LintEnv a) (Lint a) where
  ask = Lint Right
  local f (Lint m) = Lint (m . f)

infix 0 `with`

with :: Lint b c -> (LintEnv a -> LintEnv b) -> Lint a c
with (Lint m) f = Lint (m . f)

------------------------------------------------------------------------------
-- Running Lint
------------------------------------------------------------------------------

inferHardCore :: HardCore -> Lint a Form
inferHardCore Super{}         = return $ Form [D] D
inferHardCore Slot{}          = return $ Form [D] C
inferHardCore (Lit String {}) = return $ Form [] N
inferHardCore Lit{}           = return $ Form [] U
inferHardCore (Error t)       = return $ Form [] U
inferHardCore (GlobalId g)    = return $ Form [] U
inferHardCore (PrimOp p)      = preview (primCxt.ix p)     >>= liftMaybe "unknown prim"
inferHardCore (Foreign p)     = preview (foreignCxt.ix p)  >>= liftMaybe "unknown foreign"
inferHardCore (InstanceId h)  = preview (instanceCxt.ix h) >>= (liftMaybe "unknown instance head" >=> \n -> return $ Form (replicate n D) D)

checkCore :: Core a -> Convention -> Lint a ()
checkCore core cc = do
  cc' <- convention <$> inferCore core
  when (cc' /= cc) $ fail $ "type mismatch: expected " ++ show cc ++ ", received " ++ show cc'

inferCore :: Core a -> Lint a Form
inferCore (Var a) = do
  v <- view variables
  Form [] <$> liftEither (v a)
inferCore (HardCore hc) = inferHardCore hc
inferCore (Lam cc body) = do
  r <- inferCore (fromScope body) `with` variables %~ unvar (\i -> liftMaybe "illegal bound variable" $ cc^?ix (fromIntegral i))
  when (convention r /= C) $ fail "bad lambda"
  return $ Form cc C
inferCore (App cc x y) = do
  checkCore y cc
  xs <- inferCore x
  case xs of
    f@(Form [] C) -> return f -- unchecked application
    Form (c:cs) r
      | c == cc   -> return $ Form cs r
      | otherwise -> fail "bad application"