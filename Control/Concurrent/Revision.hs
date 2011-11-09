{-# LANGUAGE TupleSections #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE GADTs #-}
-- {-# LANGUAGE Trustworthy #-}
module Control.Concurrent.Revision
  (
  -- * Version Control
    Rev
  , runRev
  -- * Fork/Join parallelism
  , fork
  , join
  -- * Versioned variables
  , Versioned
  , vcreate
  , vread
  , (=:), (+=), (*=), (-=), (//=), (%=)
  -- * Customized merging
  , vcreateM
  , Merge(..)
  -- * Customized forking
  , vcreateMF
  , Fork(..)
  ) where

import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Maybe (fromMaybe)
import Data.Monoid (Monoid(..))
import Control.Applicative
import Control.Concurrent.Supply
import GHC.IO (unsafeDupablePerformIO)
import GHC.Prim (par#)
import Unsafe.Coerce (unsafeCoerce)
import GHC.Types (Int(I#))

data Merge a
  = Merge (a -> a -> a -> a) -- 3 way merge
  | JoineeMerge
  | JoinerMerge

data Write where
  MergeWrite  :: (a -> a -> a -> a) -> a -> a -> Write -- 3 way merge, using the old op
  JoineeWrite :: a -> Write -- the joinee wins
  JoinerWrite :: a -> Write -- the joiner wins

chainWrites :: Write -> Write -> Write
chainWrites (MergeWrite a m _) (MergeWrite _ _ o) = MergeWrite a m (unsafeCoerce o)
chainWrites a _ = a

vlookup :: Int -> IntMap Write -> Maybe a
vlookup i m = case IntMap.lookup i m of
  Just (MergeWrite a _ _) -> Just (unsafeCoerce a)
  Just (JoineeWrite a)    -> Just (unsafeCoerce a)
  Just (JoinerWrite a)    -> Just (unsafeCoerce a)
  Nothing                 -> Nothing
{-# INLINE vlookup #-}

-- a basic block worth of actions, no fork, no joins
data Seg = Seg
  { _reads  :: !IntSet
  , _writes :: !(IntMap Write)
  }

instance Monoid Seg where
  Seg r w `mappend` Seg r' w' = Seg (IntSet.union (r IntSet.\\ IntMap.keysSet w') r') (IntMap.unionWith chainWrites w w')
  mempty = Seg mempty mempty

type BranchId = Int
type Weight = Int
type Length = Int
type Summary = Seg

-- | A complete binary tree of segments with summaries
data Tree
  = Bin {-# UNPACK #-} !BranchId {-# UNPACK #-} !Summary {-# UNPACK #-} !Seg !Tree !Tree
  | Tip {-# UNPACK #-} !BranchId {-# UNPACK #-} !Seg

-- | A skew binomial random access list of segments with summaries
data History
  = Cons {-# UNPACK #-} !Length {-# UNPACK #-} !Weight {-# UNPACK #-} !BranchId {-# UNPACK #-} !Summary !Summary !Tree !History
  | Nil

class Segmented t where
  summary :: t -> Summary
  branchId :: t -> BranchId

instance Segmented Tree where
  summary (Tip _ s) = s
  summary (Bin _ s _ _ _) = s
  branchId (Tip i _) = i
  branchId (Bin i _ _ _ _) = i

instance Segmented History where
  summary Nil = mempty
  summary (Cons _ _ _ s _ _ _) = s
  branchId Nil = -1
  branchId (Cons _ _ b _ _ _ _) = b

consS :: BranchId -> Seg -> History -> History
consS i s (Cons l w _ u ttl tl (Cons _ w2 _ _ ttr tr rs))
  | w == w2
  , !w3 <- w * 2 + 1
  , ttt <- s `mappend` ttl `mappend` ttr
  = Cons (l + 1) w3 i (mappend s u) ttt (Bin i ttt s tl tr) rs
consS i s xs@(Cons l _ _ u _ _ _) = Cons (l + 1) 1 i (mappend s u) s (Tip i s) xs
consS i s Nil                     = Cons 1       1 i s             s (Tip i s) Nil

len :: History -> Int
len Nil = 0
len (Cons l _ _ _ _ _ _) = l


consT :: Weight -> Tree -> History -> History
consT w t h = Cons (len h + w) w (branchId t) (summary t `mappend` summary h) (summary t) t h

keep :: Length -> History -> (# Summary, History #)
keep l h
  | l == len h = (# mempty, h #)
  | otherwise  = keep' mempty l h

-- keep a history of a given length, collecting a summary of what was skipped
keep' :: Summary -> Length -> History -> (# Summary, History #)
keep' acc n h@(Cons l w _ _ ts t xs)
  | n == l    = (# acc, h #)
  | otherwise = case compare n (l - w) of
    GT -> keepT acc (n - l + w) w t xs
    EQ -> (# mappend acc ts, xs #)
    LT -> keep' (mappend acc ts) (n - w) xs
keep' acc _ Nil = (# acc, Nil #)

keepT :: Summary -> Length -> Weight -> Tree -> History -> (# Summary, History #)
keepT acc _ _ (Tip _ s) h = (# mappend acc s, h #) -- | n > 0 = (# acc, consS b s h #)
keepT acc n w (Bin _ _ a l r) h = case compare n w2 of
    LT              -> keepT (acc `mappend` a `mappend` summary l) n w2 r h
    EQ              -> (# acc `mappend` a `mappend` summary l, consT w2 r h #)
    GT | n == w - 1 -> (# acc `mappend` a, consT w2 l (consT w2 r h) #)
       | otherwise  -> keepT (acc `mappend` a) (n - w2) w2 l (consT w2 r h)
  where w2 = div w 2

-- trim history to a common shape then search for the least common ancestor
joinH :: Seg -> History -> Seg -> History -> (# Seg, History #)
joinH sl hl sr hr = case compare ll lr of
  LT | (# r, hr' #) <- keep ll hr -> joinH' sl hl (sr `mappend` r) hr'
  EQ -> joinH' sl hl sr hr
  GT | (# l, hl' #) <- keep lr hl -> joinH' (sl `mappend` l) hl' sr hr
  where 
    ll = len hl
    lr = len hr

commonH :: History -> History -> Bool
commonH Nil Nil = True
commonH (Cons _ _ bl _ _ _ _) (Cons _ _ br _ _ _ _) = bl == br
commonH _ _ = False -- crash?

joinH' :: Seg -> History -> Seg -> History -> (# Seg, History #)
joinH' sl Nil sr Nil = (# joinS sl sr,  Nil #)
joinH' sl h@(Cons _ w bl _ stl tl ls)
       sr   (Cons _ _ br _ str tr rs)
  | bl == br      = (# joinS sl sr, h #)
  | commonH ls rs = joinT w sl tl sr tr ls
  | otherwise     = joinH' (sl `mappend` stl) ls (sr  `mappend` str) rs
joinH' _ _ _ _ = error "joinH': misaligned History"

commonT :: Tree -> Tree -> Bool
commonT (Tip i _)       (Tip j _)       = i == j
commonT (Bin i _ _ _ _) (Bin j _ _ _ _) = i == j
commonT _ _ = error "commonT: misaligned History"

joinT :: Weight -> Seg -> Tree -> Seg -> Tree -> History -> (# Seg, History #)
joinT _ al (Tip i l) ar (Tip j r) h
  | i == j    = (# joinS (al `mappend` l) (ar `mappend` r), h #)
  | otherwise = (# joinS al ar, consS i l h #)
joinT w al (Bin _ _ l ll lr) ar (Bin _ _ r rl rr) h
  | commonT ll rl = (# joinS (al `mappend` summary ll `mappend` summary lr) (ar `mappend` summary rl `mappend` summary rr), h #)
  | commonT lr rr = joinT w2 (al `mappend` l) ll (ar `mappend` r) rl (consT w2 lr h)
  | otherwise     = joinT w2 (al `mappend` l `mappend` summary ll) lr (ar `mappend` r `mappend` summary rl) rr h
  where w2 = div w 2
joinT _ _ _ _ _ _ = error "joinT: misaligned history"

joinS :: Seg -> Seg -> Seg
joinS (Seg rl wl) (Seg rr wr) = Seg (IntSet.union rm (IntSet.union rl rr)) (IntMap.unionWith mergeWrites wl wr)
  where
    rm = IntMap.keysSet (IntMap.filter isMergeWrite (IntMap.intersection wl wr))
    isMergeWrite (MergeWrite _ _ _) = True
    isMergeWrite _ = False
    mergeWrites (MergeWrite f l o) (MergeWrite _ r _) = MergeWrite f (f o l (unsafeCoerce r)) o
    mergeWrites (JoinerWrite a) (JoinerWrite _) = JoinerWrite a
    mergeWrites (JoineeWrite _) (JoineeWrite b) = JoineeWrite b
    mergeWrites _ _ = error "joinS: inconsistent merge behavior"

newtype Rev s a = Rev { unRev :: Supply -> Seg -> History -> (# a, Supply, Seg, History #) }

runRev :: (forall s. Rev s a) -> a
runRev (Rev g) = case g (unsafeDupablePerformIO newSupply) mempty Nil of
  (# a, _, _, _ #) -> a

instance Functor (Rev s) where
  fmap f (Rev k) = Rev $ \s c h -> case k s c h of
    (# a, s', c', h' #) -> (# f a, s', c', h' #)

instance Applicative (Rev s) where
  pure a = Rev (# a,,, #)
  Rev mf <*> Rev ma = Rev $ \s c h -> case mf s c h of
    (# f, s', c', h' #) -> case ma s' c' h' of
       (# a, s'', c'', h'' #) -> (# f a, s'', c'', h'' #)

instance Monad (Rev s) where
  return a = Rev (# a,,, #)
  Rev g >>= f = Rev $ \s c h -> case g s c h of
    (# a, s', c', h' #) -> unRev (f a) s' c' h'

data Task s a = Task a !Supply !Seg !History

instance Functor (Task s) where
  fmap f (Task a s c h) = Task (f a) s c h

fork :: Rev s a -> Rev s (Task s a)
fork (Rev g) = Rev $ \s c h -> case freshId# s of
  (# i, s' #) -> case splitSupply# s' of
    (# sl, sr #) -> let
        !h' = consS (I# i) c h
        t = case g sr mempty h' of
              (# a, sr', c', h'' #) -> Task a sr' c' h''
      in case par# t of _ -> (# t, sl, mempty, h' #)

join :: Task s a -> Rev s a
join (Task a _ c' h') = Rev $ \s c h -> case joinH c h c' h' of
  (# c'', h'' #) -> (# a, s, c'', h'' #)

-- we hold the merge, reinitializer and INITIAL value in the versioned variables themselves
-- this way any variable disposed of after initialization but without being written to
-- won't lurk in the written sets forever.

data Fork a
  = Fork (a -> a)
  | BlindFork a

-- TODO: change the way the merge and fork functions work so we can know whether or not we use the old values
data Versioned s a = Versioned {-# UNPACK #-} !Int (Merge a) (Fork a) a

vcreateMF :: Merge a -> Fork a -> a -> Rev s (Versioned s a)
vcreateMF m f a = Rev $ \s c h -> case freshId# s of
  (# i, s' #) -> (# Versioned (I# i) m f a, s', c, h #)

vcreateM :: Merge a -> a -> Rev s (Versioned s a)
vcreateM m a = vcreateMF m (Fork id) a
{-# INLINE vcreateM #-}

vcreate :: a -> Rev s (Versioned s a)
vcreate a = vcreateMF JoineeMerge (Fork id) a
{-# INLINE vcreate #-}

vread :: Versioned s a -> Rev s a
vread (Versioned i _ f a) = Rev $ \s c@(Seg r w) h -> case vlookup i w of
  Just b -> (# b, s, c, h #)
  Nothing -> case h of
    Cons _ _ b (Seg _ w') _ _ _ | b > i -> case f of
      BlindFork bf -> (# bf, s, c, h #)
      Fork ff | !c' <- Seg (IntSet.insert i r) w -> (# ff $ fromMaybe a $ vlookup i w', s, c', h #)
    _ | !c' <- Seg (IntSet.insert i r) w -> (# a, s, c', h #)

vmodify :: Versioned s a -> (a -> (# Maybe a, b #)) -> Rev s b
vmodify = undefined
{-
vmodify (Versioned i m f a) k = Rev $ \s c@Seg r w) h -> case vlookup i w of
  Just a -> case k a of
    (# Nothing, b #) -> (# b, s, c, h #)
    (# Just a', b #) | !s' <- vinsert m a' a s -> (# b, s', c, h #)
vmodify (Versioned i a m f) k :: Versioned s a -> a -> Rev s ()
v@(Versioned i a (Merge m) f) =: a = do
  <- vread
Versioned i a JoineeMerge _ =: a = Rev $ \s (Seg r w) h -> (# (), s, Seg r (vinsert i a w), h #)
{-# INLINE (=:) #-}
-}
(=:) :: Versioned s a -> a -> Rev s ()
(=:) = undefined

(%=) :: Versioned s a -> (a -> a) -> Rev s ()
v %= f = vmodify v $ \a -> (# Just (f a), () #)
{-# INLINE (%=) #-}

(+=) :: Num a => Versioned s a -> a -> Rev s ()
(-=) :: Num a => Versioned s a -> a -> Rev s ()
(*=) :: Num a => Versioned s a -> a -> Rev s ()
v += b = v %= (b +)
v -= b = v %= (b -)
v *= b = v %= (b *)
(//=) :: Fractional a => Versioned s a -> a -> Rev s ()
v //= b = v %= (b /)
