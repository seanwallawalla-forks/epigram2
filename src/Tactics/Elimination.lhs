\section{Elimination with a Motive}

%if False

> {-# OPTIONS_GHC -F -pgmF she #-}
> {-# LANGUAGE TypeOperators, TypeSynonymInstances, GADTs #-}

> module Tactics.Elimination where

> import Control.Monad.Error
> import Cochon.Error

> import Control.Applicative
> import Data.Foldable hiding (sequence_)
> import Data.List
> import Data.Maybe
> import Data.Traversable

> import Kit.BwdFwd
> import Kit.MissingLibrary

> import NameSupply.NameSupply
> import NameSupply.NameSupplier

> import Evidences.Tm
> import Evidences.Rules hiding (simplify)

> import ProofState.ProofState
> import ProofState.ProofKit
> import ProofState.News
> import ProofState.Lifting

> import DisplayLang.DisplayTm
> import DisplayLang.Naming

> import Elaboration.Elaborator



%endif


Elimination with a motive works on a goal prepared \emph{by the user} in the
following form:

$$\Gamma, \Delta \vdash ? : T$$

Where $\Gamma$ are the external hypotheses, $\Delta$ the internal
hypotheses, and $T$ the goal to solve. The difference between external
and internal hypotheses is the following. External hypotheses scope
over the whole problem, that is the current goal and later
sub-goals. They are the ``same'' in all subgoals. On the other hand,
internal hypotheses are consumed by the eliminator, hence are
``different'' in all subgoals. Pragmatically, we want to apply the
eliminator under $\Gamma$, but over $\Delta$.

Note that we need a way to identify where to chunk the context into
its $\Gamma$ and $\Delta$ parts. One way to do that is to ask the user
to pass in the reference to the first term of $\Delta$ in the
context. If the user provides no reference, we will assume that
$\Gamma$ is empty, hence that the hypotheses are all internal:

< elim :: Maybe REF -> (...)

Obviously, we also need to be provided the eliminator we want to use. Again,
we expect the user to prepare the eliminator for us, in the same context:

$$\Gamma, \Delta \vdash e : (P : \Xi \rightarrow \Set) 
                            \rightarrow \vec{m} 
                            \rightarrow P \vec{t}$$

This eliminator, together with its type, is handled to the elimination
machinery in both term and value form. To reduce the boilerplate, we
use the following type synonym:

> type Eliminator = (INTM :=>: TY) :>: (INTM :=>: VAL)

And we will define |elim| this way:

< elim :: Maybe REF -> Eliminator -> ProofState ()
< elim comma eliminator = (...)




\subsection{Analyzing the eliminator}

Presented as a development, |elim| is called in the following context:

\begin{center}
\begin{minipage}{5cm}
\begin{alltt}
[ \((\Gamma)\) \(\rightarrow\) 
  \((\Delta)\) \(\rightarrow\)
] := ? : T
\end{alltt}
\end{minipage}
\end{center}

Where $\Gamma$ and $\Delta$ are introduced, and |T| is waiting to be
solved.

We have to analyze the eliminator we are given for two reasons. First,
we need to check that it \emph{is} an eliminator, that is:

\begin{itemize}

\item it has a motive, 

\item it has a bunch of methods, 

\item the target consists of the motive applied to some arguments

\end{itemize}

Second, we have to extract some vital piece of information from the
eliminator. Namely:

\begin{itemize} 

\item the type of the motive: $\Xi \rightarrow \Set$

\item the arguments applied to the motive: $\vec{t}$

\end{itemize}

To analyze the eliminator, we play a nice game. One option would be to
jump in a |draftModule|, introduce |lambdaBoys|, retrieve and
check the different parts as we go along. However, this means that the
terms we get are built from references which will become out of
context, hence invalid. Therefore, we suffer the burden (and danger)
of carrying renaming of those terms.

The way we actually go is the following. The trick consists in
re-building the eliminator in the current development:

\begin{center}
\begin{minipage}{6cm}
\begin{alltt}
[ \((\Gamma)\) \(\rightarrow\) 
  \((\Delta)\) \(\rightarrow\)
  makeE [   P := ? : \(\Xi \rightarrow Set\)
            \(m\sb{1}\) := ? : \(M\sb{1}\) P
            (...)  
            \(m\sb{n}\) := ? : \(M\sb{n}\) P
  ] := e P \(\vec{m}\) : P \(\vec{t}\)
] := ? : T
\end{alltt}
\end{minipage}
\end{center}

Therefore, we will build the motive \emph{in-place}, instead of
analyzing the eliminator \emph{and then} making the motive. Moreover,
we are able to safely check the shape of the eliminator as well as
extracting the interesting bits.

The development transformation is achieved by the following code:

> introElim :: Eliminator -> ProofState (TY, [INTM], Bwd (INTM :<: INTM))
> introElim (eType :=>: PI motiveType telType :>: e :=>: _) = do
>     motiveTypeTm <- bquoteHere motiveType
>     p :=>: pv <- make $ "P" :<: motiveTypeTm
>     -- Get the type of the methods and the target
>     (methods, returnType) <- mkMethods $ telType $$ (A pv)
>     -- Check the motive, and return type shape
>     checkMotive motiveType
>     checkReturnType (evTm returnType) motiveType (pv :<: motiveType)
>     -- Grab the terms which are applied to the motive (the targets)
>     targetTerms <- matchTargets returnType motiveType 
>     targets <- rightTargets (trail targetTerms) motiveType

>     -- targetTypes <- unfoldTelescope motiveType
>     -- let targets = zipBwd targetTerms (bwdList targetTypes) 

>     -- Close the problem (using the "made" subproblems!)
>     -- And go to the next subproblem, ie. making P
>     moduleToGoal returnType
>     giveNext $ N $ (e ?? eType) $## (N p : methods)
>     return (motiveType, methods, targets)
>   where
>     zipBwd :: Bwd INTM -> Bwd INTM -> Bwd (INTM :<: INTM)
>     zipBwd B0 B0 = B0
>     zipBwd (xs :< x) (ys :< y) = zipBwd xs ys :< (x :<: y) 
> introElim _ = throwError' $ err "Elimination: eliminator not a Pi-type??"


> rightTargets :: [INTM] -> TY -> ProofState (Bwd (INTM :<: INTM))
> rightTargets [] SET = return B0
> rightTargets (x:xs) (PI s t) = do
>     s' <- bquoteHere s
>     targets <- rightTargets xs (t $$ A (evTm x)) 
>     return $ targets :< (x :<: s')


Above, we have used |mkMethods| to introduce the methods and retrieve
the target of the eliminator. Remember that the eliminator is a
telescope of $\Pi$ types. To get the type of the motive, we have
matched the first component of the telescope. To get the methods, we
simply iterate that process, up to the point where all the $\Pi$s have
been consummed.

> mkMethods :: TY -> ProofState ([INTM], INTM)
> mkMethods = mkMethods' [] 
>     where mkMethods' :: [INTM] -> TY -> ProofState ([INTM], INTM)
>           mkMethods' ms t = 
>               case t of 
>                 PI s t -> do
>                     sTm <- bquoteHere s
>                     m :=>: mv <- make $ "m" :<: sTm
>                     mkMethods' (N m : ms) (t $$ A mv)
>                 target -> do
>                     targetTm <- bquoteHere target
>                     return (reverse ms, targetTm)

Another helper function has been |matchTargets|. We know that the return type
is the following term:

$$P \vec{t}$$

Hence, |matchTargets| is given the return type as well as the
telescope-type of |P|. It recursively unfolds the
telescope, accumulating the arguments of the motive along the
way. When reaching $\Set$, we have accumulated all arguments of |P|.

> matchTargets :: INTM -> VAL -> ProofState (Bwd INTM)
> matchTargets _ SET = return B0
> matchTargets (N (t :$ A x)) (PI s r) = 
>   freshRef ("s" :<: s) $ \y -> do
>       targets <- matchTargets (N t) (r $$ (A $ pval y))
>       return $ targets :< x
>       


\subsubsection{Checking the eliminator}

The calls to |checkMotive|, and |checkTarget| are here to ensure that
we are handed ``stuff'' which fits our technology. They are mostly dull
at the moment, because we only have nice users.

|checkMotive| consists in veryfing that the motive is of type:

$$P : \Xi \rightarrow Set$$

> checkMotive :: VAL -> ProofState ()
> checkMotive SET = return ()
> checkMotive (PI s t) =
>     freshRef ("s" :<: s) $ \x ->
>         checkMotive (t $$ (A $ pval x))
> checkMotive _ = throwError' $ err "elimination: your motive is suspicious"


On the other hand, |checkReturnType| consists in verifying that the return type
consists of the motive applied to some arguments.

> checkReturnType :: VAL -> VAL -> (VAL :<: VAL) -> ProofState ()
> checkReturnType returnType SET (motive :<: motiveType) = do
>      isEqual <- withNSupply $ equal (motiveType :>: (returnType, motive))
>      if isEqual 
>          then return ()
>          else throwError' $ err "elimination: return type is not using the motive?!"
> checkReturnType (N (f :$ A _)) (PI s t) (motive :<: motiveType) =
>     freshRef ("s" :<: s) $ \x ->
>         checkReturnType (N f) (t $$ (A $ pval x)) (motive :<: motiveType)
> checkReturnType _ _ _ = throwError' $ err "elimination: your target is suspicious"

\pierre{There are also some conditions on the variables that can be used in
these terms! I have to look that up too. This is a matter of traversing the
terms to collect the |REF|s in them and check that they are of the right
domains.}

\question{Can we combine and streamline matchPatterns with these?}


\subsection{Making the motive}

The |introElim| command have kindly generated a subgoal for the
motive. Doing that, it has also brought us to the subgoal consisting
of making |P|. That's a good thing because this is what we are going
to do.

First, remember the type of the motive:

$$P : \Xi \rightarrow \Set$$

So, we can introduce these lambdas straight away:

> introMotive :: ProofState [REF]
> introMotive = do
>     xis <- many $ lambdaBoy "xi"
>     return xis              



\subsubsection{Building the Motive: an overview}

Now the question is: what term are we supposed to build? To answer
that question, the best is still to read the Sanctified Papers
\cite{mcbride:motive, mcbride:pattern_matching}. If you can bear with
me, here is my strawman explanation.


\paragraph{First try: life's too short, the paper's too long.}


Remember that the eliminator will evaluate to the following term:

$$P \vec{t}$$

So, we could define $P$ as:

$$P \equiv \lambda (\Xi) . T$$


Which trivially solves the goal. However, we will have a hard time
making the methods! Indeed, we are asking to solve exactly the same
problem, with the same knowledge.


\paragraph{Second try: learning from the targets.}


We need to hand back some knowledge to the user in the methods. Where
could any knowledge come from? Well, we are sure of one thing: $(\Xi)$
will be instantiated to $\vec{t}$. So, we could define our motive as:

$$P \equiv \lambda (\Xi) . (\Xi) == \vec{t} \Rightarrow T$$

Hence, the methods will have some additional knowledge, presented as
constraints on the value that their arguments can take.


\paragraph{Third try: the problem with inductive eliminators.}


This definition would work for the ''non-inductive'' eliminators, that
is eliminators for which the method types are all of the following
form:

$$M P \equiv \Pi \Delta_S \rightarrow P \vec{s}$$

These eliminators are simply doing a case analysis, without refering
to an induction principle.

However, for ``inductive'' eliminators, this motive is too weak. An
eliminator will be inductive-ish if a method is using the motive
anywhere else than as a target. If this is the case, we would like to
be able to appeal to some induction principle: we need the freedom to
apply the motive in another context than the fixed context
$\Delta$. We can get this by abstracting $\Delta$ in $P$, without
forgetting to bring $\vec{t}$ and $T$ under this new context:

$$P \equiv \lambda (\Xi) . \Pi (\Delta') .
     (\Xi) == \vec{t}\ [\Delta'/\Delta] \Rightarrow T[\Delta'/\Delta]$$



\paragraph{Fourth try: being less parametric.}

However, there is a slight problem here. The motive and the methods
are very likely to be parameterized over $\Delta$. If we use the
motive above, we are asking for trouble in the definition of the
methods. Remember that a method typically looks like:

$$M P \equiv \Pi \Delta_S \rightarrow P \vec{s}$$

This will therefore compute to:

$$\Pi \Delta_S \Pi \Delta \Rightarrow
     \vec{s} == \vec{t}\ [\Delta'/\Delta] \Rightarrow 
     T[\Delta'/\Delta]$$

The effect is therefore that this type becomes more parametric than it
was before, for no good reason. Indeed, there is no way a method can
take advantage of this parametricity: it will be used as a boring
parameter (because it \emph{is} just a parameter).

So, we need to chunk $\Delta$ in two contexts:

\begin{itemize}

\item $\Delta_0$, containing terms involved in the type of the methods
and motive, and their respective dependencies; and

\item $\Delta_1$, containing the free terms

\end{itemize}

Instead of brutally abstracting over $\Delta$, we subtly abstract over
$\Delta_1$:

$$P \equiv \lambda (\Xi) . \Pi (\Delta_1') .
     (\Xi) == \vec{t}\ [\Delta_1'/\Delta_1] \Rightarrow T[\Delta_1'/\Delta_1]$$



\paragraph{Fifth try: simplifying equations.}

Although the previous version would be morally correct, the user will
appreciate if we simplify some trivial equations by directly
instantiating them. Our motto being ``the user is king'' (don't quote
me on that), let's simplify.

Hence, if we have $\xi_i : \Xi_i == t_i : T_i$ with $\Xi_i == T_i$ and
$t_i$ a term defined in the context $\Delta_1'$, then we can replace
$t_i$ by $\xi_i$ everywhere it appears, in the telescope and in the
goal. Having replaced $t_i$, we can remove the corresponding
abstraction in the telescope $\Pi (\Delta_1')$.

As one would expect, this process must be carried from the left to the
right, as equations might simplify further down the line. However,
there is a subtlety in that, when discovering a simplification, one
must also rename the previously discovered constraints, as they might
mention the simplified term.

\pierre{We are simplifying references here but we should do more. We
are making a (syntactic) distinction which is finer than what the
theory (semantically) describes. There is something in the pipe but I
don't understand it in the general case. Finishing that work will
consist in extending |matchRef| (defined later) with the relevant
cases.}

This concludes our overview. Now, we have to implement the last
proposal. That's not for the faint heart.


\subsubsection{Finding parametric hypotheses}

We have the internal context $\Delta$ lying around. We also have
access to the type of the eliminator, that is the type of the motive
and the methods. Therefore, we can already chunk $\Delta$ into its
parametric and non-parametric parts, $\Delta_0$ and $\Delta_1$. As we
are not interested in $\Delta_0$, we fearlessly throw it away.

We aim at implementing the following function:

< extractDelta1 :: Bwd REF -> TY -> ProofState [REF]
< extractDelta1 delta elimType = (...)

The dependencies needs to be extracted from terms, in |INTM|
form. However, we are only interested in the references appearing
inside them. To collect the references, we write the following helper
function:

> collectRefs :: INTM -> [REF]
> collectRefs r = foldMap (\x -> [x]) r

Hence, we simplify the problem by maintaining the dependencies as a
bag of |REF|s:

< extractDelta1' :: Bwd REF -> [REF] -> ProofState [REF]

Obviously, we get |extractDelta1| from there:

> extractDelta1 :: Bwd (REF :<: INTM) -> TY -> ProofState (Bwd (REF :<: INTM))
> extractDelta1 delta elimTy = do
>   argTypes <- unfoldTelescope elimTy
>   let deps = foldMap collectRefs argTypes
>   extractDelta1' delta deps

\begin{danger}

Note that we have been careful in asking for |elimTy| here, the type
of the eliminator. One could have thought of getting the type of the
motive and methods during |introElim|. That would not work: the motive
is defined under the scope of $\Delta$, hence lambda-lifted to
it. Then, the type of the methods are defined in term of the
motive. Hence, all $\Delta$ is innocently included into these types,
making them useless. 

The real solution is to go back to the type of the eliminator. We
unfold it with fresh references. Doing so, we are ensured that there
is no pollution, and we get what we asked for.

> unfoldTelescope :: TY -> ProofState [INTM]
> unfoldTelescope (PI _S _T) = do
>   _Stm <- bquoteHere _S
>   freshRef ("s" :<: _S) $ \s -> do
>       t <- unfoldTelescope (_T $$ (A $ pval s))
>       return $ _Stm : t
> unfoldTelescope _ = return []


\end{danger}


Now, we are left with implementing |extractDelta1'|.

> extractDelta1' :: Bwd (REF :<: INTM) -> [REF] -> ProofState (Bwd (REF :<: INTM))

First, we treat the case where $r \in \Delta$ belongs to the
dependency set. As expected, we ignore $r$ from
$\Delta_1$. Additionally, we collect the references in the type of $r$
and add them to the dependency set. Then, we proceed further.

\savecolumns

> extractDelta1' (rs :< (r :<: rTyTm)) deps
>   | r `usedIn` deps = do
>     -- r is used in the motive or methods
>     -- Add its components to the dependency set
>     let deps' = deps `union` collectRefs rTyTm
>     -- Drop it from Delta1
>     extractDelta1' rs deps'

Second, when $r$ is free in the dependency set, we simply add it to
$\Delta_1$.

\restorecolumns

>   | otherwise = do
>     -- r is not used
>     -- Get delta1'
>     delta1' <- extractDelta1' rs deps
>     -- And add r to it                   
>     return $ delta1' :< (r :<: rTyTm)
>         where usedIn = Data.Foldable.elem

Trivially, on an empty context, there is nothing to say.

> extractDelta1' B0 deps = return B0



\subsubsection{Turning the context into a |Binder|}


As we have seen, computing the motive will involve considering a
context $\Delta_1$ and, as we go along, remove some of its
components. We have found easier to present $\Delta_1$ in the form of
|Binders|.

An element of $\Delta_1$ is a |Binder|:

> type Binder = (Name :<: INTM)

That is, the |Name| of a reference and its type. $\Delta_1$ itself
will therefore be presented as a |Bwd| list of |Binder|:

> type Binders = Bwd Binder


We turn the context, presented as a list of references, into a
|Binders| using |toBinders|. There is no magic in there.

> toBinders :: [REF] -> NameSupply -> Binders
> toBinders delta1 =  (traverse toBinder delta1) 
>                     >>= (return . bwdList)
>     where toBinder :: REF -> NameSupply -> Binder
>           toBinder (n := ( _ :<: t)) = (| (n :<:) (bquote B0 t) |)




\subsubsection{Extracting an element of $\Delta_1$}


Recall that, during simplification, we need to identify references
belonging to the context $\Delta_1$ and, if they do, remove the
corresponding $\Pi$ in the cached context $\Delta_1'$. However, in
|ProofState|, we cannot really remove a $\Pi$ once it has been
made. Therefore, we delay the making of the $\Pi$s until we precisely
know which ones are needed. Meanwhile, to carry our analysis, we
directly manipulate the |Binders| computed from $\Delta_1$.

To symbolically remove a $\Pi$, we remove the corresponding
|Binder|. When simplification ends, we simply introduce the $\Pi$s
corresponding to the remaining |Binders|.

Let us implement the ``search and symbolic removal'' operation: we are
given a reference, which may or may not belong to the binders.
If the reference belongs to the binders, we return the binders before it,
and the binders after it (which might depend on it); if not, we return
|Nothing|.

> lookupInContext :: REF -> Binders -> Maybe (Bwd Binder, Fwd Binder)
> lookupInContext (n := _) xs = help xs F0
>   where
>     help :: Bwd Binder -> Fwd Binder -> Maybe (Bwd Binder, Fwd Binder)
>     help (xs :< b@(xn :<: _)) ys
>         | n == xn    = Just (xs, ys)
>         | otherwise  = help xs (b :> ys)
>     help B0 _        = Nothing


\subsubsection{Carrying renaming}


As we have seen, we are to carry a fair amount of renaming. As a
general rule, a renaming operation consists in replacing some
references identified by their name by some other references, in a
term in |INTM| form. In such case, renaming is simply a matter of
|fmap| over the term. Here is the solution for replacing one variable
by another:

> type Renamer = INTM -> INTM 
>
> renameVar :: Name -> REF -> Renamer
> renameVar n r' t
>     = fmap (\r@(rn := _) -> if rn == n then r' else r) t

\question{Is it worth fusing these fmaps to improve performance,
or will GHC do it for us anyway?}

In the previous section, we have shown that, given a reference
belonging to the context, we can split the context into two parts. The
first contains the terms before the cut, let us call it
|delta1Front|. The second list, called |delta1Back|, contains the
terms after the cut -- which are likely to use the reference we are
removing.

Hence, before anything, we need to re-build a valid context, without
dangling references. To this end, we are provided the context in
pieces and a renaming function (initially, one replacing the
eliminated reference by the new one). We give back a valid context and
a renaming function that records all renamings we have carried:

> normalizeDelta1 ::  Bwd Binder ->  Renamer ->  Fwd Binder -> (Bwd Binder, Renamer)
> normalizeDelta1     delta1Front    sigma       delta1Back | False = undefined

The trivial case is to have no context to rename: we return the valid
context and the renamer:

> normalizeDelta1 delta1 renamer F0 = (delta1, renamer)

In the other case, we have |(n :<: _S)| an element of the
context. First, we rename its type, giving |_S'|. We have fixed the
dangling references in that term, so we can add it to the valid
context |delta1Front|. However, we are not done: we need to inform the
terms in |delta1Back| that |n| is now something of type |_S'|. That
is, we compose the previous |renamer| with this new renaming
ordeal. And we go over |delta1Back|.

> normalizeDelta1 delta1Front renamer ((n :<: _S) :> delta1Back) = 
>     normalizeDelta1  (delta1Front :< (n :<: _S')) 
>                      ((n `renameVar` y) . renamer) 
>                      delta1Back
>         where  _S'  =  renamer _S
>                y    =  n := (DECL :<: evTm _S')

Note that we have used |DECL| when forging |y|. This is not really a
problem: remember that |Binders| are just playing an imitative fiction
here. Once we have found which |Binders| we keep, we will just use
their type to make $\Pi$-boys and replace the place-holders used here
by the $\Pi$-boys.





\subsubsection{Building and simplifying the motive}


The following function does not only look scary, but it is actually
pretty scary. It is all recursive, so it is also quite hard to begin
the explanation somewhere. 

Let us sum-up where we are in the construction of the motive. We are
sitting in some internal context $\Delta$. We have segregated this
context in two parts, keeping only $\Delta_1$, the non-parametric
hypotheses. Moreover, we have turned $\Delta_1$ into |Binders|. Our
mission here is to compute the |Binders| with no junk, that is with no
$\Pi$ quantifying an element which has been simplified.


At this stage, we have computed no |Constraints|:

> type Constraints = Bwd (Maybe (REF, INTM :>: INTM))

Where |Constraints| represents the equalities we want to generate. The
|REF| is a term of $\lambda (\Xi)$ whereas the |INTM :>: INTM| on the
right is a term of $\vec{t}$ together with its type. The whole is
wrapped into a |Maybe|: when we simplify a constraint, we notify the
simplification by putting a |Nothing|. Hence, at the end of the
simplification process, we know which |refl|-proofs are not
needed. Note that we have to be careful to rename the $\vec{t}$ and
their types as we simplify. Our goal is to compute a (valid) set of
simplified constraints.

Finally, we are initially given the goal to solve, |T|. In the end, we
want a valid goal with no dangling references: when simplifications
are introduced, they ought to be applied in the goal too.

All of this is done, in one go, by |simplify|. It operates by
induction on its third argument. This argument is composed by two
type-telescopes, initially both $\Xi$, and the whole set of
constraints between $\Xi$ and $\vec{t}$. The type-telescopes will be
unfolded to give the type of the values in $\Xi$ and $\vec{t}$ as we
go along. On the other hand, we will try to simplify the $\vec{t}$ by
their corresponding $(\Xi)$, failing that we register the constraint
and continue.

In the end, here is the type of the monster:

> simplify ::  (TY, TY, [(REF, INTM)]) -> 
>              Binders -> 
>              Constraints -> 
>              INTM -> 
>              NameSupply -> (Binders, Constraints, INTM)

When we reach the end of the telescope(s), both must have reduced to
|SET| with no more constraint to consume (because they are all
arguments of |P|). We simply return the accumulated results.

> simplify (SET, SET, []) delta1 constraints goal = return (delta1, constraints, goal)

Otherwise, pattern-matching the $\Pi$ type gives us the type of |x|
and |p|. Then, we can start the hard work.

> simplify (PI s t, PI s' t', (x@(xn := _),p) : xts) delta1 constraints goal = do
>     -- Homogenous equality:
>     -- We \emph{first} need to be sure that |x| and |p| are of the same type
>     -- Otherwise, substituting them is illegal
>     isSequalS' <- equal $ SET :>: (s, s')
>     -- \emph{Lazily}, extract |p| from the context
>     -- Assuming that |p| is a reference and that sets are equal
>     -- (the pattern guard is overcrowed, I could not put that one there)
>     let delta1FDelta1B = lookupInContext (unNP p) delta1
>     (case p of
>       NP y@(yn := _) | isJust delta1FDelta1B && isSequalS' -> do
>         -- Case 1: S and S' are equal and |p| sits in $\Delta_1$:
>         -- We can simplify!
>
>         -- Normalize the context and get a renamer
>         let  Just (delta1F, delta1B) = delta1FDelta1B
>              (delta1', renamer) = normalizeDelta1 delta1F (yn `renameVar` x) delta1B
>         -- Apply the renamer to:
>         --     * the constraints to come
>         --     * the constraints so far
>         --     * the goal
>         let xts' = fmap (mapSnd renamer) xts
>         let constraints' = fmap (fmap.mapSnd $ mapBoth renamer) constraints :< Nothing
>         let goal' = renamer goal
>         -- Continue with the updated structures, unfolding the telescope
>         simplify  (t $$ (A $ pval x), t' $$ (A $ pval x), xts')
>                   delta1' 
>                   constraints'
>                   goal'
>       _ -> do
>         -- Case 2: we cannot simplify
>
>         -- That's one more constraint my friend
>         s'Tm <- bquote B0 s'
>         let constraints' = constraints :< Just (x, s'Tm :>: p)
>         -- Continue with the updated structure, unfolding the telescope
>         simplify  ((t $$ A (pval x)), t' $$ A (evTm p), xts)
>                   delta1 
>                   constraints'
>                   goal) 
>          :: NameSupply -> (Binders, Constraints, INTM)
>     where  unNP :: INTM -> REF
>            unNP (NP y) = y
>
>            mapSnd :: (b -> c) -> (a,b) -> (a,c)
>            mapSnd f (x,y) = (x, f y)
>
>            mapBoth :: (a -> b) -> (a :>: a) -> (b :>: b)
>            mapBoth f (x :>: y) = f x :>: f y

And that's all.

Sooner or later, the following bit will be integrated where the 
|case p of| is currently sitting:

< matchRef :: (TY :>: VAL) -> Spine -> ProofState REF
< matchRef (_ :>: NP r) F0 = return r
< matchRef _ = mzero




> data a :~>: b = a :~>: b
>   deriving (Eq, Show)

To the left, we have a backwards list of binders: references from the fixed context
$\Delta$ together with their updated type and a non-updated argument term in
$\vec{t}$.

> type Binder' = (REF :<: (() :~>: INTM), INTM :~>: ())

> toBinder :: (REF :<: INTM) -> Binder'
> toBinder (r :<: t) = (r :<: (() :~>: t), NP r :~>: ())

> binderArg :: Binder' -> INTM
> binderArg (_, t :~>: ()) = t

> binderOut :: Binder' -> REF :<: INTM
> binderOut (r :<: (() :~>: t), _) = (r :<: t)

To the right, we have a forwards list of constraints: references in $\Xi$ together
with the term representation of their type, and typed terms in $\Delta$ to which
the references are equated.

> type Constraint' = (REF :<: (INTM :~>: INTM), (INTM :~>: INTM) :<: (INTM :~>: INTM))

For each constraint, we ask if it is homogeneous and the term on the right is a
reference in $\Delta$. If so, we can simplify by removing the equation, updating
the binder and renaming the following binders, constraints and term. 

> simplifyMotive :: Bwd Binder' -> Fwd Constraint' -> INTM
>     -> ProofState (Bwd Binder', INTM)

> simplifyMotive bs F0 tm = return (bs, tm)

> simplifyMotive bs (c@(x' :<: (xt :~>: xt'), (NP p :~>: NP p') :<: (pt :~>: pt')) :> cs) tm = do
>     eq <- withNSupply $ equal $ SET :>: (pty x', pty p')
>     case (eq, lookupBinders p' bs) of
>         (True, Just (pre, post)) -> do
>             let  (post', f)  = updateBinders
>                                    [(p', x')] B0 post
>                  (cs', f')   = updateConstraints f B0 cs
>                  tm'         = updateTM f' tm
>             simplifyMotive (pre <+> post') (cs' <>> F0) tm'
>         _ -> passConstraint bs c cs tm
>  where
>    updateTM :: [(REF, REF)] -> INTM -> INTM
>    updateTM news = fmap (\ r -> case lookup r news of
>                                   Just r' -> r'
>                                   Nothing -> r)
>                       
>    updateBinders :: [(REF, REF)] -> Bwd Binder' -> Fwd Binder'
>        -> (Bwd Binder', [(REF, REF)])
>    updateBinders news bs F0 = (bs, news) 
>    updateBinders news bs ((y'@(n := DECL :<: _) :<: (() :~>: yt'), a) :> xs) = do
>        let  yt''   = updateTM news yt'
>             y''    = n := DECL :<: evTm yt''
>             news'  = (y' , y'') : news
>        updateBinders news' (bs :< (y'' :<: (() :~>: yt''), a)) xs 
>
>    updateConstraints :: [(REF, REF)] -> Bwd Constraint' -> Fwd Constraint'
>        -> (Bwd Constraint', [(REF, REF)])
>    updateConstraints news bs F0 = (bs, news)
>    updateConstraints news bs ((y'@(n := DECL :<: _) :<: (yt :~>: yt'), (s :~>: s') :<: (st :~>: st')) :> xs) = do
>        let yt'' = updateTM news yt'
>            y'' = n := DECL :<: evTm yt''
>            news' = (y', y'') : news
>            s'' = updateTM news s'
>            st'' = updateTM news st'
>        updateConstraints news' (bs :< (y'' :<: (yt :~>: yt''), (s :~>: s'') :<: (st :~>: st''))) xs

> simplifyMotive bs (c :> cs) tm = passConstraint bs c cs tm


> passConstraint :: Bwd Binder' -> Constraint' -> Fwd Constraint' -> INTM
>     -> ProofState (Bwd Binder', INTM)
> passConstraint bs (x' :<: (xt :~>: xt'), (s :~>: s') :<: (st :~>: st')) cs tm = do 
>     let qt' = PRF (EQBLUE (xt' :>: NP x') (st' :>: s'))
>     optionalProofTrace $ "PASS: " ++ show qt'
>     freshRef ("qsm" :<: evTm qt')
>         (\ q -> simplifyMotive
>             (bs :< (q :<: (() :~>: qt'), N (P refl :$ A st :$ A s) :~>: ())) cs tm)


> lookupBinders :: REF -> Bwd Binder' -> Maybe (Bwd Binder', Fwd Binder')
> lookupBinders p binders = help binders F0
>   where
>     help :: Bwd Binder' -> Fwd Binder' -> Maybe (Bwd Binder', Fwd Binder')
>     help (binders :< b@(y :<: _, _)) zs
>         | p == y     = Just (binders, zs)
>         | otherwise  = help binders (b :> zs)
>     help B0 _        = Nothing




\subsubsection{Building the motive}

> optionalProofTrace s = if on then proofTrace s else return ()
>   where on = False


> introMotive' :: TY -> [INTM :<: INTM] -> Bwd Constraint'
>     -> ProofState (Bwd Constraint')
> introMotive' (PI s t) ((x :<: xty) : xs) cs = do
>     r <- lambdaBoy (fortran t)
>     rty <- bquoteHere (pty r) -- \question{can we get this from somewhere?}
>     let c = (r :<: (rty:~>: rty), (x :~>: x) :<: (xty :~>: xty))
>     optionalProofTrace $ "CONSTRAINT: " ++ show c
>     introMotive' (t $$ A (NP r)) xs (cs :< c)
> introMotive' SET [] cs = return cs


Finally, we can make the motive, hence closing the subgoal. This
simply consists in chaining the commands above, and give the computed
term. Unless I've screwed up things, |give| should always be happy.

> makeMotive ::  TY -> INTM -> Bwd (REF :<: INTM) -> Bwd (INTM :<: INTM) -> TY ->
>                ProofState [Binder']
> makeMotive motiveType goal delta targets elimTy = do
>     optionalProofTrace $ "goal: " ++ show goal
>     optionalProofTrace $ "targets: " ++ show targets

>     -- Extract $\Delta_1$ from $\Delta$
>     delta1 <- extractDelta1 delta elimTy
>     optionalProofTrace $ "delta1: " ++ show delta1

>     -- Transform $\Delta$ into Binder form
>     let binders = fmap toBinder delta1

>     constraints <- introMotive' motiveType (reverse $ trail targets) B0
>     optionalProofTrace $ "constraints: " ++ show constraints

>     (binders', goal') <- simplifyMotive binders (constraints <>> F0) goal
>     optionalProofTrace $ "binders': " ++ show binders'
>     optionalProofTrace $ "goal': " ++ show goal'

>     let goal'' = liftType' (fmap binderOut binders') goal'
>     optionalProofTrace $ "goal'': " ++ show goal''

>     give goal''

>     return $ trail binders'


> {-
>   -- Introduce $\Xi$
>   xis <- introMotive 
>   -- Make the initial list of constraints
>   let constraintsI = zip xis targets
>   let teleConstraints = (motiveType, motiveType, constraintsI)
>   optionalProofTrace $ "teleConstraints: " ++ show teleConstraints
>   -- Simplify that mess!
>   (binders, constraints, goal) <- withNSupply $ simplify teleConstraints binders B0 goalTm
>   let bindersL = trail binders
>   optionalProofTrace $ "bindersL: " ++ show bindersL
>   optionalProofTrace $ "constraints: " ++ show constraints
>   optionalProofTrace $ "goal: " ++ show goal
>   -- Make the $\Pi$-boys from $\Delta_1$
>   delta1' <- mkPiDelta1 bindersL id B0
>   optionalProofTrace $ "delta1': " ++ show delta1'
>   -- Make $(xi == ti) \rightarrow T$
>   solution <- makeEq constraints goal
>   optionalProofTrace $ "solution: " ++ show solution
>   -- Rename solution from the dummy |binders| to the fresh |delta|
>   let motive = transportToLocal bindersL delta1' solution

>   -- And we are done
>   optionalProofTrace $ "motive: " ++ show motive
>   motive :=>: _ <- give motive
>   optionalProofTrace "motivated!"
>   -- Filter out the simplified delta and patterns (for elimination application)
>   let delta1R = filterDeltas bindersL delta1
>   patterns <- filterPatterns motiveType targets (trail constraints)
>   -- Return
>   return (delta1R, N motive, patterns)
> -}

Along the way, we have used a bunch of helper functions. Let us look
at them in turn. First, we have used |mkPiDelta1| to turn the
|Binders| we have computed into $\Pi$-boys in the development.
We have to update references in the types as we go along, in case
there are dependencies.

> mkPiDelta1 :: [Binder] -> Renamer -> Bwd REF -> ProofState [REF]
> mkPiDelta1 []              renamer refs = return (trail refs)
> mkPiDelta1 ((n :<: t):bs)  renamer refs = do
>     r <- piBoy (fst (last n)  :<: renamer t)
>     mkPiDelta1 bs ((n `renameVar` r) . renamer) (refs :< r)

> introBinders :: [Binder'] -> Renamer -> Bwd REF -> ProofState (Bwd REF)
> introBinders []                             renamer refs = return refs
> introBinders ((r :<: (() :~>: t), _) : bs)  renamer refs = do
>     r' <- piBoy (fst (last (refName r))  :<: renamer t)
>     introBinders bs ((refName r `renameVar` r') . renamer) (refs :< r')



An important step is to build the term $(\Xi == \vec{t}) -> T$. This
consists in going over the |Bwd| list of constraints and make the
thing:

> makeEq :: Constraints -> INTM -> ProofState INTM
> makeEq B0 t = return t
> makeEq (cstrt :< Nothing) t = makeEq cstrt t
> makeEq (cstrt :< Just (r, sTy :>: s)) t = do
>   rTy <- bquoteHere $ pty r
>   makeEq cstrt (ARR (PRF (EQBLUE (rTy :>: NP r) (sTy :>: s))) t)

Recall that we have build the term above in the context |bindersL|,
which is a genetic mutant of $\Delta_1$. Meanwhile, we have introduced
$\Delta_1'$, a bunch of fresh $\Pi$-boys. The last step is therefore
to transport the term from |bindersL| to $\Delta_1'$. This is simply a
vast renaming operation:

> transportToLocal :: [Name :<: a] -> [REF] -> INTM -> INTM
> transportToLocal binders = rename nameBinders
>     where rename :: [Name] -> [REF] -> INTM -> INTM
>           rename [] [] t = t
>           rename (n : ns) (r : rs) t = rename ns rs (renameVar n r t)
>           nameBinders = map (\(n :<: _) -> n) binders

Finally, we do a bit of work to simplify the next step, which is of
applying the eliminator. I think I can spoil the fact that the
elimination will be of this form:

$$ e P \vec{m} \Delta_1 \vec{\mbox{refl}(t)}$$

Therefore, we need to know \emph{which} $\Delta_1$ and \emph{which}
$t$s have been simplified. This is not at all trivial, unless we have
a way to link the outputs of |simplify| with its inputs. We do have
this link, in two different forms.

For $\Delta_1$, we rely on the names: the name of the simplified
binders and the name of $\Delta_1$ are the same. Hence, we filter out
the names of $\Delta_1$ that are absent of the |binders|:

> filterDeltas :: [(Name :<: a)] -> [REF] -> [REF]
> filterDeltas binders deltas1 = filter inBinders deltas1
>     where inBinders (rn := _) = rn `Data.List.elem` bindersNames
>           bindersNames = map (\(n :<: _) -> n) binders

On the other hand, we have arranged the code of |simplify| in such a
way that when a constraint is simplified, a |Nothing| notifies the
deletion. Therefore, after simplification, we could still zip the
initial list of patterns and the simplified one. 

> filterPatterns :: TY -> [INTM] -> [Maybe (REF, INTM :>: INTM)] -> ProofState [INTM :>: INTM]
> filterPatterns motiveTy initialPatterns simplifiedPatterns | False = undefined

We filter the initial list of patterns by dropping the ones zipped
with a Nothing. Because |refl| needs both a term and a type, we also
require the type of the motive, which is unfolded along our way.

> filterPatterns (PI _S _T) (x : xs) (Nothing : cs)= do
>     ts <- filterPatterns (_T $$ (A (evTm x))) xs cs
>     return $ ts
> filterPatterns (PI _S _T) (x : xs) (Just (_, _ :>: _) : cs) = do
>     _Stm <- bquoteHere _S
>     ts <- filterPatterns (_T $$ (A (evTm x))) xs cs
>     return $ (_Stm :>: x) : ts
> filterPatterns SET [] [] = return []



\subsection{Applying the motive}

Remember our eliminator:

$$\Gamma, \Delta \vdash e : (P : \Xi \rightarrow \Set) 
                            \rightarrow \vec{m} 
                            \rightarrow P \vec{t}$$

We now have built the following motive |P| (ignoring renaming
annotations, for brevity):

$$\lambda (\Xi) . \Pi (\Delta_1') . (\Xi) == \vec{t} -> T$$

And we have introduced the methods $\vec{m}$, letting the user the task to
solve these subgoals. Hence, we can apply the eliminator, which will result in
a function of the following type:

$$P \vec{t} \equiv \Pi (\Delta_1') \rightarrow \vec{t} == \vec{t} \rightarrow T$$

That is, we need to apply the result of |elim motive methods| to the
partial internal context $\Delta_1$, and the reflexivity proofs. Let
us build these proofs first. This simply consists in taking each
variable $\vec{t}$ and apply |refl| to it.

> mkRefls :: [INTM :>: INTM] -> NameSupply -> [INTM]
> mkRefls ((t :>: v) : eqs) r =  (N $ (P refl) $##  [ t 
>                                           , v ])
>                                   : mkRefls eqs r
> mkRefls [] r = []


Then, it is straightforward to build the term we want and to give it:

> applyElim :: Name -> [Binder'] -> ProofState ()
> applyElim elimName binders = do
>     -- reflArgs <- withNSupply $ mkRefls args
>     Just (elim :=>: _) <- lookupName elimName
>     ((giveNext $ N $ elim $## map binderArg binders
>       ) >> return ())
>         `catchError` (\ es -> do
>           es' <- distillErrors es
>           proofTrace $ "applyElim failed!\n" ++ show (prettyStackError es'))
>     return ()

We (in theory) have solved the goal!


\subsection{Putting things together}

Therefore, we get the |elim| commands, the one, the unique. It is simply a
Frankenstein operation of these three parts:

> elim :: Maybe REF -> Eliminator -> ProofState ()
> elim comma eliminator@((_ :=>: elimTy) :>: _) = do 

Here we go. In a first part, we need to retrieve some information about our
goal and its context. 

>     -- The motive needs to know our goal
>     (goalTm :=>: _) <- getGoal "T"
>     delta <- getLocalContext comma

In a second part, we turn the eliminator into a girl and play the
doctor with her: we look at her internals, check that everything is
correct, and make sub-goals. Note that |introElim| make a girl and we
carefully |goOut| her in |elimDoctor|. (This paragraph is the result
of too much time spend in the lab, too far from any feminine
presence. Observe the damages).

>     -- Make an (un-goaled) module
>     -- We will turn it in a (goaled T) girl at the end
>     elimName <- makeModule "makeE"
>     goIn
>     -- Prepare the development by creating subgoals:
>     --    1/ the motive
>     --    2/ the methods
>     --    3/ the arguments of the motive
>     (motiveType, methods, targets) <- introElim eliminator
>     -- Build the motive
>     binders <- makeMotive motiveType goalTm delta targets elimTy
>     -- Leave the development with the methods unimplemented
>     goOut

In a third part, we solve the problem. To that end, we simply have to use the
|applyElim| command we have developed above.

>     -- Apply the motive, ie. solve the goal
>     applyElim elimName binders
   


> getLocalContext :: Maybe REF -> ProofState (Bwd (REF :<: INTM))
> getLocalContext comma = do
>     -- Lacking a comma term, we assume that 
>     -- the whole context is internal
>     delta <- getBoyTerms 
>     return . bwdList $ case comma of 
>         Nothing  -> delta
>         Just c   -> dropWhile (\ (r :<: _) -> c /= r) delta


We make elimination accessible to the user by adding it as a Cochon tactic:

> elimCTactic :: Maybe RelName -> ExDTmRN -> ProofState String
> elimCTactic c r = do 
>     c' <- case c of 
>           Nothing -> return Nothing
>           Just c -> do
>              c <- resolveDiscard c
>              return $ Just c
>     (e :=>: ev :<: elimTy) <- elabInfer' r
>     elimTyTm <- bquoteHere elimTy
>     elim c' ((elimTyTm :=>: elimTy) :>: (e :=>: ev))
>     return "Eliminated. Subgoals awaiting work..."

> import -> CochonTactics where
>   : (simpleCT
>     "eliminate"
>     (|(|(B0 :<) (tokenOption tokenName)|) :< (|id tokenExTm
>                                               |id tokenAscription |)|)
>     (\[n,e] -> elimCTactic (argOption (unDP . argToEx) n) (argToEx e))
>     "eliminate [<comma>] <eliminator> - eliminates with a motive.")
