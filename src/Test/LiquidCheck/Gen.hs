{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
module Test.LiquidCheck.Gen where

import           Control.Applicative
import           Control.Arrow
import           Control.Monad
import           Control.Monad.State
import           Data.Default
import qualified Data.HashMap.Strict              as M
import qualified Data.HashSet                     as S
import           Data.List
import           Data.Monoid
import qualified Data.Text.Lazy                   as T

import           Language.Fixpoint.SmtLib2
import           Language.Fixpoint.Types
import           Language.Haskell.Liquid.PredType
import           Language.Haskell.Liquid.Types

import           Encoding                         (zDecodeString)
import           GHC

import           Test.LiquidCheck.Types
import           Test.LiquidCheck.Util


newtype Gen a = Gen (StateT GenState IO a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadState GenState)

runGen :: GhcSpec -> Gen a -> IO a
runGen e (Gen x) = evalStateT x (initGS e)

execGen :: GhcSpec -> Gen a -> IO GenState
execGen e (Gen x) = execStateT x (initGS e)

data GenState
  = GS { seed         :: !Int
       , variables    :: ![Variable]
       , choices      :: ![String]
       , constraints  :: !Constraint
       , values       :: ![String]
       , deps         :: ![(String, String)]
       , dconEnv      :: ![(String, DataConP)]
       , ctorEnv      :: !DataConEnv
       , measEnv      :: !MeasureEnv
       , tyconInfo    :: !(M.HashMap TyCon RTyCon)
       , freesyms     :: ![(String,String)]
       , constructors :: ![Variable] -- (S.HashSet Variable)  --[(String, String)]
       , sigs         :: ![(String, SpecType)]
       , depth        :: !Int
       , chosen       :: !(Maybe String)
       , sorts        :: !(S.HashSet T.Text)
       , modName      :: !String
       , makingTy     :: !Sort
       } -- deriving (Show)

initGS sp = GS def def def def def def dcons cts (measures sp) tyi free [] sigs def Nothing S.empty "" FInt
  where
    dcons = map (showpp *** id) (dconsP sp)
    cts   = map (showpp *** val) (ctors sp)
    tyi   = makeTyConInfo (tconsP sp)
    free  = map (showpp *** showpp) $ freeSyms sp
    sigs  = map (showpp *** val) $ tySigs sp

setValues vs = modify $ \s@(GS {..}) -> s { values = vs }

addDep from to = modify $ \s@(GS {..}) -> s { deps = (from,to):deps }

addConstraint p = modify $ \s@(GS {..}) -> s { constraints = p:constraints }

addConstructor c
  = do -- modify $ \s@(GS {..}) -> s { constructors = S.insert c constructors }
       modify $ \s@(GS {..}) -> s { constructors = nub $ c:constructors }

inModule m act
  = do m' <- gets modName
       modify $ \s -> s { modName = m }
       r <- act
       modify $ \s -> s { modName = m' }
       return r

making ty act
  = do ty' <- gets makingTy
       modify $ \s -> s { makingTy = ty }
       r <- act
       modify $ \s -> s { makingTy = ty' }
       return r

withFreshChoice :: (String -> Gen ()) -> Gen String
withFreshChoice act
  = do c  <- freshChoice []
       mc <- gets chosen
       modify $ \s -> s { chosen = Just c }
       act c
       modify $ \s -> s { chosen = mc }
       return c

-- | `fresh` generates a fresh variable and encodes the reachability
-- relation between variables, e.g. `fresh xs sort` will return a new
-- variable `x`, from which everything in `xs` is reachable.
fresh :: [String] -> Sort -> Gen String
fresh xs sort
  = do n <- gets seed
       modify $ \s@(GS {..}) -> s { seed = seed + 1 }
       modify $ \s@(GS {..}) -> s { sorts = S.insert (smt2 sort) sorts }
       let x = (zDecodeString $ T.unpack (smt2 sort)) ++ show n
       modify $ \s@(GS {..}) -> s { variables = (x,sort) : variables }
       mapM_ (addDep x) xs
       return x

freshChoice :: [String] -> Gen String
freshChoice xs
  = do c <- fresh xs choicesort
       modify $ \s@(GS {..}) -> s { choices = c : choices }
       return c



pop :: Gen String
pop = do (v:vs) <- gets values
         modify $ \s@(GS {..}) -> s { values = vs }
         return v

popN :: Int -> Gen [String]
popN d = replicateM d pop

popChoice :: Gen Bool
popChoice = read <$> pop
  where
    read "true"  = True
    read "false" = False
    read e       = error $ "popChoice: " ++ e

popChoices :: Int -> Gen [Bool]
popChoices n = fmap read <$> popN n
  where
    read "true"  = True
    read "false" = False
    read e       = error $ "popChoices: " ++ e