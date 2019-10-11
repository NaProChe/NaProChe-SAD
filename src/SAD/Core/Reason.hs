{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018)

Reasoning methods and export to an external prover.
-}

{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module SAD.Core.Reason (
  reason,
  withGoal, withContext,
  proveThesis,
  reduceWithEvidence, trivialByEvidence,
  launchReasoning,
  thesis
  ) where
-- FIXME reconcept some functions so that this module does not need to export
--       the small fries anymore
import Control.Monad
import Data.Maybe
import System.Timeout
import Control.Exception
import Data.Monoid (Sum, getSum)
import qualified Control.Monad.Writer as W
import qualified Data.Set as Set
import qualified Data.Map as Map
import Control.Monad.State
import Control.Monad.Reader
import qualified Isabelle.Standard_Thread as Standard_Thread
import qualified Data.Text.Lazy as Text

import SAD.Core.SourcePos
import SAD.Data.VarName
import SAD.Core.Base
import qualified SAD.Core.Message as Message
import SAD.Data.Formula
import SAD.Data.Instr
import SAD.Data.Text.Context (Context(Context))
import qualified SAD.Data.Text.Context as Context
import SAD.Data.Text.Block (Section(..))
import qualified SAD.Data.Text.Block as Block
import SAD.Data.Definition (Definitions)
import qualified SAD.Data.Definition as Definition
import SAD.Data.Evaluation (Evaluation)
import qualified SAD.Data.Evaluation as Evaluation
import SAD.Export.Prover
import SAD.Prove.MESON
import qualified SAD.Data.Structures.DisTree as DT
import SAD.Data.Text.Decl

-- Reasoner

reason :: Context -> VM ()
reason tc = local (\st -> st {currentThesis = tc}) proveThesis

withGoal :: VM a -> Formula -> VM a
withGoal action goal = local (\vState ->
  vState { currentThesis = Context.setForm (currentThesis vState) goal}) action

withContext :: VM a -> [Context] -> VM a
withContext action context = local (\vState ->
  vState { currentContext = context }) action

thesis :: Monad a => ReaderT VState a Context
thesis = asks currentThesis


proveThesis :: VM ()
proveThesis = do
  reasoningDepth <- askInstructionInt Depthlimit 3;  guard $ reasoningDepth > 0
  asks currentContext >>= filterContext (splitGoal >>= sequenceGoals reasoningDepth 0)

sequenceGoals :: Int -> Int -> [Formula] -> VM ()
sequenceGoals reasoningDepth iteration (goal:restGoals) = do
  (trivial <|> proofByATP <|> reason) `withGoal` reducedGoal
  sequenceGoals reasoningDepth iteration restGoals
  where
    reducedGoal = reduceWithEvidence goal
    trivial = guard (isTop reducedGoal) >> updateTrivialStatistics
    proofByATP = launchProver iteration

    reason
      | reasoningDepth == 1 = depthExceedMessage >> mzero
      | otherwise = do
          newTask <- unfold
          let Context {Context.formula = Not newGoal} : newContext = newTask
          sequenceGoals (pred reasoningDepth) (succ iteration) [newGoal]
            `withContext` newContext

    depthExceedMessage =
      whenInstruction Printreason False $
        reasonLog Message.WARNING noSourcePos "reasoning depth exceeded"

    updateTrivialStatistics =
      unless (isTop goal) $ whenInstruction Printreason False $
         reasonLog Message.WRITELN noSourcePos ("trivial: " <> (Text.pack $ show goal))
      >> incrementIntCounter TrivialGoals

sequenceGoals  _ _ _ = return ()

splitGoal :: VM [Formula]
splitGoal = asks (normalizedSplit . strip . Context.formula . currentThesis)
  where
    normalizedSplit = split . albet
    split (All u f) = map (All u) (normalizedSplit f)
    split (And f g) = normalizedSplit f ++ normalizedSplit (Imp f g)
    split (Or f g)  = map (zOr f) (normalizedSplit g)
    split fr        = return fr


-- Call prover

launchProver :: Int -> VM ()
launchProver iteration = do
  reductionSetting <- askInstructionBool Ontored False
  whenInstruction Printfulltask False (printTask reductionSetting)
  proverList <- asks provers ; instrList <- asks instructions
  goal <- thesis; context <- asks currentContext
  let callATP = justIO $ pure $
        export reductionSetting iteration proverList instrList context goal
  callATP >>= timer ProofTime . justIO >>= guard
  res <- fmap head $ askRS counters
  case res of
    TimeCounter _ time -> do
      addTimeCounter SuccessTime time
      incrementIntCounter SuccessfulGoals
    _ -> error "No matching case in launchProver"
  where
    printTask reductionSetting = do
      let getFormula = if reductionSetting then Context.reducedFormula else Context.formula
      contextFormulas <- asks $ map getFormula . reverse . currentContext
      concl <- thesis
      reasonLog Message.WRITELN noSourcePos $ "prover task:\n" <>
        Text.concat (map (\form -> "  " <> Text.pack (show form) <> "\n") contextFormulas) <>
        "  |- " <> (Text.pack (show (Context.formula concl))) <> "\n"


launchReasoning :: VM ()
launchReasoning = do
  goal <- thesis; context <- asks currentContext
  skolemInt <- asks skolemCounter
  (mesonPos, mesonNeg) <- asks mesonRules
  let lowlevelContext = takeWhile Context.isLowLevel context
      proveGoal = prove skolemInt lowlevelContext mesonPos mesonNeg goal
      -- set timelimit to 10^4
      -- (usually not necessary as max proof depth is limited)
      callOwn = do
        Standard_Thread.expose_stopped
        timeout (1000) $ evaluate $ proveGoal
  justIO callOwn >>= guard . (==) (Just True)



-- Context filtering

{- if an explicit list of theorems is given, we set the asks context that
  plus all definitions/sigexts (as they usually import type information that
  is easily forgotten) and the low level context. Otherwise the whole
  context is selected. -}
filterContext :: VM a -> [Context] -> VM a
filterContext action context = do
  link <- asks (Set.fromList . Context.link . currentThesis);
  if Set.null link
    then action `withContext`
         (map replaceSignHead $ filter (not . isTop . Context.formula) context)
    else do
         linkedContext <- retrieveContext link
         action `withContext` (lowlevelContext ++ linkedContext ++ defsAndSigs)
  where
    (lowlevelContext, toplevelContext) = span Context.isLowLevel context
    defsAndSigs =
      let defOrSig c = (not . isTop . Context.reducedFormula $ c)
                    && (isDefinition c || isSignature c)
      in  map replaceHeadTerm $ filter defOrSig toplevelContext

isDefinition, isSignature :: Context -> Bool
isDefinition = (==) Definition . Block.kind . Context.head
isSignature  = (==) Signature  . Block.kind . Context.head

replaceHeadTerm :: Context -> Context
replaceHeadTerm c = Context.setForm c $ dive 0 $ Context.formula c
  where
    dive :: Int -> Formula -> Formula
    dive n (All _ (Imp (Tag HeadTerm Trm {trmName = "=", trmArgs = [_, t]}) f)) =
      subst t VarEmpty $ inst VarEmpty f
    dive n (All _ (Iff (Tag HeadTerm eq@Trm {trmName = "=", trmArgs = [_, t]}) f))
      = And (subst t VarEmpty $ inst VarEmpty f) (All (newDecl VarEmpty) $ Imp f eq)
    dive n (All _ (Imp (Tag HeadTerm Trm{}) Top)) = Top
    dive n (All v f) =
      bool $ All v $ bind (VarDefault $ Text.pack $ show n) $ dive (succ n) $ inst (VarDefault $ Text.pack $ show n) f
    dive n (Imp f g) = bool $ Imp f $ dive n g
    dive _ f = f

{- the mathematical function here is the same as replaceHeadTerm, but we save
some work by only diving into signature extensions and definitions-}
replaceSignHead :: Context -> Context
replaceSignHead c
  | isDefinition c || isSignature c = replaceHeadTerm c
  | otherwise = c


-- reduction by collected info

trivialByEvidence :: Formula -> Bool
trivialByEvidence f = isTop $ reduceWithEvidence f

reduceWithEvidence :: Formula -> Formula
reduceWithEvidence t@Trm{trmName = "="} = t -- leave equality untouched
reduceWithEvidence l | isLiteral l = -- try to reduce literals
  fromMaybe l $ msum $ map (lookFor l) (trmArgs $ ltAtomic l)
reduceWithEvidence f = bool $ mapF reduceWithEvidence $ bool f


{- lookFor the right evidence -}
lookFor :: Formula -> Formula -> Maybe Formula
lookFor _ Ind{} = Nothing -- bound variables have no evidence
lookFor literal (Tag _ t) = lookFor literal t -- ignore tags
lookFor literal t =
  let negatedLiteral = albet $ Not literal
  in  checkFor literal negatedLiteral $ trInfo t
  where
    checkFor literal negatedLiteral [] = Nothing
    checkFor literal negatedLiteral (atomic:rest)
      | ltTwins literal (replace t ThisT atomic)        = Just Top
      | ltTwins negatedLiteral (replace t ThisT atomic) = Just Bot
      | otherwise = checkFor literal negatedLiteral rest


-- unfolding of local properties

data UnfoldState = UF {
  defs             :: Definitions,
  evals            :: DT.DisTree Evaluation,
  unfoldSetting    :: Bool, -- user parameters that control what is unfolded
  unfoldSetSetting :: Bool }


-- FIXME the reader monad transformer used here is completely superfluous
unfold :: ReaderT VState CRM [Context]
unfold = do
  thesis <- asks currentThesis; context <- asks currentContext
  let task = Context.setForm thesis (Not $ Context.formula thesis) : context
  definitions <- asks definitions; evaluations <- asks evaluations
  generalUnfoldSetting <- askInstructionBool Unfold True
  lowlevelUnfoldSetting <- askInstructionBool Unfoldlow True
  generalSetUnfoldSetting <- askInstructionBool Unfoldsf True
  lowlevelSetUnfoldSetting <- askInstructionBool Unfoldlowsf False
  guard (generalUnfoldSetting || generalSetUnfoldSetting)
  let ((goal:toUnfold), topLevelContext) = span Context.isLowLevel task
      unfoldState = UF
        { defs = definitions
        , evals = evaluations
        , unfoldSetting = (generalUnfoldSetting    && lowlevelUnfoldSetting)
        , unfoldSetSetting = (generalSetUnfoldSetting && lowlevelSetUnfoldSetting) }
      (newLowLevelContext, numberOfUnfolds) =
        W.runWriter $ flip runReaderT unfoldState $
          liftM2 (:)
            (let localState st = st { -- unfold goal with general settings
                  unfoldSetting    = generalUnfoldSetting,
                  unfoldSetSetting = generalSetUnfoldSetting}
             in  local localState $ unfoldConservative goal)
            (mapM unfoldConservative toUnfold)
  unfoldLog newLowLevelContext
  when (numberOfUnfolds == 0) $ nothingToUnfold >> mzero
  addIntCounter Unfolds (getSum numberOfUnfolds)
  return $ newLowLevelContext ++ topLevelContext
  where
    nothingToUnfold =
      whenInstruction Printunfold False $ reasonLog Message.WRITELN noSourcePos "nothing to unfold"
    unfoldLog (goal:lowLevelContext) =
      whenInstruction Printunfold False $ reasonLog Message.WRITELN noSourcePos $ "unfold to:\n"
        <> Text.unlines (reverse $ map ((<>) "  " . Text.pack . show . Context.formula) lowLevelContext)
        <> "  |- " <> Text.pack (show (neg $ Context.formula goal))
    neg (Not f) = f; neg f = f


{- conservative unfolding of local properties -}
unfoldConservative :: Context -> ReaderT UnfoldState (W.Writer (Sum Int)) Context
unfoldConservative toUnfold
  | isDeclaration toUnfold = pure toUnfold
  | otherwise = fmap (Context.setForm toUnfold) $ fill [] (Just True) 0 $ Context.formula toUnfold
  where
    fill :: [Formula] -> Maybe Bool -> Int -> Formula -> ReaderT UnfoldState (W.Writer (Sum Int)) Formula
    fill localContext sign n f
      | hasDMK f = return f -- check if f has been unfolded already
      | isTrm f  =  fmap reduceWithEvidence $ unfoldAtomic (fromJust sign) f
    -- Iff is changed to double implication -> every position has a polarity
    fill localContext sign n (Iff f g) = fill localContext sign n $ zIff f g
    fill localContext sign n f = roundFM VarU fill localContext sign n f

    isDeclaration :: Context -> Bool
    isDeclaration = (==) LowDefinition . Block.kind . Context.head

{- unfold an atomic formula f occuring with polarity sign -}
unfoldAtomic :: (W.MonadWriter w m, MonadTrans t,
                 MonadReader UnfoldState (t m), Num w) =>
                Bool -> Formula -> t m Formula
unfoldAtomic sign f = do
  nbs <- localProperties f >>= return . foldr (if sign then And else Or ) marked
  subtermLocalProperties f >>= return . foldr (if sign then And else Imp) nbs
  where
    -- we mark the term so that it does not get
    -- unfolded again in subsequent iterations
    marked = Tag GenericMark f

    subtermLocalProperties (Tag GenericMark _) = return [] -- do not expand marked terms
    subtermLocalProperties h = foldFM termLocalProperties h
    termLocalProperties h =
      liftM2 (++) (subtermLocalProperties h) (localProperties h)
    localProperties (Tag GenericMark _) = return []
    localProperties Trm {trmName = "=", trmArgs = [l,r]} =
      liftM3 (\a b c -> a ++ b ++ c)
             (definitionalProperties l r)
             (definitionalProperties r l)
             (extensionalities l r)
  -- we combine definitional information for l, for r and if
  -- we have set equality we also throw in extensionality for sets and if
  -- we have functions we throw in function extensionality

    localProperties t
      | isApplication t || isElem t = setFunDefinitionalProperties t
      | otherwise = definitionalProperties t t

    -- return definitional property of f instantiated with g
    definitionalProperties f g = do
      definitions <- asks defs
      let definingFormula = maybeToList $ do
            id <- guard (isTrm f) >> pure (trmId f)
            def <- Map.lookup id definitions;
            -- only unfold a definitions or (a sigext in a positive position)
            guard (sign || Definition.isDefinition def)
            sb <- match (Definition.term def) f
            let definingFormula = replace (Tag GenericMark g) ThisT $ sb $ Definition.formula def
        -- substitute the (marked) term
            guard (not . isTop $ definingFormula)
            return definingFormula
      unfGuard unfoldSetting $
        unless (null definingFormula) (lift $ W.tell 1) >>
        return definingFormula
        -- increase the counter by 1 and return what we got

    extensionalities f g =
      let extensionalityFormula = -- set extensionality
            (guard (setType f && setType g) >> return (setExtensionality f g))
            `mplus`  -- function extensionality
            (guard (funType f && funType g) >> return (funExtensionality f g))
      in  lift (W.tell 1) >> return extensionalityFormula

    setExtensionality f g =
      let v = zVar VarEmpty in zAll VarEmpty $ Iff (zElem v f) (zElem v g)
    funExtensionality f g =
      let v = zVar VarEmpty
      in (domainEquality (zDom f) (zDom g)) `And`
         zAll VarEmpty (Imp (zElem v $ zDom f) $ zEqu (zApp f v) (zApp g v))

    -- depending on the sign we choose the more convenient form of set equality
    domainEquality =
      let v = zVar VarEmpty; sEqu x y = zAll VarEmpty (Iff (zElem v x) (zElem v y))
      in  if sign then zEqu else sEqu

    setFunDefinitionalProperties t = do
      evaluations <- asks evals
      let evaluationFormula = maybeToList $
            DT.lookup t evaluations >>= msum . map findev
      unfGuard unfoldSetSetting $
        unless (null evaluationFormula) (lift $ W.tell 1) >>
        return evaluationFormula
      where
        findev ev = do
          sb <- match (Evaluation.term ev) t
          guard (all trivialByEvidence $ map sb $ Evaluation.conditions ev)
          return $ replace (Tag GenericMark t) ThisT $ sb $
            if sign then Evaluation.positives ev else Evaluation.negatives ev

    unfGuard unfoldSetting action =
      asks unfoldSetting >>= \p -> if p then action else return []

hasDMK :: Formula -> Bool
hasDMK (Tag GenericMark _ ) = True
hasDMK _ = False

setType :: Formula -> Bool
setType Var {varInfo = info} = any (infoTwins ThisT $ zSet ThisT) info
setType Trm {trmInfo = info} = any (infoTwins ThisT $ zSet ThisT) info
setType _ = False

funType :: Formula -> Bool
funType Var {varInfo = info} = any (infoTwins ThisT $ zFun ThisT) info
funType Trm {trmInfo = info} = any (infoTwins ThisT $ zFun ThisT) info
funType _ = False
