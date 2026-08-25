# Autonomous delivery loop

Use this sequence for a complete hook, a material adaptation, or any request spanning dependent
surfaces. A focused edit uses `inspect → implement → check` without creating workflow artifacts.

## 1. Establish the ledger

Inspect current Git state and focused failures. For a multi-step build, keep one ignored
`.workflow/ledger.md` containing only:

- parent-gate status;
- verified evidence;
- open assumptions;
- accepted and rejected outputs;
- current frontier and blocker;
- next verifier.

Update the ledger after each material observation. It is resumable state, not a second specification
or a narrative diary.

This step is complete when another session can identify the next action and distinguish verified
facts from assumptions without replaying completed work.

## 2. Freeze one contract

Inspect the repository, then use the request or an existing task contract when it is already
checkable. Otherwise write one compact `SPEC.md`. The one contract includes only:

- observable product behavior;
- economic, custody, identity, and authority invariants;
- supported swap, token, NFT, randomness, dapp, and deployment branches;
- target-chain gas assumptions and a maximum-transaction budget for scalable public paths;
- behavioral proof for each material invariant;
- explicit external gaps and the stopping boundary.

For a port, account for every material reference behavior before production edits. Keep protected
invariants in this one contract rather than a parallel design report.

This step is complete when every decision that could change implementation or proof is observable
and checkable, while implementation mechanics remain with the owning code.

## 3. Build vertical slices

Advance one end-to-end path at a time:

```text
requirement → failing real-boundary proof → production change → focused green
```

Start with compiling interfaces and one real PoolManager interaction. Add the nearest rollback or
hostile proof before opening another branch. When an interface changes, update its contract,
deployment script, manifest schema, scenario adapter, and UI consumer in the same slice.

When a public call or deployment grows with entries, participants, lots, claims, or storage writes,
run the early feasibility gate in `docs/gas.md` after its first correct slice. The next product
surface waits until the maximum bound fits the declared budget or the operation is bounded and
resumable.

A slice is complete when the production owner—not a mock or duplicate helper—passes its focused
real-boundary proof and every consumer of its changed interface is synchronized.

## 4. Review and repair

After focused implementation is green, use this stage when the material-review trigger in
`AGENTS.md` fires or the task contract requires it:

1. Give the reviewer the exact contract, candidate diff, and proof commands. Each finding must name
   a source anchor, violated requirement, impact, and reproducer or missing proof.
2. Accept or reject every finding with a reason. Assign accepted findings to one writer with a
   bounded file surface.
3. Require the focused proof to go red for the reported cause, then green after repair.
4. Re-review changed source. Repeat only when new evidence changes the hypothesis.
5. Give a fresh verifier read-only source and exact commands. The verifier reports evidence and
   leaves repair to the writer.

Use one writer in a shared worktree. Parallel writers need isolated worktrees and frozen interfaces.
Child results are evidence; the primary agent owns the completion decision.

This step is complete when every finding is dispositioned, accepted repairs have red-to-green
proof, and an independent verifier has checked the final candidate.

## 5. Run gates and classify

Complete the applicable local gate in `docs/testing.md`. A product with router, wallet, scenario, or
UI behavior also completes `docs/devnet.md`. Any source change after material review requires fresh
review and verification.

Classify the result:

- **Complete:** requested behavior, applicable local gates, and required devnet evidence are green.
- **Escalated:** a user decision or new authority is the next action.
- **Blocked:** a technical or external limitation leaves no autonomous action.

For multi-step work, classification is complete when the ledger records final evidence, unresolved
external actions, and exactly one outcome. A focused edit records those facts in its handoff.
