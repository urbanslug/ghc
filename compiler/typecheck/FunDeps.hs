{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 2000


FunDeps - functional dependencies

It's better to read it as: "if we know these, then we're going to know these"
-}

{-# LANGUAGE CPP #-}

module FunDeps (
        FunDepEqn(..), pprEquation,
        improveFromInstEnv, improveFromAnother,
        checkInstCoverage, checkFunDeps,
        pprFundeps
    ) where

#include "HsVersions.h"

import Name
import Var
import Class
import Type
import TcType( immSuperClasses )
import Unify
import InstEnv
import VarSet
import VarEnv
import Outputable
import ErrUtils( Validity(..), allValid )
import SrcLoc
import Util
import FastString

import Pair             ( Pair(..) )
import Data.List        ( nubBy )
import Data.Maybe       ( isJust )

{-
************************************************************************
*                                                                      *
\subsection{Generate equations from functional dependencies}
*                                                                      *
************************************************************************


Each functional dependency with one variable in the RHS is responsible
for generating a single equality. For instance:
     class C a b | a -> b
The constraints ([Wanted] C Int Bool) and [Wanted] C Int alpha
will generate the folloing FunDepEqn
     FDEqn { fd_qtvs = []
           , fd_eqs  = [Pair Bool alpha]
           , fd_pred1 = C Int Bool
           , fd_pred2 = C Int alpha
           , fd_loc = ... }
However notice that a functional dependency may have more than one variable
in the RHS which will create more than one pair of types in fd_eqs. Example:
     class C a b c | a -> b c
     [Wanted] C Int alpha alpha
     [Wanted] C Int Bool beta
Will generate:
     FDEqn { fd_qtvs = []
           , fd_eqs  = [Pair Bool alpha, Pair alpha beta]
           , fd_pred1 = C Int Bool
           , fd_pred2 = C Int alpha
           , fd_loc = ... }

INVARIANT: Corresponding types aren't already equal
That is, there exists at least one non-identity equality in FDEqs.

Assume:
       class C a b c | a -> b c
       instance C Int x x
And:   [Wanted] C Int Bool alpha
We will /match/ the LHS of fundep equations, producing a matching substitution
and create equations for the RHS sides. In our last example we'd have generated:
      ({x}, [fd1,fd2])
where
       fd1 = FDEq 1 Bool x
       fd2 = FDEq 2 alpha x
To ``execute'' the equation, make fresh type variable for each tyvar in the set,
instantiate the two types with these fresh variables, and then unify or generate
a new constraint. In the above example we would generate a new unification
variable 'beta' for x and produce the following constraints:
     [Wanted] (Bool ~ beta)
     [Wanted] (alpha ~ beta)

Notice the subtle difference between the above class declaration and:
       class C a b c | a -> b, a -> c
where we would generate:
      ({x},[fd1]),({x},[fd2])
This means that the template variable would be instantiated to different
unification variables when producing the FD constraints.

Finally, the position parameters will help us rewrite the wanted constraint ``on the spot''
-}

data FunDepEqn loc
  = FDEqn { fd_qtvs :: [TyVar]   -- Instantiate these type and kind vars
                                 --   to fresh unification vars,
                                 -- Non-empty only for FunDepEqns arising from instance decls

          , fd_eqs  :: [Pair Type]  -- Make these pairs of types equal
          , fd_pred1 :: PredType    -- The FunDepEqn arose from 
          , fd_pred2 :: PredType    --  combining these two constraints 
          , fd_loc :: loc  }

{-
Given a bunch of predicates that must hold, such as

        C Int t1, C Int t2, C Bool t3, ?x::t4, ?x::t5

improve figures out what extra equations must hold.
For example, if we have

        class C a b | a->b where ...

then improve will return

        [(t1,t2), (t4,t5)]

NOTA BENE:

  * improve does not iterate.  It's possible that when we make
    t1=t2, for example, that will in turn trigger a new equation.
    This would happen if we also had
        C t1 t7, C t2 t8
    If t1=t2, we also get t7=t8.

    improve does *not* do this extra step.  It relies on the caller
    doing so.

  * The equations unify types that are not already equal.  So there
    is no effect iff the result of improve is empty
-}

instFD :: FunDep TyVar -> [TyVar] -> [Type] -> FunDep Type
-- (instFD fd tvs tys) returns fd instantiated with (tvs -> tys)
instFD (ls,rs) tvs tys
  = (map lookup ls, map lookup rs)
  where
    env       = zipVarEnv tvs tys
    lookup tv = lookupVarEnv_NF env tv

zipAndComputeFDEqs :: (Type -> Type -> Bool) -- Discard this FDEq if true
                   -> [Type] -> [Type]
                   -> [Pair Type]
-- Create a list of (Type,Type) pairs from two lists of types,
-- making sure that the types are not already equal
zipAndComputeFDEqs discard (ty1:tys1) (ty2:tys2)
 | discard ty1 ty2 = zipAndComputeFDEqs discard tys1 tys2
 | otherwise       = Pair ty1 ty2 : zipAndComputeFDEqs discard tys1 tys2
zipAndComputeFDEqs _ _ _ = []

-- Improve a class constraint from another class constraint
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
improveFromAnother :: loc
                   -> PredType -- Template item (usually given, or inert)
                   -> PredType -- Workitem [that can be improved]
                   -> [FunDepEqn loc]
-- Post: FDEqs always oriented from the other to the workitem
--       Equations have empty quantified variables
improveFromAnother loc pred1 pred2
  | Just (cls1, tys1) <- getClassPredTys_maybe pred1
  , Just (cls2, tys2) <- getClassPredTys_maybe pred2
  , tys1 `lengthAtLeast` 2 && cls1 == cls2
  = [ FDEqn { fd_qtvs = [], fd_eqs = eqs, fd_pred1 = pred1, fd_pred2 = pred2, fd_loc = loc }
    | let (cls_tvs, cls_fds) = classTvsFds cls1
    , fd <- cls_fds
    , let (ltys1, rs1) = instFD fd cls_tvs tys1
          (ltys2, rs2) = instFD fd cls_tvs tys2
    , eqTypes ltys1 ltys2               -- The LHSs match
    , let eqs = zipAndComputeFDEqs eqType rs1 rs2
    , not (null eqs) ]

improveFromAnother _ _ _ = []


-- Improve a class constraint from instance declarations
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

pprEquation :: FunDepEqn a -> SDoc
pprEquation (FDEqn { fd_qtvs = qtvs, fd_eqs = pairs })
  = vcat [ptext (sLit "forall") <+> braces (pprWithCommas ppr qtvs),
          nest 2 (vcat [ ppr t1 <+> ptext (sLit "~") <+> ppr t2 
                       | Pair t1 t2 <- pairs])]

improveFromInstEnv :: InstEnvs
                   -> (PredType -> SrcSpan -> loc)
                   -> PredType
                   -> [FunDepEqn loc] -- Needs to be a FunDepEqn because
                                      -- of quantified variables
-- Post: Equations oriented from the template (matching instance) to the workitem!
improveFromInstEnv _inst_env _ pred
  | not (isClassPred pred)
  = panic "improveFromInstEnv: not a class predicate"
improveFromInstEnv inst_env mk_loc pred
  | Just (cls, tys) <- getClassPredTys_maybe pred
  , tys `lengthAtLeast` 2
  , let (cls_tvs, cls_fds) = classTvsFds cls
        instances          = classInstances inst_env cls
        rough_tcs          = roughMatchTcs tys
  = [ FDEqn { fd_qtvs = meta_tvs, fd_eqs = eqs
            , fd_pred1 = p_inst, fd_pred2 = pred
            , fd_loc = mk_loc p_inst (getSrcSpan (is_dfun ispec)) }
    | fd <- cls_fds             -- Iterate through the fundeps first,
                                -- because there often are none!
    , let trimmed_tcs = trimRoughMatchTcs cls_tvs fd rough_tcs
                -- Trim the rough_tcs based on the head of the fundep.
                -- Remember that instanceCantMatch treats both argumnents
                -- symmetrically, so it's ok to trim the rough_tcs,
                -- rather than trimming each inst_tcs in turn
    , ispec <- instances
    , (meta_tvs, eqs) <- checkClsFD fd cls_tvs ispec
                                    emptyVarSet tys trimmed_tcs -- NB: orientation
    , let p_inst = mkClassPred cls (is_tys ispec)
    ]
improveFromInstEnv _ _ _ = []


checkClsFD :: FunDep TyVar -> [TyVar]             -- One functional dependency from the class
           -> ClsInst                             -- An instance template
           -> TyVarSet -> [Type] -> [Maybe Name]  -- Arguments of this (C tys) predicate
                                                  -- TyVarSet are extra tyvars that can be instantiated
           -> [([TyVar], [Pair Type])]

checkClsFD fd clas_tvs
           (ClsInst { is_tvs = qtvs, is_tys = tys_inst, is_tcs = rough_tcs_inst })
           extra_qtvs tys_actual rough_tcs_actual

-- 'qtvs' are the quantified type variables, the ones which an be instantiated
-- to make the types match.  For example, given
--      class C a b | a->b where ...
--      instance C (Maybe x) (Tree x) where ..
--
-- and an Inst of form (C (Maybe t1) t2),
-- then we will call checkClsFD with
--
--      is_qtvs = {x}, is_tys = [Maybe x,  Tree x]
--                     tys_actual = [Maybe t1, t2]
--
-- We can instantiate x to t1, and then we want to force
--      (Tree x) [t1/x]  ~   t2
--
-- This function is also used when matching two Insts (rather than an Inst
-- against an instance decl. In that case, qtvs is empty, and we are doing
-- an equality check
--
-- This function is also used by InstEnv.badFunDeps, which needs to *unify*
-- For the one-sided matching case, the qtvs are just from the template,
-- so we get matching

  | instanceCantMatch rough_tcs_inst rough_tcs_actual
  = []          -- Filter out ones that can't possibly match,

  | otherwise
  = ASSERT2( length tys_inst == length tys_actual     &&
             length tys_inst == length clas_tvs
            , ppr tys_inst <+> ppr tys_actual )

    case tcUnifyTys bind_fn ltys1 ltys2 of
        Nothing  -> []
        Just subst | isJust (tcUnifyTys bind_fn rtys1' rtys2')
                        -- Don't include any equations that already hold.
                        -- Reason: then we know if any actual improvement has happened,
                        --         in which case we need to iterate the solver
                        -- In making this check we must taking account of the fact that any
                        -- qtvs that aren't already instantiated can be instantiated to anything
                        -- at all
                        -- NB: We can't do this 'is-useful-equation' check element-wise
                        --     because of:
                        --           class C a b c | a -> b c
                        --           instance C Int x x
                        --           [Wanted] C Int alpha Int
                        -- We would get that  x -> alpha  (isJust) and x -> Int (isJust)
                        -- so we would produce no FDs, which is clearly wrong.
                  -> []

                  | null fdeqs
                  -> []

                  | otherwise
                  -> [(meta_tvs, fdeqs)]
                        -- We could avoid this substTy stuff by producing the eqn
                        -- (qtvs, ls1++rs1, ls2++rs2)
                        -- which will re-do the ls1/ls2 unification when the equation is
                        -- executed.  What we're doing instead is recording the partial
                        -- work of the ls1/ls2 unification leaving a smaller unification problem
                  where
                    rtys1' = map (substTy subst) rtys1
                    rtys2' = map (substTy subst) rtys2

                    fdeqs = zipAndComputeFDEqs (\_ _ -> False) rtys1' rtys2'
                        -- Don't discard anything!
                        -- We could discard equal types but it's an overkill to call
                        -- eqType again, since we know for sure that /at least one/
                        -- equation in there is useful)

                    meta_tvs = [ setVarType tv (substTy subst (varType tv))
                               | tv <- qtvs, tv `notElemTvSubst` subst ]
                        -- meta_tvs are the quantified type variables
                        -- that have not been substituted out
                        --
                        -- Eg.  class C a b | a -> b
                        --      instance C Int [y]
                        -- Given constraint C Int z
                        -- we generate the equation
                        --      ({y}, [y], z)
                        --
                        -- But note (a) we get them from the dfun_id, so they are *in order*
                        --              because the kind variables may be mentioned in the
                        --              type variabes' kinds
                        --          (b) we must apply 'subst' to the kinds, in case we have
                        --              matched out a kind variable, but not a type variable
                        --              whose kind mentions that kind variable!
                        --          Trac #6015, #6068
  where
    qtv_set = mkVarSet qtvs
    bind_fn tv | tv `elemVarSet` qtv_set    = BindMe
               | tv `elemVarSet` extra_qtvs = BindMe
               | otherwise                  = Skolem

    (ltys1, rtys1) = instFD fd clas_tvs tys_inst
    (ltys2, rtys2) = instFD fd clas_tvs tys_actual

{-
************************************************************************
*                                                                      *
        The Coverage condition for instance declarations
*                                                                      *
************************************************************************

Note [Coverage condition]
~~~~~~~~~~~~~~~~~~~~~~~~~
Example
      class C a b | a -> b
      instance theta => C t1 t2

For the coverage condition, we check
   (normal)    fv(t2) `subset` fv(t1)
   (liberal)   fv(t2) `subset` oclose(fv(t1), theta)

The liberal version  ensures the self-consistency of the instance, but
it does not guarantee termination. Example:

   class Mul a b c | a b -> c where
        (.*.) :: a -> b -> c

   instance Mul Int Int Int where (.*.) = (*)
   instance Mul Int Float Float where x .*. y = fromIntegral x * y
   instance Mul a b c => Mul a [b] [c] where x .*. v = map (x.*.) v

In the third instance, it's not the case that fv([c]) `subset` fv(a,[b]).
But it is the case that fv([c]) `subset` oclose( theta, fv(a,[b]) )

But it is a mistake to accept the instance because then this defn:
        f = \ b x y -> if b then x .*. [y] else y
makes instance inference go into a loop, because it requires the constraint
        Mul a [b] b
-}

checkInstCoverage :: Bool   -- Be liberal
                  -> Class -> [PredType] -> [Type]
                  -> Validity
-- "be_liberal" flag says whether to use "liberal" coverage of
--              See Note [Coverage Condition] below
--
-- Return values
--    Nothing  => no problems
--    Just msg => coverage problem described by msg

checkInstCoverage be_liberal clas theta inst_taus
  = allValid (map fundep_ok fds)
  where
    (tyvars, fds) = classTvsFds clas
    fundep_ok fd
       | isEmptyVarSet undetermined_tvs = IsValid
       | otherwise                      = NotValid msg
       where
         (ls,rs) = instFD fd tyvars inst_taus
         ls_tvs = tyVarsOfTypes ls
         rs_tvs = tyVarsOfTypes rs

         undetermined_tvs | be_liberal = liberal_undet_tvs
                          | otherwise  = conserv_undet_tvs

         liberal_undet_tvs = rs_tvs `minusVarSet`oclose theta (closeOverKinds ls_tvs)
         conserv_undet_tvs = rs_tvs `minusVarSet` closeOverKinds ls_tvs
            -- closeOverKinds: see Note [Closing over kinds in coverage]

         undet_list = varSetElemsKvsFirst undetermined_tvs

         msg = vcat [ -- text "ls_tvs" <+> ppr ls_tvs
                      -- , text "closed ls_tvs" <+> ppr (closeOverKinds ls_tvs)
                      -- , text "theta" <+> ppr theta
                      -- , text "oclose" <+> ppr (oclose theta (closeOverKinds ls_tvs))
                      -- , text "rs_tvs" <+> ppr rs_tvs
                      sep [ ptext (sLit "The")
                            <+> ppWhen be_liberal (ptext (sLit "liberal"))
                            <+> ptext (sLit "coverage condition fails in class")
                            <+> quotes (ppr clas)
                          , nest 2 $ ptext (sLit "for functional dependency:")
                            <+> quotes (pprFunDep fd) ]
                    , sep [ ptext (sLit "Reason: lhs type")<>plural ls <+> pprQuotedList ls
                          , nest 2 $
                            (if isSingleton ls
                             then ptext (sLit "does not")
                             else ptext (sLit "do not jointly"))
                            <+> ptext (sLit "determine rhs type")<>plural rs
                            <+> pprQuotedList rs ]
                    , ptext (sLit "Un-determined variable") <> plural undet_list <> colon
                            <+> pprWithCommas ppr undet_list
                    , ppWhen (all isKindVar undet_list) $
                      ptext (sLit "(Use -fprint-explicit-kinds to see the kind variables in the types)")
                    , ppWhen (not be_liberal && isEmptyVarSet liberal_undet_tvs) $
                      ptext (sLit "Using UndecidableInstances might help") ]

{- Note [Closing over kinds in coverage]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have a fundep  (a::k) -> b
Then if 'a' is instantiated to (x y), where x:k2->*, y:k2,
then fixing x really fixes k2 as well, and so k2 should be added to
the lhs tyvars in the fundep check.

Example (Trac #8391), using liberal coverage
      data Foo a = ...  -- Foo :: forall k. k -> *
      class Bar a b | a -> b
      instance Bar a (Foo a)

    In the instance decl, (a:k) does fix (Foo k a), but only if we notice
    that (a:k) fixes k.  Trac #10109 is another example.

Here is a more subtle example, from HList-0.4.0.0 (Trac #10564)

  class HasFieldM (l :: k) r (v :: Maybe *)
        | l r -> v where ...
  class HasFieldM1 (b :: Maybe [*]) (l :: k) r v
        | b l r -> v where ...
  class HMemberM (e1 :: k) (l :: [k]) (r :: Maybe [k])
        | e1 l -> r

  data Label :: k -> *
  type family LabelsOf (a :: [*]) ::  *

  instance (HMemberM (Label {k} (l::k)) (LabelsOf xs) b,
            HasFieldM1 b l (r xs) v)
         => HasFieldM l (r xs) v where

Is the instance OK? Does {l,r,xs} determine v?  Well:

  * From the instance constraint HMemberM (Label k l) (LabelsOf xs) b,
    plus the fundep "| el l -> r" in class HMameberM,
    we get {l,k,xs} -> b

  * Note the 'k'!! We must call closeOverKinds on the seed set
    ls_tvs = {l,r,xs}, BEFORE doing oclose, else the {l,k,xs}->b
    fundep won't fire.  This was the reason for #10564.

  * So starting from seeds {l,r,xs,k} we do oclose to get
    first {l,r,xs,k,b}, via the HMemberM constraint, and then
    {l,r,xs,k,b,v}, via the HasFieldM1 constraint.

  * And that fixes v.

However, we must closeOverKinds whenever augmenting the seed set
in oclose!  Consider Trac #10109:

  data Succ a   -- Succ :: forall k. k -> *
  class Add (a :: k1) (b :: k2) (ab :: k3) | a b -> ab
  instance (Add a b ab) => Add (Succ {k1} (a :: k1))
                               b
                               (Succ {k3} (ab :: k3})

We start with seed set {a:k1,b:k2} and closeOverKinds to {a,k1,b,k2}.
Now use the fundep to extend to {a,k1,b,k2,ab}.  But we need to
closeOverKinds *again* now to {a,k1,b,k2,ab,k3}, so that we fix all
the variables free in (Succ {k3} ab).

Bottom line:
  * closeOverKinds on initial seeds (in checkInstCoverage)
  * and closeOverKinds whenever extending those seeds (in oclose)

Note [The liberal coverage condition]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(oclose preds tvs) closes the set of type variables tvs,
wrt functional dependencies in preds.  The result is a superset
of the argument set.  For example, if we have
        class C a b | a->b where ...
then
        oclose [C (x,y) z, C (x,p) q] {x,y} = {x,y,z}
because if we know x and y then that fixes z.

We also use equality predicates in the predicates; if we have an
assumption `t1 ~ t2`, then we use the fact that if we know `t1` we
also know `t2` and the other way.
  eg    oclose [C (x,y) z, a ~ x] {a,y} = {a,y,z,x}

oclose is used (only) when checking the coverage condition for
an instance declaration
-}

oclose :: [PredType] -> TyVarSet -> TyVarSet
-- See Note [The liberal coverage condition]
oclose preds fixed_tvs
  | null tv_fds = fixed_tvs -- Fast escape hatch for common case.
  | otherwise   = fixVarSet extend fixed_tvs
  where
    extend fixed_tvs = foldl add fixed_tvs tv_fds
       where
          add fixed_tvs (ls,rs)
            | ls `subVarSet` fixed_tvs = fixed_tvs `unionVarSet` closeOverKinds rs
            | otherwise                = fixed_tvs
            -- closeOverKinds: see Note [Closing over kinds in coverage]

    tv_fds  :: [(TyVarSet,TyVarSet)]
    tv_fds  = [ (tyVarsOfTypes ls, tyVarsOfTypes rs)
              | pred <- preds
              , (ls, rs) <- determined pred ]

    determined :: PredType -> [([Type],[Type])]
    determined pred
       = case classifyPredType pred of
            EqPred NomEq t1 t2 -> [([t1],[t2]), ([t2],[t1])]
            ClassPred cls tys -> local_fds ++ concatMap determined superclasses
              where
               local_fds = [ instFD fd cls_tvs tys
                           | fd <- cls_fds ]
               (cls_tvs, cls_fds) = classTvsFds cls
               superclasses = immSuperClasses cls tys
            _ -> []

{-
************************************************************************
*                                                                      *
        Check that a new instance decl is OK wrt fundeps
*                                                                      *
************************************************************************

Here is the bad case:
        class C a b | a->b where ...
        instance C Int Bool where ...
        instance C Int Char where ...

The point is that a->b, so Int in the first parameter must uniquely
determine the second.  In general, given the same class decl, and given

        instance C s1 s2 where ...
        instance C t1 t2 where ...

Then the criterion is: if U=unify(s1,t1) then U(s2) = U(t2).

Matters are a little more complicated if there are free variables in
the s2/t2.

        class D a b c | a -> b
        instance D a b => D [(a,a)] [b] Int
        instance D a b => D [a]     [b] Bool

The instance decls don't overlap, because the third parameter keeps
them separate.  But we want to make sure that given any constraint
        D s1 s2 s3
if s1 matches
-}

checkFunDeps :: InstEnvs -> ClsInst
             -> Maybe [ClsInst] -- Nothing  <=> ok
                                -- Just dfs <=> conflict with dfs
-- Check whether adding DFunId would break functional-dependency constraints
-- Used only for instance decls defined in the module being compiled
checkFunDeps inst_envs ispec
  | null bad_fundeps = Nothing
  | otherwise        = Just bad_fundeps
  where
    (ins_tvs, clas, ins_tys) = instanceHead ispec
    ins_tv_set   = mkVarSet ins_tvs
    cls_inst_env = classInstances inst_envs clas
    bad_fundeps  = badFunDeps cls_inst_env clas ins_tv_set ins_tys

badFunDeps :: [ClsInst] -> Class
           -> TyVarSet -> [Type]        -- Proposed new instance type
           -> [ClsInst]
badFunDeps cls_insts clas ins_tv_set ins_tys
  = nubBy eq_inst $
    [ ispec | fd <- fds,        -- fds is often empty, so do this first!
              let trimmed_tcs = trimRoughMatchTcs clas_tvs fd rough_tcs,
              ispec <- cls_insts,
              notNull (checkClsFD fd clas_tvs ispec ins_tv_set ins_tys trimmed_tcs)
    ]
  where
    (clas_tvs, fds) = classTvsFds clas
    rough_tcs = roughMatchTcs ins_tys
    eq_inst i1 i2 = instanceDFunId i1 == instanceDFunId i2
        -- An single instance may appear twice in the un-nubbed conflict list
        -- because it may conflict with more than one fundep.  E.g.
        --      class C a b c | a -> b, a -> c
        --      instance C Int Bool Bool
        --      instance C Int Char Char
        -- The second instance conflicts with the first by *both* fundeps

trimRoughMatchTcs :: [TyVar] -> FunDep TyVar -> [Maybe Name] -> [Maybe Name]
-- Computing rough_tcs for a particular fundep
--     class C a b c | a -> b where ...
-- For each instance .... => C ta tb tc
-- we want to match only on the type ta; so our
-- rough-match thing must similarly be filtered.
-- Hence, we Nothing-ise the tb and tc types right here
trimRoughMatchTcs clas_tvs (ltvs, _) mb_tcs
  = zipWith select clas_tvs mb_tcs
  where
    select clas_tv mb_tc | clas_tv `elem` ltvs = mb_tc
                         | otherwise           = Nothing
