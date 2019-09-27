{-
Authors: Andrei Paskevich (2001 - 2008), Steffen Frerix (2017 - 2018)

Verifier state monad and common functions.
-}

{-# LANGUAGE PolymorphicComponents #-}
{-# LANGUAGE FlexibleContexts #-}


module SAD.Core.Base (
  RState (..), CRM,
  askRS, updateRS,
  justIO,
  (<|>),
  runRM,

  retrieveContext,
  initialDefinitions, initialGuards,
  defForm, getDef,

  setFailed, checkFailed,
  unsetChecked, setChecked,

  VState (..), VM,

  Counter (..), TimeCounter (..), IntCounter (..),
  accumulateIntCounter, accumulateTimeCounter, maximalTimeCounter,
  showTimeDiff,
  timer,

  askInstructionInt, askInstructionBool, askInstructionString,
  addInstruction, dropInstruction,
  addTimeCounter, addIntCounter, incrementIntCounter,
  guardInstruction, guardNotInstruction, whenInstruction,

  reasonLog, simpLog, thesisLog, translateLog
) where

import Control.Monad
import Data.IORef
import Data.Time
import Control.Applicative
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Map as Map
import Control.Monad.State
import Control.Monad.Reader

import SAD.Data.Formula
import SAD.Data.TermId
import SAD.Data.Instr (Instr)
import SAD.Data.Instr
import SAD.Data.Text.Block (Block, Text)
import SAD.Data.Text.Context (Context, MRule(..))
import qualified SAD.Data.Text.Context as Context (name)
import SAD.Data.Definition (Definitions, DefEntry(DE), DefType(..), Guards)
import qualified SAD.Data.Definition as Definition
import SAD.Data.Rules (Rule)
import SAD.Data.Evaluation (Evaluation)
import SAD.Export.Base
import qualified SAD.Data.Structures.DisTree as DT
import SAD.Core.SourcePos
import qualified SAD.Core.Message as Message


-- | Reasoner state
data RState = RState 
  { counters       :: [Counter]
  , failed         :: Bool
  , alreadyChecked :: Bool
  } deriving (Eq, Ord, Show)


-- | All of these counters are for gathering statistics to print out later
data Counter  =
    TimeCounter TimeCounter NominalDiffTime
  | IntCounter IntCounter Int
  deriving (Eq, Ord, Show)

data TimeCounter  =
    ProofTime
  | SuccessTime  -- successful prove time
  | SimplifyTime
  deriving (Eq, Ord, Show)

data IntCounter  =
    Sections
  | Goals
  | FailedGoals
  | TrivialGoals
  | SuccessfulGoals
  | Symbols
  | TrivialChecks
  | HardChecks
  | SuccessfulChecks
  | Unfolds
  | Equations
  | FailedEquations
  deriving (Eq, Ord, Show)


-- | CPS IO Maybe monad
newtype CRM b = CRM 
  { runCRM :: forall a . IORef RState -> IO a -> (b -> IO a) -> IO a }

instance Functor CRM where
  fmap = liftM

instance Applicative CRM where
  pure = return
  (<*>) = ap

instance Monad CRM where
  return r  = CRM $ \ _ _ k -> k r
  m >>= n   = CRM $ \ s z k -> runCRM m s z (\ r -> runCRM (n r) s z k)

instance Alternative CRM where
  empty = mzero
  (<|>) = mplus

instance MonadPlus CRM where
  mzero     = CRM $ \ _ z _ -> z
  mplus m n = CRM $ \ s z k -> runCRM m s (runCRM n s z k) k


-- | @runCRM@ with defaults.
runRM :: CRM a -> IORef RState -> IO (Maybe a)
runRM m s = runCRM m s (return Nothing) (return . Just)

data VState = VS {
  thesisMotivated :: Bool,
  rewriteRules    :: [Rule],
  evaluations     :: DT.DisTree Evaluation, -- (low level) evaluation rules
  currentThesis   :: Context,
  currentBranch   :: [Block],         -- branch of the current block
  currentContext  :: [Context],
  mesonRules      :: (DT.DisTree MRule, DT.DisTree MRule),
  definitions     :: Definitions,
  guards          :: Guards, -- record which atomic formulas appear as guard
  skolemCounter   :: Int,
  instructions    :: [Instr],
  provers         :: [Prover],
  restText        :: [Text] }

type VM = ReaderT VState CRM

justRS :: VM (IORef RState)
justRS = lift $ CRM $ \ s _ k -> k s


justIO :: IO a -> VM a
justIO m = lift $ CRM $ \ _ _ k -> m >>= k

-- State management from inside the verification monad

askRS :: (RState -> b) -> ReaderT VState CRM b
askRS f     = justRS >>= (justIO . fmap f . readIORef)

updateRS :: (RState -> RState) -> ReaderT VState CRM ()
updateRS f  = justRS >>= (justIO . flip modifyIORef f)

askInstructionInt :: MonadReader VState f => Limit -> Int -> f Int
askInstructionInt instr _default =
  fmap (askLimit instr _default) $ asks instructions

askInstructionBool :: MonadReader VState f =>
                      Flag -> Bool -> f Bool
askInstructionBool instr _default =
  fmap (askFlag instr _default) $ asks instructions

askInstructionString :: MonadReader VState f =>
                        Argument -> String -> f String
askInstructionString instr _default =
  fmap (askArgument instr _default) $ asks instructions

addInstruction :: MonadReader VState m => Instr -> m a -> m a
addInstruction instr =
  local $ \vs -> vs { instructions = instr : instructions vs }

dropInstruction :: MonadReader VState m => Drop -> m a -> m a
dropInstruction instr =
  local $ \vs -> vs { instructions = dropInstr instr $ instructions vs }

addTimeCounter :: TimeCounter
                  -> NominalDiffTime -> ReaderT VState CRM ()
addTimeCounter counter time =
  updateRS $ \rs -> rs { counters = TimeCounter counter time : counters rs }

addIntCounter :: IntCounter -> Int -> ReaderT VState CRM ()
addIntCounter  counter time =
  updateRS $ \rs -> rs { counters = IntCounter  counter time : counters rs }

incrementIntCounter :: IntCounter -> ReaderT VState CRM ()
incrementIntCounter counter = addIntCounter counter 1

-- time proof tasks
timer :: TimeCounter
         -> ReaderT VState CRM b -> ReaderT VState CRM b
timer counter task = do
  begin  <- justIO $ getCurrentTime
  result <- task
  end    <- justIO $ getCurrentTime
  addTimeCounter counter $ diffUTCTime end begin
  return result

guardInstruction :: (MonadReader VState m, Alternative m) =>
                    Flag -> Bool -> m ()
guardInstruction instr _default =
  askInstructionBool instr _default >>= guard

guardNotInstruction :: (MonadReader VState m, Alternative m) =>
                       Flag -> Bool -> m ()
guardNotInstruction instr _default =
  askInstructionBool instr _default >>= guard . not

whenInstruction :: MonadReader VState m =>
                   Flag -> Bool -> m () -> m ()
whenInstruction instr _default action =
  askInstructionBool instr _default >>= \b -> when b action

-- explicit failure management

setFailed :: ReaderT VState CRM ()
setFailed = updateRS (\st -> st {failed = True})
checkFailed :: ReaderT VState CRM b
               -> ReaderT VState CRM b -> ReaderT VState CRM b
checkFailed alt1 alt2 = do
  failed <- askRS failed
  if failed then alt1 else alt2

-- local checking support

setChecked :: ReaderT VState CRM ()
setChecked = updateRS (\st -> st {alreadyChecked = True})
unsetChecked :: ReaderT VState CRM ()
unsetChecked = updateRS (\st -> st {alreadyChecked = False})

-- Counter management

fetchIntCounter :: [Counter] -> IntCounter -> [Int]
fetchIntCounter  counterList counter =
  [ value | IntCounter  kind value <- counterList, counter == kind ]
fetchTimeCounter :: [Counter] -> TimeCounter -> [NominalDiffTime]
fetchTimeCounter counterList counter =
  [ value | TimeCounter kind value <- counterList, counter == kind ]

accumulateIntCounter :: [Counter] -> Int -> IntCounter -> Int
accumulateIntCounter  counterList startValue =
  foldr (+) startValue . fetchIntCounter counterList
accumulateTimeCounter :: [Counter]
                         -> UTCTime -> TimeCounter -> UTCTime
accumulateTimeCounter counterList startValue =
  foldr addUTCTime startValue . fetchTimeCounter counterList
maximalTimeCounter :: [Counter] -> TimeCounter -> NominalDiffTime
maximalTimeCounter counterList = foldr max 0 . fetchTimeCounter counterList

showTimeDiff :: RealFrac a => a -> String
showTimeDiff t
  | hours == 0 =
      format minutes ++ ':' : format restSeconds ++ '.' : format restCentis
  | True    =
      format hours   ++ ':' : format restMinutes ++ ':' : format restSeconds
  where
    format n = if n < 10 then '0':show n else show n
    centiseconds = (truncate $ t * 100) :: Int
    (seconds, restCentis)  = divMod centiseconds 100
    (minutes, restSeconds) = divMod seconds 60
    (hours  , restMinutes) = divMod minutes 60


-- common messages

reasonLog :: Message.Kind -> SourcePos -> String -> VM ()
reasonLog kind pos = justIO . Message.outputReasoner kind pos

thesisLog :: Message.Kind -> SourcePos -> Int -> String -> VM ()
thesisLog kind pos indent msg =
  justIO (Message.outputThesis kind pos (replicate (3 * indent) ' ' ++ msg))

simpLog :: Message.Kind -> SourcePos -> String -> VM ()
simpLog kind pos = justIO . Message.outputSimplifier kind pos

translateLog :: Message.Kind -> SourcePos -> String -> VM ()
translateLog kind pos = justIO . Message.outputTranslate kind pos



retrieveContext :: Set.Set String -> ReaderT VState CRM [Context]
retrieveContext names = do
  globalContext <- asks currentContext
  let (context, unfoundSections) = runState (retrieve globalContext) names
  -- warn the user if some sections could not be found
  unless (Set.null unfoundSections) $
    reasonLog Message.WARNING noSourcePos $
      "Could not find sections " ++ unwords (map show $ Set.elems unfoundSections)
  return context
  where
    retrieve [] = return []
    retrieve (context:restContext) =
      let name = Context.name context in
        gets (Set.member name) >>= \p ->
          if p
          then modify (Set.delete name) >> fmap (context:) (retrieve restContext)
          else retrieve restContext




-- Definition management

-- initial definitions
initialDefinitions :: Definitions
initialDefinitions = Map.fromList [
  (EqualityId,  equality),
  (LessId,  less),
  (FunctionId,  function),
  (ApplicationId,  functionApplication),
  (DomainId,  domain),
  (SetId,  set),
  (ElementId,  elementOf),
  (PairId, pair) ]

equality :: DefEntry
equality  = DE [] Top Signature (zEqu (zVar "?0") (zVar "?1")) [] []
less :: DefEntry
less      = DE [] Top Signature (zLess (zVar "?0") (zVar "?1")) [] []
set :: DefEntry
set       = DE [] Top Signature (zSet $ zVar "?0") [] []
elementOf :: DefEntry
elementOf = DE [zSet $ zVar "?1"] Top Signature
  (zElem (zVar "?0") (zVar "?1")) [] [[zSet $ zVar "?1"]]
function :: DefEntry
function  = DE [] Top Signature (zFun $ zVar "?0") [] []
domain :: DefEntry
domain    = DE [zFun $ zVar "?0"] (zSet ThisT) Signature
  (zDom $ zVar "?0") [zSet ThisT] [[zFun $ zVar "?0"]]
pair :: DefEntry
pair      = DE [] Top Signature (zPair (zVar "?0") (zVar "?1")) [] []
functionApplication :: DefEntry
functionApplication =
  DE [zFun $ zVar "?0", zElem (zVar $ "?1") $ zDom $ zVar "?0"] Top Signature
    (zApp (zVar "?0") (zVar "?1")) []
    [[zFun $ zVar "?0"],[zElem (zVar $ "?1") $ zDom $ zVar "?0"]]


initialGuards :: DT.DisTree Bool
initialGuards = foldr (\f -> DT.insert f True) (DT.empty) [
  zSet $ zVar "?1",
  zFun $ zVar "?0",
  zElem (zVar $ "?1") $ zDom $ zVar "?0"]

-- retrieve definitional formula of a term
defForm :: Definitions -> Formula -> Maybe Formula
defForm definitions term = do
  def <- Map.lookup (trId term) definitions
  guard $ Definition.isDefinition def
  sb <- match (Definition.term def) term
  return $ sb $ Definition.formula def


-- retrieve definition of a symbol (monadic)
getDef :: Formula -> VM DefEntry
getDef term = do
  defs <- asks definitions
  let mbDef = Map.lookup (trId term) defs
  guard $ isJust mbDef
  return $ fromJust mbDef