module Vectorise.Utils.Base (
  voidType,
  newLocalVVar,

  mkDataConTagLit,
  mkDataConTag, dataConTagZ,
  mkBuiltinTyConApp,
  mkBuiltinTyConApps,
  mkWrapType,
  mkClosureTypes,
  mkPReprType,
  mkPArrayType, splitPrimTyCon,
  mkPArray,
  mkPDataType,  mkPDatasType,
  mkBuiltinCo,
  mkVScrut,

  pdataReprTyCon, pdataReprTyConExact, pdatasReprTyCon,
  pdataReprDataCon, pdatasReprDataCon,
  prDFunOfTyCon
) where

import Vectorise.Monad
import Vectorise.Vect
import Vectorise.Builtins

import CoreSyn
import CoreUtils
import Coercion
import Type
import TypeRep
import TyCon
import DataCon
import MkId
import Literal
import Outputable
import FastString
import ListSetOps

import Control.Monad (liftM)


-- Simple Types ---------------------------------------------------------------
voidType :: VM Type
voidType = mkBuiltinTyConApp voidTyCon []


-- Name Generation ------------------------------------------------------------
newLocalVVar :: FastString -> Type -> VM VVar
newLocalVVar fs vty
  = do
      lty <- mkPDataType vty
      vv  <- newLocalVar fs vty
      lv  <- newLocalVar fs lty
      return (vv,lv)


-- Constructors ---------------------------------------------------------------
mkDataConTagLit :: DataCon -> Literal
mkDataConTagLit = mkMachInt . toInteger . dataConTagZ


mkDataConTag :: DataCon -> CoreExpr
mkDataConTag = mkIntLitInt . dataConTagZ


dataConTagZ :: DataCon -> Int
dataConTagZ con = dataConTag con - fIRST_TAG


-- Type Construction ----------------------------------------------------------
-- | Make an application of a builtin type constructor to some arguments.
mkBuiltinTyConApp :: (Builtins -> TyCon) -> [Type] -> VM Type
mkBuiltinTyConApp get_tc tys
 = do tc     <- builtin get_tc
      return $ mkTyConApp tc tys


mkBuiltinTyConApps :: (Builtins -> TyCon) -> [Type] -> Type -> VM Type
mkBuiltinTyConApps get_tc tys ty
 = do tc     <- builtin get_tc
      return $ foldr (mk tc) ty tys
  where
    mk tc ty1 ty2 = mkTyConApp tc [ty1,ty2]


-- | Make an application of the 'Wrap' type constructor.
mkWrapType :: Type -> VM Type
mkWrapType ty  = mkBuiltinTyConApp wrapTyCon [ty]


-- | Make an application of the closure type constructor.
mkClosureTypes :: [Type] -> Type -> VM Type
mkClosureTypes = mkBuiltinTyConApps closureTyCon


-- | Make an application of the 'PRepr' type constructor.
mkPReprType :: Type -> VM Type
mkPReprType ty = mkBuiltinTyConApp preprTyCon [ty]


-- | Wrap a type into 'PArray', treating unboxed types specially.
mkPArrayType :: Type -> VM Type
mkPArrayType ty
  | Just tycon <- splitPrimTyCon ty
  = do { arr <- builtin (parray_PrimTyCon tycon)
       ; return $ mkTyConApp arr []
       }
mkPArrayType ty = mkBuiltinTyConApp parrayTyCon [ty]


-- | Make an appliction of the 'PData' tycon to some argument.
mkPDataType :: Type -> VM Type
mkPDataType ty  = mkBuiltinTyConApp pdataTyCon [ty]


-- | Make an application of the 'PDatas' tycon to some argument.
mkPDatasType :: Type -> VM Type
mkPDatasType ty = mkBuiltinTyConApp pdatasTyCon [ty]


-- |Checks if a type constructor is defined in 'GHC.Prim' (e.g., 'Int#'); if so, returns it.
splitPrimTyCon :: Type -> Maybe TyCon
splitPrimTyCon ty
  | Just (tycon, []) <- splitTyConApp_maybe ty
  , isPrimTyCon tycon
  = Just tycon
  | otherwise = Nothing



-- CoreExpr Construction ------------------------------------------------------
-- | Make an application of the 'PArray' data constructor.
mkPArray 
        :: Type         -- ^ Element type
        -> CoreExpr     -- ^ 'Int'   for the array length.
        -> CoreExpr     -- ^ 'PData' for the array data.
        -> VM CoreExpr

mkPArray ty len dat 
 = do   tc <- builtin parrayTyCon
        let [dc] = tyConDataCons tc
        return $ mkConApp dc [Type ty, len, dat]


-- Coercion Construction -----------------------------------------------------
-- | Make a coersion to some builtin type.
mkBuiltinCo :: (Builtins -> TyCon) -> VM Coercion
mkBuiltinCo get_tc
 = do tc     <- builtin get_tc
      return $ mkTyConAppCo tc []


-------------------------------------------------------------------------------

mkVScrut :: VExpr -> VM (CoreExpr, CoreExpr, TyCon, [Type])
mkVScrut (ve, le)
  = do
      (tc, arg_tys) <- pdataReprTyCon ty
      return (ve, unwrapFamInstScrut tc arg_tys le, tc, arg_tys)
  where
    ty = exprType ve

-- |Get the representation tycon of the 'PData' data family for a given type.
--
-- This tycon does not appear explicitly in the source program — see Note [PData TyCons] in
-- 'Vectorise.Generic.Description':
--
--   @pdataReprTyCon {Sum2} = {PDataSum2}@
--
-- The type for which we look up a 'PData' instance may be more specific than the type in the
-- instance declaration.  In that case the second component of the result will be more specific than
-- a set of distinct type variables.
-- 
pdataReprTyCon :: Type -> VM (TyCon, [Type])
pdataReprTyCon ty = builtin pdataTyCon >>= (`lookupFamInst` [ty])

-- |Get the representation tycon of the 'PData' data family for a given type which must match the
-- type index in the looked up 'PData' instance exactly.
--
pdataReprTyConExact :: Type -> VM TyCon
pdataReprTyConExact ty
  = do { (tycon, tys) <- pdataReprTyCon ty
       ; if uniqueTyVars tys
         then
           return tycon
         else
           cantVectorise "No exact 'PData' family instance for" (ppr ty)
       } 
  where
    uniqueTyVars tys = all isTyVarTy tys && hasNoDups (map extractTyVar tys)
      where
        extractTyVar (TyVarTy tv) = tv
        extractTyVar _            = panic "Vectorise.Utils.Base: extractTyVar"

pdataReprDataCon :: Type -> VM (DataCon, [Type])
pdataReprDataCon ty
  = do { (tc, arg_tys) <- pdataReprTyCon ty
       ; let [dc] = tyConDataCons tc
       ; return (dc, arg_tys)
       }

pdatasReprTyCon :: Type -> VM (TyCon, [Type])
pdatasReprTyCon ty = builtin pdatasTyCon >>= (`lookupFamInst` [ty])

pdatasReprDataCon :: Type -> VM (DataCon, [Type])
pdatasReprDataCon ty
  = do { (tc, arg_tys) <- pdatasReprTyCon ty
       ; let [dc] = tyConDataCons tc
       ; return (dc, arg_tys)
       }

prDFunOfTyCon :: TyCon -> VM CoreExpr
prDFunOfTyCon tycon
  = liftM Var
  . maybeCantVectoriseM "No PR dictionary for tycon" (ppr tycon)
  $ lookupTyConPR tycon
