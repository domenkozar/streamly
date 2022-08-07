{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Streamly.Internal.Data.Stream.Type
-- Copyright   : (c) 2017 Composewell Technologies
-- License     : BSD-3-Clause
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--
module Streamly.Internal.Data.Stream.Type
    (
    -- * Stream Type
      Stream

    -- * Type Conversion
    , fromStreamK
    , toStreamK
    , fromStreamD
    , toStreamD

    -- * Construction
    , cons
    , consM
    , nil
    , nilM
    , fromPure
    , fromEffect

    -- * Bind/Concat
    , bindWith
    , concatMapWith

    -- * Double folds
    , eqBy
    , cmpBy
    )
where

import Control.Applicative (liftA2)
import Control.DeepSeq (NFData(..), NFData1(..))
import Control.Monad.Base (MonadBase(..), liftBaseDefault)
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.State.Class (MonadState(..))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Data.Foldable (Foldable(foldl'), fold)
import Data.Functor.Identity (Identity(..), runIdentity)
import Data.Maybe (fromMaybe)
import Data.Semigroup (Endo(..))
#if __GLASGOW_HASKELL__ < 808
import Data.Semigroup (Semigroup(..))
#endif
import GHC.Exts (IsList(..), IsString(..), oneShot)
import Streamly.Internal.BaseCompat ((#.))
import Streamly.Internal.Data.Maybe.Strict (Maybe'(..), toMaybe)
import Text.Read
       ( Lexeme(Ident), lexP, parens, prec, readPrec, readListPrec
       , readListPrecDefault)

import qualified Streamly.Internal.Data.Stream.Common as P
import qualified Streamly.Internal.Data.Stream.StreamD.Type as D
import qualified Streamly.Internal.Data.Stream.StreamK.Type as K

#include "Instances.hs"
#include "inline.hs"

-- $setup
-- >>> import qualified Streamly.Data.Fold as Fold
-- >>> import qualified Streamly.Internal.Data.Unfold as Unfold
-- >>> import qualified Streamly.Internal.Data.Stream as Stream

------------------------------------------------------------------------------
-- Stream
------------------------------------------------------------------------------

-- | Semigroup instance appends two streams:
--
-- >>> (<>) = Stream.append
--
-- Monad bind maps a stream generator function on the stream and flattens the
-- resulting stream:
--
-- >>> (>>=) = flip (Stream.concatMapWith Stream.append)
--
-- A 'Monad' bind behaves like a @for@ loop:
--
-- >>> :{
-- Stream.fold Fold.toList $ do
--      x <- Stream.unfold Unfold.fromList [1,2] -- foreach x in stream
--      return x
-- :}
-- [1,2]
--
-- Nested monad binds behave like nested @for@ loops:
--
-- >>> :{
-- Stream.fold Fold.toList $ do
--     x <- Stream.unfold Unfold.fromList [1,2] -- foreach x in stream
--     y <- Stream.unfold Unfold.fromList [3,4] -- foreach y in stream
--     return (x, y)
-- :}
-- [(1,3),(1,4),(2,3),(2,4)]
--
-- @since 0.9.0
newtype Stream m a = Stream (K.Stream m a)
    -- XXX when deriving do we inherit an INLINE?
    deriving (Semigroup, Monoid, MonadTrans)

------------------------------------------------------------------------------
-- Conversions
------------------------------------------------------------------------------

{-# INLINE fromStreamK #-}
fromStreamK :: K.Stream m a -> Stream m a
fromStreamK = Stream

{-# INLINE toStreamK #-}
toStreamK :: Stream m a -> K.Stream m a
toStreamK (Stream k) = k

{-# INLINE fromStreamD #-}
fromStreamD :: Monad m => D.Stream m a -> Stream m a
fromStreamD = fromStreamK . D.toStreamK

{-# INLINE toStreamD #-}
toStreamD :: Applicative m => Stream m a -> D.Stream m a
toStreamD = D.fromStreamK . toStreamK

------------------------------------------------------------------------------
-- Comparison
------------------------------------------------------------------------------

-- | Compare two streams for equality
--
-- @since 0.9.0
{-# INLINE eqBy #-}
eqBy :: Monad m =>
    (a -> b -> Bool) -> Stream m a -> Stream m b -> m Bool
eqBy f m1 m2 = D.eqBy f (toStreamD m1) (toStreamD m2)

-- | Compare two streams
--
-- @since 0.9.0
{-# INLINE cmpBy #-}
cmpBy
    :: Monad m
    => (a -> b -> Ordering) -> Stream m a -> Stream m b -> m Ordering
cmpBy f m1 m2 = D.cmpBy f (toStreamD m1) (toStreamD m2)

------------------------------------------------------------------------------
-- Monad
------------------------------------------------------------------------------

instance Monad m => Monad (Stream m) where
    return = pure

    -- Benchmarks better with StreamD bind and pure:
    -- toList, filterAllout, *>, *<, >> (~2x)
    --
    -- pure = Stream . D.fromStreamD . D.fromPure
    -- m >>= f = D.fromStreamD $ D.concatMap (D.toStreamD . f) (D.toStreamD m)

    -- Benchmarks better with CPS bind and pure:
    -- Prime sieve (25x)
    -- n binds, breakAfterSome, filterAllIn, state transformer (~2x)
    --
    {-# INLINE (>>=) #-}
    (>>=) m f = fromStreamK $ K.bindWith K.serial (toStreamK m) (toStreamK . f)

    {-# INLINE (>>) #-}
    (>>)  = (*>)

------------------------------------------------------------------------------
-- Other instances
------------------------------------------------------------------------------

{-# INLINE apSerial #-}
apSerial :: Monad m => Stream m (a -> b) -> Stream m a -> Stream m b
apSerial (Stream m1) (Stream m2) =
    fromStreamK $ D.toStreamK $ D.fromStreamK m1 <*> D.fromStreamK m2

{-# INLINE apSequence #-}
apSequence :: Monad m => Stream m a -> Stream m b -> Stream m b
apSequence (Stream m1) (Stream m2) =
    fromStreamK $ D.toStreamK $ D.fromStreamK m1 *> D.fromStreamK m2

{-# INLINE apDiscardSnd #-}
apDiscardSnd :: Monad m => Stream m a -> Stream m b -> Stream m a
apDiscardSnd (Stream m1) (Stream m2) =
    fromStreamK $ D.toStreamK $ D.fromStreamK m1 <* D.fromStreamK m2

-- Note: we need to define all the typeclass operations because we want to
-- INLINE them.
instance Monad m => Applicative (Stream m) where
    {-# INLINE pure #-}
    pure = fromStreamK . K.fromPure

    {-# INLINE (<*>) #-}
    (<*>) = apSerial
    -- (<*>) = K.apSerial

    {-# INLINE liftA2 #-}
    liftA2 f x = (<*>) (fmap f x)

    {-# INLINE (*>) #-}
    (*>)  = apSequence
    -- (*>)  = K.apSerialDiscardFst

    {-# INLINE (<*) #-}
    (<*) = apDiscardSnd
    -- (<*)  = K.apSerialDiscardSnd

-- XXX Need to remove the MonadBase instance
MONAD_COMMON_INSTANCES(Stream,)
LIST_INSTANCES(Stream)
NFDATA1_INSTANCE(Stream)
FOLDABLE_INSTANCE(Stream)
TRAVERSABLE_INSTANCE(Stream)

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------

infixr 5 `cons`

-- | Construct a stream by adding a pure value at the head of an existing
-- stream. Same as the following but more efficient:
--
-- For example:
--
-- >>> s = 1 `Stream.cons` 2 `Stream.cons` 3 `Stream.cons` Stream.nil
-- >>> Stream.fold Fold.toList s
-- [1,2,3]
--
-- >>> cons x xs = return x `Stream.consM` xs
--
-- /Pre-release/
--
{-# INLINE_NORMAL cons #-}
cons ::  a -> Stream m a -> Stream m a
cons x = fromStreamK . K.cons x . toStreamK

infixr 5 `consM`

-- | Constructs a stream by adding a monadic action at the head of an
-- existing stream. For example:
--
-- >>> s = putStrLn "hello" `consM` putStrLn "world" `consM` Stream.nil
-- >>> Stream.fold Fold.drain s
-- hello
-- world
--
-- >>> consM x xs = Stream.fromEffect x `Stream.append` xs
--
-- /Pre-release/
--
{-# INLINE consM #-}
{-# SPECIALIZE consM :: IO a -> Stream IO a -> Stream IO a #-}
consM :: Monad m => m a -> Stream m a -> Stream m a
consM m = fromStreamK . K.consM m . toStreamK

-- | A pure empty stream with no result and no side-effect.
--
-- >>> Stream.fold Fold.toList Stream.nil
-- []
--
{-# INLINE_NORMAL nil #-}
nil ::  Stream m a
nil = fromStreamK K.nil

-- | An empty stream producing the supplied side effect.
--
-- >>> Stream.fold Fold.toList (Stream.nilM (print "nil"))
-- "nil"
-- []
--
-- /Pre-release/
{-# INLINE_NORMAL nilM #-}
nilM :: Monad m => m b -> Stream m a
nilM = fromStreamK . K.nilM

-- | Create a singleton stream from a pure value.
--
-- >>> fromPure a = a `cons` Stream.nil
-- >>> fromPure = pure
-- >>> fromPure = fromEffect . pure
--
{-# INLINE_NORMAL fromPure #-}
fromPure :: a -> Stream m a
fromPure = fromStreamK . K.fromPure

-- | Create a singleton stream from a monadic action.
--
-- >>> fromEffect m = m `consM` Stream.nil
-- >>> fromEffect = Stream.sequence . Stream.fromPure
--
-- >>> Stream.fold Fold.drain $ Stream.fromEffect (putStrLn "hello")
-- hello
--
{-# INLINE_NORMAL fromEffect #-}
fromEffect :: Monad m => m a -> Stream m a
fromEffect = fromStreamK . K.fromEffect

-------------------------------------------------------------------------------
-- Bind/Concat
-------------------------------------------------------------------------------

{-# INLINE bindWith #-}
bindWith
    :: (Stream m b -> Stream m b -> Stream m b)
    -> Stream m a
    -> (a -> Stream m b)
    -> Stream m b
bindWith par m1 f =
    fromStreamK
        $ K.bindWith
            (\s1 s2 -> toStreamK $ par (fromStreamK s1) (fromStreamK s2))
            (toStreamK m1)
            (toStreamK . f)

-- | @concatMapWith mixer generator stream@ is a two dimensional looping
-- combinator.  The @generator@ function is used to generate streams from the
-- elements in the input @stream@ and the @mixer@ function is used to merge
-- those streams.
--
-- Note we can merge streams concurrently by using a concurrent merge function.
--
{-# INLINE concatMapWith #-}
concatMapWith
    :: (Stream m b -> Stream m b -> Stream m b)
    -> (a -> Stream m b)
    -> Stream m a
    -> Stream m b
concatMapWith par f xs = bindWith par xs f
