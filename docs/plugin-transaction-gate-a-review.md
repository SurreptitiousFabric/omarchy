# Gate A review: smallest staged transaction

## Decision summary

This review revises the O-2 contract using the O-3 feasibility evidence. The race finding and no-precommit-load property remain unchanged; protocol complexity that does not enforce that property is removed.

| Question | Decision | Reason |
| --- | --- | --- |
| Full raw configuration hash | Evidence only, not a hard commit precondition. Hard-bind the accepted source identity and exact plugin-reference projection. | An unrelated option can change raw bytes without changing whether this plugin is referenced. Rejecting that update adds availability failures without protecting the plugin boundary. Before/after raw hashes remain useful evidence. |
| Registry generation | Evidence on the gated rescan, not a stage-to-commit precondition. | The transaction's own rescan changes registry generation. The security-relevant comparison is the source and plugin projection; the acknowledged generation identifies the rescan result. |
| Secret tokens | Keep one caller-generated `operationToken`; store only its hash; remove `candidateToken`. | The caller can retry a lost stage response without Omarchy persisting recoverable bearer material. The durable operation record already binds the candidate tree identity, so a second secret enforces no additional property. |
| Stale before mutation | Durable `REJECTED` state with typed stale status and rollback `not-applicable`. | No prior state was restored, so `ROLLED_BACK` would be false terminology. |
| Rolled back | Use only after actual filesystem or eligibility restoration. | A Quo and operators must be able to distinguish rejection from compensating action. |
| Public versus internal states | Keep exact durable journal states available for status and recovery, but require external decision logic to use stable typed terminal status and multidimensional facts. | Recovery needs precision, while ordinary consumers should not infer success from an intermediate transition name. |

## Plugin-reference projection

Omarchy computes the projection from the accepted parsed schema-v1 configuration for one exact plugin ID. It contains every matching reference kind and stable logical location used by current eligibility decisions: selected bar, bar-layout entries, and top-level plugin entries. Entries are canonicalized, sorted by encoded bytes, and hashed. One central schema-v1 eligibility API MUST produce this projection and the accepted source and MUST be consulted by every third-party loader and transaction release decision. Bash, the C filesystem helper, and external clients MUST NOT maintain a second approximate parser. O-4/O-6 tests must prove that every loader eligibility source contributes to the projection and that release consumes the same authoritative snapshot.

The accepted configuration source identity and projection hash are hard preconditions at stage, immediately before exposure, after exposure, and immediately before release. `require-unreferenced` additionally requires an empty projection throughout. `preserve-observed` requires exact projection equality, not merely the same referenced/unreferenced boolean.

Raw source SHA-256 is recorded at each observation. A raw change with an unchanged source and projection is reported in the receipt but does not reject commit. A source change, malformed configuration, projection change, or reference-policy violation fails closed. This avoids false staleness for unrelated settings while preventing a same-plugin reference change from crossing the release boundary unnoticed.

This remains coordination, not protection from a hostile same-UID process. A same-UID process can mutate the file again after release.

## Minimal shell contract

The transaction helper needs only three operation-bound shell actions plus read-only reconciliation:

1. `gatePlugin(operationId, pluginId)` installs or confirms the durable gate, unloads existing instances for that plugin, and acknowledges only when every schema-v1 loader consults the gate and the plugin is ineligible. Repeating the exact call is idempotent; a conflicting operation returns busy.
2. `rescanGated(operationId, pluginId, expectedTree)` performs or joins a registry rescan while the gate remains authoritative. It acknowledges the shell instance, registry generation, expected plugin discovery result, and continued ineligibility. It does not execute the plugin or establish safety.
3. `releasePlugin(operationId, pluginId, expectedTree, generation)` conditionally removes only the matching gate. While that gate remains authoritative, the shell obtains the current accepted source and projection from its central eligibility API, retrieves the operation-bound expectations through `operationId`, enforces the reference policy, and verifies `expectedTree` plus the gated-rescan generation. Comparison and gate removal form one shell-controlled decision with no intervening configuration processing. A mismatch retains the gate and returns a typed failure; because exposure may already have occurred, the transaction proceeds to rollback or recovery, never `REJECTED`. A helper-side check immediately before this call is insufficient. A successful acknowledgement reports publication of the resulting registry state, not successful plugin execution.
4. `transactionPluginState(operationId, pluginId)` is read-only startup/recovery reconciliation. On shell start, nonterminal durable gates are loaded before any third-party entry point can be selected.

Ordinary plugin-directory and configuration watcher events may coalesce or request rescans, but they cannot bypass a matching durable gate. The transport and QML method names may change during O-6; these semantics are the contract.

## Result vocabulary

External results expose stable facts rather than the complete internal journal state:

- `committed`: exact candidate released after acknowledged gated rescan;
- `rejected`: no live namespace or eligibility mutation occurred, with a typed stale reason;
- `aborted`: inert stage explicitly cancelled;
- `rolled-back`: an actual prior filesystem or eligibility state was restored;
- `indeterminate`: recovery is pending and the affected plugin remains gated if exposure may have occurred;
- `manual-attention`: exact automated completion or restoration cannot be proved and the plugin remains blocked.

Candidate, previous/live tree, configuration source, raw hashes, projection hashes, reference states, rescan acknowledgement, load eligibility, rollback, and recovery remain separate dimensions.

## Reviewable implementation sequence

The existing issues remain one bounded run each, but upstream presentation should use small commits with explicit seams:

1. O-4: canonical tree identity library, hostile-tree tests, then inert import using that library. No shell changes.
2. O-5: durable operation record and replay/conflict tests. No live mutation.
3. O-6: authoritative eligibility predicate, startup gate restoration, and gate/unload acknowledgement; then gated rescan/release acknowledgement as a separate shell commit.
4. O-7: capability/stage/status/abort wrapper and protocol tests.
5. O-8: install no-replace commit path first; update exchange/retained rollback second; result mapping and failure paths third.
6. O-9: recovery matrix and fault-injection expansions without unrelated command UX.
7. O-10: route existing add first and update second through the stable transaction.
8. O-11/O-12: adversarial automated evidence and disposable-VM real-shell evidence remain separate commits and review claims.

The eventual upstream PR may be one focused PR if maintainers prefer, but its commit series must remain reviewable in this order. If maintainers request multiple PRs, the split should follow these dependency seams rather than rewriting an already-reviewed monolith.

## Gate A invariants and nonclaims

At every step a reviewer must be able to answer:

- Before exposure, the candidate is outside ordinary discovery.
- From acknowledged gate through conditional release or exact rollback, every loader treats the plugin as ineligible.
- Conditional release obtains the same authoritative source/projection snapshot used by loaders and compares it with operation-bound expectations before removing the gate, with no intervening configuration processing.
- The operation record binds one plugin, candidate tree, expected active tree or absence, configuration source, exact reference projection, reference policy, and one capability token.
- Every namespace mutation has a prior durable intent and a following durability barrier and exact postcheck.
- A crash selects completion, exact rollback, or continued blocking from durable identities; it never grants eligibility.
- Rescan completion proves discovery facts only, not execution or harmlessness.
- Same-UID compromise, sandboxing, signature verification, behavioral analysis, and A Quo consent remain outside Omarchy's claim.

## Effect on prior Gate A artifacts

O-2 remains the protocol history, amended by this review and its edits to `plugin-transaction-protocol-v1.md`. O-3's C helper, tree identity, atomic rename/exchange, `.git`, durability, packaging, and fault-injection decisions remain proposed without change. Checklist completion does not make either artifact immutable; this document is the controlling Gate A decision if the owner approves its exact commit.
