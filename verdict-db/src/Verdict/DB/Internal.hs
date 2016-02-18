{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE GADTs #-}
module Verdict.DB.Internal where

import Data.Proxy
import qualified Data.Vector as V
import GHC.TypeLits
import Verdict

------------------------------------------------------------------------------
-- API
empty :: MkIxs cs val => DB cs val
empty = DB { dbData = V.empty , dbIxs = mkIxs }

query :: forall c cs val. (HaskVerdict c val, HOccurs c cs val) => DB cs val -> [Validated c val]
query db = query' ix (dbData db)
  where
    ix = hOccurrence (Proxy :: Proxy c) (dbIxs db)

insert :: (InsertAll cs val) => val -> DB cs val -> DB cs val
insert val db = DB { dbData = V.snoc (dbData db) val
                   , dbIxs = insertAll (V.length (dbData db), val) (dbIxs db)
                   }

------------------------------------------------------------------------------


class InsertAll cs v where
    insertAll :: (Int, v) -> HList cs v -> HList cs v

instance InsertAll '[] v where
    insertAll _ HNil = HNil

instance (HaskVerdict c v, InsertAll cs v) => InsertAll (c ': cs) v where
    insertAll new (HCons i rest) = HCons (insert' p new i) (insertAll new rest)
      where p = Proxy :: Proxy (c, v)

class MkIxs cs val where
    mkIxs :: HList cs val

instance MkIxs '[] val where
    mkIxs = HNil

instance (DBVerdictIx x val, MkIxs xs val) => MkIxs (x ': xs) val where
    mkIxs = HCons (empty' p) mkIxs
      where p = Proxy :: Proxy (x, val)

-- TODO: Find a better data structure
--
-- | A single secondary key index
class DBVerdictIx c val where
    type Index c val
    empty' :: Proxy (c, val) -> Index c val
    insert' :: Proxy (c, val) -> (Int, val) -> Index c val -> Index c val
    query' :: Index c val -> V.Vector val -> [Validated c val]

instance (HaskVerdict c v) => DBVerdictIx c v where
    type Index c v = ([Int], [Int])
    empty' _  = ([], [])
    insert' _ (i,val) (ts, fs) = if isValid p val then (i:ts, fs) else (ts, i:fs)
      where p = Proxy :: Proxy c
    query' (ts, fs) vec = [ unsafeValidated (vec V.! i) | i <- ts ]

data DB cs val = DB
    { dbData :: V.Vector val
    , dbIxs  :: HList cs val
    }

-- Gets the first occurrence of a 'c'-index in the HList.
class HOccurs c cs v where
    hOccurrence :: Proxy c -> HList cs v -> Index c v

instance HOccurs x (x ': xs) v where
    hOccurrence _ (HCons i _) = i

instance (HOccurs x xs v) => HOccurs x (y ': xs) v where
    hOccurrence p (HCons i xs) = hOccurrence p xs

data HList xs v where
    HNil :: HList '[] v
    HCons :: {- DBVerdictIx c v => -} Index c v -> HList cs v -> HList (c ': cs) v
{-
instance (DBVerdict c v, DBVerdict cs v) => DB (c ': cs) v where
    type Index (c ': cs) v = (Index c v, Index cs v)
    empty = empty : empty
    insert new ixs = insert new <$> ixs
-}

-- * Joins
class RemoveFirst a b | a -> b where
  removeFirst :: a -> b

instance RemoveFirst (DB (x ': xs) v) (DB xs v) where
  removeFirst (DB d ixs) = DB d (removeFirst ixs)

instance RemoveFirst (HList (x ': xs) v) (HList xs v) where
  removeFirst (HCons x xs) = xs


data Joined a b where
   Joined :: Validated c a -> Validated c b -> Joined a b

instance (Eq a, Eq b) => Eq (Joined a b) where
  Joined a1 b1 == Joined a2 b2 = getVal a1 == getVal a2 && getVal b1 == getVal b2

instance (Show a, Show b) => Show (Joined a b) where
  show (Joined a b) = "Joined " ++ show (getVal a) ++ " " ++ show (getVal b)

class CrossJoin db1 db2 a where
    crossJoin :: db1 -> db2 -> a

instance (HaskVerdict x a, HaskVerdict x b)
    => CrossJoin (DB '[x] a) (DB '[x] b) [Joined a b] where
    crossJoin db1 db2 = [ Joined a b | (a :: Validated x a) <- query db1
                                , (b :: Validated x b) <- query db2 ]

instance (HaskVerdict x a, HaskVerdict x b)
    => CrossJoin (DB '[x] a) (DB '[y] b) [Joined a b] where
    crossJoin _ _ = []

instance (HaskVerdict x a, HaskVerdict x b, CrossJoin (DB xs a) (DB ys b) [Joined a b])
    => CrossJoin (DB (x ': xs) a) (DB (x ': ys) b) [Joined a b] where
    crossJoin db1 db2 = [ Joined a b | (a :: Validated x a) <- query db1
                                , (b :: Validated x b) <- query db2 ]
                ++ crossJoin (removeFirst db1) (removeFirst db2)
