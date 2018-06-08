module SIL where

import Data.Char

-- if classes were categories, this would be an EndoFunctor?
class EndoMapper a where
  endoMap :: (a -> a) -> a -> a

class EitherEndoMapper a where
  eitherEndoMap :: (a -> Either e a) -> a -> Either e a

class MonoidEndoFolder a where
  monoidFold :: Monoid m => (a -> m) -> a -> m

data IExpr
  = Zero                     -- no special syntax necessary
  | Pair !IExpr !IExpr       -- {,}
  | Env                      -- identifier
  | SetEnv !IExpr
  | Defer !IExpr
  | Twiddle !IExpr
  | Abort !IExpr
  | Gate !IExpr
  | PLeft !IExpr             -- left
  | PRight !IExpr            -- right
  | Trace !IExpr             -- trace
  deriving (Eq, Show, Ord)

data ExprA a
  = ZeroA a
  | PairA !(ExprA a) !(ExprA a) a
  | VarA a
  | SetEnvA !(ExprA a) a
  | DeferA !(ExprA a) a
  | TwiddleA !(ExprA a) a
  | AbortA !(ExprA a) a
  | GateA !(ExprA a) a
  | PLeftA !(ExprA a) a
  | PRightA !(ExprA a) a
  | TraceA !(ExprA a) a
  deriving (Eq, Ord, Show)

instance EndoMapper IExpr where
  endoMap f Zero = f Zero
  endoMap f (Pair a b) = f $ Pair (endoMap f a) (endoMap f b)
  endoMap f Env = f Env
  endoMap f (SetEnv x) = f $ SetEnv (endoMap f x)
  endoMap f (Defer x) = f $ Defer (endoMap f x)
  endoMap f (Twiddle x) = f $ Twiddle (endoMap f x)
  endoMap f (Abort x) = f $ Abort (endoMap f x)
  endoMap f (Gate g) = f $ Gate (endoMap f g)
  endoMap f (PLeft x) = f $ PLeft (endoMap f x)
  endoMap f (PRight x) = f $ PRight (endoMap f x)
  endoMap f (Trace x) = f $ Trace (endoMap f x)

instance EitherEndoMapper IExpr where
  eitherEndoMap f Zero = f Zero
  eitherEndoMap f (Pair a b) = (Pair <$> eitherEndoMap f a <*> eitherEndoMap f b) >>= f
  eitherEndoMap f Env = f Env
  eitherEndoMap f (SetEnv x) = (SetEnv <$> eitherEndoMap f x) >>= f
  eitherEndoMap f (Defer x) = (Defer <$> eitherEndoMap f x) >>= f
  eitherEndoMap f (Twiddle x) = (Twiddle <$> eitherEndoMap f x) >>= f
  eitherEndoMap f (Abort x) = (Abort <$> eitherEndoMap f x) >>= f
  eitherEndoMap f (Gate x) = (Gate <$> eitherEndoMap f x) >>= f
  eitherEndoMap f (PLeft x) = (PLeft <$> eitherEndoMap f x) >>= f
  eitherEndoMap f (PRight x) = (PRight <$> eitherEndoMap f x) >>= f
  eitherEndoMap f (Trace x) = (Trace <$> eitherEndoMap f x) >>= f

instance MonoidEndoFolder IExpr where
  monoidFold f Zero = f Zero
  monoidFold f (Pair a b) = mconcat [f (Pair a b), monoidFold f a, monoidFold f b]
  monoidFold f Env = f Env
  monoidFold f (SetEnv x) = mconcat [f (SetEnv x), monoidFold f x]
  monoidFold f (Defer x) = mconcat [f (Defer x), monoidFold f x]
  monoidFold f (Twiddle x) = mconcat [f (Twiddle x), monoidFold f x]
  monoidFold f (Abort x) = mconcat [f (Abort x), monoidFold f x]
  monoidFold f (Gate x) = mconcat [f (Gate x), monoidFold f x]
  monoidFold f (PLeft x) = mconcat [f (PLeft x), monoidFold f x]
  monoidFold f (PRight x) = mconcat [f (PRight x), monoidFold f x]
  monoidFold f (Trace x) = mconcat [f (Trace x), monoidFold f x]

zero :: IExpr
zero = Zero
pair :: IExpr -> IExpr -> IExpr
pair = Pair
var :: IExpr
var = Env
env :: IExpr
env = Env
twiddle :: IExpr -> IExpr
twiddle = Twiddle
app :: IExpr -> IExpr -> IExpr
app c i = setenv (twiddle (pair i c))
check :: IExpr -> IExpr -> IExpr
check c tc = setenv (pair (defer (ite
                                  (app (pleft env) (pright env))
                                  (Abort $ app (pleft env) (pright env))
                                  (pright env)
                          ))
                          (pair tc c)
                    )
gate :: IExpr -> IExpr
gate = Gate
pleft :: IExpr -> IExpr
pleft = PLeft
pright :: IExpr -> IExpr
pright = PRight
setenv :: IExpr -> IExpr
setenv = SetEnv
defer :: IExpr -> IExpr
defer = Defer
lam :: IExpr -> IExpr
lam x = pair (defer x) env
-- a form of lambda that does not pull in a surrounding environment
completeLam :: IExpr -> IExpr
completeLam x = pair (defer x) zero
ite :: IExpr -> IExpr -> IExpr -> IExpr
ite i t e = setenv (pair (gate i) (pair e t))
varN :: Int -> IExpr
varN n = pleft (iterate pright env !! n)

data DataType
  = ZeroType
  | ArrType DataType DataType
  | PairType DataType DataType -- only used when at least one side of a pair is not ZeroType
  deriving (Eq, Show, Ord)

newtype PrettyDataType = PrettyDataType DataType

showInternal at@(ArrType _ _) = concat ["(", show $ PrettyDataType at, ")"]
showInternal t = show . PrettyDataType $ t

instance Show PrettyDataType where
  show (PrettyDataType dt) = case dt of
    ZeroType -> "D"
    (ArrType a b) -> concat [showInternal a, " -> ", showInternal b]
    (PairType a b) ->
      concat ["{", show $ PrettyDataType a, ",", show $ PrettyDataType b, "}"]

data PartialType
  = ZeroTypeP
  | AnyType
  | TypeVariable Int
  | ArrTypeP PartialType PartialType
  | PairTypeP PartialType PartialType
  deriving (Eq, Show, Ord)

newtype PrettyPartialType = PrettyPartialType PartialType

showInternalP at@(ArrTypeP _ _) = concat ["(", show $ PrettyPartialType at, ")"]
showInternalP t = show . PrettyPartialType $ t

instance Show PrettyPartialType where
  show (PrettyPartialType dt) = case dt of
    ZeroTypeP -> "Z"
    AnyType -> "A"
    (ArrTypeP a b) -> concat [showInternalP a, " -> ", showInternalP b]
    (PairTypeP a b) ->
      concat ["{", show $ PrettyPartialType a, ",", show $ PrettyPartialType b, "}"]
    (TypeVariable (-1)) -> "badType"
    (TypeVariable x) -> 'v' : show x

instance EndoMapper DataType where
  endoMap f ZeroType = f ZeroType
  endoMap f (ArrType a b) = f $ ArrType (endoMap f a) (endoMap f b)
  endoMap f (PairType a b) = f $ PairType (endoMap f a) (endoMap f b)

instance EndoMapper PartialType where
  endoMap f ZeroTypeP = f ZeroTypeP
  endoMap f AnyType = f AnyType
  endoMap f (TypeVariable i) = f $ TypeVariable i
  endoMap f (ArrTypeP a b) = f $ ArrTypeP (endoMap f a) (endoMap f b)
  endoMap f (PairTypeP a b) = f $ PairTypeP (endoMap f a) (endoMap f b)

mergePairType :: DataType -> DataType
mergePairType = endoMap f where
  f (PairType ZeroType ZeroType) = ZeroType
  f x = x

mergePairTypeP :: PartialType -> PartialType
mergePairTypeP = endoMap f where
  f (PairTypeP ZeroTypeP ZeroTypeP) = ZeroTypeP
  f x = x

packType :: DataType -> IExpr
packType ZeroType = Zero
packType (ArrType a b) = Pair (packType a) (packType b)

unpackType :: IExpr -> Maybe DataType
unpackType Zero = pure ZeroType
unpackType (Pair a b) = ArrType <$> unpackType a <*> unpackType b
unpackType _ = Nothing

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
