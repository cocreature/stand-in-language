{-# LANGUAGE DeriveFunctor #-}
module SIL where

import Control.Monad.Fix
import Control.Monad.State.Lazy
import Data.Char
import Data.Map (Map)
import Data.Set (Set)
import Data.Functor.Identity
import Debug.Trace
import qualified Data.Map as Map
import qualified Data.Set as Set

data IExpr
  = Zero                     -- no special syntax necessary
  | Pair !IExpr !IExpr       -- {,}
  | Var !IExpr               -- identifier
  | App !IExpr !IExpr        --
  | Anno !IExpr !IExpr       -- :
  | ITE !IExpr !IExpr !IExpr -- if a then b else c
  | PLeft !IExpr             -- left
  | PRight !IExpr            -- right
  | Trace !IExpr             -- trace
  | Closure !IExpr !IExpr
  deriving (Eq, Show, Ord)

data IExprA a
  = ZeroA
  | PairA (IExprA a) (IExprA a)
  | VarA (IExprA a) a
  | AppA (IExprA a) (IExprA a) a
  | AnnoA (IExprA a) IExpr
  | ITEA (IExprA a) (IExprA a) (IExprA a)
  | PLeftA (IExprA a)
  | PRightA (IExprA a)
  | TraceA (IExprA a)
  | LamA (IExprA a) a
  | ClosureA (IExprA a) (IExprA a) a
  deriving (Eq, Show, Ord, Functor)

lam :: IExpr -> IExpr
lam x = Closure x Zero

getPartialAnnotation :: IExprA PartialType -> PartialType
getPartialAnnotation (VarA _ a) = a
getPartialAnnotation (AppA _ _ a) = a
getPartialAnnotation (LamA _ a) = a
getPartialAnnotation (ClosureA _ _ a) = a
getPartialAnnotation ZeroA = ZeroTypeP
getPartialAnnotation (PairA _ _) = ZeroTypeP
getPartialAnnotation (AnnoA x _) = getPartialAnnotation x
getPartialAnnotation (ITEA _ t _) = getPartialAnnotation t
getPartialAnnotation (PLeftA _) = ZeroTypeP
getPartialAnnotation (PRightA _) = ZeroTypeP
getPartialAnnotation (TraceA x) = getPartialAnnotation x

data DataType
  = ZeroType
  | ArrType DataType DataType
  deriving (Eq, Show, Ord)

packType :: DataType -> IExpr
packType ZeroType = Zero
packType (ArrType a b) = Pair (packType a) (packType b)

unpackType :: IExpr -> Maybe DataType
unpackType Zero = pure ZeroType
unpackType (Pair a b) = ArrType <$> unpackType a <*> unpackType b
unpackType _ = Nothing

unpackPartialType :: IExpr -> Maybe PartialType
unpackPartialType Zero = pure ZeroTypeP
unpackPartialType (Pair a b) = ArrTypeP <$> unpackPartialType a <*> unpackPartialType b
unpackPartialType _ = Nothing

data PartialType
  = ZeroTypeP
  | TypeVariable Int
  | ArrTypeP PartialType PartialType
  deriving (Eq, Show, Ord)

toPartial :: DataType -> PartialType
toPartial ZeroType = ZeroTypeP
toPartial (ArrType a b) = ArrTypeP (toPartial a) (toPartial b)

badType = TypeVariable (-1)

newtype PrettyIExpr = PrettyIExpr IExpr

instance Show PrettyIExpr where
  show (PrettyIExpr iexpr) = case iexpr of
    p@(Pair a b) -> if isNum p
      then show $ g2i p
      else concat ["{", show (PrettyIExpr a), ",", show (PrettyIExpr b), "}"]
    Zero -> "0"
    x -> show x

g2i :: IExpr -> Int
g2i Zero = 0
g2i (Pair a b) = 1 + (g2i a) + (g2i b)
g2i x = error $ "g2i " ++ (show x)

i2g :: Int -> IExpr
i2g 0 = Zero
i2g n = Pair (i2g (n - 1)) Zero

ints2g :: [Int] -> IExpr
ints2g = foldr (\i g -> Pair (i2g i) g) Zero

g2Ints :: IExpr -> [Int]
g2Ints Zero = []
g2Ints (Pair n g) = g2i n : g2Ints g
g2Ints x = error $ "g2Ints " ++ show x

s2g :: String -> IExpr
s2g = ints2g . map ord

g2s :: IExpr -> String
g2s = map chr . g2Ints

-- convention is numbers are left-nested pairs with zero on right
isNum :: IExpr -> Bool
isNum Zero = True
isNum (Pair n Zero) = isNum n
isNum _ = False

lookupTypeEnv :: [a] -> Int -> Maybe a
lookupTypeEnv env ind = if ind < length env then Just (env !! ind) else Nothing

-- State is closure environment, map of unresolved types, unresolved type id supply
type AnnotateState a = State ([PartialType], Map Int PartialType, Int) a

freshVar :: AnnotateState PartialType
freshVar = state $ \(env, typeMap, v) ->
  (TypeVariable v, (TypeVariable v : env, typeMap, v + 1))

popEnvironment :: AnnotateState ()
popEnvironment = state $ \(env, typeMap, v) -> ((), (tail env, typeMap, v))

checkOrAssociate :: PartialType -> PartialType -> Set Int -> Map Int PartialType
  -> Maybe (Map Int PartialType)
checkOrAssociate t _ _ _ | t == badType = Nothing
checkOrAssociate _ t _ _ | t == badType = Nothing
-- do nothing for circular (already resolved) references
checkOrAssociate (TypeVariable t) _ resolvedSet _ | Set.member t resolvedSet = Nothing
checkOrAssociate _ (TypeVariable t) resolvedSet _ | Set.member t resolvedSet = Nothing
checkOrAssociate (TypeVariable ta) (TypeVariable tb) resolvedSet typeMap =
  case (Map.lookup ta typeMap, Map.lookup tb typeMap) of
    (Just ra, Just rb) ->
      checkOrAssociate ra rb (Set.insert ta (Set.insert tb resolvedSet)) typeMap
    (Just ra, Nothing) ->
      checkOrAssociate (TypeVariable tb) ra (Set.insert ta resolvedSet) typeMap
    (Nothing, Just rb) ->
      checkOrAssociate (TypeVariable ta) rb (Set.insert tb resolvedSet) typeMap
    (Nothing, Nothing) -> pure $ Map.insert ta (TypeVariable tb) typeMap
checkOrAssociate (TypeVariable t) x resolvedSet typeMap = case Map.lookup t typeMap of
  Nothing -> pure $ Map.insert t x typeMap
  Just rt -> checkOrAssociate x rt (Set.insert t resolvedSet) typeMap
checkOrAssociate x (TypeVariable t) resolvedSet typeMap = case Map.lookup t typeMap of
  Nothing -> pure $ Map.insert t x typeMap
  Just rt -> checkOrAssociate x rt (Set.insert t resolvedSet) typeMap
checkOrAssociate (ArrTypeP a b) (ArrTypeP c d) resolvedSet typeMap =
  checkOrAssociate a c resolvedSet typeMap >>= checkOrAssociate b d resolvedSet
checkOrAssociate a b _ typeMap = if a == b then pure typeMap else Nothing

associateVar :: PartialType -> PartialType -> AnnotateState ()
associateVar a b = state $ \(env, typeMap, v)
  -> case checkOrAssociate a b Set.empty typeMap of
       Just tm -> ((), (env, tm, v))
       Nothing -> ((), (env, typeMap, v))
{-
associateVar a b =
  let modMap :: (Map Int PartialType -> Map Int PartialType) -> AnnotateState ()
      modMap f = state $ \(env, typeMap, v) -> ((), (env, f typeMap, v))
  in case (a, b) of
    (TypeVariable _, TypeVariable _) -> modMap id -- do nothing
    (TypeVariable t, x) | t /= (-1) -> modMap $ Map.insert t x
    (x, TypeVariable t) | t /= (-1) -> modMap $ Map.insert t x
    (ArrTypeP a b, ArrTypeP c d) -> associateVar a c >> associateVar b d
    _ -> modMap id -- do nothing
  -}

-- convert a PartialType to a full type, aborting on circular references
fullyResolve_ :: Set Int -> Map Int PartialType -> PartialType -> Maybe DataType
fullyResolve_ _ _ ZeroTypeP = pure ZeroType
fullyResolve_ resolved typeMap (TypeVariable i) = if Set.member i resolved
  then Nothing
  else Map.lookup i typeMap >>= fullyResolve_ (Set.insert i resolved) typeMap
fullyResolve_ resolved typeMap (ArrTypeP a b) =
  ArrType <$> fullyResolve_ resolved typeMap a <*> fullyResolve_ resolved typeMap b

fullyResolve :: Map Int PartialType -> PartialType -> Maybe DataType
fullyResolve = fullyResolve_ Set.empty

annotate :: IExpr -> AnnotateState (IExprA PartialType)
annotate Zero = pure ZeroA
annotate (Pair a b) = PairA <$> annotate a <*> annotate b
annotate (Var v) = do
  (env, _, _) <- get
  va <- annotate v
  case lookupTypeEnv env $ g2i v of
    Nothing -> pure $ VarA va badType
    Just pt -> pure $ VarA va pt
annotate (Closure l Zero) = do
  v <- freshVar
  la <- annotate l
  popEnvironment
  pure $ LamA la (ArrTypeP v (getPartialAnnotation la))
annotate (Closure l x) = fail $ concat ["unexpected closure environment ", show x]
annotate (App g i) = do
  ga <- annotate g
  ia <- annotate i
  case (getPartialAnnotation ga, getPartialAnnotation ia) of
    (ZeroTypeP, _) -> pure $ AppA ga ia badType
    (TypeVariable fv, it) -> do
      (TypeVariable v) <- freshVar
      popEnvironment
      associateVar (TypeVariable fv) (ArrTypeP it (TypeVariable v))
      pure $ AppA ga ia (TypeVariable v)
    (ArrTypeP a b, c) -> do
      associateVar a c
      pure $ AppA ga ia b
{-
annotate (Anno g Zero) = do
  ga <- annotate g
  associateVar (getPartialAnnotation ga) ZeroTypeP
  pure $ AnnoA ga Zero
-}
annotate (Anno g t) = if fullCheck t ZeroType -- (\x -> AnnoA x t) <$> annotate g
  then do
  ga <- annotate g
  let et = pureEval t
  case unpackPartialType et of
    Nothing -> error "bad type signature eval"
    Just evt -> do
      associateVar (getPartialAnnotation ga) evt
      pure $ AnnoA ga et
  else (`AnnoA` t) <$> annotate g
annotate (ITE i t e) = ITEA <$> annotate i <*> annotate t <*> annotate e
annotate (PLeft x) = PLeftA <$> annotate x
annotate (PRight x) = PRightA <$> annotate x
annotate (Trace x) = TraceA <$> annotate x
annotate (Closure g c) = error "TODO - annotate"

evalTypeCheck :: IExpr -> IExpr -> Bool
evalTypeCheck g t = fullCheck t ZeroType && case unpackType (pureEval t) of
  Just tt -> fullCheck g tt
  Nothing -> False

checkType_ :: Map Int PartialType -> IExprA PartialType -> DataType -> Bool
checkType_ _ ZeroA ZeroType = True
checkType_ typeMap (PairA a b) ZeroType =
  checkType_ typeMap a ZeroType && checkType_ typeMap b ZeroType
checkType_ typeMap (VarA v a) t = case fullyResolve typeMap a of
  Nothing -> False
  Just t2 -> t == t2 && checkType_ typeMap v ZeroType
checkType_ typeMap (LamA l a) ct@(ArrType _ ot) =
  case checkOrAssociate a (toPartial ct) Set.empty typeMap of
    Nothing -> False
    Just t -> checkType_ t l ot
checkType_ typeMap (AppA g i a) t = fullyResolve typeMap a == Just t &&
  case fullyResolve typeMap (getPartialAnnotation i) of
    Nothing -> False
    Just it -> checkType_ typeMap i it && checkType_ typeMap g (ArrType it t)
{-
checkType_ typeMap (AnnoA g Zero) ZeroType = checkType_ typeMap g ZeroType
checkType_ typeMap (AnnoA g tg) t = fullCheck tg ZeroType
  && packType t == pureEval tg
  && checkType_ typeMap g t
-}
checkType_ typeMap (AnnoA g tg) t = packType t == tg && checkType_ typeMap g t
checkType_ typeMap (ITEA i t e) ty = checkType_ typeMap i ZeroType
  && checkType_ typeMap t ty
  && checkType_ typeMap e ty
checkType_ typeMap (PLeftA g) ZeroType = checkType_ typeMap g ZeroType
checkType_ typeMap (PRightA g) ZeroType = checkType_ typeMap g ZeroType
checkType_ typeMap (TraceA g) t = checkType_ typeMap g t
checkType_ typeMap (ClosureA g c a) t = error "TODO - checkType_"
checkType_ _ _ _ = error "unmatched rule"

fullCheck :: IExpr -> DataType -> Bool
fullCheck iexpr t =
  let (iexpra, (_, typeMap, _)) = runState (annotate iexpr) ([], Map.empty, 0)
      debugT = trace (concat ["iexpra:\n", show iexpra, "\ntypemap:\n", show typeMap])
  in checkType_ typeMap iexpra t

{-
-- types are give by IExpr. Zero represents Data and Pair represents Arrow
inferType :: [IExpr] -> IExpr -> Maybe IExpr
inferType _ Zero = Just Zero
inferType env (Pair a b) = do
  ta <- inferType env a
  tb <- inferType env b
  if ta == Zero && tb == Zero
    then pure Zero
    else Nothing -- can't have functions in pairs
inferType env (Var v) = lookupTypeEnv env $ g2i v
inferType env (App g i) = case inferType env g of
  Just (Pair l r) -> if checkType env i l then Just r else Nothing
  _ -> Nothing
inferType env (Anno g Zero) = if checkType env g Zero then Just Zero else Nothing
inferType env (Anno c t) = case pureEval (Anno t Zero) of -- Anno never checked, pointless?
  (Closure _ _) -> Nothing
  g -> if checkType env c g then Just g else Nothing
inferType env (ITE i t e) =
  let tt = inferType env t in if tt == inferType env e then tt else Nothing
inferType env (PLeft p) = inferType env p
inferType env (PRight p) = inferType env p
inferType env (Trace p) = inferType env p
inferType _ _ = Nothing

checkType :: [IExpr] -> IExpr -> IExpr -> Bool
checkType env (Lam c) (Pair l r) = checkType (l : env) c r
checkType env (App g i) t = case inferType env i of
  Just x -> checkType env g (Pair x t)
  Nothing -> inferType env (App g i) == Just t
checkType env x t = inferType env x == Just t
-}

lookupEnv :: IExpr -> Int -> Maybe IExpr
lookupEnv (Closure i _) 0 = Just i
lookupEnv (Closure _ c) n = lookupEnv c (n - 1)
lookupEnv _ _ = Nothing

{-
iEval :: Monad m => ([Result] -> IExpr -> m Result)
  -> [Result] -> IExpr -> m Result
-}
iEval f env g = let f' = f env in case g of
  Zero -> pure Zero
  Pair a b -> do
    na <- f' a
    nb <- f' b
    pure $ Pair na nb
  Var v -> case lookupEnv env $ g2i v of
    Nothing -> error $ "variable not found " ++ show v
    Just var -> pure var
  Anno c t -> f' c -- TODO typecheck
  App g cexp -> do --- given t, type {{a,t},{a,t}}
    ng <- f' g
    i <- f' cexp
    apply f ng i
  ITE c t e -> f' c >>= \g -> case g of
    Zero -> f' e
    _ -> f' t
  PLeft g -> f' g >>= \g -> case g of
    (Pair a _) -> pure a
    --x -> error $ "left on " ++ show x
    _ -> pure Zero
  PRight g -> f' g >>= \g -> case g of
    (Pair _ x) -> pure x
    _ -> pure Zero
  Trace g -> f' g >>= \g -> pure $ trace (show g) g
--  Lam c -> pure $ Closure c env
  Closure c Zero -> pure $ Closure c env
  Closure _ e -> fail $ concat ["unexpected closure with environment ", show e]

{-
apply :: Monad m => ([Result] -> IExpr -> m Result) -> Result -> Result -> m Result
-}
apply f (Closure g env) v = f (Closure v env) g
apply _ g _ = error $ "not a closure " ++ show g

toChurch :: Int -> IExpr
toChurch x =
  let inner 0 = Var Zero
      inner x = App (Var $ i2g 1) (inner (x - 1))
  in lam (lam (inner x))

simpleEval :: IExpr -> IO IExpr
simpleEval = fix iEval Zero

pureEval :: IExpr -> IExpr
pureEval g = runIdentity $ fix iEval Zero g

showPass :: Show a => IO a -> IO a
showPass a = a >>= print >> a

tEval :: IExpr -> IO IExpr
tEval = fix (\f e g -> showPass $ iEval f e g) Zero

typedEval :: IExpr -> (IExpr -> IO ()) -> IO ()
typedEval iexpr prettyPrint = if fullCheck iexpr ZeroType
  then do
    simpleEval iexpr >>= prettyPrint
  else putStrLn "failed typecheck"

debugEval :: IExpr -> IO ()
debugEval iexpr = if fullCheck iexpr ZeroType
  then do
    tEval iexpr >>= (print . PrettyIExpr)
  else putStrLn "failed typecheck"

fullEval i = typedEval i print

prettyEval i = typedEval i (print . PrettyIExpr)

evalLoop :: IExpr -> IO ()
evalLoop iexpr = if fullCheck iexpr (ArrType ZeroType ZeroType)
  then let mainLoop s = do
             result <- simpleEval $ App iexpr s
             case result of
               Zero -> putStrLn "aborted"
               (Pair disp newState) -> do
                 putStrLn . g2s $ disp
                 case newState of
                   Zero -> putStrLn "done"
                   _ -> do
                     inp <- s2g <$> getLine
                     mainLoop $ Pair inp newState
               r -> putStrLn $ concat ["runtime error, dumped ", show r]
       in mainLoop Zero
  else putStrLn "failed typecheck"
