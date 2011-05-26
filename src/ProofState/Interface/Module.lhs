\section{Modules in Proof Context}

%if False

> {-# OPTIONS_GHC -F -pgmF she #-}
> {-# LANGUAGE FlexibleInstances, TypeOperators, TypeSynonymInstances,
>              GADTs, RankNTypes #-}

> module ProofState.Interface.Module where

> import ShePrelude

> import Data.Foldable

> import Kit.BwdFwd
> import Kit.NatFinVec
> import Kit.MissingLibrary

> import ProofState.Structure.Developments

> import ProofState.Edition.ProofContext
> import ProofState.Edition.Scope
> import ProofState.Edition.ProofState
> import ProofState.Edition.GetSet
> import ProofState.Edition.Navigation

< import ProofState.Interface.Lifting

> import ProofState.Interface.ProofKit

> import Evidences.Tm
> import Evidences.NameSupply
> import Evidences.ErrorHandling

%endif


A module is a pretty dull thing: it is just a name and a
development. As far as I know, there are three usages of modules. The
first one is the one we are used to: introducing namespaces and
avoiding name clashes. This is mostly used at the programming
level. For making modules, we use |makeModule|.

> makeModule :: String -> ProofState Name
> makeModule s = do
>     nsupply <- getDevNSupply
>     lev <- getDevLev
>     let n = mkName nsupply s
>     -- Insert a new entry above, the empty module |s|
>     let dev = Dev {  devEntries       =  B0
>                   ,  devTip           =  Module 
>                   ,  devNSupply       =  freshNSpace nsupply s
>                   ,  devSuspendState  =  SuspendNone 
>                   ,  devLevelCount    =  lev }
>     putEntryAbove $ EModule  {  name   =  n 
>                              ,  dev    =  dev}
>     putDevNSupply $ freshen nsupply
>     return n


The second usage is more technical, and occurs exclusively in the
implementation (such as in tactics, for instance). It consists in
making a module, going in it, doing some constructions and analyses,
and at some stage wanting to say that this module is actually an open
definition of a certain type (a goal). Turning a module into a goal is
implemented by |moduleToGoal|. An instance of this pattern appears in
Section~\ref{subsec:Tactics.Elimination.analysis}.


> moduleToGoal :: EXP -> ProofState EXP
> moduleToGoal ty = do
>     chkPS (SET :>: ty)
>     CModule _ <- getCurrentEntry
>     putDevTip $ Unknown ty Waiting
>     (_, t) <- updateDefFromTip
>     return t
>  where 
>    boys :: Entries -> Bwd (Int, String, TY)
>    boys B0 = B0
>    boys (es :< EParam _ s t l) =  boys es :< (l, s, t)
>    boys (es :< _) =  boys es 


The last usage of modules is to mess around: introducing things in the
proof context to later, in one go, remove it all. One need to be
extremely careful with the removed objects: the risk of introducing
dangling references is high.


> draftModule :: String -> ProofState t -> ProofState t
> draftModule name draftyStuff = do
>     makeModule name
>     goIn
>     t <- draftyStuff
>     goOutBelow
>     mm <- removeEntryAbove
>     case mm of
>         Just (EModule _ _) -> return t
>         _ -> throwError' . err $ "draftModule: drafty " ++ name
>                                  ++ " did not end up in the right place!"

