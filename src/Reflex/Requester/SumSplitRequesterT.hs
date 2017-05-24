-- | This module provides 'SumSplitRequesterT'
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
#ifdef USE_REFLEX_OPTIMIZER
{-# OPTIONS_GHC -fplugin=Reflex.Optimizer #-}
#endif
module Reflex.Requester.SumSplitRequester
  ( SumSplitRequesterT (..)
  , runSunSplitRequesterT
--  , runWithReplaceSumSplitRequesterTWith
--  , sequenceDMapWithAdjustSumSplitRequesterTWith
  ) where

import           Reflex.Class
import           Reflex.EventWriter
import           Reflex.Host.Class
import           Reflex.PerformEvent.Class
import           Reflex.PostBuild.Class
import           Reflex.Requester.Class
import           Reflex.TriggerEvent.Class

import           Control.Monad.Exception
import           Control.Monad.Identity
import           Control.Monad.Primitive
import           Control.Monad.Reader
import           Control.Monad.Ref
import           Control.Monad.State.Strict
import           Data.Coerce
import           Data.Dependent.Map         (DMap, DSum (..))
import qualified Data.Dependent.Map         as DMap
import           Data.Functor.Misc
import           Data.Map                   (Map)
import           Data.Some                  (Some)
import           Data.Unique.Tag

import           Generics.SOP               (I, NP)
import           Generics.SOP.DMapUtilities (TypeListTag)


newtype SumSplitRequesterT t reqTL respTL m a =
  SumSplitRequesterT { unSumSplitRequesterT :: EventWriterT t (DMap (TypeListTag reqTL) (NP I)) (ReaderT (EventSelector t (TypeListTag respTL))) m a }
  deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadException, MonadAsyncException)

deriving instance MonadSample t m => MonadSample t (SumSplitRequesterT t reqTL respTL m)
deriving instance MonadHold t m => MonadHold t (SumSplitRequesterT t reqTL respTL m)
deriving instance PostBuild t m => PostBuild t (SumSplitRequesterT t reqTL respTL m)
deriving instance TriggerEvent t m => TriggerEvent t (SumSplitRequesterT t reqTL respTL m)

-- | Run a 'SumSplitRequesterT' action.  The resulting 'Event' will fire whenever
-- requests are made, and responses should be provided in the input 'Event'.
-- The 'Tag' keys will be used to return the responses to the same place the
-- requests were issued.

runSumSplitRequesterT :: (Reflex t, Monad m)
                      => SumSplitRequesterT t reqTL respTL m a
                      -> Event t (DMap (TypeListTag respTL) (NP I))
                      -> m (a, Event t (DMap (TypeListTag reqTL) (NP I)))
runSumSplitRequesterT (SumSplitRequesterT a) responses = do
  (result, requests) <- runReaderT (runEventWriterT a) $ fan $
    mapKeyValuePairsMonotonic (\(t :=> e) -> WrapArg t :=> Identity e) <$> responses
  return (result, requests)

instance (Reflex t, PrimMonad m) => Requester t (SumSplitRequesterT t reqTL respTL m) where
  type Request (SumSplitRequesterT t reqTL respTL m) = NP I
  type Response (RequesterT t reqTL respTL m) = NP I
  withRequesting a = do
    !t <- lift newTag --TODO: Fix this upstream
    s <- RequesterT ask
    (req, result) <- a $ select s $ WrapArg t
    RequesterT $ tellEvent $ fmapCheap (DMap.singleton t) req
    return result

instance MonadTrans (RequesterT t request response) where
  lift = RequesterT . lift . lift

instance PerformEvent t m => PerformEvent t (RequesterT t request response m) where
  type Performable (RequesterT t request response m) = Performable m
  performEvent_ = lift . performEvent_
  performEvent = lift . performEvent

instance MonadRef m => MonadRef (RequesterT t request response m) where
  type Ref (RequesterT t request response m) = Ref m
  newRef = lift . newRef
  readRef = lift . readRef
  writeRef r = lift . writeRef r

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (RequesterT t request response m) where
  newEventWithTrigger = lift . newEventWithTrigger
  newFanEventWithTrigger f = lift $ newFanEventWithTrigger f

instance MonadReader r m => MonadReader r (RequesterT t request response m) where
  ask = lift ask
  local f (RequesterT (EventWriterT a)) = RequesterT $ EventWriterT $ mapStateT (mapReaderT $ local f) a
  reader = lift . reader

instance (Reflex t, MonadAdjust t m, MonadHold t m) => MonadAdjust t (RequesterT t request response m) where
  runWithReplace (RequesterT a) em = RequesterT $ runWithReplace a (coerceEvent em)
  traverseDMapWithKeyWithAdjust f dm edm = RequesterT $ traverseDMapWithKeyWithAdjust (\k v -> unRequesterT $ f k v) (coerce dm) (coerceEvent edm)
  traverseDMapWithKeyWithAdjustWithMove f dm edm = RequesterT $ traverseDMapWithKeyWithAdjustWithMove (\k v -> unRequesterT $ f k v) (coerce dm) (coerceEvent edm)

runWithReplaceRequesterTWith :: forall m t request response a b. (Reflex t, MonadHold t m)
                             => (forall a' b'. m a' -> Event t (m b') -> RequesterT t request response m (a', Event t b'))
                             -> RequesterT t request response m a
                             -> Event t (RequesterT t request response m b)
                             -> RequesterT t request response m (a, Event t b)
runWithReplaceRequesterTWith f a0 a' =
  let f' :: forall a' b'. ReaderT (EventSelector t (WrapArg response (Tag (PrimState m)))) m a'
         -> Event t (ReaderT (EventSelector t (WrapArg response (Tag (PrimState m)))) m b')
         -> EventWriterT t (DMap (Tag (PrimState m)) request) (ReaderT (EventSelector t (WrapArg response (Tag (PrimState m)))) m) (a', Event t b')
      f' x y = do
        r <- EventWriterT $ ask
        unRequesterT (f (runReaderT x r) (fmapCheap (`runReaderT` r) y))
  in RequesterT $ runWithReplaceEventWriterTWith f' (coerce a0) (coerceEvent a')

sequenceDMapWithAdjustRequesterTWith :: forall k t request response m v v' p p'.
                                        ( GCompare k
                                        , Reflex t
                                        , MonadHold t m
                                        , PatchTarget (p' (Some k) (Event t (DMap (Tag (PrimState m)) request))) ~ Map (Some k) (Event t (DMap (Tag (PrimState m)) request))
                                        , Patch (p' (Some k) (Event t (DMap (Tag (PrimState m)) request)))
                                        )
                                     => (forall k' v1 v2. GCompare k'
                                         => (forall a. k' a -> v1 a -> m (v2 a))
                                         -> DMap k' v1
                                         -> Event t (p k' v1)
                                         -> RequesterT t request response m (DMap k' v2, Event t (p k' v2))
                                        )
                                     -> (forall v1. (forall a. v1 a -> v' a) -> p k v1 -> p k v')
                                     -> (forall v1 v2. (forall a. v1 a -> v2) -> p k v1 -> p' (Some k) v2)
                                     -> (forall v2. p' (Some k) v2 -> [v2])
                                     -> (forall a. Incremental t (p' (Some k) (Event t a)) -> Event t (Map (Some k) a))
                                     -> (forall a. k a -> v a -> RequesterT t request response m (v' a))
                                     -> DMap k v
                                     -> Event t (p k v)
                                     -> RequesterT t request response m (DMap k v', Event t (p k v'))
sequenceDMapWithAdjustRequesterTWith base mapPatch weakenPatchWith patchNewElements mergePatchIncremental f dm0 dm' =
  let base' :: forall v1 v2.
           (forall a. k a -> v1 a -> ReaderT (EventSelector t (WrapArg response (Tag (PrimState m)))) m (v2 a))
        -> DMap k v1
        -> Event t (p k v1)
        -> EventWriterT t (DMap (Tag (PrimState m)) request) (ReaderT (EventSelector t (WrapArg response (Tag (PrimState m)))) m) (DMap k v2, Event t (p k v2))
      base' f' x y = do
        r <- EventWriterT ask
        unRequesterT $ base (\k v -> runReaderT (f' k v) r) x y
  in RequesterT $ sequenceDMapWithAdjustEventWriterTWith base' mapPatch weakenPatchWith patchNewElements mergePatchIncremental (\k v -> unRequesterT $ f k v) (coerce dm0) (coerceEvent dm')
