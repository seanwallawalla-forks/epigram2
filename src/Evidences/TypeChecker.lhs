\section{Type-checker}
\label{sec:Evidences.TypeChecker}

%if False

> {-# OPTIONS_GHC -F -pgmF she #-}
> {-# LANGUAGE TypeOperators, GADTs, KindSignatures,
>     TypeSynonymInstances, FlexibleInstances, FlexibleContexts, PatternGuards #-}

> module Evidences.TypeChecker where

> import Prelude hiding (exp)

> import Control.Applicative
> import Control.Monad.Error

> import Data.Traversable

> import Kit.BwdFwd
> import Kit.MissingLibrary
> import Kit.NatFinVec

> import Evidences.Tm
> import Evidences.TmJig
> import Evidences.NameSupply

%endif


> canTy :: (Can, [EXP]) :>: Can -> Maybe VAL
> canTy ((Set, []) :>: Set)    = (| ONE |)
> canTy ((Set, []) :>: Pi)     = return $ ("S", SET) -** \ _S -> ARR _S SET *** ONE
> canTy ((Set, []) :>: Sigma)  = return $ ("S", SET) -** \ _S -> ARR _S SET *** ONE
> canTy ((Set, []) :>: One)    = (| ONE |)

> canTy ((Sigma, [_S, _T]) :>: Pair)  = return $ ("s", _S) -** \ s -> wr _T s *** ONE
> canTy ((One, []) :>: Zero)          = (| ONE |)
> canTy _ = (|)

It's just possible that variable-management should be baked into a monad,
here.

> chev :: Int -> TY :>: (Env {Z, n}, Tm {Body, s, n}) -> Maybe VAL
> chev l prob@(_ :>: (g, t)) = do
>   chk l prob
>   return (ev (g :/ t))

> chk :: Int -> TY :>: (Env {Z, n}, Tm {Body, s, n}) -> Maybe ()
> chk l (_T :>: (g, c :- es)) = case ev _T of
>   _C :- as -> do
>     _Ts <- canTy ((_C, as) :>: c)
>     chks l (_Ts :>: (g, es))
>   _ -> (|)
> chk l (_T :>: (g, L g' x b)) = case ev _T of
>   PI _S _T -> chk (l + 1) (_T $$ x' :>: (g <+< g' <:< x', b)) where
>     x' = P (l, x, _S) :$ B0
>   _ -> (|)

> chks :: Int -> VAL :>: (Env {Z, n}, [Tm {Body, s, n}]) -> Maybe ()
> chks l (ONE           :>:  (g, []))     = (|()|)
> chks l (SIGMA _S _T   :>:  (g, s : t))  = do
>   s' <- chev l (_S :>: (g, s))
>   chks l (ev (_T $$ s') :>: (g, t))
> chks _ _ = (|)






