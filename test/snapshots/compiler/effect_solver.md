# META
source_lines=823
stages=DESUGAR,MARK
# SOURCE
-- Binding-owned effect equations. Operational lower bounds and compatibility
-- constraints are separate inputs: checking a type never adds a body effect.
-- The worklist solves summaries and their local existential dependencies before
-- any cells are linked, including filtered cycles through higher-order calls.
import map as M
import map.{Map(..)}
import types.effect_domain.{Atom, atomsUnion, atomsDiff}
import types.effect_rows.{
  EffRow(..), Effvar(..), effvarId, rowFlat, rowFlatMembers, rowHasSummary,
  linkRow, solveSummaryCell
}
import support.util.{reverseL, isNonEmptyL, isEmptyL}
import support.scc.{tarjanSCCs}

export data SummarySolver c = SummarySolver {
  essStack : Ref (List (SummaryScope c)),
}

data SummaryScope c = SummaryScope {
  essOwner : Int,
  essEffvarFloor : Int,
  essLevel : Int,
  essNodes : Ref (Map Int SummaryNode),
  essExistentials : Ref (Map Int (Ref Effvar)),
  essAllowances : Ref (Map Int (Ref Effvar)),
  essRelations : Ref (List (RowRelation c)),
}

data SummaryNode = SummaryNode {
  esnCell : Ref Effvar,
  esnLowers : Ref (List EffRow),
}

data RowRelation c = RowRelation {
  esrLower : EffRow,
  esrUpper : EffRow,
  esrExact : Bool,
  esrContext : c,
  esrProtected : Map Int Unit,
}

public export data SummaryFailure c = SummaryFailure {
  esfLower : EffRow,
  esfUpper : EffRow,
  esfExact : Bool,
  esfContext : c,
}

export
newSolver : Unit -> SummarySolver c
newSolver _ = SummarySolver { essStack = Ref [] }

export
hasSummaryScope : SummarySolver c -> Bool
hasSummaryScope solver = isNonEmptyL solver.essStack.value

export
openSummaryScope : SummarySolver c -> Int -> Int -> Unit
openSummaryScope solver owner level =
  solver.essStack :=
    SummaryScope {
        essOwner = owner,
        essEffvarFloor = owner,
        essLevel = level,
        essNodes = Ref Tip,
        essExistentials = Ref Tip,
        essAllowances = Ref Tip,
        essRelations = Ref [],
      }
      :: solver.essStack.value

currentScope : SummarySolver c -> SummaryScope c
currentScope solver = match solver.essStack.value
  scope :: _ => scope
  [] => panic "effect summary outside an inference scope"

export
newSummary : SummarySolver c -> Int -> EffRow
newSummary solver id =
  let scope = currentScope solver
  let cell = Ref (ESummary id scope.essLevel scope.essOwner)
  scope.essNodes :=
    M.set
      id
      SummaryNode {
        esnCell = cell,
        esnLowers = Ref [],
      }
      scope.essNodes.value
  EffRow [] (Some cell)

export
isOwnedSummary : SummarySolver c -> EffRow -> Bool
isOwnedSummary solver (EffRow [] (Some cell)) =
  M.has (effvarId cell) (currentScope solver).essNodes.value
isOwnedSummary _ _ = False

-- Instantiating a quantified scheme or inferring an unknown callable introduces
-- existential choices owned by this scope. This differs from observing a row
-- while capturing effects: an environment/callback tail is not ours to close.
export
registerExistential : SummarySolver c -> Ref Effvar -> Unit
registerExistential solver cell = match solver.essStack.value
  scope :: _ =>
    scope.essExistentials :=
      M.set (effvarId cell) cell scope.essExistentials.value
  [] => ()

-- A positive value envelope is an inference choice whose least solution is
-- observable even inside an invariant result. It is not a body summary and
-- does not confer permission to widen an already-typed value.
export
registerValueAllowance : SummarySolver c -> Ref Effvar -> Unit
registerValueAllowance solver cell = match solver.essStack.value
  scope :: _ =>
    let _ = registerExistential solver cell
    scope.essAllowances := M.set (effvarId cell) cell scope.essAllowances.value
  [] => ()

export
recordBodyLower : SummarySolver c -> EffRow -> EffRow -> Unit
recordBodyLower solver (EffRow [] (Some cell)) lower =
  let scope = currentScope solver
  match M.get (effvarId cell) scope.essNodes.value
    Some node => node.esnLowers := lower :: node.esnLowers.value
    None => panic "body lower bound assigned outside its summary owner"
recordBodyLower _ _ _ = panic "body lower bound requires a summary slot"

-- Exact compares Effect-kind indices; the checker supplies the two concrete
-- orders (ordinary capability inclusion and invariant index inclusion).
export
recordRelation : SummarySolver c -> Bool -> c -> EffRow -> EffRow -> Unit
recordRelation solver exact context lower upper =
  let scope = currentScope solver
  scope.essRelations :=
    RowRelation {
        esrLower = lower,
        esrUpper = upper,
        esrExact = exact,
        esrContext = context,
        esrProtected = Tip,
      }
      :: scope.essRelations.value

data SolveEdge = SolveEdge {
  eseTarget : Int,
  eseCoverAtoms : List Atom,
  eseCoverLeaves : Map Int Unit,
  eseExact : Bool,
}

data WorkNode = WorkNode {
  ewnCell : Ref Effvar,
  ewnAtoms : Ref (List Atom),
  ewnLeaves : Ref (Map Int (Ref Effvar)),
  ewnPendingAtoms : Ref (List Atom),
  ewnPendingLeaves : Ref (Map Int (Ref Effvar)),
  ewnEdges : Ref (List SolveEdge),
}

data SolveWork = SolveWork {
  eswNodes : Map Int WorkNode,
  eswQueue : Ref (List Int),
  eswQueued : Ref (Map Int Unit),
  eswOrdinaryTargets : Ref (Map Int Unit),
  eswExactTargets : Ref (Map Int Unit),
  eswEscape : Bool -> List Atom -> List Atom -> List Atom,
}

newWorkNode : Ref Effvar -> WorkNode
newWorkNode cell = WorkNode {
  ewnCell = cell,
  ewnAtoms = Ref [],
  ewnLeaves = Ref Tip,
  ewnPendingAtoms = Ref [],
  ewnPendingLeaves = Ref Tip,
  ewnEdges = Ref [],
}

-- Only same-owner inference existentials are candidates. Parameter, signature,
-- environment and rigid roots are supplied explicitly by the checker.
eligibleUpper : SummaryScope c -> Map Int Unit -> Ref Effvar -> Bool
eligibleUpper scope protected cell = match !cell
  EUnbound id level =>
    level >= scope.essLevel
      && id > scope.essEffvarFloor
      && not (M.has id protected)
  -- Owned summaries are solved from explicit body lower bounds. They are not
  -- compatibility absorbers: counting one as an upper candidate would make
  -- `{summary, caller-tail}` ambiguous and leave the real inferred tail open.
  ESummary _ _ _ => False
  _ => False

relationNodes : SummaryScope c ->
  Map Int Unit ->
  List (RowRelation c) ->
  Map Int WorkNode ->
  Map Int WorkNode
relationNodes _ _ [] nodes = nodes
relationNodes scope protected (rel :: rest) nodes =
  let candidates =
    filter (eligibleUpper scope protected) (snd (rowFlat rel.esrUpper))
  let nodes2 = match candidates
    [cell] => match !cell
      EUnbound id _ =>
        if M.has id nodes then nodes else M.set id (newWorkNode cell) nodes
      _ => nodes
    _ => nodes
  relationNodes scope protected rest nodes2

enqueue : SolveWork -> Int -> Unit
enqueue work id =
  if not (M.has id work.eswQueued.value) then
    work.eswQueued := M.set id () work.eswQueued.value
    work.eswQueue := id :: work.eswQueue.value

grow : SolveWork -> Int -> List Atom -> Map Int (Ref Effvar) -> Unit
grow work id atoms leaves = match M.get id work.eswNodes
  None => panic "missing effect equation vertex"
  Some node =>
    let newAtoms = atomsDiff atoms node.ewnAtoms.value
    let newLeaves =
      M.foldlWithKey
        (acc key cell =>
          if M.has key node.ewnLeaves.value then acc else M.set key cell acc)
        Tip
        leaves
    let _ =
      if isNonEmptyL newAtoms then
        node.ewnAtoms := atomsUnion node.ewnAtoms.value newAtoms
        node.ewnPendingAtoms := atomsUnion node.ewnPendingAtoms.value newAtoms
    let changedLeaves = match newLeaves
      Tip => False
      _ =>
        node.ewnLeaves :=
          M.foldlWithKey
            (acc key cell => M.set key cell acc)
            node.ewnLeaves.value
            newLeaves
        node.ewnPendingLeaves :=
          M.foldlWithKey
            (acc key cell => M.set key cell acc)
            node.ewnPendingLeaves.value
            newLeaves
        True
    if isNonEmptyL newAtoms || changedLeaves then enqueue work id

-- RHS leaves become either graph edges or external symbolic payload. No cell is
-- mutated here, so cycles are finite equations rather than cyclic ELink chains.
addEquation : SolveWork ->
  Int ->
  EffRow ->
  List Atom ->
  Map Int Unit ->
  Bool ->
  Unit
addEquation work target rhs coverAtoms coverLeaves exact =
  let (atoms, cells) = rowFlat rhs
  let leaves = addEdges work target cells coverAtoms coverLeaves exact Tip
  grow work target (work.eswEscape exact atoms coverAtoms) leaves

addEdges : SolveWork ->
  Int ->
  List (Ref Effvar) ->
  List Atom ->
  Map Int Unit ->
  Bool ->
  Map Int (Ref Effvar) ->
  Map Int (Ref Effvar)
addEdges _ _ [] _ _ _ leaves = leaves
addEdges work target (cell :: rest) coverAtoms coverLeaves exact leaves =
  let id = effvarId cell
  let leaves2 =
    if M.has id coverLeaves then
      leaves
    else match M.get id work.eswNodes
      Some node =>
        node.ewnEdges :=
          SolveEdge {
              eseTarget = target,
              eseCoverAtoms = coverAtoms,
              eseCoverLeaves = coverLeaves,
              eseExact = exact,
            }
            :: node.ewnEdges.value
        leaves
      None => M.set id cell leaves
  addEdges work target rest coverAtoms coverLeaves exact leaves2

addBodyEquations : SolveWork -> List SummaryNode -> Unit
addBodyEquations _ [] = ()
addBodyEquations work (node :: rest) =
  let _ = addLowers work (effvarId node.esnCell) node.esnLowers.value
  addBodyEquations work rest

addLowers : SolveWork -> Int -> List EffRow -> Unit
addLowers _ _ [] = ()
addLowers work id (row :: rest) =
  let _ = addEquation work id row [] Tip False
  addLowers work id rest

leafSet : List (Ref Effvar) -> Map Int Unit
leafSet cells = leafSetGo cells Tip

leafSetGo : List (Ref Effvar) -> Map Int Unit -> Map Int Unit
leafSetGo [] acc = acc
leafSetGo (cell :: rest) acc = leafSetGo rest (M.set (effvarId cell) () acc)

addRelationEquations : SolveWork -> List (RowRelation c) -> Unit
addRelationEquations _ [] = ()
addRelationEquations work (rel :: rest) =
  let (upperAtoms, upperCells) = rowFlat rel.esrUpper
  let vertices = filter (cell => M.has (effvarId cell) work.eswNodes) upperCells
  let _ = match vertices
    [cell] => match !cell
      EUnbound id _ =>
        let fixed = filter (c => effvarId c /= id) upperCells
        let _ =
          addEquation
            work
            id
            rel.esrLower
            upperAtoms
            (leafSet fixed)
            rel.esrExact
        if rel.esrExact then
          work.eswExactTargets := M.set id () work.eswExactTargets.value
        else
          work.eswOrdinaryTargets := M.set id () work.eswOrdinaryTargets.value
      _ => ()
    -- No arbitrary decomposition of a join between two unknown tails. Such a
    -- constraint remains a check after the body equations have been solved.
    _ => ()
  addRelationEquations work rest

drainWork : SolveWork -> Unit
drainWork work = match work.eswQueue.value
  [] => ()
  id :: rest =>
    work.eswQueue := rest
    work.eswQueued := M.delete id work.eswQueued.value
    let _ = match M.get id work.eswNodes
      Some node =>
        let atoms = node.ewnPendingAtoms.value
        let leaves = node.ewnPendingLeaves.value
        node.ewnPendingAtoms := []
        node.ewnPendingLeaves := Tip
        propagate work atoms leaves node.ewnEdges.value
      None => panic "missing queued effect equation"
    drainWork work

-- Every newly discovered atom/leaf crosses each outgoing edge once. Snapshot
-- and clear the delta before propagation so a cycle can enqueue new work.
propagate : SolveWork ->
  List Atom ->
  Map Int (Ref Effvar) ->
  List SolveEdge ->
  Unit
propagate _ _ _ [] = ()
propagate work atoms delta (edge :: rest) =
  let leaves =
    M.foldlWithKey
      (acc id cell =>
        if M.has id edge.eseCoverLeaves then acc else M.set id cell acc)
      Tip
      delta
  let _ =
    grow
      work
      edge.eseTarget
      (work.eswEscape edge.eseExact atoms edge.eseCoverAtoms)
      leaves
  propagate work atoms delta rest

linkSolutions : Int ->
  (List (Ref Effvar) -> Ref Effvar) ->
  List WorkNode ->
  Unit
linkSolutions _ _ [] = ()
linkSolutions owner makeJoin (node :: rest) =
  let row = match M.values node.ewnLeaves.value
    [] => EffRow node.ewnAtoms.value None
    [cell] => EffRow node.ewnAtoms.value (Some cell)
    cells => EffRow node.ewnAtoms.value (Some (makeJoin cells))
  let _ = match !node.ewnCell
    ESummary _ _ _ => solveSummaryCell owner node.ewnCell row
    _ => linkRow node.ewnCell row
  linkSolutions owner makeJoin rest

missingLeaves : List (Ref Effvar) -> Map Int Unit -> Bool
missingLeaves [] _ = False
missingLeaves (cell :: rest) upper =
  not (M.has (effvarId cell) upper) || missingLeaves rest upper

validateRelations : SummarySolver c ->
  Map Int Unit ->
  (Bool -> List Atom -> List Atom -> List Atom) ->
  List (RowRelation c) ->
  List (SummaryFailure c)
validateRelations _ _ _ [] = []
validateRelations solver protected escape (rel :: rest) =
  if rowHasSummary rel.esrLower
    || rowHasSummary rel.esrUpper then match solver.essStack.value
    _ :: parent :: _ =>
      let _ = retainRowAt parent.essLevel rel.esrLower
      let _ = retainRowAt parent.essLevel rel.esrUpper
      parent.essRelations :=
        RowRelation {
            esrLower = rel.esrLower,
            esrUpper = rel.esrUpper,
            esrExact = rel.esrExact,
            esrContext = rel.esrContext,
            esrProtected = protected,
          }
          :: parent.essRelations.value
      validateRelations solver protected escape rest
    -- An unresolved summary relation at the outermost boundary is a real
    -- unsatisfied effect obligation, not a reason to reach for a nonexistent
    -- parent scope. Keep it observable as a normal failure so laundering
    -- cannot turn into a stack panic or an implicit acceptance.
    _ =>
      SummaryFailure {
          esfLower = rel.esrLower,
          esfUpper = rel.esrUpper,
          esfExact = rel.esrExact,
          esfContext = rel.esrContext,
        }
        :: validateRelations solver protected escape rest
  else
    let (lowerAtoms, lowerCells) = rowFlat rel.esrLower
    let (upperAtoms, upperCells) = rowFlat rel.esrUpper
    let failures = validateRelations solver protected escape rest
    if isNonEmptyL (escape rel.esrExact lowerAtoms upperAtoms)
      || missingLeaves lowerCells (leafSet upperCells) then
      SummaryFailure {
          esfLower = rel.esrLower,
          esfUpper = rel.esrUpper,
          esfExact = rel.esrExact,
          esfContext = rel.esrContext,
        }
        :: failures
    else
      failures

-- A residual proof may move outward, but a local scheme cannot freshen its
-- flexible endpoints away from that proof. Keep exactly those leaves at the
-- parent's level; protected leaves retain their identities and protection.
retainRowAt : Int -> EffRow -> Unit
retainRowAt level row = retainLeavesAt level (snd (rowFlat row))

retainLeavesAt : Int -> List (Ref Effvar) -> Unit
retainLeavesAt _ [] = ()
retainLeavesAt level (cell :: rest) =
  let _ = match !cell
    EUnbound id old => if old > level then cell := EUnbound id level
    _ => ()
  retainLeavesAt level rest

export
closeSummaryScope : SummarySolver c ->
  Map Int Unit ->
  Map Int Unit ->
  Map Int (Ref Effvar) ->
  (Bool -> List Atom -> List Atom -> List Atom) ->
  (List (Ref Effvar) -> Ref Effvar) ->
  (Int -> Ref Effvar) ->
  List (SummaryFailure c)
closeSummaryScope solver protected retained borrowed escape makeJoin makeResidual =
  let scope = currentScope solver
  let summaries = M.values scope.essNodes.value
  let untransferred =
    filter
      (rel => not (relationProven escape rel))
      (reverseL scope.essRelations.value)
  let relationRoots =
    fold
      (acc rel =>
        M.foldlWithKey (roots id _ => M.set id () roots) acc rel.esrProtected)
      protected
      untransferred
  let frozen = relationRoots
  let initialAllowances =
    snd (rowFlatMembers [] (M.values scope.essAllowances.value))
  let outward = leafSet (filter (outwardAllowance scope) initialAllowances)
  let pending = transferAllowanceRelations solver frozen outward untransferred
  let _ = transferAllowances solver initialAllowances
  let retained2 = collapseInclusionCycles scope frozen retained pending
  let allowanceCells =
    snd (rowFlatMembers [] (M.values scope.essAllowances.value))
  let allowanceRoots = leafSet allowanceCells
  let inputRoots = leafSet (snd (rowFlatMembers [] (M.values borrowed)))
  let relations = filter (rel => not (relationProven escape rel)) pending
  let summaryNodes = map (node => newWorkNode node.esnCell) scope.essNodes.value
  let choices = snd (rowFlatMembers [] (M.values scope.essExistentials.value))
  let initial =
    fold
      (nodes cell =>
        if eligibleUpper scope frozen cell
          && (not (M.has (effvarId cell) retained2)
            || M.has (effvarId cell) allowanceRoots
              && not (M.has (effvarId cell) inputRoots)) then
          M.set (effvarId cell) (newWorkNode cell) nodes
        else
          nodes)
      summaryNodes
      choices
  -- Published flexible leaves are symbolic inputs to the least equations, not
  -- zero-information vertices. Otherwise S = input, S <= input would erase
  -- the input by solving both vertices from bottom.
  let leastFrozen =
    M.foldlWithKey (acc id _ => M.set id () acc) frozen retained2
  let nodes = relationNodes scope leastFrozen relations initial
  let _ =
    solveEquations
      scope.essOwner
      nodes
      summaries
      relations
      Tip
      escape
      makeJoin
      makeResidual
  -- Only after summaries have solutions can their evidence constrain a
  -- retained upper row. Normalize/drop reflexive obligations first; fresh bare
  -- inclusion cycles exposed by summary substitution again mean equality.
  let residual0 = filter (rel => not (relationProven escape rel)) relations
  let local = filter summaryFreeRelation residual0
  let _ = collapseInclusionCycles scope frozen retained2 local
  let residual = filter (rel => not (relationProven escape rel)) local
  let retainedNodes = relationNodes scope frozen residual Tip
  let borrowedRoots = leafSet (snd (rowFlatMembers [] (M.values borrowed)))
  let _ =
    solveEquations
      scope.essOwner
      retainedNodes
      []
      residual
      borrowedRoots
      escape
      makeJoin
      makeResidual
  let unproven = filter (rel => not (relationProven escape rel)) residual0
  let failures = validateRelations solver frozen escape unproven
  solver.essStack := match solver.essStack.value
    _ :: rest => rest
    [] => panic "effect scope stack underflow"
  failures

outwardAllowance : SummaryScope c -> Ref Effvar -> Bool
outwardAllowance scope cell = match !cell
  EUnbound id level => level < scope.essLevel || id <= scope.essEffvarFloor
  _ => False

-- Moving one obligation also moves its flexible endpoints. Follow the connected
-- constraint component before solving anything locally, so a sibling bound on
-- a newly-outward endpoint cannot be diagnosed or defaulted in the child.
data TransferWork = TransferWork {
  etwRows : Map Int (Map Int Unit),
  etwUsers : Map Int (List Int),
  etwSelected : Ref (Map Int Unit),
  etwSeen : Ref (Map Int Unit),
}

relationRoots : RowRelation c -> Map Int Unit
relationRoots rel =
  leafSetGo (snd (rowFlat rel.esrUpper)) (leafSet (snd (rowFlat rel.esrLower)))

indexTransferRelations : List (RowRelation c) ->
  Int ->
  Map Int (Map Int Unit) ->
  Map Int (List Int) ->
  TransferWork
indexTransferRelations [] _ rows users = TransferWork {
  etwRows = rows,
  etwUsers = users,
  etwSelected = Ref Tip,
  etwSeen = Ref Tip,
}
indexTransferRelations (rel :: rest) id rows users =
  let roots = relationRoots rel
  let users2 =
    M.foldlWithKey
      (acc root _ => M.set root (id :: optionOr [] (M.get root acc)) acc)
      users
      roots
  indexTransferRelations rest (id + 1) (M.set id roots rows) users2

selectTransferRows : TransferWork -> List Int -> Unit
selectTransferRows _ [] = ()
selectTransferRows work (root :: rest) =
  if M.has root work.etwSeen.value then
    selectTransferRows work rest
  else
    work.etwSeen := M.set root () work.etwSeen.value
    let next =
      fold
        (pending id =>
          if M.has id work.etwSelected.value then
            pending
          else
            work.etwSelected := M.set id () work.etwSelected.value
            M.foldlWithKey
              (acc key _ => key :: acc)
              pending
              (optionOr Tip (M.get id work.etwRows)))
        rest
        (optionOr [] (M.get root work.etwUsers))
    selectTransferRows work next

transferAllowanceRelations : SummarySolver c ->
  Map Int Unit ->
  Map Int Unit ->
  List (RowRelation c) ->
  List (RowRelation c)
transferAllowanceRelations solver protected outward relations =
  match solver.essStack.value
    _ :: parent :: _ => match outward
      Tip => relations
      _ =>
        let work = indexTransferRelations relations 0 Tip Tip
        let _ = selectTransferRows work (M.keys outward)
        partitionTransferred parent protected work.etwSelected.value 0 relations
    _ => relations

partitionTransferred : SummaryScope c ->
  Map Int Unit ->
  Map Int Unit ->
  Int ->
  List (RowRelation c) ->
  List (RowRelation c)
partitionTransferred _ _ _ _ [] = []
partitionTransferred parent protected selected id (rel :: rest) =
  if M.has id selected then
    let _ = retainRowAt parent.essLevel rel.esrLower
    let _ = retainRowAt parent.essLevel rel.esrUpper
    parent.essRelations :=
      RowRelation {
          esrLower = rel.esrLower,
          esrUpper = rel.esrUpper,
          esrExact = rel.esrExact,
          esrContext = rel.esrContext,
          esrProtected = protected,
        }
        :: parent.essRelations.value
    partitionTransferred parent protected selected (id + 1) rest
  else
    rel :: partitionTransferred parent protected selected (id + 1) rest

-- Transfer before solving: only original inference choices carry this role,
-- never external leaves introduced by a solution's borrowed residual.
transferAllowances : SummarySolver c -> List (Ref Effvar) -> Unit
transferAllowances solver cells = match solver.essStack.value
  _ :: parent :: _ =>
    fold
      (_ cell => match !cell
        EUnbound id level =>
          if level <= parent.essLevel then
            parent.essExistentials := M.set id cell parent.essExistentials.value
            parent.essAllowances := M.set id cell parent.essAllowances.value
        _ => ())
      ()
      cells
  _ => ()

summaryFreeRelation : RowRelation c -> Bool
summaryFreeRelation rel =
  not (rowHasSummary rel.esrLower || rowHasSummary rel.esrUpper)

solveEquations : Int ->
  Map Int WorkNode ->
  List SummaryNode ->
  List (RowRelation c) ->
  Map Int Unit ->
  (Bool -> List Atom -> List Atom -> List Atom) ->
  (List (Ref Effvar) -> Ref Effvar) ->
  (Int -> Ref Effvar) ->
  Unit
solveEquations owner nodes summaries relations borrowed escape makeJoin makeResidual =
  let work = SolveWork {
    eswNodes = nodes,
    eswQueue = Ref [],
    eswQueued = Ref Tip,
    eswOrdinaryTargets = Ref Tip,
    eswExactTargets = Ref Tip,
    eswEscape = escape,
  }
  let _ = addBodyEquations work summaries
  let _ = addRelationEquations work relations
  let _ =
    M.foldlWithKey
      (_ id node => seedBorrowedResidual work borrowed makeResidual id node)
      ()
      nodes
  let _ = drainWork work
  linkSolutions owner makeJoin (M.values nodes)

-- An input allowance may include more than its demonstrated lower bound.
-- Seed one external residual before propagation, so cyclic/sibling constraints
-- see the same slack. Exact index equations do not admit that extra freedom.
seedBorrowedResidual : SolveWork ->
  Map Int Unit ->
  (Int -> Ref Effvar) ->
  Int ->
  WorkNode ->
  Unit
seedBorrowedResidual work borrowed makeResidual id node =
  if M.has id borrowed
    && M.has id work.eswOrdinaryTargets.value
    && not (M.has id work.eswExactTargets.value) then
    let residual = makeResidual (inclusionLevel node.ewnCell)
    grow work id [] (M.set (effvarId residual) residual Tip)

-- Mutual reachability of unfiltered singleton inclusions proves equality.
-- Collapse precisely those classes before least solving; an unconstrained
-- retained class must remain a polymorphic variable, not be defaulted to pure.
-- Filtered joins and body summaries are equations, not equality-class edges.
collapseInclusionCycles : SummaryScope c ->
  Map Int Unit ->
  Map Int Unit ->
  List (RowRelation c) ->
  Map Int Unit
collapseInclusionCycles scope rigid retained relations =
  let pairs = flatMap (singletonInclusion scope rigid) relations
  match pairs
    [] => retained
    _ =>
      let cells =
        fold
          (acc (a, b) => M.set (effvarId a) a (M.set (effvarId b) b acc))
          Tip
          pairs
      -- Allocate each string key once for the existing SCC service. Edges
      -- reuse those keys; the hot row/worklist maps remain integer-keyed.
      let names = M.mapWithKey (id _ => intToString id) cells
      let byName =
        M.foldlWithKey
          (acc id cell => M.set (inclusionName names id) cell acc)
          Tip
          cells
      let edges =
        fold
          (acc (a, b) =>
            let from = inclusionName names (effvarId a)
            let to = inclusionName names (effvarId b)
            M.set from (to :: optionOr [] (M.get from acc)) acc)
          Tip
          pairs
      fold
        (collapseInclusionClass byName)
        retained
        (tarjanSCCs (M.values names) edges)

singletonInclusion : SummaryScope c ->
  Map Int Unit ->
  RowRelation c ->
  List (Ref Effvar, Ref Effvar)
singletonInclusion scope rigid rel = match (
  rowFlat rel.esrLower,
  rowFlat rel.esrUpper,
)
  (([], [a]), ([], [b])) =>
    if eligibleUpper scope rigid a && eligibleUpper scope rigid b then
      [(a, b)]
    else
      []
  _ => []

inclusionName : Map Int String -> Int -> String
inclusionName names id = match M.get id names
  Some name => name
  None => panic "missing inclusion graph name"

inclusionCell : Map String (Ref Effvar) -> String -> Ref Effvar
inclusionCell cells name = match M.get name cells
  Some cell => cell
  None => panic "missing inclusion graph cell"

inclusionLevel : Ref Effvar -> Int
inclusionLevel cell = match !cell
  EUnbound _ level => level
  _ => panic "non-flexible inclusion graph vertex"

collapseInclusionClass : Map String (Ref Effvar) ->
  Map Int Unit ->
  List String ->
  Map Int Unit
collapseInclusionClass _ retained [] = retained
collapseInclusionClass _ retained [_] = retained
collapseInclusionClass cells retained (first :: rest) =
  let members = map (inclusionCell cells) (first :: rest)
  let initial = inclusionCell cells first
  let (representative, level, keep) =
    fold
      ((best, level, keep) cell =>
        let retainedCell = M.has (effvarId cell) retained
        (
          if retainedCell && not keep then cell else best,
          min level (inclusionLevel cell),
          keep || retainedCell,
        ))
      (initial, inclusionLevel initial, M.has (effvarId initial) retained)
      members
  let id = effvarId representative
  representative := EUnbound id level
  let _ =
    fold
      (_ cell =>
        if effvarId cell /= id then
          linkRow cell (EffRow [] (Some representative)))
      ()
      members
  if keep then M.set id () retained else retained

-- Reflexivity and known widening impose no lower bound on an unknown tail.
-- In particular, pure <= e must not turn an observable e into a pure row.
relationProven : (Bool -> List Atom -> List Atom -> List Atom) ->
  RowRelation c ->
  Bool
relationProven escape rel =
  let (lowerAtoms, lowerCells) = rowFlat rel.esrLower
  let (upperAtoms, upperCells) = rowFlat rel.esrUpper
  isEmptyL (escape rel.esrExact lowerAtoms upperAtoms)
    && not (missingLeaves lowerCells (leafSet upperCells))
# DESUGAR
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Atom" false) (mem "atomsUnion" false) (mem "atomsDiff" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "effvarId" false) (mem "rowFlat" false) (mem "rowFlatMembers" false) (mem "rowHasSummary" false) (mem "linkRow" false) (mem "solveSummaryCell" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "isNonEmptyL" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DData Abstract "SummarySolver" ("c") ((variant "SummarySolver" (ConNamed (field "essStack" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "SummaryScope") (TyVar "c")))))))) ())
(DData Private "SummaryScope" ("c") ((variant "SummaryScope" (ConNamed (field "essOwner" (TyCon "Int")) (field "essEffvarFloor" (TyCon "Int")) (field "essLevel" (TyCon "Int")) (field "essNodes" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "SummaryNode")))) (field "essExistentials" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "essAllowances" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "essRelations" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c")))))))) ())
(DData Private "SummaryNode" () ((variant "SummaryNode" (ConNamed (field "esnCell" (TyApp (TyCon "Ref") (TyCon "Effvar"))) (field "esnLowers" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))))))) ())
(DData Private "RowRelation" ("c") ((variant "RowRelation" (ConNamed (field "esrLower" (TyCon "EffRow")) (field "esrUpper" (TyCon "EffRow")) (field "esrExact" (TyCon "Bool")) (field "esrContext" (TyVar "c")) (field "esrProtected" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))) ())
(DData Public "SummaryFailure" ("c") ((variant "SummaryFailure" (ConNamed (field "esfLower" (TyCon "EffRow")) (field "esfUpper" (TyCon "EffRow")) (field "esfExact" (TyCon "Bool")) (field "esfContext" (TyVar "c"))))) ())
(DTypeSig true "newSolver" (TyFun (TyCon "Unit") (TyApp (TyCon "SummarySolver") (TyVar "c"))))
(DFunDef false "newSolver" (PWild) (ERecordCreate "SummarySolver" ((fa "essStack" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "hasSummaryScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyCon "Bool")))
(DFunDef false "hasSummaryScope" ((PVar "solver")) (EApp (EVar "isNonEmptyL") (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value")))
(DTypeSig true "openSummaryScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "openSummaryScope" ((PVar "solver") (PVar "owner") (PVar "level")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "solver") "essStack")) (EBinOp "::" (ERecordCreate "SummaryScope" ((fa "essOwner" (EVar "owner")) (fa "essEffvarFloor" (EVar "owner")) (fa "essLevel" (EVar "level")) (fa "essNodes" (EApp (EVar "Ref") (EVar "Tip"))) (fa "essExistentials" (EApp (EVar "Ref") (EVar "Tip"))) (fa "essAllowances" (EApp (EVar "Ref") (EVar "Tip"))) (fa "essRelations" (EApp (EVar "Ref") (EListLit))))) (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value"))))
(DTypeSig false "currentScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyApp (TyCon "SummaryScope") (TyVar "c"))))
(DFunDef false "currentScope" ((PVar "solver")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons (PVar "scope") PWild) () (EVar "scope")) (arm (PList) () (EApp (EVar "panic") (ELit (LString "effect summary outside an inference scope"))))))
(DTypeSig true "newSummary" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "Int") (TyCon "EffRow"))))
(DFunDef false "newSummary" ((PVar "solver") (PVar "id")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "ESummary") (EVar "id")) (EFieldAccess (EVar "scope") "essLevel")) (EFieldAccess (EVar "scope") "essOwner")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essNodes")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ERecordCreate "SummaryNode" ((fa "esnCell" (EVar "cell")) (fa "esnLowers" (EApp (EVar "Ref") (EListLit)))))) (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value")))) (DoExpr (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))))
(DTypeSig true "isOwnedSummary" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "isOwnedSummary" ((PVar "solver") (PCon "EffRow" (PList) (PCon "Some" (PVar "cell")))) (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EApp (EVar "currentScope") (EVar "solver")) "essNodes") "value")))
(DFunDef false "isOwnedSummary" (PWild PWild) (EVar "False"))
(DTypeSig true "registerExistential" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Unit"))))
(DFunDef false "registerExistential" ((PVar "solver") (PVar "cell")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons (PVar "scope") PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essExistentials")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "scope") "essExistentials") "value")))) (arm (PList) () (ELit LUnit))))
(DTypeSig true "registerValueAllowance" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Unit"))))
(DFunDef false "registerValueAllowance" ((PVar "solver") (PVar "cell")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons (PVar "scope") PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "registerExistential") (EVar "solver")) (EVar "cell"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essAllowances")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "scope") "essAllowances") "value")))))) (arm (PList) () (ELit LUnit))))
(DTypeSig true "recordBodyLower" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordBodyLower" ((PVar "solver") (PCon "EffRow" (PList) (PCon "Some" (PVar "cell"))) (PVar "lower")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoExpr (EMatch (EApp (EApp (EVar "M.get") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value")) (arm (PCon "Some" (PVar "node")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "esnLowers")) (EBinOp "::" (EVar "lower") (EFieldAccess (EFieldAccess (EVar "node") "esnLowers") "value")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "body lower bound assigned outside its summary owner"))))))))
(DFunDef false "recordBodyLower" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "body lower bound requires a summary slot"))))
(DTypeSig true "recordRelation" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "Bool") (TyFun (TyVar "c") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))))
(DFunDef false "recordRelation" ((PVar "solver") (PVar "exact") (PVar "context") (PVar "lower") (PVar "upper")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essRelations")) (EBinOp "::" (ERecordCreate "RowRelation" ((fa "esrLower" (EVar "lower")) (fa "esrUpper" (EVar "upper")) (fa "esrExact" (EVar "exact")) (fa "esrContext" (EVar "context")) (fa "esrProtected" (EVar "Tip")))) (EFieldAccess (EFieldAccess (EVar "scope") "essRelations") "value"))))))
(DData Private "SolveEdge" () ((variant "SolveEdge" (ConNamed (field "eseTarget" (TyCon "Int")) (field "eseCoverAtoms" (TyApp (TyCon "List") (TyCon "Atom"))) (field "eseCoverLeaves" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "eseExact" (TyCon "Bool"))))) ())
(DData Private "WorkNode" () ((variant "WorkNode" (ConNamed (field "ewnCell" (TyApp (TyCon "Ref") (TyCon "Effvar"))) (field "ewnAtoms" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Atom")))) (field "ewnLeaves" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "ewnPendingAtoms" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Atom")))) (field "ewnPendingLeaves" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "ewnEdges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "SolveEdge"))))))) ())
(DData Private "SolveWork" () ((variant "SolveWork" (ConNamed (field "eswNodes" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode"))) (field "eswQueue" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int")))) (field "eswQueued" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "eswOrdinaryTargets" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "eswExactTargets" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "eswEscape" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))))) ())
(DTypeSig false "newWorkNode" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "WorkNode")))
(DFunDef false "newWorkNode" ((PVar "cell")) (ERecordCreate "WorkNode" ((fa "ewnCell" (EVar "cell")) (fa "ewnAtoms" (EApp (EVar "Ref") (EListLit))) (fa "ewnLeaves" (EApp (EVar "Ref") (EVar "Tip"))) (fa "ewnPendingAtoms" (EApp (EVar "Ref") (EListLit))) (fa "ewnPendingLeaves" (EApp (EVar "Ref") (EVar "Tip"))) (fa "ewnEdges" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig false "eligibleUpper" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool")))))
(DFunDef false "eligibleUpper" ((PVar "scope") (PVar "protected") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "level")) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "level") (EFieldAccess (EVar "scope") "essLevel")) (EBinOp ">" (EVar "id") (EFieldAccess (EVar "scope") "essEffvarFloor"))) (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "protected"))))) (arm (PCon "ESummary" PWild PWild PWild) () (EVar "False")) (arm PWild () (EVar "False"))))
(DTypeSig false "relationNodes" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode")))))))
(DFunDef false "relationNodes" (PWild PWild (PList) (PVar "nodes")) (EVar "nodes"))
(DFunDef false "relationNodes" ((PVar "scope") (PVar "protected") (PCons (PVar "rel") (PVar "rest")) (PVar "nodes")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EVar "filter") (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "protected"))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))))) (DoLet false false (PVar "nodes2") (EMatch (EVar "candidates") (arm (PList (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "nodes")) (EVar "nodes") (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EApp (EVar "newWorkNode") (EVar "cell"))) (EVar "nodes")))) (arm PWild () (EVar "nodes")))) (arm PWild () (EVar "nodes")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "relationNodes") (EVar "scope")) (EVar "protected")) (EVar "rest")) (EVar "nodes2")))))
(DTypeSig false "enqueue" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "enqueue" ((PVar "work") (PVar "id")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswQueued") "value"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueued")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "eswQueued") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueue")) (EBinOp "::" (EVar "id") (EFieldAccess (EFieldAccess (EVar "work") "eswQueue") "value"))))) (ELit LUnit)))
(DTypeSig false "grow" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))))
(DFunDef false "grow" ((PVar "work") (PVar "id") (PVar "atoms") (PVar "leaves")) (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "eswNodes")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing effect equation vertex")))) (arm (PCon "Some" (PVar "node")) () (EBlock (DoLet false false (PVar "newAtoms") (EApp (EApp (EVar "atomsDiff") (EVar "atoms")) (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value"))) (DoLet false false (PVar "newLeaves") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") (PVar "cell")) (EIf (EApp (EApp (EVar "M.has") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "node") "ewnLeaves") "value")) (EVar "acc") (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (EVar "cell")) (EVar "acc"))))) (EVar "Tip")) (EVar "leaves"))) (DoLet false false PWild (EIf (EApp (EVar "isNonEmptyL") (EVar "newAtoms")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnAtoms")) (EApp (EApp (EVar "atomsUnion") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EVar "newAtoms")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingAtoms")) (EApp (EApp (EVar "atomsUnion") (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingAtoms") "value")) (EVar "newAtoms"))))) (ELit LUnit))) (DoLet false false (PVar "changedLeaves") (EMatch (EVar "newLeaves") (arm (PCon "Tip") () (EVar "False")) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnLeaves")) (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") (PVar "cell")) (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (EVar "cell")) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "node") "ewnLeaves") "value")) (EVar "newLeaves")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingLeaves")) (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") (PVar "cell")) (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (EVar "cell")) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingLeaves") "value")) (EVar "newLeaves")))) (DoExpr (EVar "True")))))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "newAtoms")) (EVar "changedLeaves")) (EApp (EApp (EVar "enqueue") (EVar "work")) (EVar "id")) (ELit LUnit)))))))
(DTypeSig false "addEquation" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyCon "Unit"))))))))
(DFunDef false "addEquation" ((PVar "work") (PVar "target") (PVar "rhs") (PVar "coverAtoms") (PVar "coverLeaves") (PVar "exact")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "cells")) (EApp (EVar "rowFlat") (EVar "rhs"))) (DoLet false false (PVar "leaves") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "work")) (EVar "target")) (EVar "cells")) (EVar "coverAtoms")) (EVar "coverLeaves")) (EVar "exact")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "grow") (EVar "work")) (EVar "target")) (EApp (EApp (EApp (EFieldAccess (EVar "work") "eswEscape") (EVar "exact")) (EVar "atoms")) (EVar "coverAtoms"))) (EVar "leaves")))))
(DTypeSig false "addEdges" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar")))))))))))
(DFunDef false "addEdges" (PWild PWild (PList) PWild PWild PWild (PVar "leaves")) (EVar "leaves"))
(DFunDef false "addEdges" ((PVar "work") (PVar "target") (PCons (PVar "cell") (PVar "rest")) (PVar "coverAtoms") (PVar "coverLeaves") (PVar "exact") (PVar "leaves")) (EBlock (DoLet false false (PVar "id") (EApp (EVar "effvarId") (EVar "cell"))) (DoLet false false (PVar "leaves2") (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "coverLeaves")) (EVar "leaves") (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "eswNodes")) (arm (PCon "Some" (PVar "node")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnEdges")) (EBinOp "::" (ERecordCreate "SolveEdge" ((fa "eseTarget" (EVar "target")) (fa "eseCoverAtoms" (EVar "coverAtoms")) (fa "eseCoverLeaves" (EVar "coverLeaves")) (fa "eseExact" (EVar "exact")))) (EFieldAccess (EFieldAccess (EVar "node") "ewnEdges") "value")))) (DoExpr (EVar "leaves")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "leaves")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "work")) (EVar "target")) (EVar "rest")) (EVar "coverAtoms")) (EVar "coverLeaves")) (EVar "exact")) (EVar "leaves2")))))
(DTypeSig false "addBodyEquations" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyCon "List") (TyCon "SummaryNode")) (TyCon "Unit"))))
(DFunDef false "addBodyEquations" (PWild (PList)) (ELit LUnit))
(DFunDef false "addBodyEquations" ((PVar "work") (PCons (PVar "node") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "addLowers") (EVar "work")) (EApp (EVar "effvarId") (EFieldAccess (EVar "node") "esnCell"))) (EFieldAccess (EFieldAccess (EVar "node") "esnLowers") "value"))) (DoExpr (EApp (EApp (EVar "addBodyEquations") (EVar "work")) (EVar "rest")))))
(DTypeSig false "addLowers" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "Unit")))))
(DFunDef false "addLowers" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "addLowers" ((PVar "work") (PVar "id") (PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEquation") (EVar "work")) (EVar "id")) (EVar "row")) (EListLit)) (EVar "Tip")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EVar "addLowers") (EVar "work")) (EVar "id")) (EVar "rest")))))
(DTypeSig false "leafSet" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "leafSet" ((PVar "cells")) (EApp (EApp (EVar "leafSetGo") (EVar "cells")) (EVar "Tip")))
(DTypeSig false "leafSetGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "leafSetGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "leafSetGo" ((PCons (PVar "cell") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "leafSetGo") (EVar "rest")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "addRelationEquations" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyCon "Unit"))))
(DFunDef false "addRelationEquations" (PWild (PList)) (ELit LUnit))
(DFunDef false "addRelationEquations" ((PVar "work") (PCons (PVar "rel") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "upperAtoms") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (DoLet false false (PVar "vertices") (EApp (EApp (EVar "filter") (ELam ((PVar "cell")) (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EVar "work") "eswNodes")))) (EVar "upperCells"))) (DoLet false false PWild (EMatch (EVar "vertices") (arm (PList (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EBlock (DoLet false false (PVar "fixed") (EApp (EApp (EVar "filter") (ELam ((PVar "c")) (EBinOp "/=" (EApp (EVar "effvarId") (EVar "c")) (EVar "id")))) (EVar "upperCells"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEquation") (EVar "work")) (EVar "id")) (EFieldAccess (EVar "rel") "esrLower")) (EVar "upperAtoms")) (EApp (EVar "leafSet") (EVar "fixed"))) (EFieldAccess (EVar "rel") "esrExact"))) (DoExpr (EIf (EFieldAccess (EVar "rel") "esrExact") (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswExactTargets")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "eswExactTargets") "value"))) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswOrdinaryTargets")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "eswOrdinaryTargets") "value"))))))) (arm PWild () (ELit LUnit)))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "addRelationEquations") (EVar "work")) (EVar "rest")))))
(DTypeSig false "drainWork" (TyFun (TyCon "SolveWork") (TyCon "Unit")))
(DFunDef false "drainWork" ((PVar "work")) (EMatch (EFieldAccess (EFieldAccess (EVar "work") "eswQueue") "value") (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "id") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueue")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueued")) (EApp (EApp (EVar "M.delete") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswQueued") "value")))) (DoLet false false PWild (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "eswNodes")) (arm (PCon "Some" (PVar "node")) () (EBlock (DoLet false false (PVar "atoms") (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingAtoms") "value")) (DoLet false false (PVar "leaves") (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingLeaves") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingAtoms")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingLeaves")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "propagate") (EVar "work")) (EVar "atoms")) (EVar "leaves")) (EFieldAccess (EFieldAccess (EVar "node") "ewnEdges") "value"))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing queued effect equation")))))) (DoExpr (EApp (EVar "drainWork") (EVar "work")))))))
(DTypeSig false "propagate" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "SolveEdge")) (TyCon "Unit"))))))
(DFunDef false "propagate" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "propagate" ((PVar "work") (PVar "atoms") (PVar "delta") (PCons (PVar "edge") (PVar "rest"))) (EBlock (DoLet false false (PVar "leaves") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "id") (PVar "cell")) (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EVar "edge") "eseCoverLeaves")) (EVar "acc") (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "acc"))))) (EVar "Tip")) (EVar "delta"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "grow") (EVar "work")) (EFieldAccess (EVar "edge") "eseTarget")) (EApp (EApp (EApp (EFieldAccess (EVar "work") "eswEscape") (EFieldAccess (EVar "edge") "eseExact")) (EVar "atoms")) (EFieldAccess (EVar "edge") "eseCoverAtoms"))) (EVar "leaves"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "propagate") (EVar "work")) (EVar "atoms")) (EVar "delta")) (EVar "rest")))))
(DTypeSig false "linkSolutions" (TyFun (TyCon "Int") (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "WorkNode")) (TyCon "Unit")))))
(DFunDef false "linkSolutions" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "linkSolutions" ((PVar "owner") (PVar "makeJoin") (PCons (PVar "node") (PVar "rest"))) (EBlock (DoLet false false (PVar "row") (EMatch (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "node") "ewnLeaves") "value")) (arm (PList) () (EApp (EApp (EVar "EffRow") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EVar "None"))) (arm (PList (PVar "cell")) () (EApp (EApp (EVar "EffRow") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EApp (EVar "Some") (EVar "cell")))) (arm (PVar "cells") () (EApp (EApp (EVar "EffRow") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EApp (EVar "Some") (EApp (EVar "makeJoin") (EVar "cells"))))))) (DoLet false false PWild (EMatch (EUnOp "!" (EFieldAccess (EVar "node") "ewnCell")) (arm (PCon "ESummary" PWild PWild PWild) () (EApp (EApp (EApp (EVar "solveSummaryCell") (EVar "owner")) (EFieldAccess (EVar "node") "ewnCell")) (EVar "row"))) (arm PWild () (EApp (EApp (EVar "linkRow") (EFieldAccess (EVar "node") "ewnCell")) (EVar "row"))))) (DoExpr (EApp (EApp (EApp (EVar "linkSolutions") (EVar "owner")) (EVar "makeJoin")) (EVar "rest")))))
(DTypeSig false "missingLeaves" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "missingLeaves" ((PList) PWild) (EVar "False"))
(DFunDef false "missingLeaves" ((PCons (PVar "cell") (PVar "rest")) (PVar "upper")) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "upper"))) (EApp (EApp (EVar "missingLeaves") (EVar "rest")) (EVar "upper"))))
(DTypeSig false "validateRelations" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyCon "List") (TyApp (TyCon "SummaryFailure") (TyVar "c"))))))))
(DFunDef false "validateRelations" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "validateRelations" ((PVar "solver") (PVar "protected") (PVar "escape") (PCons (PVar "rel") (PVar "rest"))) (EIf (EBinOp "||" (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrLower")) (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrUpper"))) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PCons (PVar "parent") PWild)) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrUpper"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essRelations")) (EBinOp "::" (ERecordCreate "RowRelation" ((fa "esrLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esrUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esrExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esrContext" (EFieldAccess (EVar "rel") "esrContext")) (fa "esrProtected" (EVar "protected")))) (EFieldAccess (EFieldAccess (EVar "parent") "essRelations") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "protected")) (EVar "escape")) (EVar "rest"))))) (arm PWild () (EBinOp "::" (ERecordCreate "SummaryFailure" ((fa "esfLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esfUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esfExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esfContext" (EFieldAccess (EVar "rel") "esrContext")))) (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "protected")) (EVar "escape")) (EVar "rest"))))) (EBlock (DoLet false false (PTuple (PVar "lowerAtoms") (PVar "lowerCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false (PTuple (PVar "upperAtoms") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (DoLet false false (PVar "failures") (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "protected")) (EVar "escape")) (EVar "rest"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "escape") (EFieldAccess (EVar "rel") "esrExact")) (EVar "lowerAtoms")) (EVar "upperAtoms"))) (EApp (EApp (EVar "missingLeaves") (EVar "lowerCells")) (EApp (EVar "leafSet") (EVar "upperCells")))) (EBinOp "::" (ERecordCreate "SummaryFailure" ((fa "esfLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esfUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esfExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esfContext" (EFieldAccess (EVar "rel") "esrContext")))) (EVar "failures")) (EVar "failures"))))))
(DTypeSig false "retainRowAt" (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "retainRowAt" ((PVar "level") (PVar "row")) (EApp (EApp (EVar "retainLeavesAt") (EVar "level")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "retainLeavesAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))
(DFunDef false "retainLeavesAt" (PWild (PList)) (ELit LUnit))
(DFunDef false "retainLeavesAt" ((PVar "level") (PCons (PVar "cell") (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "old")) () (EIf (EBinOp ">" (EVar "old") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "level"))) (ELit LUnit))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "retainLeavesAt") (EVar "level")) (EVar "rest")))))
(DTypeSig true "closeSummaryScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyApp (TyCon "SummaryFailure") (TyVar "c")))))))))))
(DFunDef false "closeSummaryScope" ((PVar "solver") (PVar "protected") (PVar "retained") (PVar "borrowed") (PVar "escape") (PVar "makeJoin") (PVar "makeResidual")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoLet false false (PVar "summaries") (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value"))) (DoLet false false (PVar "untransferred") (EApp (EApp (EVar "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "scope") "essRelations") "value")))) (DoLet false false (PVar "relationRoots") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "rel")) (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "roots") (PVar "id") PWild) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EVar "roots")))) (EVar "acc")) (EFieldAccess (EVar "rel") "esrProtected")))) (EVar "protected")) (EVar "untransferred"))) (DoLet false false (PVar "frozen") (EVar "relationRoots")) (DoLet false false (PVar "initialAllowances") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essAllowances") "value"))))) (DoLet false false (PVar "outward") (EApp (EVar "leafSet") (EApp (EApp (EVar "filter") (EApp (EVar "outwardAllowance") (EVar "scope"))) (EVar "initialAllowances")))) (DoLet false false (PVar "pending") (EApp (EApp (EApp (EApp (EVar "transferAllowanceRelations") (EVar "solver")) (EVar "frozen")) (EVar "outward")) (EVar "untransferred"))) (DoLet false false PWild (EApp (EApp (EVar "transferAllowances") (EVar "solver")) (EVar "initialAllowances"))) (DoLet false false (PVar "retained2") (EApp (EApp (EApp (EApp (EVar "collapseInclusionCycles") (EVar "scope")) (EVar "frozen")) (EVar "retained")) (EVar "pending"))) (DoLet false false (PVar "allowanceCells") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essAllowances") "value"))))) (DoLet false false (PVar "allowanceRoots") (EApp (EVar "leafSet") (EVar "allowanceCells"))) (DoLet false false (PVar "inputRoots") (EApp (EVar "leafSet") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EVar "borrowed")))))) (DoLet false false (PVar "relations") (EApp (EApp (EVar "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "pending"))) (DoLet false false (PVar "summaryNodes") (EApp (EApp (EVar "map") (ELam ((PVar "node")) (EApp (EVar "newWorkNode") (EFieldAccess (EVar "node") "esnCell")))) (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value"))) (DoLet false false (PVar "choices") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essExistentials") "value"))))) (DoLet false false (PVar "initial") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "nodes") (PVar "cell")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "frozen")) (EVar "cell")) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "retained2"))) (EBinOp "&&" (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "allowanceRoots")) (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "inputRoots")))))) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (EApp (EVar "newWorkNode") (EVar "cell"))) (EVar "nodes")) (EVar "nodes")))) (EVar "summaryNodes")) (EVar "choices"))) (DoLet false false (PVar "leastFrozen") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "frozen")) (EVar "retained2"))) (DoLet false false (PVar "nodes") (EApp (EApp (EApp (EApp (EVar "relationNodes") (EVar "scope")) (EVar "leastFrozen")) (EVar "relations")) (EVar "initial"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "solveEquations") (EFieldAccess (EVar "scope") "essOwner")) (EVar "nodes")) (EVar "summaries")) (EVar "relations")) (EVar "Tip")) (EVar "escape")) (EVar "makeJoin")) (EVar "makeResidual"))) (DoLet false false (PVar "residual0") (EApp (EApp (EVar "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "relations"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "filter") (EVar "summaryFreeRelation")) (EVar "residual0"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "collapseInclusionCycles") (EVar "scope")) (EVar "frozen")) (EVar "retained2")) (EVar "local"))) (DoLet false false (PVar "residual") (EApp (EApp (EVar "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "local"))) (DoLet false false (PVar "retainedNodes") (EApp (EApp (EApp (EApp (EVar "relationNodes") (EVar "scope")) (EVar "frozen")) (EVar "residual")) (EVar "Tip"))) (DoLet false false (PVar "borrowedRoots") (EApp (EVar "leafSet") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EVar "borrowed")))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "solveEquations") (EFieldAccess (EVar "scope") "essOwner")) (EVar "retainedNodes")) (EListLit)) (EVar "residual")) (EVar "borrowedRoots")) (EVar "escape")) (EVar "makeJoin")) (EVar "makeResidual"))) (DoLet false false (PVar "unproven") (EApp (EApp (EVar "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "residual0"))) (DoLet false false (PVar "failures") (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "frozen")) (EVar "escape")) (EVar "unproven"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "solver") "essStack")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PVar "rest")) () (EVar "rest")) (arm (PList) () (EApp (EVar "panic") (ELit (LString "effect scope stack underflow"))))))) (DoExpr (EVar "failures"))))
(DTypeSig false "outwardAllowance" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool"))))
(DFunDef false "outwardAllowance" ((PVar "scope") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "level")) () (EBinOp "||" (EBinOp "<" (EVar "level") (EFieldAccess (EVar "scope") "essLevel")) (EBinOp "<=" (EVar "id") (EFieldAccess (EVar "scope") "essEffvarFloor")))) (arm PWild () (EVar "False"))))
(DData Private "TransferWork" () ((variant "TransferWork" (ConNamed (field "etwRows" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "etwUsers" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))) (field "etwSelected" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "etwSeen" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))))) ())
(DTypeSig false "relationRoots" (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "relationRoots" ((PVar "rel")) (EApp (EApp (EVar "leafSetGo") (EApp (EVar "snd") (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper")))) (EApp (EVar "leafSet") (EApp (EVar "snd") (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower"))))))
(DTypeSig false "indexTransferRelations" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "TransferWork"))))))
(DFunDef false "indexTransferRelations" ((PList) PWild (PVar "rows") (PVar "users")) (ERecordCreate "TransferWork" ((fa "etwRows" (EVar "rows")) (fa "etwUsers" (EVar "users")) (fa "etwSelected" (EApp (EVar "Ref") (EVar "Tip"))) (fa "etwSeen" (EApp (EVar "Ref") (EVar "Tip"))))))
(DFunDef false "indexTransferRelations" ((PCons (PVar "rel") (PVar "rest")) (PVar "id") (PVar "rows") (PVar "users")) (EBlock (DoLet false false (PVar "roots") (EApp (EVar "relationRoots") (EVar "rel"))) (DoLet false false (PVar "users2") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "root") PWild) (EApp (EApp (EApp (EVar "M.set") (EVar "root")) (EBinOp "::" (EVar "id") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "root")) (EVar "acc"))))) (EVar "acc")))) (EVar "users")) (EVar "roots"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "indexTransferRelations") (EVar "rest")) (EBinOp "+" (EVar "id") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "roots")) (EVar "rows"))) (EVar "users2")))))
(DTypeSig false "selectTransferRows" (TyFun (TyCon "TransferWork") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "selectTransferRows" (PWild (PList)) (ELit LUnit))
(DFunDef false "selectTransferRows" ((PVar "work") (PCons (PVar "root") (PVar "rest"))) (EIf (EApp (EApp (EVar "M.has") (EVar "root")) (EFieldAccess (EFieldAccess (EVar "work") "etwSeen") "value")) (EApp (EApp (EVar "selectTransferRows") (EVar "work")) (EVar "rest")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "etwSeen")) (EApp (EApp (EApp (EVar "M.set") (EVar "root")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "etwSeen") "value")))) (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "pending") (PVar "id")) (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "etwSelected") "value")) (EVar "pending") (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "etwSelected")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "etwSelected") "value")))) (DoExpr (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") PWild) (EBinOp "::" (EVar "key") (EVar "acc")))) (EVar "pending")) (EApp (EApp (EVar "optionOr") (EVar "Tip")) (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "etwRows"))))))))) (EVar "rest")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "root")) (EFieldAccess (EVar "work") "etwUsers"))))) (DoExpr (EApp (EApp (EVar "selectTransferRows") (EVar "work")) (EVar "next"))))))
(DTypeSig false "transferAllowanceRelations" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))))))))
(DFunDef false "transferAllowanceRelations" ((PVar "solver") (PVar "protected") (PVar "outward") (PVar "relations")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PCons (PVar "parent") PWild)) () (EMatch (EVar "outward") (arm (PCon "Tip") () (EVar "relations")) (arm PWild () (EBlock (DoLet false false (PVar "work") (EApp (EApp (EApp (EApp (EVar "indexTransferRelations") (EVar "relations")) (ELit (LInt 0))) (EVar "Tip")) (EVar "Tip"))) (DoLet false false PWild (EApp (EApp (EVar "selectTransferRows") (EVar "work")) (EApp (EVar "M.keys") (EVar "outward")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "partitionTransferred") (EVar "parent")) (EVar "protected")) (EFieldAccess (EFieldAccess (EVar "work") "etwSelected") "value")) (ELit (LInt 0))) (EVar "relations"))))))) (arm PWild () (EVar "relations"))))
(DTypeSig false "partitionTransferred" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c")))))))))
(DFunDef false "partitionTransferred" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "partitionTransferred" ((PVar "parent") (PVar "protected") (PVar "selected") (PVar "id") (PCons (PVar "rel") (PVar "rest"))) (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "selected")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrUpper"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essRelations")) (EBinOp "::" (ERecordCreate "RowRelation" ((fa "esrLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esrUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esrExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esrContext" (EFieldAccess (EVar "rel") "esrContext")) (fa "esrProtected" (EVar "protected")))) (EFieldAccess (EFieldAccess (EVar "parent") "essRelations") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "partitionTransferred") (EVar "parent")) (EVar "protected")) (EVar "selected")) (EBinOp "+" (EVar "id") (ELit (LInt 1)))) (EVar "rest")))) (EBinOp "::" (EVar "rel") (EApp (EApp (EApp (EApp (EApp (EVar "partitionTransferred") (EVar "parent")) (EVar "protected")) (EVar "selected")) (EBinOp "+" (EVar "id") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "transferAllowances" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))
(DFunDef false "transferAllowances" ((PVar "solver") (PVar "cells")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PCons (PVar "parent") PWild)) () (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "level")) () (EIf (EBinOp "<=" (EVar "level") (EFieldAccess (EVar "parent") "essLevel")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essExistentials")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "parent") "essExistentials") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essAllowances")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "parent") "essAllowances") "value"))))) (ELit LUnit))) (arm PWild () (ELit LUnit))))) (ELit LUnit)) (EVar "cells"))) (arm PWild () (ELit LUnit))))
(DTypeSig false "summaryFreeRelation" (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyCon "Bool")))
(DFunDef false "summaryFreeRelation" ((PVar "rel")) (EApp (EVar "not") (EBinOp "||" (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrLower")) (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrUpper")))))
(DTypeSig false "solveEquations" (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode")) (TyFun (TyApp (TyCon "List") (TyCon "SummaryNode")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))))))))
(DFunDef false "solveEquations" ((PVar "owner") (PVar "nodes") (PVar "summaries") (PVar "relations") (PVar "borrowed") (PVar "escape") (PVar "makeJoin") (PVar "makeResidual")) (EBlock (DoLet false false (PVar "work") (ERecordCreate "SolveWork" ((fa "eswNodes" (EVar "nodes")) (fa "eswQueue" (EApp (EVar "Ref") (EListLit))) (fa "eswQueued" (EApp (EVar "Ref") (EVar "Tip"))) (fa "eswOrdinaryTargets" (EApp (EVar "Ref") (EVar "Tip"))) (fa "eswExactTargets" (EApp (EVar "Ref") (EVar "Tip"))) (fa "eswEscape" (EVar "escape"))))) (DoLet false false PWild (EApp (EApp (EVar "addBodyEquations") (EVar "work")) (EVar "summaries"))) (DoLet false false PWild (EApp (EApp (EVar "addRelationEquations") (EVar "work")) (EVar "relations"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam (PWild (PVar "id") (PVar "node")) (EApp (EApp (EApp (EApp (EApp (EVar "seedBorrowedResidual") (EVar "work")) (EVar "borrowed")) (EVar "makeResidual")) (EVar "id")) (EVar "node")))) (ELit LUnit)) (EVar "nodes"))) (DoLet false false PWild (EApp (EVar "drainWork") (EVar "work"))) (DoExpr (EApp (EApp (EApp (EVar "linkSolutions") (EVar "owner")) (EVar "makeJoin")) (EApp (EVar "M.values") (EVar "nodes"))))))
(DTypeSig false "seedBorrowedResidual" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "Int") (TyFun (TyCon "WorkNode") (TyCon "Unit")))))))
(DFunDef false "seedBorrowedResidual" ((PVar "work") (PVar "borrowed") (PVar "makeResidual") (PVar "id") (PVar "node")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "borrowed")) (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswOrdinaryTargets") "value"))) (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswExactTargets") "value")))) (EBlock (DoLet false false (PVar "residual") (EApp (EVar "makeResidual") (EApp (EVar "inclusionLevel") (EFieldAccess (EVar "node") "ewnCell")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "grow") (EVar "work")) (EVar "id")) (EListLit)) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "residual"))) (EVar "residual")) (EVar "Tip"))))) (ELit LUnit)))
(DTypeSig false "collapseInclusionCycles" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "collapseInclusionCycles" ((PVar "scope") (PVar "rigid") (PVar "retained") (PVar "relations")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "singletonInclusion") (EVar "scope")) (EVar "rigid"))) (EVar "relations"))) (DoExpr (EMatch (EVar "pairs") (arm (PList) () (EVar "retained")) (arm PWild () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "a"))) (EVar "a")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "b"))) (EVar "b")) (EVar "acc"))))) (EVar "Tip")) (EVar "pairs"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "M.mapWithKey") (ELam ((PVar "id") PWild) (EApp (EVar "intToString") (EVar "id")))) (EVar "cells"))) (DoLet false false (PVar "byName") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "id") (PVar "cell")) (EApp (EApp (EApp (EVar "M.set") (EApp (EApp (EVar "inclusionName") (EVar "names")) (EVar "id"))) (EVar "cell")) (EVar "acc")))) (EVar "Tip")) (EVar "cells"))) (DoLet false false (PVar "edges") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "from") (EApp (EApp (EVar "inclusionName") (EVar "names")) (EApp (EVar "effvarId") (EVar "a")))) (DoLet false false (PVar "to") (EApp (EApp (EVar "inclusionName") (EVar "names")) (EApp (EVar "effvarId") (EVar "b")))) (DoExpr (EApp (EApp (EApp (EVar "M.set") (EVar "from")) (EBinOp "::" (EVar "to") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "from")) (EVar "acc"))))) (EVar "acc")))))) (EVar "Tip")) (EVar "pairs"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (EApp (EVar "collapseInclusionClass") (EVar "byName"))) (EVar "retained")) (EApp (EApp (EVar "tarjanSCCs") (EApp (EVar "M.values") (EVar "names"))) (EVar "edges"))))))))))
(DTypeSig false "singletonInclusion" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "singletonInclusion" ((PVar "scope") (PVar "rigid") (PVar "rel")) (EMatch (ETuple (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (arm (PTuple (PTuple (PList) (PList (PVar "a"))) (PTuple (PList) (PList (PVar "b")))) () (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "rigid")) (EVar "a")) (EApp (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "rigid")) (EVar "b"))) (EListLit (ETuple (EVar "a") (EVar "b"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "inclusionName" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "inclusionName" ((PVar "names") (PVar "id")) (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EVar "names")) (arm (PCon "Some" (PVar "name")) () (EVar "name")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing inclusion graph name"))))))
(DTypeSig false "inclusionCell" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "inclusionCell" ((PVar "cells") (PVar "name")) (EMatch (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EVar "cell")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing inclusion graph cell"))))))
(DTypeSig false "inclusionLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Int")))
(DFunDef false "inclusionLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" PWild (PVar "level")) () (EVar "level")) (arm PWild () (EApp (EVar "panic") (ELit (LString "non-flexible inclusion graph vertex"))))))
(DTypeSig false "collapseInclusionClass" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "collapseInclusionClass" (PWild (PVar "retained") (PList)) (EVar "retained"))
(DFunDef false "collapseInclusionClass" (PWild (PVar "retained") (PList PWild)) (EVar "retained"))
(DFunDef false "collapseInclusionClass" ((PVar "cells") (PVar "retained") (PCons (PVar "first") (PVar "rest"))) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "map") (EApp (EVar "inclusionCell") (EVar "cells"))) (EBinOp "::" (EVar "first") (EVar "rest")))) (DoLet false false (PVar "initial") (EApp (EApp (EVar "inclusionCell") (EVar "cells")) (EVar "first"))) (DoLet false false (PTuple (PVar "representative") (PVar "level") (PVar "keep")) (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "best") (PVar "level") (PVar "keep")) (PVar "cell")) (EBlock (DoLet false false (PVar "retainedCell") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "retained"))) (DoExpr (ETuple (EIf (EBinOp "&&" (EVar "retainedCell") (EApp (EVar "not") (EVar "keep"))) (EVar "cell") (EVar "best")) (EApp (EApp (EVar "min") (EVar "level")) (EApp (EVar "inclusionLevel") (EVar "cell"))) (EBinOp "||" (EVar "keep") (EVar "retainedCell"))))))) (ETuple (EVar "initial") (EApp (EVar "inclusionLevel") (EVar "initial")) (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "initial"))) (EVar "retained")))) (EVar "members"))) (DoLet false false (PVar "id") (EApp (EVar "effvarId") (EVar "representative"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "representative")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "level")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cell")) (EIf (EBinOp "/=" (EApp (EVar "effvarId") (EVar "cell")) (EVar "id")) (EApp (EApp (EVar "linkRow") (EVar "cell")) (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "representative")))) (ELit LUnit)))) (ELit LUnit)) (EVar "members"))) (DoExpr (EIf (EVar "keep") (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EVar "retained")) (EVar "retained")))))
(DTypeSig false "relationProven" (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyCon "Bool"))))
(DFunDef false "relationProven" ((PVar "escape") (PVar "rel")) (EBlock (DoLet false false (PTuple (PVar "lowerAtoms") (PVar "lowerCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false (PTuple (PVar "upperAtoms") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (DoExpr (EBinOp "&&" (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "escape") (EFieldAccess (EVar "rel") "esrExact")) (EVar "lowerAtoms")) (EVar "upperAtoms"))) (EApp (EVar "not") (EApp (EApp (EVar "missingLeaves") (EVar "lowerCells")) (EApp (EVar "leafSet") (EVar "upperCells"))))))))
# MARK
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Atom" false) (mem "atomsUnion" false) (mem "atomsDiff" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "effvarId" false) (mem "rowFlat" false) (mem "rowFlatMembers" false) (mem "rowHasSummary" false) (mem "linkRow" false) (mem "solveSummaryCell" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "isNonEmptyL" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DData Abstract "SummarySolver" ("c") ((variant "SummarySolver" (ConNamed (field "essStack" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "SummaryScope") (TyVar "c")))))))) ())
(DData Private "SummaryScope" ("c") ((variant "SummaryScope" (ConNamed (field "essOwner" (TyCon "Int")) (field "essEffvarFloor" (TyCon "Int")) (field "essLevel" (TyCon "Int")) (field "essNodes" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "SummaryNode")))) (field "essExistentials" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "essAllowances" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "essRelations" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c")))))))) ())
(DData Private "SummaryNode" () ((variant "SummaryNode" (ConNamed (field "esnCell" (TyApp (TyCon "Ref") (TyCon "Effvar"))) (field "esnLowers" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))))))) ())
(DData Private "RowRelation" ("c") ((variant "RowRelation" (ConNamed (field "esrLower" (TyCon "EffRow")) (field "esrUpper" (TyCon "EffRow")) (field "esrExact" (TyCon "Bool")) (field "esrContext" (TyVar "c")) (field "esrProtected" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))) ())
(DData Public "SummaryFailure" ("c") ((variant "SummaryFailure" (ConNamed (field "esfLower" (TyCon "EffRow")) (field "esfUpper" (TyCon "EffRow")) (field "esfExact" (TyCon "Bool")) (field "esfContext" (TyVar "c"))))) ())
(DTypeSig true "newSolver" (TyFun (TyCon "Unit") (TyApp (TyCon "SummarySolver") (TyVar "c"))))
(DFunDef false "newSolver" (PWild) (ERecordCreate "SummarySolver" ((fa "essStack" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "hasSummaryScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyCon "Bool")))
(DFunDef false "hasSummaryScope" ((PVar "solver")) (EApp (EVar "isNonEmptyL") (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value")))
(DTypeSig true "openSummaryScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "openSummaryScope" ((PVar "solver") (PVar "owner") (PVar "level")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "solver") "essStack")) (EBinOp "::" (ERecordCreate "SummaryScope" ((fa "essOwner" (EVar "owner")) (fa "essEffvarFloor" (EVar "owner")) (fa "essLevel" (EVar "level")) (fa "essNodes" (EApp (EVar "Ref") (EVar "Tip"))) (fa "essExistentials" (EApp (EVar "Ref") (EVar "Tip"))) (fa "essAllowances" (EApp (EVar "Ref") (EVar "Tip"))) (fa "essRelations" (EApp (EVar "Ref") (EListLit))))) (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value"))))
(DTypeSig false "currentScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyApp (TyCon "SummaryScope") (TyVar "c"))))
(DFunDef false "currentScope" ((PVar "solver")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons (PVar "scope") PWild) () (EVar "scope")) (arm (PList) () (EApp (EVar "panic") (ELit (LString "effect summary outside an inference scope"))))))
(DTypeSig true "newSummary" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "Int") (TyCon "EffRow"))))
(DFunDef false "newSummary" ((PVar "solver") (PVar "id")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "ESummary") (EVar "id")) (EFieldAccess (EVar "scope") "essLevel")) (EFieldAccess (EVar "scope") "essOwner")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essNodes")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ERecordCreate "SummaryNode" ((fa "esnCell" (EVar "cell")) (fa "esnLowers" (EApp (EVar "Ref") (EListLit)))))) (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value")))) (DoExpr (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))))
(DTypeSig true "isOwnedSummary" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "isOwnedSummary" ((PVar "solver") (PCon "EffRow" (PList) (PCon "Some" (PVar "cell")))) (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EApp (EVar "currentScope") (EVar "solver")) "essNodes") "value")))
(DFunDef false "isOwnedSummary" (PWild PWild) (EVar "False"))
(DTypeSig true "registerExistential" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Unit"))))
(DFunDef false "registerExistential" ((PVar "solver") (PVar "cell")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons (PVar "scope") PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essExistentials")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "scope") "essExistentials") "value")))) (arm (PList) () (ELit LUnit))))
(DTypeSig true "registerValueAllowance" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Unit"))))
(DFunDef false "registerValueAllowance" ((PVar "solver") (PVar "cell")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons (PVar "scope") PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "registerExistential") (EVar "solver")) (EVar "cell"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essAllowances")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "scope") "essAllowances") "value")))))) (arm (PList) () (ELit LUnit))))
(DTypeSig true "recordBodyLower" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordBodyLower" ((PVar "solver") (PCon "EffRow" (PList) (PCon "Some" (PVar "cell"))) (PVar "lower")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoExpr (EMatch (EApp (EApp (EVar "M.get") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value")) (arm (PCon "Some" (PVar "node")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "esnLowers")) (EBinOp "::" (EVar "lower") (EFieldAccess (EFieldAccess (EVar "node") "esnLowers") "value")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "body lower bound assigned outside its summary owner"))))))))
(DFunDef false "recordBodyLower" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "body lower bound requires a summary slot"))))
(DTypeSig true "recordRelation" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyCon "Bool") (TyFun (TyVar "c") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))))
(DFunDef false "recordRelation" ((PVar "solver") (PVar "exact") (PVar "context") (PVar "lower") (PVar "upper")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "scope") "essRelations")) (EBinOp "::" (ERecordCreate "RowRelation" ((fa "esrLower" (EVar "lower")) (fa "esrUpper" (EVar "upper")) (fa "esrExact" (EVar "exact")) (fa "esrContext" (EVar "context")) (fa "esrProtected" (EVar "Tip")))) (EFieldAccess (EFieldAccess (EVar "scope") "essRelations") "value"))))))
(DData Private "SolveEdge" () ((variant "SolveEdge" (ConNamed (field "eseTarget" (TyCon "Int")) (field "eseCoverAtoms" (TyApp (TyCon "List") (TyCon "Atom"))) (field "eseCoverLeaves" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "eseExact" (TyCon "Bool"))))) ())
(DData Private "WorkNode" () ((variant "WorkNode" (ConNamed (field "ewnCell" (TyApp (TyCon "Ref") (TyCon "Effvar"))) (field "ewnAtoms" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Atom")))) (field "ewnLeaves" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "ewnPendingAtoms" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Atom")))) (field "ewnPendingLeaves" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (field "ewnEdges" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "SolveEdge"))))))) ())
(DData Private "SolveWork" () ((variant "SolveWork" (ConNamed (field "eswNodes" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode"))) (field "eswQueue" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int")))) (field "eswQueued" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "eswOrdinaryTargets" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "eswExactTargets" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "eswEscape" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))))) ())
(DTypeSig false "newWorkNode" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "WorkNode")))
(DFunDef false "newWorkNode" ((PVar "cell")) (ERecordCreate "WorkNode" ((fa "ewnCell" (EVar "cell")) (fa "ewnAtoms" (EApp (EVar "Ref") (EListLit))) (fa "ewnLeaves" (EApp (EVar "Ref") (EVar "Tip"))) (fa "ewnPendingAtoms" (EApp (EVar "Ref") (EListLit))) (fa "ewnPendingLeaves" (EApp (EVar "Ref") (EVar "Tip"))) (fa "ewnEdges" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig false "eligibleUpper" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool")))))
(DFunDef false "eligibleUpper" ((PVar "scope") (PVar "protected") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "level")) () (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "level") (EFieldAccess (EVar "scope") "essLevel")) (EBinOp ">" (EVar "id") (EFieldAccess (EVar "scope") "essEffvarFloor"))) (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "protected"))))) (arm (PCon "ESummary" PWild PWild PWild) () (EVar "False")) (arm PWild () (EVar "False"))))
(DTypeSig false "relationNodes" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode")))))))
(DFunDef false "relationNodes" (PWild PWild (PList) (PVar "nodes")) (EVar "nodes"))
(DFunDef false "relationNodes" ((PVar "scope") (PVar "protected") (PCons (PVar "rel") (PVar "rest")) (PVar "nodes")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EMethodRef "filter") (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "protected"))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))))) (DoLet false false (PVar "nodes2") (EMatch (EVar "candidates") (arm (PList (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "nodes")) (EVar "nodes") (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EApp (EVar "newWorkNode") (EVar "cell"))) (EVar "nodes")))) (arm PWild () (EVar "nodes")))) (arm PWild () (EVar "nodes")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "relationNodes") (EVar "scope")) (EVar "protected")) (EVar "rest")) (EVar "nodes2")))))
(DTypeSig false "enqueue" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "enqueue" ((PVar "work") (PVar "id")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswQueued") "value"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueued")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "eswQueued") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueue")) (EBinOp "::" (EVar "id") (EFieldAccess (EFieldAccess (EVar "work") "eswQueue") "value"))))) (ELit LUnit)))
(DTypeSig false "grow" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))))
(DFunDef false "grow" ((PVar "work") (PVar "id") (PVar "atoms") (PVar "leaves")) (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "eswNodes")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing effect equation vertex")))) (arm (PCon "Some" (PVar "node")) () (EBlock (DoLet false false (PVar "newAtoms") (EApp (EApp (EVar "atomsDiff") (EVar "atoms")) (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value"))) (DoLet false false (PVar "newLeaves") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") (PVar "cell")) (EIf (EApp (EApp (EVar "M.has") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "node") "ewnLeaves") "value")) (EVar "acc") (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (EVar "cell")) (EVar "acc"))))) (EVar "Tip")) (EVar "leaves"))) (DoLet false false PWild (EIf (EApp (EVar "isNonEmptyL") (EVar "newAtoms")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnAtoms")) (EApp (EApp (EVar "atomsUnion") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EVar "newAtoms")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingAtoms")) (EApp (EApp (EVar "atomsUnion") (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingAtoms") "value")) (EVar "newAtoms"))))) (ELit LUnit))) (DoLet false false (PVar "changedLeaves") (EMatch (EVar "newLeaves") (arm (PCon "Tip") () (EVar "False")) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnLeaves")) (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") (PVar "cell")) (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (EVar "cell")) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "node") "ewnLeaves") "value")) (EVar "newLeaves")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingLeaves")) (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") (PVar "cell")) (EApp (EApp (EApp (EVar "M.set") (EVar "key")) (EVar "cell")) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingLeaves") "value")) (EVar "newLeaves")))) (DoExpr (EVar "True")))))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "newAtoms")) (EVar "changedLeaves")) (EApp (EApp (EVar "enqueue") (EVar "work")) (EVar "id")) (ELit LUnit)))))))
(DTypeSig false "addEquation" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyCon "Unit"))))))))
(DFunDef false "addEquation" ((PVar "work") (PVar "target") (PVar "rhs") (PVar "coverAtoms") (PVar "coverLeaves") (PVar "exact")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "cells")) (EApp (EVar "rowFlat") (EVar "rhs"))) (DoLet false false (PVar "leaves") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "work")) (EVar "target")) (EVar "cells")) (EVar "coverAtoms")) (EVar "coverLeaves")) (EVar "exact")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "grow") (EVar "work")) (EVar "target")) (EApp (EApp (EApp (EFieldAccess (EVar "work") "eswEscape") (EVar "exact")) (EVar "atoms")) (EVar "coverAtoms"))) (EVar "leaves")))))
(DTypeSig false "addEdges" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar")))))))))))
(DFunDef false "addEdges" (PWild PWild (PList) PWild PWild PWild (PVar "leaves")) (EVar "leaves"))
(DFunDef false "addEdges" ((PVar "work") (PVar "target") (PCons (PVar "cell") (PVar "rest")) (PVar "coverAtoms") (PVar "coverLeaves") (PVar "exact") (PVar "leaves")) (EBlock (DoLet false false (PVar "id") (EApp (EVar "effvarId") (EVar "cell"))) (DoLet false false (PVar "leaves2") (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "coverLeaves")) (EVar "leaves") (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "eswNodes")) (arm (PCon "Some" (PVar "node")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnEdges")) (EBinOp "::" (ERecordCreate "SolveEdge" ((fa "eseTarget" (EVar "target")) (fa "eseCoverAtoms" (EVar "coverAtoms")) (fa "eseCoverLeaves" (EVar "coverLeaves")) (fa "eseExact" (EVar "exact")))) (EFieldAccess (EFieldAccess (EVar "node") "ewnEdges") "value")))) (DoExpr (EVar "leaves")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "leaves")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "work")) (EVar "target")) (EVar "rest")) (EVar "coverAtoms")) (EVar "coverLeaves")) (EVar "exact")) (EVar "leaves2")))))
(DTypeSig false "addBodyEquations" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyCon "List") (TyCon "SummaryNode")) (TyCon "Unit"))))
(DFunDef false "addBodyEquations" (PWild (PList)) (ELit LUnit))
(DFunDef false "addBodyEquations" ((PVar "work") (PCons (PVar "node") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "addLowers") (EVar "work")) (EApp (EVar "effvarId") (EFieldAccess (EVar "node") "esnCell"))) (EFieldAccess (EFieldAccess (EVar "node") "esnLowers") "value"))) (DoExpr (EApp (EApp (EVar "addBodyEquations") (EVar "work")) (EVar "rest")))))
(DTypeSig false "addLowers" (TyFun (TyCon "SolveWork") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "Unit")))))
(DFunDef false "addLowers" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "addLowers" ((PVar "work") (PVar "id") (PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEquation") (EVar "work")) (EVar "id")) (EVar "row")) (EListLit)) (EVar "Tip")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EVar "addLowers") (EVar "work")) (EVar "id")) (EVar "rest")))))
(DTypeSig false "leafSet" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "leafSet" ((PVar "cells")) (EApp (EApp (EVar "leafSetGo") (EVar "cells")) (EVar "Tip")))
(DTypeSig false "leafSetGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "leafSetGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "leafSetGo" ((PCons (PVar "cell") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "leafSetGo") (EVar "rest")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "addRelationEquations" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyCon "Unit"))))
(DFunDef false "addRelationEquations" (PWild (PList)) (ELit LUnit))
(DFunDef false "addRelationEquations" ((PVar "work") (PCons (PVar "rel") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "upperAtoms") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (DoLet false false (PVar "vertices") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "cell")) (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EVar "work") "eswNodes")))) (EVar "upperCells"))) (DoLet false false PWild (EMatch (EVar "vertices") (arm (PList (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EBlock (DoLet false false (PVar "fixed") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "c")) (EBinOp "/=" (EApp (EVar "effvarId") (EVar "c")) (EVar "id")))) (EVar "upperCells"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addEquation") (EVar "work")) (EVar "id")) (EFieldAccess (EVar "rel") "esrLower")) (EVar "upperAtoms")) (EApp (EVar "leafSet") (EVar "fixed"))) (EFieldAccess (EVar "rel") "esrExact"))) (DoExpr (EIf (EFieldAccess (EVar "rel") "esrExact") (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswExactTargets")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "eswExactTargets") "value"))) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswOrdinaryTargets")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "eswOrdinaryTargets") "value"))))))) (arm PWild () (ELit LUnit)))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "addRelationEquations") (EVar "work")) (EVar "rest")))))
(DTypeSig false "drainWork" (TyFun (TyCon "SolveWork") (TyCon "Unit")))
(DFunDef false "drainWork" ((PVar "work")) (EMatch (EFieldAccess (EFieldAccess (EVar "work") "eswQueue") "value") (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "id") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueue")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "eswQueued")) (EApp (EApp (EVar "M.delete") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswQueued") "value")))) (DoLet false false PWild (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "eswNodes")) (arm (PCon "Some" (PVar "node")) () (EBlock (DoLet false false (PVar "atoms") (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingAtoms") "value")) (DoLet false false (PVar "leaves") (EFieldAccess (EFieldAccess (EVar "node") "ewnPendingLeaves") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingAtoms")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "node") "ewnPendingLeaves")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "propagate") (EVar "work")) (EVar "atoms")) (EVar "leaves")) (EFieldAccess (EFieldAccess (EVar "node") "ewnEdges") "value"))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing queued effect equation")))))) (DoExpr (EApp (EVar "drainWork") (EVar "work")))))))
(DTypeSig false "propagate" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "SolveEdge")) (TyCon "Unit"))))))
(DFunDef false "propagate" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "propagate" ((PVar "work") (PVar "atoms") (PVar "delta") (PCons (PVar "edge") (PVar "rest"))) (EBlock (DoLet false false (PVar "leaves") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "id") (PVar "cell")) (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EVar "edge") "eseCoverLeaves")) (EVar "acc") (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "acc"))))) (EVar "Tip")) (EVar "delta"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "grow") (EVar "work")) (EFieldAccess (EVar "edge") "eseTarget")) (EApp (EApp (EApp (EFieldAccess (EVar "work") "eswEscape") (EFieldAccess (EVar "edge") "eseExact")) (EVar "atoms")) (EFieldAccess (EVar "edge") "eseCoverAtoms"))) (EVar "leaves"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "propagate") (EVar "work")) (EVar "atoms")) (EVar "delta")) (EVar "rest")))))
(DTypeSig false "linkSolutions" (TyFun (TyCon "Int") (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "WorkNode")) (TyCon "Unit")))))
(DFunDef false "linkSolutions" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "linkSolutions" ((PVar "owner") (PVar "makeJoin") (PCons (PVar "node") (PVar "rest"))) (EBlock (DoLet false false (PVar "row") (EMatch (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "node") "ewnLeaves") "value")) (arm (PList) () (EApp (EApp (EVar "EffRow") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EVar "None"))) (arm (PList (PVar "cell")) () (EApp (EApp (EVar "EffRow") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EApp (EVar "Some") (EVar "cell")))) (arm (PVar "cells") () (EApp (EApp (EVar "EffRow") (EFieldAccess (EFieldAccess (EVar "node") "ewnAtoms") "value")) (EApp (EVar "Some") (EApp (EVar "makeJoin") (EVar "cells"))))))) (DoLet false false PWild (EMatch (EUnOp "!" (EFieldAccess (EVar "node") "ewnCell")) (arm (PCon "ESummary" PWild PWild PWild) () (EApp (EApp (EApp (EVar "solveSummaryCell") (EVar "owner")) (EFieldAccess (EVar "node") "ewnCell")) (EVar "row"))) (arm PWild () (EApp (EApp (EVar "linkRow") (EFieldAccess (EVar "node") "ewnCell")) (EVar "row"))))) (DoExpr (EApp (EApp (EApp (EVar "linkSolutions") (EVar "owner")) (EVar "makeJoin")) (EVar "rest")))))
(DTypeSig false "missingLeaves" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "missingLeaves" ((PList) PWild) (EVar "False"))
(DFunDef false "missingLeaves" ((PCons (PVar "cell") (PVar "rest")) (PVar "upper")) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "upper"))) (EApp (EApp (EVar "missingLeaves") (EVar "rest")) (EVar "upper"))))
(DTypeSig false "validateRelations" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyCon "List") (TyApp (TyCon "SummaryFailure") (TyVar "c"))))))))
(DFunDef false "validateRelations" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "validateRelations" ((PVar "solver") (PVar "protected") (PVar "escape") (PCons (PVar "rel") (PVar "rest"))) (EIf (EBinOp "||" (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrLower")) (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrUpper"))) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PCons (PVar "parent") PWild)) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrUpper"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essRelations")) (EBinOp "::" (ERecordCreate "RowRelation" ((fa "esrLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esrUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esrExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esrContext" (EFieldAccess (EVar "rel") "esrContext")) (fa "esrProtected" (EVar "protected")))) (EFieldAccess (EFieldAccess (EVar "parent") "essRelations") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "protected")) (EVar "escape")) (EVar "rest"))))) (arm PWild () (EBinOp "::" (ERecordCreate "SummaryFailure" ((fa "esfLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esfUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esfExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esfContext" (EFieldAccess (EVar "rel") "esrContext")))) (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "protected")) (EVar "escape")) (EVar "rest"))))) (EBlock (DoLet false false (PTuple (PVar "lowerAtoms") (PVar "lowerCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false (PTuple (PVar "upperAtoms") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (DoLet false false (PVar "failures") (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "protected")) (EVar "escape")) (EVar "rest"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "escape") (EFieldAccess (EVar "rel") "esrExact")) (EVar "lowerAtoms")) (EVar "upperAtoms"))) (EApp (EApp (EVar "missingLeaves") (EVar "lowerCells")) (EApp (EVar "leafSet") (EVar "upperCells")))) (EBinOp "::" (ERecordCreate "SummaryFailure" ((fa "esfLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esfUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esfExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esfContext" (EFieldAccess (EVar "rel") "esrContext")))) (EVar "failures")) (EVar "failures"))))))
(DTypeSig false "retainRowAt" (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "retainRowAt" ((PVar "level") (PVar "row")) (EApp (EApp (EVar "retainLeavesAt") (EVar "level")) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))
(DTypeSig false "retainLeavesAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))
(DFunDef false "retainLeavesAt" (PWild (PList)) (ELit LUnit))
(DFunDef false "retainLeavesAt" ((PVar "level") (PCons (PVar "cell") (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "old")) () (EIf (EBinOp ">" (EVar "old") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "level"))) (ELit LUnit))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "retainLeavesAt") (EVar "level")) (EVar "rest")))))
(DTypeSig true "closeSummaryScope" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyApp (TyCon "SummaryFailure") (TyVar "c")))))))))))
(DFunDef false "closeSummaryScope" ((PVar "solver") (PVar "protected") (PVar "retained") (PVar "borrowed") (PVar "escape") (PVar "makeJoin") (PVar "makeResidual")) (EBlock (DoLet false false (PVar "scope") (EApp (EVar "currentScope") (EVar "solver"))) (DoLet false false (PVar "summaries") (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value"))) (DoLet false false (PVar "untransferred") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "scope") "essRelations") "value")))) (DoLet false false (PVar "relationRoots") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "rel")) (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "roots") (PVar "id") PWild) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EVar "roots")))) (EVar "acc")) (EFieldAccess (EVar "rel") "esrProtected")))) (EVar "protected")) (EVar "untransferred"))) (DoLet false false (PVar "frozen") (EVar "relationRoots")) (DoLet false false (PVar "initialAllowances") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essAllowances") "value"))))) (DoLet false false (PVar "outward") (EApp (EVar "leafSet") (EApp (EApp (EMethodRef "filter") (EApp (EVar "outwardAllowance") (EVar "scope"))) (EVar "initialAllowances")))) (DoLet false false (PVar "pending") (EApp (EApp (EApp (EApp (EVar "transferAllowanceRelations") (EVar "solver")) (EVar "frozen")) (EVar "outward")) (EVar "untransferred"))) (DoLet false false PWild (EApp (EApp (EVar "transferAllowances") (EVar "solver")) (EVar "initialAllowances"))) (DoLet false false (PVar "retained2") (EApp (EApp (EApp (EApp (EVar "collapseInclusionCycles") (EVar "scope")) (EVar "frozen")) (EVar "retained")) (EVar "pending"))) (DoLet false false (PVar "allowanceCells") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essAllowances") "value"))))) (DoLet false false (PVar "allowanceRoots") (EApp (EVar "leafSet") (EVar "allowanceCells"))) (DoLet false false (PVar "inputRoots") (EApp (EVar "leafSet") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EVar "borrowed")))))) (DoLet false false (PVar "relations") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "pending"))) (DoLet false false (PVar "summaryNodes") (EApp (EApp (EMethodRef "map") (ELam ((PVar "node")) (EApp (EVar "newWorkNode") (EFieldAccess (EVar "node") "esnCell")))) (EFieldAccess (EFieldAccess (EVar "scope") "essNodes") "value"))) (DoLet false false (PVar "choices") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EFieldAccess (EFieldAccess (EVar "scope") "essExistentials") "value"))))) (DoLet false false (PVar "initial") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "nodes") (PVar "cell")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "frozen")) (EVar "cell")) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "retained2"))) (EBinOp "&&" (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "allowanceRoots")) (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "inputRoots")))))) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "cell"))) (EApp (EVar "newWorkNode") (EVar "cell"))) (EVar "nodes")) (EVar "nodes")))) (EVar "summaryNodes")) (EVar "choices"))) (DoLet false false (PVar "leastFrozen") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "frozen")) (EVar "retained2"))) (DoLet false false (PVar "nodes") (EApp (EApp (EApp (EApp (EVar "relationNodes") (EVar "scope")) (EVar "leastFrozen")) (EVar "relations")) (EVar "initial"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "solveEquations") (EFieldAccess (EVar "scope") "essOwner")) (EVar "nodes")) (EVar "summaries")) (EVar "relations")) (EVar "Tip")) (EVar "escape")) (EVar "makeJoin")) (EVar "makeResidual"))) (DoLet false false (PVar "residual0") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "relations"))) (DoLet false false (PVar "local") (EApp (EApp (EMethodRef "filter") (EVar "summaryFreeRelation")) (EVar "residual0"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "collapseInclusionCycles") (EVar "scope")) (EVar "frozen")) (EVar "retained2")) (EVar "local"))) (DoLet false false (PVar "residual") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "local"))) (DoLet false false (PVar "retainedNodes") (EApp (EApp (EApp (EApp (EVar "relationNodes") (EVar "scope")) (EVar "frozen")) (EVar "residual")) (EVar "Tip"))) (DoLet false false (PVar "borrowedRoots") (EApp (EVar "leafSet") (EApp (EVar "snd") (EApp (EApp (EVar "rowFlatMembers") (EListLit)) (EApp (EVar "M.values") (EVar "borrowed")))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "solveEquations") (EFieldAccess (EVar "scope") "essOwner")) (EVar "retainedNodes")) (EListLit)) (EVar "residual")) (EVar "borrowedRoots")) (EVar "escape")) (EVar "makeJoin")) (EVar "makeResidual"))) (DoLet false false (PVar "unproven") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "rel")) (EApp (EVar "not") (EApp (EApp (EVar "relationProven") (EVar "escape")) (EVar "rel"))))) (EVar "residual0"))) (DoLet false false (PVar "failures") (EApp (EApp (EApp (EApp (EVar "validateRelations") (EVar "solver")) (EVar "frozen")) (EVar "escape")) (EVar "unproven"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "solver") "essStack")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PVar "rest")) () (EVar "rest")) (arm (PList) () (EApp (EVar "panic") (ELit (LString "effect scope stack underflow"))))))) (DoExpr (EVar "failures"))))
(DTypeSig false "outwardAllowance" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool"))))
(DFunDef false "outwardAllowance" ((PVar "scope") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "level")) () (EBinOp "||" (EBinOp "<" (EVar "level") (EFieldAccess (EVar "scope") "essLevel")) (EBinOp "<=" (EVar "id") (EFieldAccess (EVar "scope") "essEffvarFloor")))) (arm PWild () (EVar "False"))))
(DData Private "TransferWork" () ((variant "TransferWork" (ConNamed (field "etwRows" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "etwUsers" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))) (field "etwSelected" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))) (field "etwSeen" (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))))) ())
(DTypeSig false "relationRoots" (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "relationRoots" ((PVar "rel")) (EApp (EApp (EVar "leafSetGo") (EApp (EVar "snd") (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper")))) (EApp (EVar "leafSet") (EApp (EVar "snd") (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower"))))))
(DTypeSig false "indexTransferRelations" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyCon "TransferWork"))))))
(DFunDef false "indexTransferRelations" ((PList) PWild (PVar "rows") (PVar "users")) (ERecordCreate "TransferWork" ((fa "etwRows" (EVar "rows")) (fa "etwUsers" (EVar "users")) (fa "etwSelected" (EApp (EVar "Ref") (EVar "Tip"))) (fa "etwSeen" (EApp (EVar "Ref") (EVar "Tip"))))))
(DFunDef false "indexTransferRelations" ((PCons (PVar "rel") (PVar "rest")) (PVar "id") (PVar "rows") (PVar "users")) (EBlock (DoLet false false (PVar "roots") (EApp (EVar "relationRoots") (EVar "rel"))) (DoLet false false (PVar "users2") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "root") PWild) (EApp (EApp (EApp (EVar "M.set") (EVar "root")) (EBinOp "::" (EVar "id") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "root")) (EVar "acc"))))) (EVar "acc")))) (EVar "users")) (EVar "roots"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "indexTransferRelations") (EVar "rest")) (EBinOp "+" (EVar "id") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "roots")) (EVar "rows"))) (EVar "users2")))))
(DTypeSig false "selectTransferRows" (TyFun (TyCon "TransferWork") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "selectTransferRows" (PWild (PList)) (ELit LUnit))
(DFunDef false "selectTransferRows" ((PVar "work") (PCons (PVar "root") (PVar "rest"))) (EIf (EApp (EApp (EVar "M.has") (EVar "root")) (EFieldAccess (EFieldAccess (EVar "work") "etwSeen") "value")) (EApp (EApp (EVar "selectTransferRows") (EVar "work")) (EVar "rest")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "etwSeen")) (EApp (EApp (EApp (EVar "M.set") (EVar "root")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "etwSeen") "value")))) (DoLet false false (PVar "next") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "pending") (PVar "id")) (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "etwSelected") "value")) (EVar "pending") (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "work") "etwSelected")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "work") "etwSelected") "value")))) (DoExpr (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "key") PWild) (EBinOp "::" (EVar "key") (EVar "acc")))) (EVar "pending")) (EApp (EApp (EVar "optionOr") (EVar "Tip")) (EApp (EApp (EVar "M.get") (EVar "id")) (EFieldAccess (EVar "work") "etwRows"))))))))) (EVar "rest")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "root")) (EFieldAccess (EVar "work") "etwUsers"))))) (DoExpr (EApp (EApp (EVar "selectTransferRows") (EVar "work")) (EVar "next"))))))
(DTypeSig false "transferAllowanceRelations" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))))))))
(DFunDef false "transferAllowanceRelations" ((PVar "solver") (PVar "protected") (PVar "outward") (PVar "relations")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PCons (PVar "parent") PWild)) () (EMatch (EVar "outward") (arm (PCon "Tip") () (EVar "relations")) (arm PWild () (EBlock (DoLet false false (PVar "work") (EApp (EApp (EApp (EApp (EVar "indexTransferRelations") (EVar "relations")) (ELit (LInt 0))) (EVar "Tip")) (EVar "Tip"))) (DoLet false false PWild (EApp (EApp (EVar "selectTransferRows") (EVar "work")) (EApp (EVar "M.keys") (EVar "outward")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "partitionTransferred") (EVar "parent")) (EVar "protected")) (EFieldAccess (EFieldAccess (EVar "work") "etwSelected") "value")) (ELit (LInt 0))) (EVar "relations"))))))) (arm PWild () (EVar "relations"))))
(DTypeSig false "partitionTransferred" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c")))))))))
(DFunDef false "partitionTransferred" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "partitionTransferred" ((PVar "parent") (PVar "protected") (PVar "selected") (PVar "id") (PCons (PVar "rel") (PVar "rest"))) (EIf (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "selected")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false PWild (EApp (EApp (EVar "retainRowAt") (EFieldAccess (EVar "parent") "essLevel")) (EFieldAccess (EVar "rel") "esrUpper"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essRelations")) (EBinOp "::" (ERecordCreate "RowRelation" ((fa "esrLower" (EFieldAccess (EVar "rel") "esrLower")) (fa "esrUpper" (EFieldAccess (EVar "rel") "esrUpper")) (fa "esrExact" (EFieldAccess (EVar "rel") "esrExact")) (fa "esrContext" (EFieldAccess (EVar "rel") "esrContext")) (fa "esrProtected" (EVar "protected")))) (EFieldAccess (EFieldAccess (EVar "parent") "essRelations") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "partitionTransferred") (EVar "parent")) (EVar "protected")) (EVar "selected")) (EBinOp "+" (EVar "id") (ELit (LInt 1)))) (EVar "rest")))) (EBinOp "::" (EVar "rel") (EApp (EApp (EApp (EApp (EApp (EVar "partitionTransferred") (EVar "parent")) (EVar "protected")) (EVar "selected")) (EBinOp "+" (EVar "id") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "transferAllowances" (TyFun (TyApp (TyCon "SummarySolver") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))
(DFunDef false "transferAllowances" ((PVar "solver") (PVar "cells")) (EMatch (EFieldAccess (EFieldAccess (EVar "solver") "essStack") "value") (arm (PCons PWild (PCons (PVar "parent") PWild)) () (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "level")) () (EIf (EBinOp "<=" (EVar "level") (EFieldAccess (EVar "parent") "essLevel")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essExistentials")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "parent") "essExistentials") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "parent") "essAllowances")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EFieldAccess (EFieldAccess (EVar "parent") "essAllowances") "value"))))) (ELit LUnit))) (arm PWild () (ELit LUnit))))) (ELit LUnit)) (EVar "cells"))) (arm PWild () (ELit LUnit))))
(DTypeSig false "summaryFreeRelation" (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyCon "Bool")))
(DFunDef false "summaryFreeRelation" ((PVar "rel")) (EApp (EVar "not") (EBinOp "||" (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrLower")) (EApp (EVar "rowHasSummary") (EFieldAccess (EVar "rel") "esrUpper")))))
(DTypeSig false "solveEquations" (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "WorkNode")) (TyFun (TyApp (TyCon "List") (TyCon "SummaryNode")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))))))))
(DFunDef false "solveEquations" ((PVar "owner") (PVar "nodes") (PVar "summaries") (PVar "relations") (PVar "borrowed") (PVar "escape") (PVar "makeJoin") (PVar "makeResidual")) (EBlock (DoLet false false (PVar "work") (ERecordCreate "SolveWork" ((fa "eswNodes" (EVar "nodes")) (fa "eswQueue" (EApp (EVar "Ref") (EListLit))) (fa "eswQueued" (EApp (EVar "Ref") (EVar "Tip"))) (fa "eswOrdinaryTargets" (EApp (EVar "Ref") (EVar "Tip"))) (fa "eswExactTargets" (EApp (EVar "Ref") (EVar "Tip"))) (fa "eswEscape" (EVar "escape"))))) (DoLet false false PWild (EApp (EApp (EVar "addBodyEquations") (EVar "work")) (EVar "summaries"))) (DoLet false false PWild (EApp (EApp (EVar "addRelationEquations") (EVar "work")) (EVar "relations"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam (PWild (PVar "id") (PVar "node")) (EApp (EApp (EApp (EApp (EApp (EVar "seedBorrowedResidual") (EVar "work")) (EVar "borrowed")) (EVar "makeResidual")) (EVar "id")) (EVar "node")))) (ELit LUnit)) (EVar "nodes"))) (DoLet false false PWild (EApp (EVar "drainWork") (EVar "work"))) (DoExpr (EApp (EApp (EApp (EVar "linkSolutions") (EVar "owner")) (EVar "makeJoin")) (EApp (EVar "M.values") (EVar "nodes"))))))
(DTypeSig false "seedBorrowedResidual" (TyFun (TyCon "SolveWork") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "Int") (TyFun (TyCon "WorkNode") (TyCon "Unit")))))))
(DFunDef false "seedBorrowedResidual" ((PVar "work") (PVar "borrowed") (PVar "makeResidual") (PVar "id") (PVar "node")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "M.has") (EVar "id")) (EVar "borrowed")) (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswOrdinaryTargets") "value"))) (EApp (EVar "not") (EApp (EApp (EVar "M.has") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "work") "eswExactTargets") "value")))) (EBlock (DoLet false false (PVar "residual") (EApp (EVar "makeResidual") (EApp (EVar "inclusionLevel") (EFieldAccess (EVar "node") "ewnCell")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "grow") (EVar "work")) (EVar "id")) (EListLit)) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "residual"))) (EVar "residual")) (EVar "Tip"))))) (ELit LUnit)))
(DTypeSig false "collapseInclusionCycles" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "RowRelation") (TyVar "c"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "collapseInclusionCycles" ((PVar "scope") (PVar "rigid") (PVar "retained") (PVar "relations")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "singletonInclusion") (EVar "scope")) (EVar "rigid"))) (EVar "relations"))) (DoExpr (EMatch (EVar "pairs") (arm (PList) () (EVar "retained")) (arm PWild () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "a"))) (EVar "a")) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "effvarId") (EVar "b"))) (EVar "b")) (EVar "acc"))))) (EVar "Tip")) (EVar "pairs"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "M.mapWithKey") (ELam ((PVar "id") PWild) (EApp (EVar "intToString") (EVar "id")))) (EVar "cells"))) (DoLet false false (PVar "byName") (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "id") (PVar "cell")) (EApp (EApp (EApp (EVar "M.set") (EApp (EApp (EVar "inclusionName") (EVar "names")) (EVar "id"))) (EVar "cell")) (EVar "acc")))) (EVar "Tip")) (EVar "cells"))) (DoLet false false (PVar "edges") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "from") (EApp (EApp (EVar "inclusionName") (EVar "names")) (EApp (EVar "effvarId") (EVar "a")))) (DoLet false false (PVar "to") (EApp (EApp (EVar "inclusionName") (EVar "names")) (EApp (EVar "effvarId") (EVar "b")))) (DoExpr (EApp (EApp (EApp (EVar "M.set") (EVar "from")) (EBinOp "::" (EVar "to") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "from")) (EVar "acc"))))) (EVar "acc")))))) (EVar "Tip")) (EVar "pairs"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "collapseInclusionClass") (EVar "byName"))) (EVar "retained")) (EApp (EApp (EVar "tarjanSCCs") (EApp (EVar "M.values") (EVar "names"))) (EVar "edges"))))))))))
(DTypeSig false "singletonInclusion" (TyFun (TyApp (TyCon "SummaryScope") (TyVar "c")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "singletonInclusion" ((PVar "scope") (PVar "rigid") (PVar "rel")) (EMatch (ETuple (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (arm (PTuple (PTuple (PList) (PList (PVar "a"))) (PTuple (PList) (PList (PVar "b")))) () (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "rigid")) (EVar "a")) (EApp (EApp (EApp (EVar "eligibleUpper") (EVar "scope")) (EVar "rigid")) (EVar "b"))) (EListLit (ETuple (EVar "a") (EVar "b"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "inclusionName" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "inclusionName" ((PVar "names") (PVar "id")) (EMatch (EApp (EApp (EVar "M.get") (EVar "id")) (EVar "names")) (arm (PCon "Some" (PVar "name")) () (EVar "name")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing inclusion graph name"))))))
(DTypeSig false "inclusionCell" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "inclusionCell" ((PVar "cells") (PVar "name")) (EMatch (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EVar "cell")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "missing inclusion graph cell"))))))
(DTypeSig false "inclusionLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Int")))
(DFunDef false "inclusionLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" PWild (PVar "level")) () (EVar "level")) (arm PWild () (EApp (EVar "panic") (ELit (LString "non-flexible inclusion graph vertex"))))))
(DTypeSig false "collapseInclusionClass" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "collapseInclusionClass" (PWild (PVar "retained") (PList)) (EVar "retained"))
(DFunDef false "collapseInclusionClass" (PWild (PVar "retained") (PList PWild)) (EVar "retained"))
(DFunDef false "collapseInclusionClass" ((PVar "cells") (PVar "retained") (PCons (PVar "first") (PVar "rest"))) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EMethodRef "map") (EApp (EVar "inclusionCell") (EVar "cells"))) (EBinOp "::" (EVar "first") (EVar "rest")))) (DoLet false false (PVar "initial") (EApp (EApp (EVar "inclusionCell") (EVar "cells")) (EVar "first"))) (DoLet false false (PTuple (PVar "representative") (PVar "level") (PVar "keep")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "best") (PVar "level") (PVar "keep")) (PVar "cell")) (EBlock (DoLet false false (PVar "retainedCell") (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "retained"))) (DoExpr (ETuple (EIf (EBinOp "&&" (EVar "retainedCell") (EApp (EVar "not") (EVar "keep"))) (EVar "cell") (EVar "best")) (EApp (EApp (EMethodRef "min") (EVar "level")) (EApp (EVar "inclusionLevel") (EVar "cell"))) (EBinOp "||" (EVar "keep") (EVar "retainedCell"))))))) (ETuple (EVar "initial") (EApp (EVar "inclusionLevel") (EVar "initial")) (EApp (EApp (EVar "M.has") (EApp (EVar "effvarId") (EVar "initial"))) (EVar "retained")))) (EVar "members"))) (DoLet false false (PVar "id") (EApp (EVar "effvarId") (EVar "representative"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "representative")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "level")))) (DoLet false false PWild (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cell")) (EIf (EBinOp "/=" (EApp (EVar "effvarId") (EVar "cell")) (EVar "id")) (EApp (EApp (EVar "linkRow") (EVar "cell")) (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "representative")))) (ELit LUnit)))) (ELit LUnit)) (EVar "members"))) (DoExpr (EIf (EVar "keep") (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (ELit LUnit)) (EVar "retained")) (EVar "retained")))))
(DTypeSig false "relationProven" (TyFun (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))) (TyFun (TyApp (TyCon "RowRelation") (TyVar "c")) (TyCon "Bool"))))
(DFunDef false "relationProven" ((PVar "escape") (PVar "rel")) (EBlock (DoLet false false (PTuple (PVar "lowerAtoms") (PVar "lowerCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrLower"))) (DoLet false false (PTuple (PVar "upperAtoms") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "rel") "esrUpper"))) (DoExpr (EBinOp "&&" (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "escape") (EFieldAccess (EVar "rel") "esrExact")) (EVar "lowerAtoms")) (EVar "upperAtoms"))) (EApp (EVar "not") (EApp (EApp (EVar "missingLeaves") (EVar "lowerCells")) (EApp (EVar "leafSet") (EVar "upperCells"))))))))
