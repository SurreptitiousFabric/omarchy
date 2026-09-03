# Hidden plugin transaction command v1

## Scope and route

`omarchy plugin transaction` routes to the hidden `omarchy-plugin-transaction` binary. It reads one JSON object from standard input and writes one canonical compact JSON object plus LF to standard output. The actions are `capabilities`, `stage`, `status`, `abort`, and the O-8 `commit` action. The interface still has no public gate, rescan, release, activation, recovery-execution, configuration-mutation, safety, trust, signer, scanner, publisher, consent, or A Quo surface.

The protocol is exactly `legacy-schema-v1-transaction/v1`. Input is at most 65,536 bytes. The package native helper validates UTF-8 and complete JSON grammar, rejects literal NUL, trailing bytes, multiple values, and decoded-equivalent duplicate keys at every object depth, and returns the unchanged bytes through an anonymous pipe. The action-specific jq validator then checks exact key sets, types, vocabularies, and bounds. jq is deliberately not treated as a duplicate-key detector.

Capabilities has no side effects. Stage compares caller expectations with one plugin-scoped O-6 accepted snapshot and an independently measured active tree before calling the reviewed inert stage boundary. The helper's bounded structured result channel is combined with an authoritative durable-journal read; a `rejected` response is never emitted for an operation journal that exists. Exact retries of `REQUEST_BOUND` and `PUBLICATION_INTENT` resume the reviewed stage-candidate reconciliation path. Status is logically read-only: it acquires the existing operation lock, synchronizes the existing journals directory, and then performs a descriptor-pinned bounded journal read without creating or repairing state. A prior parent-fsync ambiguity remains indeterminate until that synchronization succeeds. Abort uses the same no-create synchronization/read seam while its already-held operation-then-plugin locks remain held, applies only to an exact `STAGED`/`ABORTED` operation, and retains the candidate.

## Responses and exit classes

Every rejection uses `protocol`, `action`, `operationId`, `pluginId`, and `state` when safely known, plus `status` and one typed `reason`. Successful stage, status, and abort responses add the durable state, operation, public candidate tree, observed active state/tree, and the redacted observed configuration source/raw hash/reference projection hash/reference state. They omit source and destination paths, raw configuration, normalized request digest, capability hash, and internal slot names.

Exit codes are:

| Code | Class |
| --- | --- |
| 0 | Handled result, including a stable precondition rejection or not-found status. |
| 2 | Malformed, invalid, or incompatible request. |
| 3 | Invalid operation token or immutable operation-ID conflict. |
| 4 | Unavailable shell authority, invalid local authority, manual attention, or local I/O failure. |
| 5 | Indeterminate durable outcome or durable recovery-required state. |

Clients use JSON `status` and `reason`, not stderr or the exit code alone, as the transaction result. Stderr is diagnostic only and never contains the request or raw operation token.

## O-8 commit authority

The hidden `commit` action is derived from a bounded structured native result
and the authoritative durable operation journal. A terminal `rejected` result
is never emitted when a nonterminal operation record exists. O-8 uses
state-conditioned journal fields and gate-v2's stable operation binding rather
than a mutable full-journal digest.

Status is logically read-only, but synchronizes the existing journal directory
under the existing operation lock before its descriptor-pinned validation. A
prior parent-fsync ambiguity remains indeterminate until that reconciliation
synchronization succeeds.

Fresh installs use the package-owned `discoveryDirectory/pluginId` destination.
Updates use the exact authoritative active source directory selected by the
O-6 registry authority. That source must be one real direct child of the
discovery directory; its basename need not equal the manifest ID.

The O-8 commit coordinator reserves `COMMIT_PREPARED` before requesting shell
gating and never holds the ordered operation/plugin locks while waiting for a
shell action. It accepts a gated rescan only from `LIVE_TREE_EXCHANGED`, and
accepts candidate release only from durable `RELEASE_PENDING` with a
`RESCAN_ACKNOWLEDGED` gate. Every namespace operation has a durable intent,
uses descriptor-relative `renameat2` (`RENAME_NOREPLACE` for install and
`RENAME_EXCHANGE` for update), synchronizes the candidate/operation parent
before the discovery parent, and postchecks exact runtime-tree identities.
There is no copy-based live-tree fallback.

The shell-to-coordinator terminal handoff is receipt-first: the shell writes a
durable `TERMINAL_RECEIPT` gate targeting `COMMITTED` or `ROLLED_BACK` only
after its final eligibility decision has been published, acknowledges that
receipt, and the coordinator writes the terminal journal state last. A
terminal receipt without its matching terminal journal, or a terminal journal
without its matching receipt, remains blocking on restart. A release timeout
therefore reconciles the receipt and current shell state; `RELEASE_AUTHORIZED`
alone is not treated as proof that this shell is still gated or released.

Rollback records `ROLLBACK_STARTED` before mutation, retargets the blocking
gate to exact absence for install or the retained prior tree for update, and
requires rollback rescan plus restoration of source identity, canonical
projection, reference policy, and reference state before publishing restored
eligibility. Filesystem restoration without that eligibility acknowledgement
is indeterminate, not `ROLLED_BACK`. O-8 performs only direct exact rollback
and replay of completed steps; broad restart recovery remains O-9.

## Request-field ledger

| Field | Action | Validator and bound | Consumer |
| --- | --- | --- | --- |
| `protocol` | all | exact protocol string | dispatcher and every response |
| `action` | all | exact action vocabulary | dispatcher |
| `operationId` | stage/status/abort | lowercase UUIDv4 | journal name and operation lock |
| `operationToken` | stage/abort | canonical unpadded base64url; decoded 32–128 bytes | private stdin to stage; domain-separated hash stdin for abort |
| `operation` | stage | `install` or `update` | reviewed stage request facts |
| `pluginId` | stage | schema-v1 third-party ID; 1–128 ASCII characters | manifest comparison and package-derived destination |
| `source.kind` | stage | exactly `directory` | reviewed stage request facts |
| `source.path` | stage | normalized absolute control-free UTF-8; at most 4,096 bytes | source identity/read and stage argv |
| `candidateTree` | stage | exact algorithm and lowercase SHA-256 digest | pre-import identity comparison and reviewed stage facts |
| `expectedActive` | stage | exact operation-dependent shape and tree identity | independent live destination observation |
| `expectedConfiguration.source` | stage | exact kind plus control-free opaque identity up to 256 bytes | comparison with accepted O-6 source |
| reference projection/state/policy | stage | exact SHA-256/vocabulary; install requires registered empty projection and unreferenced policy | comparison with canonical O-6 projection and reviewed stage facts |

No request field selects a destination, helper, validator, candidate store, transaction root, discovery root, shell instance, generation, epoch, gate, stage observation, capability hash, or candidate token.

## Secret-flow ledger

The token enters only within the bounded stdin request. Before schema materialization, the native syntax/duplicate checker receives the request on stdin and returns it through a pipe. jq validation and field extraction also receive it on stdin. Bash retains the bounded request and token only in non-exported variables with tracing disabled.

For stage, the token is written directly to the reviewed `stage-candidate` stdin. It is not placed in that process's argv or environment. Stage hashes and clears it at its existing native boundary. An authenticated durable replay may additionally hash it through the native helper's stdin before deciding whether the durable state is eligible for replay. For abort, the command hashes it through that same domain-separated native stdin boundary, clears the raw variable, and compares fixed-size hashes through the existing constant-time path. No raw-token value enters a filename, temporary file, journal, result, stdout, stderr, retained test evidence, or exported environment.

## Observation ledger

| Fact | Authoritative producer |
| --- | --- |
| candidate tree | `plugin-tree identity` canonical runtime-tree implementation |
| active absence/source/tree | O-6 registry target cardinality and selected source, which must be absent or one exact canonical destination, plus `plugin-tree identity` for a present tree |
| accepted configuration source | `PluginEligibility.acceptedSnapshot` with opaque package-issued identity |
| raw configuration hash | SHA-256 of the accepted snapshot's bounded `rawBase64` bytes |
| reference projection | `PluginReferenceProjection.canonicalBytes` on that same accepted object, transported as bounded base64 and hashed |
| reference state | reference count from that same canonical producer and accepted object |
| discovery/state roots | `PluginRegistry.pluginsDir` and `PluginEligibility.stateRoot`, checked against package rules |

The shell observation schema is plugin-scoped. It rejects ambiguous registry IDs and binds a single discovered active source to the package-derived destination before the command hashes that tree. Raw accepted configuration is capped at 32,768 bytes and the canonical projection at 4,096 bytes before base64 transport. The command validates the complete observation under the same 64 KiB JSON syntax bound. It does not parse `shell.json` or evaluate plugin QML. The observation is point-in-time evidence only; later commit work must revalidate it.

Destination authority is operation-specific. An install requires exact absence at the package-owned direct child `discoveryDirectory/pluginId`. An update takes its destination from O-6's authoritative selected active source and accepts any one real, non-symlinked direct child of the canonical discovery directory; the directory basename need not equal the manifest ID. Both rules are rechecked for durable replay, and the caller cannot supply a destination.

## Side-effect ledger

| Action | Reads | Writes | Locks | Shell IPC | Prohibited effects |
| --- | --- | --- | --- | --- | --- |
| capabilities | package helper/validator and stdin | none | none | none | all filesystem/config/plugin activity |
| stage, new | source/candidate, exact live destination or absence, accepted shell observation | transient normalized-request/journal assembly files, then the existing O-5 journal and inert candidate store | operation | one plugin-scoped read | gate, discovery/live tree, config, rescan, plugin execution |
| stage, exact replay | journal and exact owned candidate | the reviewed helper's transient normalized-request/journal assembly files; stable `STAGED`/`ABORTED` durable evidence is not replaced | waits for any existing operation owner, re-reads while holding that operation lock, then uses the reviewed stage lock | none | external source dependency, recovery command, nonterminal reconciliation, restage after abort |
| status | existing operation lock, synchronized journals directory, one pinned bounded journal and package validator | no logical state; directory synchronization only | existing operation lock (shared) | none | state initialization, lock/journal creation, repair, quarantine, candidate reconciliation |
| abort | journal, candidate identity, gate absence | one mode-0600 transient generated-journal input removed on exit and one atomic `STAGED`→`ABORTED` journal replacement | operation then canonical plugin lifecycle; synchronization/read is no-relock while held | none | candidate deletion, live/config/registry/gate change |

Caller `OMARCHY_PATH` and `OMARCHY_PLUGIN_*` variables are removed before processing. Stage invokes package-relative helpers with an explicit minimal environment. HOME and XDG state roots remain the user's standard authority roots; there is no production redirect switch.

## State/output ledger

| Durable state | Public status | Redaction | Permitted next O-7 action |
| --- | --- | --- | --- |
| `REQUEST_BOUND` | `in-progress` | no capability or paths | status; a concurrently owned exact stage may join |
| `PUBLICATION_INTENT` | `in-progress` | no capability or paths | status; a concurrently owned exact stage may join |
| `STAGED` | `ok` | public identities/observations only | status or exact abort |
| `RECOVERY_REQUIRED` | `indeterminate` | no internal evidence names | status only |
| `MANUAL_ATTENTION` | `manual-attention` | corrupt bytes/hash and capability omitted | status only |
| `ABORTED` | `aborted` | retained candidate identity is public; internal path omitted | status or idempotent abort/stage replay |

An unowned nonterminal journal is reconciled only by an exact same-operation retry: the caller waits for the current operation owner, releases the read lock, and lets stage-candidate resume its durable `REQUEST_BOUND` or `PUBLICATION_INTENT` path. A concurrent caller reads the resulting durable state while holding the operation lock. Exact same-operation replay after `ABORTED` returns the durable terminal result and cannot republish the candidate.

## Abort crash matrix

| Fault point | Authoritative journal after fresh open | Candidate | Live tree | Public abort result |
| --- | --- | --- | --- | --- |
| before write | old `STAGED` | retained exact | unchanged | indeterminate |
| after write | old `STAGED` | retained exact | unchanged | indeterminate |
| journal-file fsync | old `STAGED` | retained exact | unchanged | indeterminate |
| after file fsync | old `STAGED` | retained exact | unchanged | indeterminate |
| rename failure | old `STAGED` | retained exact | unchanged | indeterminate |
| after rename | new `ABORTED` | retained exact | unchanged | indeterminate |
| journal-parent fsync | new `ABORTED` may be visible and is never reported durable by that invocation | retained exact | unchanged | indeterminate |

Every case is followed by a fresh descriptor-pinned status and exact abort retry. Only the complete old or new canonical journal is authoritative; temporary journal names are never read as state.
