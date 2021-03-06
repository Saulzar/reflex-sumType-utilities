{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeOperators         #-}
module Reflex.Dynamic.PerConstructor
  (
    DynMaybe
  , dynamicToEventList
  , dynamicToNamedEventList
  , dynMaybeToEventList
  , dynMaybeToNamedEventList
  , whichFired
  , ConWidget(..)
  , DynMBuildable(..)
  , AllDynMBuildable
  , dynamicToConWidgets
  , dynamicToWidgetEvent
  , dynMaybeToConWidgets
  , dynMaybeToWidgetEvent
  , dynMBuildableToConWidgets
  , dynMBuildableToWidgetEvent
  , Generic
  , HasDatatypeInfo
  ) where

import           Reflex.Dynamic.Common       (AllDynMBuildable,
                                              DynMBuildable (dynMBuild),
                                              DynMaybe)

import           Control.Monad               (join)
import           Data.Functor.Compose        (Compose (Compose, getCompose))

import           Generics.SOP                ((:.:) (..), All2, Code,
                                              ConstructorName, Generic,
                                              HasDatatypeInfo, I, Proxy (Proxy),
                                              SListI, hcliftA, hmap, hsequence,
                                              unComp, unPOP)
import           Generics.SOP.NP             (NP, sequence'_NP, sequence_NP)


import           Generics.SOP.DMapUtilities  (npSequenceViaDMap)
import           Generics.SOP.PerConstructor (Dict (..), MapFieldsAndSequence,
                                              constructorNameList,
                                              functorDoPerConstructorWithNames,
                                              functorToPerConstructorList,
                                              mapFieldsFromConstraintAndCustomSequence)

import           Reflex                      (Dynamic, Event, Reflex,
                                              distributeDMapOverDynPure,
                                              fmapMaybe, leftmost, updated)


-- pure

-- These events only fire if the corresponding constructor value changes.  They do not fire on changes to other constructors.
dynamicToEventList::(Reflex t, Generic a)=>Dynamic t a -> [Event t a]
dynamicToEventList = functorToPerConstructorList (hmap dynMaybeToEvent)

dynamicToNamedEventList::forall t a.(Reflex t, HasDatatypeInfo a, Generic a)=>Dynamic t a -> [(ConstructorName,Event t a)]
dynamicToNamedEventList dynA =
  let names = constructorNameList (Proxy :: Proxy a)
  in zip names (dynamicToEventList dynA)

dynMaybeToEvent::forall a t (f :: k -> *).Reflex t=>((Dynamic t :.: Maybe) :.: f) a -> (Event t :.: f) a
dynMaybeToEvent = Comp . fmapMaybe id . updated . unComp . unComp

dynMaybeToEventList::(Reflex t, Generic a)=>DynMaybe t a -> [Event t a]
dynMaybeToEventList = functorToPerConstructorList (hmap dynMaybeMaybeToEvent)

dynMaybeToNamedEventList::forall t a.(Reflex t, HasDatatypeInfo a, Generic a)=>DynMaybe t a -> [(ConstructorName,Event t a)]
dynMaybeToNamedEventList dynA =
  let names = constructorNameList (Proxy :: Proxy a)
  in zip names (dynMaybeToEventList dynA)

dynMaybeMaybeToEvent::forall a t (f :: k -> *).Reflex t=>((DynMaybe t :.: Maybe) :.: f) a -> (Event t :.: f) a
dynMaybeMaybeToEvent = Comp . fmapMaybe join . updated . getCompose . unComp . unComp

-- utility which comes in handy for using the lists above in a control
whichFired::Reflex t=>[Event t a]->Event t Int
whichFired = leftmost . zipWith (<$) [0..]

-- widget building
-- given an applicative m (e.g., a DomBuilder or MonadHold), and a function build::DynMaybe t a -> m (DynMaybe t a) for all types in the fields of b
-- we can take a Dynamic t b (or DynMaybe t b), apply the build function at each field of each constructor and get the resulting widgets along with constructor names
-- and (pure) events to simplify switching on input changes.
-- If all you want is the Event with the current widget (based on the input), you can use the XXXToWidgetEvent version.


data ConWidget t m a = ConWidget { conName::ConstructorName, switchedTo::Event t a, widget::m (DynMaybe t a) }

type MapAndSequenceDynMaybeFields t m a = MapFieldsAndSequence (DynMaybe t) (Compose m (DynMaybe t)) (Code a)

dynamicToConWidgets::(Reflex t, Generic a,HasDatatypeInfo a, Applicative m)
  =>MapAndSequenceDynMaybeFields t m a->Dynamic t a-> [ConWidget t m a]
dynamicToConWidgets mapAndS dynA =
  let switchEvents = dynamicToEventList dynA
      mapFsAndS = mapAndS . hmap (Compose . unComp)
      namedWidgets = functorDoPerConstructorWithNames mapFsAndS dynA
  in zipWith (\ev (n,w) -> ConWidget n ev (getCompose w)) switchEvents namedWidgets

joinComposedMaybes::Reflex t=>(DynMaybe t :.: Maybe) a -> (Dynamic t :.: Maybe) a
joinComposedMaybes = Comp . fmap join . getCompose . unComp

dynMaybeToConWidgets::(Reflex t, Generic a,HasDatatypeInfo a, Applicative m)
  =>MapAndSequenceDynMaybeFields t m a->DynMaybe t a-> [ConWidget t m a]
dynMaybeToConWidgets mapAndS dynMA =
  let switchEvents = dynMaybeToEventList dynMA
      mapFsAndS = mapAndS . hmap (Compose . unComp)
      namedWidgets = functorDoPerConstructorWithNames (mapFsAndS . hmap joinComposedMaybes) dynMA
  in zipWith (\ev (n,w) -> ConWidget n ev (getCompose w)) switchEvents namedWidgets


dynamicToWidgetEvent::(Reflex t, Generic a,HasDatatypeInfo a, Applicative m)
  =>MapAndSequenceDynMaybeFields t m a->Dynamic t a->Event t (m (DynMaybe t a))
dynamicToWidgetEvent mapAndS dynA =
  let conWidgets = dynamicToConWidgets mapAndS dynA
      f (ConWidget _ ev w) = w <$ ev
  in leftmost $ f <$> conWidgets

dynMaybeToWidgetEvent::(Reflex t, Generic a,HasDatatypeInfo a, Applicative m)
  =>MapAndSequenceDynMaybeFields t m a->DynMaybe t a->Event t (m (DynMaybe t a))
dynMaybeToWidgetEvent mapAndS dynMA =
  let conWidgets = dynMaybeToConWidgets mapAndS dynMA
      f (ConWidget _ ev w) = w <$ ev
  in leftmost $ f <$> conWidgets

-- this uses distributeDMapOverDynPure to sequence the Dynamic.  At the cost of three sequences instead of one.
-- this also seems like it may have more traversals over the structure (4) than we need.  Someday, an optimization pass.
sequenceViaDMap::(Reflex t, Applicative m, SListI xs)=>NP (Compose m (DynMaybe t)) xs -> (Compose m (DynMaybe t)) (NP I xs)
sequenceViaDMap =  Compose . fmap (Compose . fmap hsequence . npSequenceViaDMap distributeDMapOverDynPure . hmap (Comp . getCompose)) . sequence'_NP . hmap (Comp . getCompose)

-- specialized to the DynMBuildable case.  Derive an instance of DynMBuildable using your build function and these functions will do the rest.
dynMBuildableToConWidgets::forall t m a.( Reflex t
                                        , Generic a
                                        , HasDatatypeInfo a
                                        , Applicative m
                                        , AllDynMBuildable t m a)
  =>DynMaybe t a -> [ConWidget t m a]
dynMBuildableToConWidgets = dynMaybeToConWidgets widgetFieldsAndSequence where
  widgetFieldsAndSequence = mapFieldsFromConstraintAndCustomSequence (Dict :: Dict (All2 (DynMBuildable t m)) (Code a)) (Compose . dynMBuild) sequenceViaDMap


dynMBuildableToWidgetEvent::(Reflex t, Generic a,HasDatatypeInfo a, Applicative m,AllDynMBuildable t m a)
  =>DynMaybe t a->Event t (m (DynMaybe t a))
dynMBuildableToWidgetEvent dynMA =
  let conWidgets = dynMBuildableToConWidgets dynMA
      f (ConWidget _ ev w) = w <$ ev
  in leftmost $ f <$> conWidgets

