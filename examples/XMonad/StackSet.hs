{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE DeriveGeneric #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.StackSet
-- Copyright   :  (c) Don Stewart 2007
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  dons@galois.com
-- Stability   :  experimental
-- Portability :  portable, Haskell 98
--

module XMonad.StackSet (
        -- * Introduction
        -- $intro

        -- ** The Zipper
        -- $zipper

        -- ** Xinerama support
        -- $xinerama

        -- ** Master and Focus
        -- $focus

        StackSet(..), Workspace(..), Screen(..), Stack(..), RationalRect(..),
        -- *  Construction
        -- $construction
        new, view, greedyView,
        -- * Xinerama operations
        -- $xinerama
        lookupWorkspace,
        screens, workspaces, allWindows, currentTag,
        -- *  Operations on the current stack
        -- $stackOperations
        peek, index, integrate, integrate', differentiate,
        focusUp, focusDown, focusUp', focusDown', focusMaster, focusWindow,
        tagMember, renameTag, ensureTags, member, findTag, mapWorkspace, mapLayout,
        -- * Modifying the stackset
        -- $modifyStackset
        insertUp, delete, delete', filter,
        -- * Setting the master window
        -- $settingMW
        swapUp, swapDown, swapMaster, shiftMaster, modify, modify', float, sink, -- needed by users
        -- * Composite operations
        -- $composite
        shift, shiftWin,

        -- for testing
        abort
    ) where

{-@ LIQUID "--totality" @-}

import Prelude hiding (filter)
import Data.Maybe   (listToMaybe,isJust,fromMaybe)
import qualified Data.List as L (deleteBy,find,splitAt,filter,nub)
import Data.List ( (\\) )
import qualified Data.Map  as M (Map,insert,delete,empty)

import qualified Data.Set
import GHC.Generics
-- $intro
--
-- The 'StackSet' data type encodes a window manager abstraction. The
-- window manager is a set of virtual workspaces. On each workspace is a
-- stack of windows. A given workspace is always current, and a given
-- window on each workspace has focus. The focused window on the current
-- workspace is the one which will take user input. It can be visualised
-- as follows:
--
-- > Workspace  { 0*}   { 1 }   { 2 }   { 3 }   { 4 }
-- >
-- > Windows    [1      []      [3*     [6*]    []
-- >            ,2*]            ,4
-- >                            ,5]
--
-- Note that workspaces are indexed from 0, windows are numbered
-- uniquely. A '*' indicates the window on each workspace that has
-- focus, and which workspace is current.

-- $zipper
--
-- We encode all the focus tracking directly in the data structure, with a 'zipper':
--
--    A Zipper is essentially an `updateable' and yet pure functional
--    cursor into a data structure. Zipper is also a delimited
--    continuation reified as a data structure.
--
--    The Zipper lets us replace an item deep in a complex data
--    structure, e.g., a tree or a term, without an  mutation.  The
--    resulting data structure will share as much of its components with
--    the old structure as possible.
--
--      Oleg Kiselyov, 27 Apr 2005, haskell\@, "Zipper as a delimited continuation"
--
-- We use the zipper to keep track of the focused workspace and the
-- focused window on each workspace, allowing us to have correct focus
-- by construction. We closely follow Huet's original implementation:
--
--      G. Huet, /Functional Pearl: The Zipper/,
--      1997, J. Functional Programming 75(5):549-554.
-- and:
--      R. Hinze and J. Jeuring, /Functional Pearl: The Web/.
--
-- and Conor McBride's zipper differentiation paper.
-- Another good reference is:
--
--      The Zipper, Haskell wikibook

-- $xinerama
-- Xinerama in X11 lets us view multiple virtual workspaces
-- simultaneously. While only one will ever be in focus (i.e. will
-- receive keyboard events), other workspaces may be passively
-- viewable.  We thus need to track which virtual workspaces are
-- associated (viewed) on which physical screens.  To keep track of
-- this, 'StackSet' keeps separate lists of visible but non-focused
-- workspaces, and non-visible workspaces.

-- $focus
--
-- Each stack tracks a focused item, and for tiling purposes also tracks
-- a 'master' position. The connection between 'master' and 'focus'
-- needs to be well defined, particularly in relation to 'insert' and
-- 'delete'.
--

------------------------------------------------------------------------
-- |
-- A cursor into a non-empty list of workspaces.
--
-- We puncture the workspace list, producing a hole in the structure
-- used to track the currently focused workspace. The two other lists
-- that are produced are used to track those workspaces visible as
-- Xinerama screens, and those workspaces not visible anywhere.

data StackSet i l a sid sd =
    StackSet { current  :: !(Screen i l a sid sd)    -- ^ currently focused workspace
             , visible  :: [Screen i l a sid sd]     -- ^ non-focused workspaces, visible in xinerama
             , hidden   :: [Workspace i l a]         -- ^ workspaces not visible anywhere
             , floating :: M.Map a RationalRect      -- ^ floating windows
             } deriving (Show, Read, Eq, Generic)

{-@ data StackSet i l a sid sd <p :: Workspace i l a -> Prop> =
       StackSet { lcurrent  :: (Screen <p> i l a sid sd)
                , lvisible  :: [(Screen <p> i l a sid sd)]
                , lhidden   :: [<(Workspace i l a)<p>>]
                , lfloating :: M.Map a RationalRect
                }
  @-}

{-@ using (StackSet i l a sid sd) as  {v: (StackSet i l a sid sd) | (NoDuplicates v)} @-}

{-@ visible :: x:(StackSet i l a sid sd)
            -> {v : [(Screen i l a sid sd)] | (v = (lvisible x)) }@-}

{-@ hidden :: x:(StackSet i l a sid sd)
           -> {v : [(Workspace i l a)] | (v = (lhidden x)) }@-}

{-@ current :: x:(StackSet i l a sid sd)
            -> {v : (Screen i l a sid sd) | (v = (lcurrent x)) } @-}

-- | Visible workspaces, and their Xinerama screens.
data Screen i l a sid sd = Screen { workspace :: !(Workspace i l a)
                                  , screen :: !sid
                                  , screenDetail :: !sd }
    deriving (Show, Read, Eq, Generic)
{-@ data Screen i l a sid sd <p :: Workspace i l a -> Prop>
   = Screen { lworkspace    :: <(Workspace i l a) <p>>
            , lscreen       :: sid
            , lscreenDetail :: sd
            }
@-}
{-@ workspace :: x:(Screen i l a sid sd)
              -> {v:(Workspace i l a) | v = (lworkspace x)}@-}

-- |
-- A workspace is just a tag, a layout, and a stack.
--
data Workspace i l a = Workspace  { tag :: !i, layout :: l, stack :: Maybe (Stack a) }
   deriving (Show, Read, Eq, Generic)
{-@
data Workspace i l a = Workspace  { ltag    :: i
                                  , llayout :: l
                                  , lstack :: (Maybe (UStack a)) }
  @-}


{-@ layout :: x:(Workspace i l a) -> {v:l | (v = (llayout x))} @-}
{-@ tag    :: x:(Workspace i l a) -> {v:i | (v = (ltag x))} @-}

{-@ stack  :: w:(Workspace i l a)
           -> {v:(Maybe (UStack a)) | v = (lstack w)}
  @-}


-- | A structure for window geometries
{-@ data RationalRect = RationalRect {r1::Rational, r2::Rational, r3::Rational, r4::Rational} @-}
data RationalRect = RationalRect Rational Rational Rational Rational
    deriving (Show, Read, Eq, Generic)

-- |
-- A stack is a cursor onto a window list.
-- The data structure tracks focus by construction, and
-- the master window is by convention the top-most item.
-- Focus operations will not reorder the list that results from
-- flattening the cursor. The structure can be envisaged as:
--
-- >    +-- master:  < '7' >
-- > up |            [ '2' ]
-- >    +---------   [ '3' ]
-- > focus:          < '4' >
-- > dn +----------- [ '8' ]
--
-- A 'Stack' can be viewed as a list with a hole punched in it to make
-- the focused position. Under the zipper\/calculus view of such
-- structures, it is the differentiation of a [a], and integrating it
-- back has a natural implementation used in 'index'.
--
data Stack a = Stack { focus  :: !a        -- focused thing in this set
                     , up     :: [a]       -- clowns to the left
                     , down   :: [a] }     -- jokers to the right
    deriving (Show, Read, Eq, Generic)

{-@
data Stack a = Stack { focus :: a
                     , up    :: UListDif a focus
                     , down  :: UListDif a focus }
@-}


{-@ type UStack a = {v:(Stack a) | (ListDisjoint (up v) (down v))}@-}

{-@ using (Stack a) as  {v: Stack a | (ListDisjoint (up v) (down v))}@-}


-- | this function indicates to catch that an error is expected
abort :: String -> a
abort x = error $ "xmonad: StackSet: " ++. x

-- ---------------------------------------------------------------------
-- $construction

-- | /O(n)/. Create a new stackset, of empty stacks, with given tags,
-- with physical screens whose descriptions are given by 'm'. The
-- number of physical screens (@length 'm'@) should be less than or
-- equal to the number of workspace tags.  The first workspace in the
-- list will be current.
--
-- Xinerama: Virtual workspaces are assigned to physical screens, starting at 0.
--


{-@ new :: (Integral s)
        => l
        -> ns:[i]
        -> [sd]
        -> {v:EmptyStackSet i l a s sd |((ltag (lworkspace (lcurrent v))) = (head ns))}
  @-}
new :: (Integral s) => l -> [i] -> [sd] -> StackSet i l a s sd
new l wids m | not (null wids) && length m <= length wids && not (null m)
  = StackSet cur visi unseen M.empty
  where (seen,unseen) = L.splitAt (length m) $ map (\i -> Workspace i l Nothing) wids
        (cur:visi)    = liquidAssume ((>1) . length) [ Screen i s sd |  ((i, s), sd) <- zip (zip seen [0..]) m ]
                -- now zip up visibles with their screen id
new _ _ _ = abort "non-positive argument to StackSet.new"

-- |
-- /O(w)/. Set focus to the workspace with index \'i\'.
-- If the index is out of range, return the original 'StackSet'.
--
-- Xinerama: If the workspace is not visible on any Xinerama screen, it
-- becomes the current screen. If it is in the visible list, it becomes
-- current.

{-@ predicate EqTag X S = (X = (ltag (lworkspace (lcurrent S)))) @-}

{-@ predicate TagMember X S =
      (
       (EqTag X S)
      ||
       (Set_mem X (workspacesTags (lhidden S)))
      ||
       (Set_mem X (screensTags    (lvisible S)))
      )
  @-}

-- TODO prove uniqueness of tags!
{-@ invariant {v:StackSet i l a sid sd | (
      Disjoint3 (Set_sng (ltag (lworkspace (lcurrent v)))) (workspacesTags (lhidden v)) (screensTags (lvisible v))
  )} @-}

{-@ predicate EqEltsStackSet X Y = ((stackSetElts X) = (stackSetElts Y)) @-}

{-@ view :: (Eq s, Eq i)
         => x:i
         -> s:StackSet i l a s sd
         -> {v:StackSet i l a s sd | ( ((TagMember x s) => (EqTag x v)) && (EqEltsStackSet s v) && (((EqTag x s) || (not (TagMember x s))) => (s = v)) ) }
  @-}
view :: (Eq s, Eq i) => i -> StackSet i l a s sd -> StackSet i l a s sd
view i s
    | i == currentTag s = s  -- current

    | Just x <- raiseIfVisible i s = x

    | Just x <- raiseIfHidden i s  = x
-- LIQUID     | Just x <- L.find ((i==).tag.workspace) (visible s)
-- LIQUID  -- if it is visible, it is just raised
-- LIQUID     = s { current = x
-- LIQUID         , visible = current s : deleteByScreen x (visible s) }
-- LIQUID
-- LIQUID     | Just x <- L.find ((i==).tag)           (hidden  s) -- must be hidden then
-- LIQUID     -- if it was hidden, it is raised on the xine screen currently used
-- LIQUID     = s { current = (current s) { workspace = x }
-- LIQUID         , hidden = workspace (current s) : L.deleteBy (equating tag) x (hidden s) }
-- LIQUID
   | otherwise = s -- not a member of the stackset

  where equating f = \x y -> f x == f y

{-@ raiseIfVisible :: (Eq s, Eq i)
                   => x:i
                   -> s:StackSet i l a s sd
                   -> {vv:(Maybe ({v:StackSet i l a s sd | ((EqTag x v) && (EqEltsStackSet s v))})) | ((isJust vv) <=> (Set_mem x (screensTags (lvisible s))))} @-}
raiseIfVisible :: (Eq s, Eq i) => i -> StackSet i l a s sd -> Maybe (StackSet i l a s sd)
raiseIfVisible i (StackSet c v h f)
  | Just (c', v') <- go i v v []
  = let Just (c', v') = go i v v [] in Just $ StackSet c' (c:v') h f
  | otherwise
  = Nothing
  where
{-@ predicate EqJoinScreens2 X ZS YS =
     (
      ((screensElts X) = (Set_cup (screensElts ZS) (screensElts YS) ))
     &&
     (Set_emp (Set_cap (screensElts ZS) (screensElts YS)))
     &&
      (screensTags X) = (Set_cup (screensTags ZS) (screensTags YS))
     ) @-}

{-@ predicate EqJoinScreens X Y YS =
     (
      ((screensElts X) = (Set_cup (screenElts Y) (screensElts YS) ))
     &&
      (Set_emp (Set_cap (screenElts Y) (screensElts YS)))
     &&
      (screensTags X) = (Set_cup (screenTags Y) (screensTags YS))
     ) @-}

{-@ go :: Eq i
       => x1:i
       -> init:(UScreens i l a sid sd)
       -> y:(UScreens i l a sid sd)
       -> ys:{v:(UScreens i l a sid sd) | (EqJoinScreens2 init y v) }
       -> {vv: (Maybe ((Screen i l a sid sd, (UScreens i l a sid sd))<{\x xs -> ((x1 = (ltag (lworkspace x))) && (EqJoinScreens init x xs))}>)) | ((Set_mem x1 (screensTags y)) <=> (isJust vv))  }
  @-}
{-@ Decrease go 4 @-}
go :: Eq i => i -> [Screen i l a sid sd] -> [Screen i l a sid sd] -> [Screen i l a sid sd]
   -> Maybe (Screen i l a sid sd, [Screen i l a sid sd])

go i vv (v:vs) ovs | boo i v  = Just (v, ovs .++. vs)
                   | otherwise                = go i vv vs (v:ovs)

go i vv [] ovs                                = Nothing


{-@ boo :: (Eq i) => i:i -> w:Screen i l a sid sd
        -> {v:Bool |(((Prop v) <=> (Set_mem i (screenTags w)))
                     &&
                     ((Prop v) <=> (i = (ltag (lworkspace w)))))
                     } @-}
boo i v@(Screen (Workspace _ _ _) _ _) = i == (tag $ workspace v)
{-@ (.++.) :: xs:UScreens i l a sid sd
           -> ys:{v:UScreens i l a sid sd | (Set_emp (Set_cap (screensElts xs) (screensElts v))) }
           -> {v:UScreens i l a sid sd | (((Set_cup (screensElts xs) (screensElts ys)) = (screensElts v)) && ((screensTags v) = (Set_cup (screensTags xs) (screensTags ys))))}
  @-}
(.++.) :: [Screen i l a sid sd] -> [Screen i l a sid sd] -> [Screen i l a sid sd]
[] .++. ys = ys
(x:xs) .++. ys = x : (xs .++. ys)



{-@assume  bar    :: x: Screen i l a sid sd
           ->  {v:(UScreens i l a sid sd) | (Set_emp (Set_cap (screenElts x) (screensElts v)))}
           -> UScreens i l a sid sd
  @-}

bar :: Screen i l a sid sd -> [Screen i l a sid sd] -> [Screen i l a sid sd]
bar x xs = x : xs


-- this code is similar to raiseIfVisible
-- TODO prove
{-@ assume raiseIfHidden :: (Eq s, Eq i)
                  => x:i
                  -> s:StackSet i l a s sd
                  -> {vv: (Maybe ({v:StackSet i l a s sd | ((EqTag x v) && (EqEltsStackSet s v)) })) |
                  ((isJust vv) <=> (Set_mem x (workspacesTags (lhidden s))))
                  }@-}
raiseIfHidden :: (Eq s, Eq i) => i -> StackSet i l a s sd -> Maybe (StackSet i l a s sd)
raiseIfHidden i (StackSet (Screen w sid sd) v h f)
  | Just (w', h') <- go h []
  = Just $ StackSet (Screen w' sid sd) v (w:h') f
  | otherwise
  = Nothing
  where
    go ohs (h:hs) | i == (tag h) = Just (h, ohs ++ hs)
                  | otherwise    = go (h:ohs) hs
    go ohs []                    = Nothing


    -- 'Catch'ing this might be hard. Relies on monotonically increasing
    -- workspace tags defined in 'new'
    --
    -- and now tags are not monotonic, what happens here?

-- |
-- Set focus to the given workspace.  If that workspace does not exist
-- in the stackset, the original workspace is returned.  If that workspace is
-- 'hidden', then display that workspace on the current screen, and move the
-- current workspace to 'hidden'.  If that workspace is 'visible' on another
-- screen, the workspaces of the current screen and the other screen are
-- swapped.
{-@ greedyView :: (Eq s, Eq i)
         => x:i
         -> s:StackSet i l a s sd
         -> {v:StackSet i l a s sd | ( ((TagMember x s) => (EqTag x v)) && (EqEltsStackSet s v) && (((EqTag x s) || (not (TagMember x s))) => (v = s))) }
  @-}

greedyView :: (Eq s, Eq i) => i -> StackSet i l a s sd -> StackSet i l a s sd
greedyView w ws@(StackSet _ _ _ _)
     | w `elem` workspacesTags (hidden ws) = view w ws
     | Just x <- greedyRaiseIfVisible w ws = x
-- LIQUID      | (Just s) <- L.find (wTag . workspace) (visible ws)
-- LIQUID                             = ws { current = (current ws) { workspace = workspace s }
-- LIQUID                                  , visible = s { workspace = workspace (current ws) }
-- LIQUID                                            : filterScreen (not . wTag . workspace) (visible ws) }
     | otherwise = ws
   where wTag = (w == ) . tag

-- TODO similar as for view
{-@ assume greedyRaiseIfVisible :: (Eq s, Eq i)
                         => x:i
                         -> s:StackSet i l a s sd
                         -> {vv:(Maybe ({v:StackSet i l a s sd|((EqTag x v) && (EqEltsStackSet s v))})) |
                         ((Set_mem x (screensTags (lvisible s))) <=> (isJust vv))
                         }@-}
greedyRaiseIfVisible :: (Eq s, Eq i) => i -> StackSet i l a s sd -> Maybe (StackSet i l a s sd)
greedyRaiseIfVisible i (StackSet (Screen w sid sd) v h f)
  | Just ((Screen w' sid' sd'), v') <- go v []
  = Just $ StackSet (Screen w' sid sd) ((Screen w sid' sd'):v') h f
  | otherwise
  = Nothing
  where
    go ovs (v:vs) | i == (tag $ workspace v) = Just (v, ovs ++ vs)
                  | otherwise                = go (v:ovs) vs
    go ovs []                                = Nothing

-- ---------------------------------------------------------------------
-- $xinerama

-- | Find the tag of the workspace visible on Xinerama screen 'sc'.
-- 'Nothing' if screen is out of bounds.
lookupWorkspace :: Eq s => s -> StackSet i l a s sd -> Maybe i
lookupWorkspace sc w = listToMaybe [ tag i | Screen i s _ <- current w : visible w, s == sc ]

-- ---------------------------------------------------------------------
-- $stackOperations

-- |
-- The 'with' function takes a default value, a function, and a
-- StackSet. If the current stack is Nothing, 'with' returns the
-- default value. Otherwise, it applies the function to the stack,
-- returning the result. It is like 'maybe' for the focused workspace.
--
with :: b -> (Stack a -> b) -> StackSet i l a s sd -> b
with dflt f = maybe dflt f . stack . workspace . current

withStack :: Maybe (Stack a)
          -> (Stack a -> Maybe (Stack a))
          -> StackSet i l a s sd
          -> Maybe (Stack a)
withStack dflt f = maybe dflt f . stack . workspace . current

-- |
-- Apply a function, and a default value for 'Nothing', to modify the current stack.
--
--

{-@ predicate GoodCurrent X ST =
       (Set_sub (mStackElts X) (mStackElts (lstack (lworkspace (lcurrent ST))))) @-}

{-@ measure mStackElts :: (Maybe (Stack a)) -> (Data.Set.Set a)
    mStackElts (Just x) = (stackElts x)
    mStackElts (Nothing) = {v | (? (Set_emp v))}
  @-}

{-@ invariant {v: (Maybe (Stack a)) | ((((stackElts (fromJust v)) = (mStackElts v)) <=> (isJust v) )  && ((Set_emp (mStackElts v)) <=> (isNothing v)))} @-}
{-@ measure isNothing :: (Maybe a) -> Prop
    isNothing (Nothing) = true
    isNothing (Just x)  = false
  @-}

{-@ modify :: {v:Maybe (UStack a) | (? (isNothing v))}
           -> (y:(UStack a) -> ({v: Maybe (UStack a) | (Set_sub (mStackElts v)  (stackElts y))}) )
           -> StackSet i l a s sd
           -> StackSet i l a s sd @-}
modify :: Maybe (Stack a) -> (Stack a -> Maybe (Stack a)) -> StackSet i l a s sd -> StackSet i l a s sd

modify d f (StackSet (Screen (Workspace i l Nothing) sid sd) v h fl)
  = (StackSet (Screen  (Workspace i l d) sid sd) v h fl)

modify d f (StackSet (Screen (Workspace i l (Just x)) sid sd) v h fl)
  = (StackSet (Screen  (Workspace i l (f x)) sid sd) v h fl)

-- LIQUID Agreesive rewrite modify .....
-- LIQUID modify :: Maybe (Stack a) -> (Stack a -> Maybe (Stack a)) -> StackSet i l a s sd -> StackSet i l a s sd
-- LIQUID modify d f s = s { current = (current s)
--                         { workspace = (workspace (current s)) { stack = with d f s }}}

-- |
-- Apply a function to modify the current stack if it isn't empty, and we don't
--  want to empty it.
--
{-@ modify' :: (x:UStack a -> {v : UStack a | (Set_sub (stackElts v) (stackElts x)) } ) -> StackSet i l a s sd -> StackSet i l a s sd @-}
modify' :: (Stack a -> Stack a) -> StackSet i l a s sd -> StackSet i l a s sd
modify' f = modify Nothing (Just . f)

-- |
-- /O(1)/. Extract the focused element of the current stack.
-- Return 'Just' that element, or 'Nothing' for an empty stack.
--
peek :: StackSet i l a s sd -> Maybe a
{-@ peek :: StackSet i l a s sd -> Maybe a @-}
peek = with Nothing (return . focus)

-- |
-- /O(n)/. Flatten a 'Stack' into a list.
--
{-@ integrate :: UStack a -> UList a @-}
integrate :: Stack a -> [a]
integrate (Stack x l r) = reverse l ++ x : r

-- |
-- /O(n)/ Flatten a possibly empty stack into a list.
{-@ integrate' :: Maybe (UStack a) -> UList a @-}
integrate' :: Maybe (Stack a) -> [a]
integrate' = maybe [] integrate

-- |
-- /O(n)/. Turn a list into a possibly empty stack (i.e., a zipper):
-- the first element of the list is current, and the rest of the list
-- is down.
{-@ differentiate :: UList a -> Maybe (Stack a) @-}
differentiate :: [a] -> Maybe (Stack a)
differentiate []     = Nothing
differentiate (x:xs) = Just $ Stack x [] xs


-- |
-- /O(n)/. 'filter p s' returns the elements of 's' such that 'p' evaluates to
-- 'True'.  Order is preserved, and focus moves as described for 'delete'.
--
{-@ filter :: (a -> Bool) -> x:UStack a -> {v:Maybe (UStack a) |(Set_sub (mStackElts v) (stackElts x)) }@-}
filter :: (a -> Bool) -> Stack a -> Maybe (Stack a)
filter p (Stack f ls rs) = case L.filter p (f:rs) of
    f':rs' -> Just $ Stack f' (L.filter p ls) rs'    -- maybe move focus down
    []     -> case L.filter p ls of                  -- filter back up
                    f':ls' -> Just $ Stack f' ls' [] -- else up
                    []     -> Nothing

-- |
-- /O(s)/. Extract the stack on the current workspace, as a list.
-- The order of the stack is determined by the master window -- it will be
-- the head of the list. The implementation is given by the natural
-- integration of a one-hole list cursor, back to a list.
--
index :: StackSet i l a s sd -> [a]
index = with [] integrate

-- |
-- /O(1), O(w) on the wrapping case/.
--
-- focusUp, focusDown. Move the window focus up or down the stack,
-- wrapping if we reach the end. The wrapping should model a 'cycle'
-- on the current stack. The 'master' window, and window order,
-- are unaffected by movement of focus.
--
-- swapUp, swapDown, swap the neighbour in the stack ordering, wrapping
-- if we reach the end. Again the wrapping model should 'cycle' on
-- the current stack.
--
{-@ focusUp, focusDown, swapUp, swapDown :: StackSet i l a s sd -> StackSet i l a s sd @-}
focusUp, focusDown, swapUp, swapDown :: StackSet i l a s sd -> StackSet i l a s sd
focusUp   = modify' focusUp'
focusDown = modify' focusDown'

swapUp    = modify' swapUp'
swapDown  = modify' (reverseStack . swapUp' . reverseStack)

-- | Variants of 'focusUp' and 'focusDown' that work on a
-- 'Stack' rather than an entire 'StackSet'.


{-@ invariant {v:[a] |
       ((not (null v)) => (listElts v) = (Set_cup (Set_sng (head v)) (listElts (tail v)))) }@-}

{-@ invariant {v:[a] | ((null v) => (Set_emp (listElts v))) }@-}


{-@ measure head :: [a] -> a
    head (x:xs) = x
  @-}

{-@ measure tail :: [a] -> [a]
    tail (x:xs) = xs
  @-}

{-@ focusUp', focusDown', swapUp' :: x:UStack a -> {v:UStack a|((stackElts v) = (stackElts x))} @-}
focusUp', focusDown' :: Stack a -> Stack a
focusUp' (Stack t (l:ls) rs) = Stack l ls (t:rs)
focusUp' (Stack t []     rs) = Stack (head xs) (tail xs) [] where xs = reverse (t:rs)
focusDown'                   = reverseStack . focusUp' . reverseStack

swapUp' :: Stack a -> Stack a
swapUp'  (Stack t (l:ls) rs) = Stack t ls (l:rs)
swapUp'  (Stack t []     rs) = Stack t (reverse rs) []

-- | reverse a stack: up becomes down and down becomes up.
reverseStack :: Stack a -> Stack a
reverseStack (Stack t ls rs) = Stack t rs ls

--
-- | /O(1) on current window, O(n) in general/. Focus the window 'w',
-- and set its workspace as current.
--
focusWindow :: (Eq s, Eq a, Eq i) => a -> StackSet i l a s sd -> StackSet i l a s sd
focusWindow w s | Just w == peek s = s
                | otherwise        = fromMaybe s $ do
                    n <- findTag w s
                    return $ until ((Just w ==) . peek) focusUp (view n s)

-- | Get a list of all screens in the 'StackSet'.
screens :: StackSet i l a s sd -> [Screen i l a s sd]
screens s = current s : visible s

-- | Get a list of all workspaces in the 'StackSet'.
workspaces :: StackSet i l a s sd -> [Workspace i l a]
workspaces s = workspace (current s) : map workspace (visible s) ++. hidden s

-- | Get a list of all windows in the 'StackSet' in no particular order
allWindows :: Eq a => StackSet i l a s sd -> [a]
allWindows = L.nub . concatMap (integrate' . stack) . workspaces

-- | Get the tag of the currently focused workspace.
{-@ currentTag :: x:StackSet i l a s sd -> {v:i| (EqTag v x)} @-}
currentTag :: StackSet i l a s sd -> i
currentTag (StackSet (Screen (Workspace i _ _) _ _) _ _ _)  = i
-- LIQUID currentTag = tag . workspace . current

-- | Is the given tag present in the 'StackSet'?
tagMember :: Eq i => i -> StackSet i l a s sd -> Bool
{-@ tagMember :: Eq i
          => x:i
          -> s:StackSet i l a s sd
          -> {v:Bool| ( (Prop v) <=> (TagMember x s))}
  @-}
tagMember t s =   t == currentTag s
              ||  (t `elem` workspacesTags (hidden s))
              ||  (t `elem` screensTags (visible s))
{-@ screensTags :: ss:[Screen i l a sid sd] -> {v:[i] | (listElts v) = (screensTags ss)}@-}
screensTags :: [Screen i l a sid sd] -> [i]
screensTags (x@(Screen (Workspace _ _ _) _ _):xs) = (tag $ workspace x):(screensTags xs)
screensTags []     = []

{-@ workspacesTags :: ws:[Workspace i l a] -> {v:[i] |(listElts v) = (workspacesTags ws)} @-}
workspacesTags :: [Workspace i l a] -> [i]
workspacesTags (x:xs) = (tag x):(workspacesTags xs)
workspacesTags []     = []

-- | Rename a given tag if present in the 'StackSet'.
renameTag :: Eq i => i -> i -> StackSet i l a s sd -> StackSet i l a s sd
renameTag o n = mapWorkspace rename
    where rename w = if tag w == o then w { tag = n } else w

-- | Ensure that a given set of workspace tags is present by renaming
-- existing workspaces and\/or creating new hidden workspaces as
-- necessary.
{-@ ensureTags :: Eq i => l -> [i] -> StackSet i l a s sd -> StackSet i l a s sd @-}
ensureTags :: Eq i => l -> [i] -> StackSet i l a s sd -> StackSet i l a s sd
ensureTags l allt st = et allt (map tag (workspaces st) \\ allt) st
    where et [] _ s = s
          et (i:is) rn s | i `tagMember` s = et is rn s
          et (i:is) [] s = et is [] (s { hidden = Workspace i l Nothing : hidden s })
          et (i:is) (r:rs) s = et is rs $ renameTag r i s


{- invariant {v:Screen i l a sid sd | (screenElts v) = (workspaceElts (lworkspace v)) } @-}

-- | Map a function on all the workspaces in the 'StackSet'.
{-@ mapWorkspace :: (x:Workspace i l a -> {v:Workspace i l a| (workspaceElts x) = (workspaceElts v)})
                 -> StackSet i l a s sd
                 -> StackSet i l a s sd @-}
mapWorkspace :: (Workspace i l a -> Workspace i l a) -> StackSet i l a s sd -> StackSet i l a s sd
mapWorkspace f s
  = s { current = updScr (current s)
      , visible = mapS updScr (visible s)
      , hidden  = mapW f (hidden s) }
  where
     {- updScr :: x:Screen i l a sid sd -> {v:Screen i l a sid sd | (screenElts v) = (screenElts x)} @-}
     updScr (Screen w sid sd) = (Screen (f w) sid sd)


-- | Map a function on all the layouts in the 'StackSet'.
{-@ mapLayout :: (l1 -> l2) -> StackSet i l1 a s sd -> StackSet i l2 a s sd @-}
mapLayout :: (l -> l') -> StackSet i l a s sd -> StackSet i l' a s sd
mapLayout f (StackSet v vs hs m) = StackSet (fScreen v) (mapS fScreen vs) (mapW fWorkspace hs) m
 where

{- fScreen :: x:Screen i l1 a s sid -> {v:Screen i l2 a s sid | (screenElts x) = (screenElts v)} @-}
    fScreen (Screen ws s sd) = Screen (fWorkspace ws) s sd

{-  fWorkspace :: x:Workspace i l1 a -> {v:Workspace i l2 a | (workspaceElts x) = (workspaceElts v)} @-}
    fWorkspace (Workspace t l s) = Workspace t (f l) s


{-@  mapS' :: (x:Screen i l1 a sid sd
                       -> {v:Screen i l2 a sid sd|(Set_sub (screenElts v) (screenElts x))})
                  -> xs:UScreens i l1 a sid sd
                  -> {v:(UScreens i l2 a sid sd) |(Set_sub (screensElts v) (screensElts xs))} @-}
mapS' :: (Screen i l a sid sd -> Screen i l' a sid sd) -> [Screen i l a sid sd] -> [Screen i l' a sid sd]
mapS' f [] = []
mapS' f (x:xs) = f x : mapS' f xs

{-@  mapW' :: (x:Workspace i l1 a
                       -> {v:Workspace i l2 a|(Set_sub (workspaceElts v) (workspaceElts x))})
                  -> xs:(UWorkspaces i l1 a)
                  -> {v:(UWorkspaces i l2 a) |(Set_sub (workspacesElts v) (workspacesElts xs))} @-}
mapW' :: (Workspace i l a -> Workspace i l' a) -> [Workspace i l a] -> [Workspace i l' a]
mapW' f [] = []
mapW' f (x:xs) = f x : mapW' f xs



{-@  mapS :: (x:Screen i l1 a sid sd
                       -> {v:Screen i l2 a sid sd|(screenElts x) = (screenElts v)})
                  -> xs:(UScreens i l1 a sid sd)
                  -> {v:(UScreens i l2 a sid sd) |((screensElts v) = (screensElts xs))} @-}
mapS :: (Screen i l a sid sd -> Screen i l' a sid sd) -> [Screen i l a sid sd] -> [Screen i l' a sid sd]
mapS f [] = []
mapS f (x:xs) = f x : mapS f xs

{-@  mapW :: (x:Workspace i l1 a
                       -> {v:Workspace i l2 a|(workspaceElts x) = (workspaceElts v)})
                  -> xs:UWorkspaces i l1 a
                  -> {v:(UWorkspaces i l2 a) |(workspacesElts v) = (workspacesElts xs)} @-}
mapW :: (Workspace i l a -> Workspace i l' a) -> [Workspace i l a] -> [Workspace i l' a]
mapW f [] = []
mapW f (x:xs) = f x : mapW f xs

-- | /O(n)/. Is a window in the 'StackSet'?
{-@ member :: Eq a
           => x:a
           -> st:(StackSet i l a s sd)
           -> {v:Bool| ((~(Prop v)) => (~(StackSetElt x st)))}
  @-}
member :: Eq a => a -> StackSet i l a s sd -> Bool
member a s =  memberStack      a (stack $ workspace $ current s)
           || memberScreens    a (visible s)
           || memberWorkspaces a (hidden s)
           || isJust (findTag a s)
-- member a s = isJust (findTag a s)

{-@ memberWorkspace :: Eq a
                    => x:a
                    -> w:(Workspace i l a)
                    -> {v:Bool|((Prop v)<=>(Set_mem x (workspaceElts w)))}
  @-}
memberWorkspace x (Workspace _ _ (Just (Stack f u d))) = x`elem` (f:u++d)
memberWorkspace _ _                     = False

{-@ invariant {v:(Screen i l a sid sd) | (screenElts v) = (mStackElts (lstack (lworkspace v)))} @-}
{-@ memberScreen :: Eq a
                    => x:a
                    -> w:(Screen i l a sid sd)
                    -> {v:Bool|((Prop v)<=>(Set_mem x (screenElts w)))}
  @-}
memberScreen x (Screen w _ _) = memberWorkspace x w



{-@ memberWorkspaces :: Eq a
                     => x:a
                     -> ss:[Workspace i l a]
                     -> {v:Bool|((Prop v)<=>(Set_mem x (workspacesElts ss)))}
  @-}

memberWorkspaces _ []     = False
memberWorkspaces a (w:ws) = memberWorkspace a w || memberWorkspaces a ws

{-@ memberScreens :: Eq a
                  => x:a
                  -> ss:[Screen i l a s sd]
                  -> {v:Bool|((Prop v)<=>(Set_mem x (screensElts ss)))}
  @-}

memberScreens a []     = False
memberScreens a (s:ss) = memberScreen a s || memberScreens a ss

{-@ memberStack :: Eq a
                => x:a
                -> st:(Maybe (UStack a))
                -> {v:Bool|((Prop v)<=>((isJust st) && (StackElt x (fromJust st))))}
  @-}
memberStack :: Eq a => a -> Maybe (Stack a) -> Bool
memberStack x (Just (Stack f up down)) = x `elem` (f : up ++ down)
memberStack _ Nothing                  = False

-- | /O(1) on current window, O(n) in general/.
-- Return 'Just' the workspace tag of the given window, or 'Nothing'
-- if the window is not in the 'StackSet'.
findTag :: Eq a => a -> StackSet i l a s sd -> Maybe i
{-@ findTag :: Eq a => a -> StackSet i l a s sd -> Maybe i @-}
findTag a s = listToMaybe
    [ tag w | w <- workspaces s, has a (stack w) ]
    where has _ Nothing         = False
          has x (Just (Stack t l r)) = x `elem` (t : l ++ r)

-- ---------------------------------------------------------------------
-- $modifyStackset

-- |
-- /O(n)/. (Complexity due to duplicate check). Insert a new element
-- into the stack, above the currently focused element. The new
-- element is given focus; the previously focused element is moved
-- down.
--
-- If the element is already in the stackset, the original stackset is
-- returned unmodified.
--
-- Semantics in Huet's paper is that insert doesn't move the cursor.
-- However, we choose to insert above, and move the focus.
--
{-@ insertUp :: Eq a
             => x:a
             -> StackSet i l a s sd
             -> StackSet i l a s sd @-}
insertUp :: Eq a => a -> StackSet i l a s sd -> StackSet i l a s sd
insertUp a s = if member a s then s else insertUp_ a (Just $ Stack a [] []) s

{-@ insertUp_ :: x:a
              -> {v: (Maybe (UStack a)) | ((isJust v) => ((stackElts (fromJust v)) = (Set_sng x)))}
              -> {v:StackSet i l a s sd | (~ (StackSetElt x v))}
              -> StackSet i l a s sd @-}
insertUp_ :: a
          -> Maybe (Stack a)
          -> StackSet i l a s sd
          -> StackSet i l a s sd
insertUp_ x _ (StackSet (Screen (Workspace i l (Just (Stack t ls rs))) a b ) v h c)
 = (StackSet (Screen (Workspace i l (Just (Stack x ls (t:rs)))) a b) v h c)
insertUp_ _ d (StackSet (Screen (Workspace i l Nothing) a b ) v h c)
 = (StackSet (Screen (Workspace i l d) a b ) v h c)

-- insertDown :: a -> StackSet i l a s sd -> StackSet i l a s sd
-- insertDown a = modify (Stack a [] []) $ \(Stack t l r) -> Stack a (t:l) r
-- Old semantics, from Huet.
-- >    w { down = a : down w }

-- |
-- /O(1) on current window, O(n) in general/. Delete window 'w' if it exists.
-- There are 4 cases to consider:
--
--   * delete on an 'Nothing' workspace leaves it Nothing
--
--   * otherwise, try to move focus to the down
--
--   * otherwise, try to move focus to the up
--
--   * otherwise, you've got an empty workspace, becomes 'Nothing'
--
-- Behaviour with respect to the master:
--
--   * deleting the master window resets it to the newly focused window
--
--   * otherwise, delete doesn't affect the master.
--
delete :: (Ord a, Eq s) => a -> StackSet i l a s sd -> StackSet i l a s sd
delete w = sink w . delete' w

-- | Only temporarily remove the window from the stack, thereby not destroying special
-- information saved in the 'Stackset'
delete' :: (Eq a, Eq s) => a -> StackSet i l a s sd -> StackSet i l a s sd
delete' w s = s { current = removeFromScreen        (current s)
                , visible = mapS' removeFromScreen    (visible s)
                , hidden  = mapW' removeFromWorkspace (hidden  s) }
    where

      {- removeFromWorkspace :: x:Workspace i l a -> {v:Workspace i l a | (Set_sub  (workspaceElts v) (workspaceElts  x) )} @-}
      {- removeFromScreen :: x:Screen i l a sid sd -> {v:Screen i l a sid sd| (Set_sub  (screenElts v) (screenElts x) )} @-}
      removeFromWorkspace (Workspace i l Nothing) = Workspace i l Nothing
      removeFromWorkspace (Workspace i l (Just x)) = Workspace i l (filter (/=w) x)
-- LIQUID       removeFromWorkspace ws = ws { stack = stack ws >>= filter (/=w) }
      removeFromScreen scr   = scr { workspace = removeFromWorkspace (workspace scr) }


------------------------------------------------------------------------

-- | Given a window, and its preferred rectangle, set it as floating
-- A floating window should already be managed by the 'StackSet'.
float :: Ord a => a -> RationalRect -> StackSet i l a s sd -> StackSet i l a s sd
float w r s = s { floating = M.insert w r (floating s) }

-- | Clear the floating status of a window
sink :: Ord a => a -> StackSet i l a s sd -> StackSet i l a s sd
sink w s = s { floating = M.delete w (floating s) }

------------------------------------------------------------------------
-- $settingMW

-- | /O(s)/. Set the master window to the focused window.
-- The old master window is swapped in the tiling order with the focused window.
-- Focus stays with the item moved.
{-@ swapMaster :: StackSet i l a s sd -> StackSet i l a s sd @-}
swapMaster :: StackSet i l a s sd -> StackSet i l a s sd
swapMaster = modify' $ \c -> case c of
    Stack _ [] _  -> c    -- already master.
    Stack t ls rs -> Stack t [] ((tail xs) ++ (head xs):rs) where xs = reverse ls

-- natural! keep focus, move current to the top, move top to current.

-- | /O(s)/. Set the master window to the focused window.
-- The other windows are kept in order and shifted down on the stack, as if you
-- just hit mod-shift-k a bunch of times.
-- Focus stays with the item moved.
shiftMaster :: StackSet i l a s sd -> StackSet i l a s sd
shiftMaster = modify' $ \c -> case c of
    Stack _ [] _ -> c     -- already master.
    Stack t ls rs -> Stack t [] (reverse ls ++ rs)

-- | /O(s)/. Set focus to the master window.
{-@ focusMaster :: StackSet i l a s sd -> StackSet i l a s sd @-}
focusMaster :: StackSet i l a s sd -> StackSet i l a s sd
focusMaster = modify' $ \c -> case c of
    Stack _ [] _ -> c
    Stack t ls rs ->  Stack (head xs) [] (tail xs ++ t:rs) where xs = reverse ls



{-@ assume Prelude.tail :: x:UList a -> {v:UList a | ((listElts x) = (Set_cup (Set_sng (head x)) (listElts v)) && (not (Set_mem (head x) (listElts v))))} @-}


{-@ assume Prelude.head :: x:UList a -> {v:a | ((listElts x) = (Set_cup (Set_sng v) (listElts (tail x))) && (not (Set_mem v (listElts (tail x)))))} @-}
--
-- ---------------------------------------------------------------------
-- $composite

-- | /O(w)/. shift. Move the focused element of the current stack to stack
-- 'n', leaving it as the focused element on that stack. The item is
-- inserted above the currently focused element on that workspace.
-- The actual focused workspace doesn't change. If there is no
-- element on the current stack, the original stackSet is returned.
--
shift :: (Ord a, Eq s, Eq i) => i -> StackSet i l a s sd -> StackSet i l a s sd
shift n s = maybe s (\w -> shiftWin n w s) (peek s)

-- | /O(n)/. shiftWin. Searches for the specified window 'w' on all workspaces
-- of the stackSet and moves it to stack 'n', leaving it as the focused
-- element on that stack. The item is inserted above the currently
-- focused element on that workspace.
-- The actual focused workspace doesn't change. If the window is not
-- found in the stackSet, the original stackSet is returned.
shiftWin :: (Ord a, Eq a, Eq s, Eq i) => i -> a -> StackSet i l a s sd -> StackSet i l a s sd
shiftWin n w s = case findTag w s of
                    Just from | n `tagMember` s && n /= from -> go from s
                    _                                        -> s
 where go from = onWorkspace n (insertUp w) . onWorkspace from (delete' w)

onWorkspace :: (Eq i, Eq s) => i -> (StackSet i l a s sd -> StackSet i l a s sd)
            -> (StackSet i l a s sd -> StackSet i l a s sd)
onWorkspace n f s = view (currentTag s) . f . view n $ s


-- LIQUID HELPERS

{-@ assume liquidAssume :: forall <p :: a -> Prop>. (a<p> -> {v:Bool| ((Prop v) <=> true)}) -> a -> a<p> @-}
liquidAssume :: (a -> Bool) -> a -> a
liquidAssume p x | p x       = x
                 | otherwise = error "liquidAssume fails"

{-@ assume (Prelude.++) :: xs:(UList a)
                -> ys:{v: UList a | (ListDisjoint v xs)}
                -> {v: UList a | (UnionElts v xs ys)}
  @-}
infix 4 ++.
{- (++.) :: [a] -> [a] -> [a] @-}
(++.) :: [a] -> [a] -> [a]
[]     ++. ys = ys
(x:xs) ++. ys = x:(xs ++. ys)

{-@ filterScreen :: (Screen i l a sid sd -> Bool)
                 -> [Screen i l a sid sd]
                 -> [Screen i l a sid sd]
  @-}

filterScreen :: (Screen i l a sid sd -> Bool)
             -> [Screen i l a sid sd]
             -> [Screen i l a sid sd]
filterScreen f []                 = []
filterScreen f (x:xs) | f x       = x : filterScreen f xs
                      | otherwise =     filterScreen f xs

{- assume Data.List.filter :: (a -> Bool)
                            -> xs:(UList a)
                            -> {v:UList a | (SubElts v xs)} @-}

{- assume elem :: Eq a
                => x:a
                -> xs:[a]
                -> {v:Bool|((Prop v)<=>(ListElt x xs))}
  @-}

{- assume reverse :: xs:(UList a)
                   -> {v: UList a | ((EqElts v xs) && (Set_sub (listElts v) (listElts xs)))}
  @-}

{-@ predicate NoDuplicates SS =
      (
      (Disjoint3  (workspacesElts (lhidden SS))
                  (screenElts     (lcurrent SS))
                  (screensElts    (lvisible SS))
       )
       &&
       (ScreensNoDups (lvisible SS))
       &&
       (WorkspacesNoDups (lhidden SS))
       &&
       (NoDuplicateTags SS)
       &&
       (NoDuplicateScreens SS)
      )
  @-}

{-@ predicate NoDuplicateTags SS = (Disjoint3 (Set_sng (ltag (lworkspace (lcurrent SS)))) (workspacesTags (lhidden SS)) (screensTags (lvisible SS))) @-}

{-@ predicate NoDuplicateScreens SS = (Set_emp (Set_cap (Set_sng (lscreen (lcurrent SS))) (screensScreens (lvisible SS)))) @-}

{-@ type UScreens i l a sid sd  = {v:[Screen i l a sid sd ] | (ScreensNoDups v) } @-}

{-@ type UWorkspaces i l a = {v:[Workspace i l a] | (WorkspacesNoDups v) } @-}

{-@ predicate StackSetElt N S =
      (
        (ScreenElt N (lcurrent S))
      ||
        (Set_mem N (screensElts (lvisible S)))
      ||
        (Set_mem N (workspacesElts (lhidden S)))
      )
  @-}

{-@ predicate Disjoint3 X Y Z =
       (
         (Set_emp (Set_cap X Y))
       &&
         (Set_emp (Set_cap Y Z))
       &&
         (Set_emp (Set_cap Z X))
       )
  @-}

{-@ measure screenScreens :: (Screen i l a sid sd) ->  (Data.Set.Set sid)
    screenScreens(Screen w x y) = (Set_sng x)
  @-}

{-@ measure screensScreens :: ([Screen i l a sid sd]) ->  (Data.Set.Set sid)
    screensScreens([]) = {v|(?(Set_emp v))}
    screensScreens(x:xs) = (Set_cup (screenScreens x) (screensScreens xs))
  @-}

{-@ measure screenTags :: (Screen i l a sid sd) ->  (Data.Set.Set i)
    screenTags(Screen w x y) = (Set_sng (ltag w))
  @-}

{-@ measure screensTags :: ([Screen i l a sid sd]) ->  (Data.Set.Set i)
    screensTags([]) = {v|(?(Set_emp v))}
    screensTags(x:xs) = (Set_cup (screenTags x) (screensTags xs))
  @-}

{-@ measure workspacesTags :: ([Workspace i l a]) ->  (Data.Set.Set i)
    workspacesTags([]) = {v|(?(Set_emp v))}
    workspacesTags(x:xs) = (Set_cup (Set_sng(ltag x)) (workspacesTags xs))
  @-}

{-@ measure screenElts :: (Screen i l a sid sd) -> (Data.Set.Set a)
    screenElts(Screen w s sc) = (workspaceElts w)
  @-}

{-@ measure stackElts :: (Stack a) -> (Data.Set.Set a)
    stackElts(Stack f u d) = (Set_cup (Set_sng f) (Set_cup (listElts u) (listElts d)))
  @-}

{-@ measure screensElts :: [(Screen i l a sid sd)] -> (Data.Set.Set a)
    screensElts([])   = {v| (? (Set_emp v))}
    screensElts(x:xs) = (Set_cup (screenElts x) (screensElts xs))
  @-}

{-@ measure workspacesElts :: [(Workspace i l a)] -> (Data.Set.Set a)
    workspacesElts([])   = {v| (? (Set_emp v))}
    workspacesElts(x:xs) = (Set_cup (workspaceElts x) (workspacesElts xs))
  @-}

{-@ measure workspacesDups :: [(Workspace i l a)] -> (Data.Set.Set a)
    workspacesDups([])   = {v | (? (Set_emp v)) }
    workspacesDups(x:xs) = (Set_cup (Set_cap (workspaceElts x) (workspacesElts xs)) (workspacesDups xs))
  @-}

{-@ measure screensDups :: [(Screen i l a sid sd)] -> (Data.Set.Set a)
    screensDups([])   = {v | (? (Set_emp v))}
    screensDups(x:xs) = (Set_cup (Set_cap (screenElts x) (screensElts xs)) (screensDups xs))
  @-}

{-@ predicate ScreensNoDups XS = (Set_emp (screensDups XS)) @-}
{-@ predicate WorkspacesNoDups XS = (Set_emp (workspacesDups XS)) @-}

{-@ measure workspaceElts :: (Workspace i l a) -> (Data.Set.Set a)
    workspaceElts (Workspace i l s) = {v | (if (isJust s) then (v = (stackElts (fromJust s))) else (? (Set_emp v)))}
  @-}

{-@ predicate StackSetCurrentElt N S =
      (ScreenElt N (lcurrent S))
  @-}

{-@ predicate ScreenElt N S =
      (WorkspaceElt N (lworkspace S))
  @-}

{-@ predicate WorkspaceElt N W =
  ((isJust (lstack W)) && (StackElt N (fromJust (lstack W)))) @-}

{-@ predicate StackElt N S =
       (((ListElt N (up S))
       || (Set_mem N (Set_sng (focus S)))
       || (ListElt N (down S))))
  @-}

{-@
  measure listDup :: [a] -> (Data.Set.Set a)
  listDup([])   = {v | (? Set_emp (v))}
  listDup(x:xs) = {v | v = ((Set_mem x (listElts xs))?(Set_cup (Set_sng x) (listDup xs)):(listDup xs)) }
  @-}

{-@ predicate SubElts X Y =
       (Set_sub (listElts X) (listElts Y)) @-}

{-@ predicate UnionElts X Y Z =
       ((listElts X) = (Set_cup (listElts Y) (listElts Z))) @-}

{-@ predicate EqElts X Y =
       ((listElts X) = (listElts Y)) @-}

{-@ predicate ListUnique LS =
       (Set_emp (listDup LS)) @-}

{-@ predicate ListElt N LS =
       (Set_mem N (listElts LS)) @-}

{-@ predicate ListDisjoint X Y =
       (Set_emp (Set_cap (listElts X) (listElts Y))) @-}


{-@ type UList a = {v:[a] | (ListUnique v)} @-}

{-@ type UListDif a N = {v:[a] | ((not (ListElt N v)) && (ListUnique v))} @-}

{-@ qualif NotMem1(v: List a, x:a) : (not (Set_mem x (listElts v))) @-}

{-@ qualif NotMem2(v:a, x: List a) : (not (Set_mem v (listElts x))) @-}

{-@ qualif NoDup(v: List a) : (Set_emp(listDup v)) @-}

{-@ qualif Disjoint(v: List a, x:List a) : (Set_emp(Set_cap (listElts v) (listElts x))) @-}















-------------------------------------------------------------------------------
---------------  QUICKCHECK PROPERTIES : --------------------------------------
-------------------------------------------------------------------------------

-- TODO move them in a seperate file, after name resolution is fixed....

{-@ type EmptyStackSet i l a sid sd = StackSet <{\w -> (isNothing (lstack w))}> i l a sid sd @-}

{-@ type Valid = {v:Bool | (Prop v) } @-}
{-@ type TOPROVE = Bool @-}

{-@ prop_empty :: (Eq a) => EmptyStackSet i l a sid sd -> Valid  @-}
prop_empty :: (Eq a) => StackSet i l a sid sd -> Bool
prop_empty s@(StackSet (Screen _ _ _) vs hs _)
  =  isNothing (stack (workspace (current s)))
  && allIsNothingW hs && allIsNothingS vs

{-@ prop_empty_current :: (Integral l, Eq i) => {v:[i]|(not (null v))} -> [sd] -> l ->  Valid @-}
prop_empty_current :: (Integral l, Eq i) => [i] -> [sd] -> l -> Bool
prop_empty_current ns@(n:_) sds l =
    tag (workspace (current x)) == n
    where x = new l ns sds

{-@ prop_member_empty :: Eq a => a -> EmptyStackSet i l a sid sd -> TOPROVE @-}
prop_member_empty :: Eq a => a -> StackSet i l a sid sd -> Bool
prop_member_empty i x
    = member i x == False

-- viewing workspaces

{-@ prop_view_current :: (Eq s, Eq i) => StackSet i l a sid sd -> i -> Valid @-}
prop_view_current :: (Eq sid, Eq i) => StackSet i l a sid sd -> i -> Bool
prop_view_current x i
  | i `tagMember` x = tag (workspace $ current (view i x)) == i
  | otherwise       = True

{-@ prop_view_local :: (Eq s, Eq i, Ord a) => StackSet i l a sid sd -> i -> Valid @-}
prop_view_local :: (Eq sid, Eq i, Ord a) => StackSet i l a sid sd -> i -> Bool

prop_view_local x i
  | i `tagMember` x = x =~= (view i x)
  | otherwise       = True

{-@ prop_view_idem :: (Eq s, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Valid @-}
prop_view_idem :: (Eq sid, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Bool
prop_view_idem x i
  | i `tagMember` x = let v = view i x in view i v == v
  | otherwise       = True

{-@ prop_view_reversible :: (Eq s, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Valid @-}
prop_view_reversible :: (Eq sid, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Bool
prop_view_reversible x i
  | i `tagMember` x = let v1 = view i x in
                      let v2 = view n v1 in v2 =~= x
  | otherwise       = True
  where n = currentTag x

-- greedyViewing workspaces

{-@ prop_greedyView_current :: (Eq s, Eq i) => StackSet i l a sid sd -> i -> Valid @-}
prop_greedyView_current :: (Eq sid, Eq i) => StackSet i l a sid sd -> i -> Bool
prop_greedyView_current x i
  | i `tagMember` x = tag (workspace $ current (greedyView i x)) == i
  | otherwise       = True

{-@ prop_greedyView_current_id :: (Eq s, Eq i) => StackSet i l a sid sd -> i -> Valid @-}
prop_greedyView_current_id :: (Eq sid, Eq i) => StackSet i l a sid sd -> i -> Bool
prop_greedyView_current_id x i
  | not (i `tagMember` x) = tag (workspace $ current (greedyView i x)) == (currentTag x)
  | otherwise             = True

{-@ prop_greedyView_local :: (Eq s, Eq i, Ord a) => StackSet i l a sid sd -> i -> Valid @-}
prop_greedyView_local :: (Eq sid, Eq i, Ord a) => StackSet i l a sid sd -> i -> Bool

prop_greedyView_local x i
  | i `tagMember` x = x =~= (greedyView i x)
  | otherwise       = True

{-@ prop_greedyView_idem :: (Eq s, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Valid @-}
prop_greedyView_idem :: (Eq sid, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Bool
prop_greedyView_idem x i
  | i `tagMember` x = let v = greedyView i x in greedyView i v == v
  | otherwise       = True

{-@ prop_greedyView_reversible :: (Eq s, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Valid @-}
prop_greedyView_reversible :: (Eq sid, Eq sd, Eq l, Eq i, Ord a) => StackSet i l a sid sd -> i -> Bool
prop_greedyView_reversible x i
  | i `tagMember` x = let v1 = greedyView i x in
                      let v2 = greedyView n v1 in v2 =~= x
  | otherwise       = True
  where n = currentTag x




-- HELPERS


{-@ (=~=) :: (Ord a) => x:StackSet i l a sid sd -> y:StackSet i l a sid sd -> {v:Bool | ((Prop v) <=> ((stackSetElts x) = (stackSetElts y)))} @-}
(=~=) :: Ord a => StackSet i l a sid sd -> StackSet i l a sid sd -> Bool
s1 =~= s2 = (stackSetElts s1) == (stackSetElts s2)

{-@ stackSetElts :: (Ord a) => x:StackSet i l a sid sd -> {v:Data.Set.Set a | v = (stackSetElts x)} @-}
stackSetElts :: Ord a => StackSet i l a sid sd -> Data.Set.Set a
stackSetElts (StackSet c v h _)
  = screenElts c `Data.Set.union` screensElts v `Data.Set.union` workspacesElts h

{-@ measure stackSetElts :: (StackSet i l a sid sd) -> (Data.Set.Set a)
    stackSetElts (StackSet c v h l) = (Set_cup (screenElts c) (Set_cup (screensElts v) (workspacesElts h)))
  @-}

{-@ screenElts :: (Ord a) => x:Screen i l a sid sd -> {v:Data.Set.Set a | v = (screenElts x)} @-}
screenElts :: Ord a => Screen i l a sid sd -> Data.Set.Set a
screenElts (Screen w _ _) = workspaceElts w

{-@ screensElts :: (Ord a) => x:[Screen i l a sid sd] -> {v:Data.Set.Set a | v = (screensElts x)} @-}
screensElts :: Ord a => [Screen i l a sid sd] -> Data.Set.Set a
screensElts (x:xs) = screenElts x `Data.Set.union` screensElts xs
screensElts []     = Data.Set.empty


{-@ workspaceElts :: (Ord a) => x:Workspace i l a -> {v:Data.Set.Set a | v = (workspaceElts x)} @-}
workspaceElts :: Ord a => Workspace i l a -> Data.Set.Set a
workspaceElts (Workspace _ _ Nothing)  = Data.Set.empty
workspaceElts (Workspace _ _ (Just s)) = stackElts s

{-@ workspacesElts :: (Ord a) => x:[Workspace i l a] -> {v:Data.Set.Set a | v = (workspacesElts x)} @-}
workspacesElts :: Ord a => [Workspace i l a] -> Data.Set.Set a
workspacesElts (x:xs) = workspaceElts x `Data.Set.union` workspacesElts xs
workspacesElts []     = Data.Set.empty

{-@ stackElts :: (Ord a) => x:Stack a -> {v:Data.Set.Set a | v = (stackElts x)} @-}
stackElts :: Ord a => Stack a -> Data.Set.Set a
stackElts (Stack f u d) = Data.Set.fromList $ f:u++d



{-@ allIsNothingS :: [Screen <{\w -> (isNothing (lstack w))}> i l a sid sd] -> {v:Bool | (Prop v) } @-}
allIsNothingS :: [Screen i l a sid sd] -> Bool
allIsNothingS ((Screen (Workspace _ _ Nothing) _ _):xs) = allIsNothingS xs
allIsNothingS ((Screen (Workspace _ _ (Just _)) _ _):xs) = False
allIsNothingS []                          = True

{-@ allIsNothingW :: [{v:Workspace i l a|(isNothing (lstack v))}] -> {v:Bool | (Prop v) } @-}
allIsNothingW :: [Workspace i l a] -> Bool
allIsNothingW (Workspace _ _ Nothing :xs) = allIsNothingW xs
allIsNothingW (Workspace _ _ (Just _):xs) = False
allIsNothingW []                          = True

{-@ isNothing :: x:Maybe a -> {v:Bool | ((Prop v) <=> (isNothing x)) } @-}
isNothing (Nothing) = True
isNothing (Just _)  = False