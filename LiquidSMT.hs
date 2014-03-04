{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module LiquidSMT where

import           Control.Applicative
import           Control.Arrow hiding (app)
import           Control.Monad.State
import           Data.Char
import           Data.Default
import           Data.Function
import qualified Data.HashMap.Strict as M
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Ord
import           Data.String
import qualified Data.Text.Lazy as T
import           Debug.Trace
import           Language.Fixpoint.Config (SMTSolver (..))
import           Language.Fixpoint.Parse
import           Language.Fixpoint.SmtLib2
import           Language.Fixpoint.Types hiding (prop, Def)
import           Language.Haskell.Liquid.Parse
import           Language.Haskell.Liquid.RefType
import           Language.Haskell.Liquid.Types hiding (ctors, var, env)
import           Language.Haskell.TH.Syntax (Name)
import           System.Exit
import           System.IO.Unsafe
import           Text.PrettyPrint.HughesPJ hiding (first)

import qualified SMTLib2 as SMT
import qualified SMTLib2.Core as SMT
import qualified SMTLib2.Int as SMT

-- instance (SMTLIB2 a) => SMTLIB2 [a] where
--   smt2 = T.concat . map smt2


-- instance SMTLIB2 BareType where
--   smt2 (RApp c as ps r) = smt2 $ toReft r


-- instance SMTLIB2 Reft where
--   smt2 (Reft (v, rs)) = smt2 $ map toPred rs
--     where
--       toPred (RConc p) = p

io = liftIO

driver :: Constrain a => Int -> Int -> BareType -> a -> DataConEnv -> IO [a]
driver n d t v env = runGen env $ do
       root <- gen v d t
       ctx <- io $ makeContext Z3
       let ctx' = ctx  -- {verbose = True}
       -- declare sorts
       io $ smtWrite ctx "(define-sort CHOICE () Bool)"
       --mapM_ (\ s      -> io . command ctx $ Define s) (sorts v)
       -- declare data constructors
       -- mapM_ (\ (x,t)  -> io . command ctx $ makeDecl (symbol x) t) cts
       -- declare variables
       vs <- gets variables
       mapM_ (\ x      -> io . command ctx $ Declare (symbol x) [] (snd x)) vs
       -- declare measures
       -- should be part of type class..
       io $ command ctx $ Declare (stringSymbol "len") [listsort] FInt
       -- io $ command ctx $ Declare (stringSymbol "size") [treesort] FInt
       cs <- gets constraints
       deps <- gets deps
       mapM_ (io . command ctx .  Assert) cs
       vals <- io $ take n <$> allSat ctx' (symbol root) (map (symbol *** symbol) deps) vs
       -- build up the haskell value
       xs <- forM vals $ \ vs -> do
         setValues vs
         stitch d
       io $ cleanupContext ctx
       return xs
  where
    unints vs = [symbol v | (v,t) <- vs, t `elem` interps]
    interps   = [FInt, boolsort, choicesort]
    allSat ctx root deps vs
      = do resp <- command ctx CheckSat
           print resp
           case resp of
             Error e -> error $ T.unpack e
             Unsat   -> return []
             Sat     -> unsafeInterleaveIO $ do
               Values model <- command ctx (GetValue $ map symbol vs)
               let cs = refute root model deps vs
               command ctx $ Assert $ PNot $ pAnd cs
               (map snd model:) <$> allSat ctx root deps vs

    -- refute model vs = let equiv = map (map fst) . filter ((>1) . length) . groupBy ((==) `on` snd) . sortBy (comparing snd) $ model
    --                   in [var x `eq` (ESym $ SL v) | (x,v) <- model, x `elem` unints vs]
    refute root model deps vs = let realized = reaches root model deps
                                in [var x `eq` (ESym $ SL v) | (x,v) <- realized, x `elem` unints vs]


reaches root model deps = go root
  where
    go root
      | isChoice && taken
      = (root,val) : concatMap go [r | (x,r) <- deps, x == root]
      | isChoice
      = [(root,val)]
      | otherwise
      = (root,val) : concatMap go [r | (x,r) <- deps, x == root]
      where
        val      = fromJust $ lookup root model
        isChoice = "CHOICE" `isPrefixOf` symbolString root
        taken    = val == "true"


myTrace s x = trace (s ++ ": " ++ show x) x

makeDecl x (FFunc _ ts) = Declare x (init ts) (last ts)
makeDecl x t            = Declare x []        t

type Constraint = [Pred]
type Variable   = ( String -- ^ the name
                  , Sort   -- ^ the `Sort'
                  )
type Value      = String

instance Symbolic Variable where
  symbol (x, s) = symbol x

instance SMTLIB2 Constraint where
  smt2 = smt2 . PAnd


listsort = FObj $ stringSymbol "Int"
boolsort = FObj $ stringSymbol "Bool"

unfoldrM :: Monad m => (a -> m (b, a)) -> a -> m [b]
unfoldrM f z
  = do (x,z') <- f z
       xs     <- unfoldrM f z'
       return (x:xs)

unfoldrNM :: Monad m => Int -> (a -> m (b, a)) -> a -> m [b]
unfoldrNM 0 f z = return []
unfoldrNM d f z
  = do (x,z') <- f z
       xs     <- unfoldrNM (d-1) f z'
       return (x:xs)

newtype Gen a = Gen (StateT GenState IO a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadState GenState)

runGen :: DataConEnv -> Gen a -> IO a
runGen e (Gen x) = evalStateT x (initGS e)

execGen :: DataConEnv -> Gen a -> IO GenState
execGen e (Gen x) = execStateT x (initGS e)

data GenState
  = GS { seed        :: !Int
       , variables   :: ![Variable]
       , choices     :: ![String]
       , constraints :: !Constraint
       , values      :: ![String]
       , deps        :: ![(String, String)]
       , ctorEnv     :: !DataConEnv
       } deriving (Show)

-- instance Default GenState where
--   def = GS def def def def def def def

initGS env = GS def def def def def def env

type DataConEnv = [(String, BareType)]

setValues vs = modify $ \s@(GS {..}) -> s { values = vs }

addDep from to = modify $ \s@(GS {..}) -> s { deps = (from,to):deps }

-- | `fresh' generates a fresh variable and encodes the reachability
-- relation between variables, e.g. `fresh xs sort` will return a new
-- variable `x`, from which everything in `xs` is reachable.
fresh :: [String] -> Sort -> Gen String
fresh xs sort
  = do n <- gets seed
       modify $ \s@(GS {..}) -> s { seed = seed + 1 }
       let x = T.unpack (smt2 sort) ++ show n
       modify $ \s@(GS {..}) -> s { variables = (x,sort) : variables }
       mapM_ (addDep x) xs
       return x

freshChoice :: [String] -> Gen String
freshChoice xs
  = do c <- fresh xs choicesort
       modify $ \s@(GS {..}) -> s { choices = c : choices }
       return c

choicesort = FObj $ stringSymbol "CHOICE"

freshChoose :: [String] -> Sort -> Gen String
freshChoose xs sort
  = do x <- fresh [] sort
       cs <- forM xs $ \x' -> do
               c <- freshChoice [x']
               constrain $ prop c `iff` var x `eq` var x'
               addDep x c
               return $ prop c
       constrain $ pOr cs
       constrain $ pAnd [ PNot $ pAnd [x, y] | [x, y] <- filter ((==2) . length) $ subsequences cs ]
       return x


make :: Name -> [String] -> Sort -> Gen String
make c vs s
  = do x  <- fresh vs s
       t <- (fromJust . lookup (show c)) <$> gets ctorEnv
       let (xs, _, rt) = bkArrowDeep t
           su          = mkSubst $ myTrace "su" $ zip (map symbol xs) (map var vs)
       constrain $ myTrace "make" $ ofReft x $ subst su $ toReft $ rt_reft rt
       return x

constrain :: Pred -> Gen ()
constrain p = modify $ \s@(GS {..}) -> s { constraints = p : constraints }

pop :: Gen String
pop = do v <- gets $ head . values
         modify $ \s@(GS {..}) -> s { values = tail values}
         return v

popN :: Int -> Gen [String]
popN d = replicateM d pop

popChoices :: Int -> Gen [Bool]
popChoices n = fmap read <$> popN n
  where
    read "true"  = True
    read "false" = False
    read e       = error $ "popChoices: " ++ e

class Constrain a where
  gen    :: a -> Int -> BareType -> Gen String
  stitch :: Int -> Gen a
  sorts  :: a -> [Sort]
  ctors  :: a -> [Variable]

instance Constrain Int where
  gen _ _  (RApp _ [] _ r) = fresh [] FInt >>= \x ->
    do constrain $ ofReft x (toReft r)
       return x
  stitch _                 = read <$> pop
  sorts _                  = []
  ctors _                  = []

instance (Constrain a) => Constrain [a] where
  gen _ 0 t = gen_nil t
  gen _ d t@(RApp c [ta] ps r)
    = do let t' = RApp c [ta] ps mempty
         x1 <- gen_nil t' -- (undefined :: [a]) (d-1) t
         x2 <- gen_cons ((undefined :: a) : []) d t'
         x3 <- freshChoose [x1,x2] listsort
         constrain $ ofReft x3 (toReft r)
         return x3

  stitch 0 = stitch_nil
  stitch d = do [c,n] <- popChoices 2
                pop  -- the "actual" list, but we don't care about it
                cc    <- stitch_cons d
                nn    <- stitch_nil
                case (n,c) of
                  (True,_) -> return nn
                  (_,True) -> return cc

  ctors _ = [ ("nil", listsort)
            , ("cons", FFunc 2 [FInt, listsort, listsort])
            ] ++ ctors (undefined :: a)
  sorts _ = [listsort] ++ sorts (undefined :: a)

gen_nil (RApp _ _ _ _)
  = make '[] [] listsort

stitch_nil
  = do pop >> return []

gen_cons :: Constrain a => [a] -> Int -> BareType -> Gen String
gen_cons l@(a:_) n t@(RApp c [ta] [p] r)
  = do x  <- gen a (n-1) ta
       let ta' = applyRef p [x] ta
       let t'  = RApp c [ta'] [p] r
       xs <- gen l (n-1) t'
       make '(:) [x,xs] listsort

-- stitch_cons :: Constrain [a] => Int -> Gen [a]
stitch_cons d
  = do z  <- pop
       xs <- stitch (d-1)
       x  <- stitch (d-1)
       return (x:xs)

ofReft :: String -> Reft -> Pred
ofReft s (Reft (v, rs))
  = let x = mkSubst [(v, var s)]
    in pAnd [subst x p | RConc p <- rs]

infix 4 `eq`
eq  = PAtom Eq
infix 3 `iff`
iff = PIff
infix 3 `imp`
imp = PImp


app :: Symbolic a => a -> [Expr] -> Expr
app f es = EApp (dummyLoc $ symbol f) es

var :: Symbolic a => a -> Expr
var = EVar . symbol

prop :: Symbolic a => a -> Pred
prop = PBexp . EVar . symbol


instance Num Expr where
  fromInteger = ECon . I . fromInteger
  (+) = EBin Plus
  (-) = EBin Minus
  (*) = EBin Times

instance Real Expr
instance Enum Expr

instance Integral Expr where
  div = EBin Div
  mod = EBin Mod


--------------------------------------------------------------------------------
--- test data
--------------------------------------------------------------------------------

t :: BareType
t = rr "{v:[{v0:Int | (v0 >= 0 && v0 < 5)}]<{\\h t -> h < t}> | (len v) >= 0}"

t' :: BareType
t' = rr "{v:[{v0:Int | (v0 >= 0 && v0 < 6)}] | true}"


i :: BareType
i = rr "{v:Int | v > 0}"

list :: [Int]
list = []

inT :: Int
inT = 0

tree :: Tree Int
tree = Leaf

tt :: BareType
tt = rr "{v:Tree <{\\r x -> x < r}, {\\r y -> r < y}> {v0 : Int | (v0 >= 0 && v0 < 16)} | (size v) > 0}"

specs :: String
specs = unlines [ "measure len :: [a] -> Int"
                , "len ([])   = 0"
                , "len (x:xs) = 1 + len(xs)"

                , "measure size :: Tree a -> Int"
                , "size (Leaf)       = 0"
                , "size (Node x l r) = 1 + size(l) + size(r)"
                ]

nilT  = rr "{v:[a] | (len v) = 0}"
consT = rr "x:a -> xs:[a] -> {v:[a] | (len v) = 1 + (len xs)}"
env :: DataConEnv
env = [("GHC.Types.[]",nilT),("GHC.Types.:",consT)]

data Tree a = Leaf | Node a (Tree a) (Tree a) deriving (Eq, Ord, Show)
treesort = FObj $ stringSymbol "Tree"

treeList Leaf = []
treeList (Node x l r) = treeList l ++ [x] ++ treeList r

instance Constrain a => Constrain (Tree a) where
  gen _ 0 t = gen_leaf t
  gen _ d t@(RApp c [ta] ps r)
    = do let t' = RApp c [ta] ps mempty
         l <- gen_leaf t'
         n <- gen_node (Node (undefined :: a) undefined undefined) d t'
         z <- freshChoose [l,n] treesort
         constrain $ ofReft z (toReft r)
         return z

  stitch 0 = stitch_leaf
  stitch d
    = do [cn,cl] <- popChoices 2
         void pop -- "actual" tree
         n <- stitch_node d
         l  <- stitch_leaf
         case (cn,cl) of
           (True,_) -> return n
           (_,True) -> return l

  ctors _ = [ ("leaf", treesort)
            , ("node", FFunc 3 [FInt, treesort, treesort, treesort])
            ] ++ ctors (undefined :: a)
  sorts _ = [treesort] ++ sorts (undefined :: a)

gen_leaf _
  = make 'Leaf [] treesort

stitch_leaf = pop >> return Leaf

gen_node :: Constrain a => Tree a -> Int -> BareType -> Gen String
gen_node foo@(Node a _ _) d t@(RApp c [ta] [pl,pr] r)
  = do x <- gen (a) (d-1) ta
       let tal = applyRef pl [x] ta
       let tl  = RApp c [tal] [pl,pr] r
       let tar = applyRef pr [x] ta
       let tr  = RApp c [tar] [pl,pr] r
       nl <- gen (foo) (d-1) tl
       nr <- gen (foo) (d-1) tr
       make 'Node [x,nl,nr] treesort

stitch_node d
  = do z <- pop
       nr <- stitch (d-1)
       nl <- stitch (d-1)
       x <- stitch (d-1)
       return (Node x nl nr)


-- applyRef :: Ref -> [Variable] -> RType
applyRef (RPoly xs p) vs t
  = t `strengthen` r
  where
    r  = subst su $ rt_reft p
    su = mkSubst [(fst x, var v) | x <- xs | v <- vs]


--------------------------------------------------------------------------------
--- | Dependency Graph
--------------------------------------------------------------------------------

data Dep = Empty
         | Choice String [Dep]
         | Direct String Dep
         deriving (Show, Eq)

leaf = flip Direct Empty
x20 = leaf "x20"
x21 = leaf "x21"
p10 = Direct "p10" x20
p11 = Direct "p11" x21
x10 = Choice "x10" [p10, p11]
x11 = leaf "x11"
p00 = Direct "p00" x10
p01 = Direct "p01" x11
x0  = Choice "x0" [p00, p01]
