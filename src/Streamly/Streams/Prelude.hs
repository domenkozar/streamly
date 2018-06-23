{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving#-}
{-# LANGUAGE InstanceSigs              #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE UndecidableInstances      #-} -- XXX

-- |
-- Module      : Streamly.Streams.Prelude
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
--
module Streamly.Streams.Prelude
    (
    -- * Elimination
      runStream
    , runStreaming      -- deprecated

    -- * Fold Utilities
    , foldWith
    , foldMapWith
    , forEachWith
    )
where

import Streamly.Streams.Serial (SerialT)
import Streamly.Streams.StreamK hiding (runStream)
import qualified Streamly.Streams.StreamK as K

------------------------------------------------------------------------------
-- Eliminating a stream
------------------------------------------------------------------------------

-- | Run a streaming composition, discard the results. By default it interprets
-- the stream as 'SerialT', to run other types of streams use the type adapting
-- combinators for example @runStream . 'asyncly'@.
--
-- @since 0.2.0
runStream :: Monad m => SerialT m a -> m ()
runStream = K.runStream

-- | Same as 'runStream'
--
-- @since 0.1.0
{-# DEPRECATED runStreaming "Please use runStream instead." #-}
runStreaming :: (Monad m, IsStream t) => t m a -> m ()
runStreaming = runStream . adapt

------------------------------------------------------------------------------
-- Fold Utilities
------------------------------------------------------------------------------

-- | A variant of 'Data.Foldable.fold' that allows you to fold a 'Foldable'
-- container of streams using the specified stream sum operation.
--
-- @foldWith 'async' $ map return [1..3]@
--
-- @since 0.1.0
{-# INLINABLE foldWith #-}
foldWith :: (IsStream t, Foldable f)
    => (t m a -> t m a -> t m a) -> f (t m a) -> t m a
foldWith f = foldr f nil

-- | A variant of 'foldMap' that allows you to map a monadic streaming action
-- on a 'Foldable' container and then fold it using the specified stream sum
-- operation.
--
-- @foldMapWith 'async' return [1..3]@
--
-- @since 0.1.0
{-# INLINABLE foldMapWith #-}
foldMapWith :: (IsStream t, Foldable f)
    => (t m b -> t m b -> t m b) -> (a -> t m b) -> f a -> t m b
foldMapWith f g = foldr (f . g) nil

-- | Like 'foldMapWith' but with the last two arguments reversed i.e. the
-- monadic streaming function is the last argument.
--
-- @since 0.1.0
{-# INLINABLE forEachWith #-}
forEachWith :: (IsStream t, Foldable f)
    => (t m b -> t m b -> t m b) -> f a -> (a -> t m b) -> t m b
forEachWith f xs g = foldr (f . g) nil xs

-------------------------------------------------------------------------------
-- Generation by unfold
-------------------------------------------------------------------------------

{-
{-# INLINE unfoldr #-}
unfoldr :: (b -> Maybe (a, b)) -> b -> Stream m a
unfoldr step = go
    where
    go s = Stream $ \_ stp _ yld ->
        case step s of
            Nothing -> stp
            Just (a, b) -> yld a (go b)

{-# INLINE unfoldrM #-}
unfoldrM :: Monad m => (b -> m (Maybe (a, b))) -> b -> Stream m a
unfoldrM step = go
    where
    go s = Stream $ \svr stp sng yld -> do
        mayb <- step s
        case mayb of
            Nothing -> stp
            Just (a, b) ->
                K.runStream (a `cons` go b) svr stp sng yld
-}
