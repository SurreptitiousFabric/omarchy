# Staged plugin transaction protocol v1

## Status and purpose

This document specifies the review contract for `legacy-schema-v1-transaction/v1`. It is a protocol design, not an implementation. It binds one inert candidate, one plugin, one expected installed state, and one exact configuration observation to an explicit commit whose load gate remains closed through namespace mutation, postchecks, and an acknowledged rescan.

The protocol is transport-neutral. A local command may exchange one JSON object per invocation, but command names, storage paths, filesystem primitives, and helper language are deliberately left to O-3 and later implementation issues. Unknown fields are rejected unless a later protocol version explicitly permits them.

Normative words such as MUST, MUST NOT, SHOULD, and MAY have their usual requirements meaning.

## Security property and boundaries

For a committed operation, Omarchy attests only that the exact staged candidate did not become ordinarily load-eligible through Omarchy's schema-v1 registry before the transaction rechecked its preconditions, exposed and revalidated the live tree, completed the operation-bound gated rescan, recorded `RELEASE_PENDING`, and released eligibility.

The protocol does not establish that plugin code is harmless, sandboxed, successfully executed, or permanently immutable. Schema-v1 code retains full user-session authority. A hostile process already running as the same Unix user can modify user-owned files and invoke local interfaces. Operation tokens prevent accidental cross-operation confusion and blind replay; they are bearer secrets, not strong authentication of an application or protection from a hostile same-UID peer.

Omarchy does not accept or interpret `safe`, `trusted`, `approved`, signer, publisher, scanner, persona, or consent assertions. An external installer owns those decisions and binds them to the returned Omarchy facts on its side.

## Common types

All JSON strings are UTF-8. All objects reject duplicate keys. Numbers are base-10 JSON integers. Digests use lowercase hexadecimal. IDs and tokens are compared byte-for-byte after JSON decoding; they are never case-folded or path-normalized.

| Type | Syntax and meaning |
| --- | --- |
| `protocol` | Exact string `legacy-schema-v1-transaction/v1`. |
| `operationId` | Caller-generated UUIDv4 string. It names one immutable request history and is not authorization. |
| `operationToken` | Caller-generated capability with at least 256 bits from a cryptographically secure generator, encoded as unpadded base64url. It is supplied at stage and required for later mutating calls; Omarchy stores only a domain-separated hash. |
| `pluginId` | Canonical manifest ID accepted by the current schema-v1 validator. It MUST equal the request ID and is compared exactly. |
| `operation` | `install` or `update`. Removal is not part of v1. |
| `treeIdentity` | `{ "algorithm": string, "digest": string }`. The algorithm names a complete canonicalization profile, not merely its hash primitive. O-3 MUST register the first supported profile before implementation; a peer MUST reject unsupported profiles. |
| `configSource` | `{ "kind": "user" | "default" | "absent", "identity": string }`. `identity` is an Omarchy-issued stable source identifier, not a caller-selected filesystem path. |
| `configSha256` | SHA-256 of the exact raw bytes read from the accepted source, formatted `sha256:<64 lowercase hex>`. The empty byte sequence has its ordinary SHA-256; `null` is used only when `configSource.kind` is `absent`. |
| `referenceProjection` | Canonical Omarchy-produced record of every schema-v1 reference to the exact plugin ID, including reference kind and stable logical location, sorted by encoded bytes. Its SHA-256 is formatted `sha256:<64 lowercase hex>`. |
| `referenceState` | `referenced` or `unreferenced`, computed by Omarchy using all current schema-v1 reference sites for the exact plugin ID. |
| `referencePolicy` | `require-unreferenced` or `preserve-observed`. |
| `generation` | Non-negative monotonically increasing registry generation scoped to one shell instance, paired with the shell instance ID. It acknowledges discovery, not execution. |

The canonical tree profile selected in O-3 MUST bind every runtime-relevant relative path, entry type, relevant mode bits, file size, and file content; define path encoding and ordering; define whether directories are explicit; prohibit or precisely represent links and special files; impose depth, count, and byte bounds; and define treatment of `.git`. Changing any of those rules requires a different `algorithm` identifier.

## Capability response

Capability discovery has no side effects:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "capabilities": ["legacy-schema-v1-transaction/v1"],
  "treeIdentityAlgorithms": ["omarchy-runtime-tree-sha256-v1"],
  "operations": ["install", "update"],
  "referencePolicies": ["require-unreferenced", "preserve-observed"]
}
```

An absent protocol or unsupported identity algorithm is incompatibility, never permission to silently weaken the transaction.

## Stage

Stage imports an external directory into an Omarchy-owned store outside ordinary plugin discovery. Import, validation, and hashing operate on the transaction-owned snapshot. Stage grants no load eligibility and performs no configuration edit or rescan.

Request schema:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "action": "stage",
  "operationId": "018f3f62-4d31-4dd0-8fc8-2ee33eaeba2c",
  "operationToken": "<caller-generated bearer token>",
  "operation": "update",
  "pluginId": "example.plugin",
  "source": { "kind": "directory", "path": "/caller/private/candidate" },
  "candidateTree": {
    "algorithm": "omarchy-runtime-tree-sha256-v1",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "expectedActive": {
    "state": "present",
    "tree": {
      "algorithm": "omarchy-runtime-tree-sha256-v1",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  },
  "expectedConfiguration": {
    "source": { "kind": "user", "identity": "omarchy-shell-config:user:v1" },
    "referenceProjectionSha256": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "referenceState": "referenced",
    "referencePolicy": "preserve-observed"
  }
}
```

For `install`, `expectedActive` MUST be `{ "state": "absent" }` and `referencePolicy` MUST be `require-unreferenced`. For `update`, `expectedActive.state` MUST be `present` with an exact tree identity; either reference policy is allowed. `preserve-observed` means the commit projection and reference state MUST exactly equal the staged observation. `require-unreferenced` means the projection is empty and the state is `unreferenced` at stage and every commit/postcheck observation.

The accepted source identity and exact plugin-reference projection are hard preconditions. The projection MUST come from the same authoritative schema-v1 eligibility path consulted by every third-party loader; Bash, the filesystem helper, and external clients MUST NOT reproduce configuration parsing or eligibility rules. The raw source SHA-256 and registry generation are observations recorded in responses and receipts, not stage-to-commit equality requirements. This permits an unrelated configuration option to change without weakening protection against a new, removed, or relocated reference to the affected plugin. A malformed source, source switch, projection change, or reference-policy violation still fails closed.

Omarchy independently observes the current active tree and configuration during stage. A mismatch returns a typed stale result and creates no staged operation. A successful response is:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "operationId": "018f3f62-4d31-4dd0-8fc8-2ee33eaeba2c",
  "pluginId": "example.plugin",
  "state": "STAGED",
  "candidateTree": {
    "algorithm": "omarchy-runtime-tree-sha256-v1",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "activeObserved": {
    "state": "present",
    "tree": {
      "algorithm": "omarchy-runtime-tree-sha256-v1",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  },
  "configurationObserved": {
    "source": { "kind": "user", "identity": "omarchy-shell-config:user:v1" },
    "rawSha256": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "referenceProjectionSha256": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "referenceState": "referenced"
  }
}
```

The token MUST NOT be written to ordinary logs or returned by status and terminal receipts. A retry supplies the same token; Omarchy compares its hash without persisting recoverable bearer material.

## Commit, status, abort, and recover

Commit request:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "action": "commit",
  "operationId": "018f3f62-4d31-4dd0-8fc8-2ee33eaeba2c",
  "operationToken": "<opaque bearer token>"
}
```

The commit authorizes only the already-recorded immutable operation. No field can replace its plugin, candidate, operation, expected active state, configuration observation, or reference policy.

`status` takes the protocol and operation ID and is read-only. It returns the current durable state and redacted facts. Implementations MAY require the operation token for nonterminal status, but terminal receipts MUST be retrievable for an exact operation ID by the same local user so a client that loses its response can reconcile safely.

`abort` requires the operation ID and operation token. It succeeds only from `STAGED`, records `ABORTED`, and makes only that inert candidate eligible for later garbage collection. It MUST NOT change the active tree, configuration, registry, or gate. Abort after commit preparation returns `operation-in-progress`; recovery owns the outcome from then on.

`recover` requests reconciliation of one nonterminal operation. It never supplies replacement identities or a desired outcome. Recovery uses the durable journal and exact observed identities to complete, roll back, or enter manual attention.

## Minimal shell coordination

The shell-facing contract has three idempotent operation-bound mutations: gate and unload one plugin, rescan that plugin while it remains gated for an expected live tree, and conditionally release only the matching gate after the expected rescan generation. A read-only reconciliation call reports the gate on shell startup and recovery. Gate acknowledgement means every schema-v1 loader treats the plugin as ineligible and existing instances have been unloaded. Rescan acknowledgement means discovery completed for the expected tree while ineligible.

While the gate remains authoritative, release MUST obtain the current accepted configuration source and plugin-reference projection through that same central eligibility path. As one shell-controlled decision with no intervening configuration processing, it MUST compare those facts with the operation-bound expectations, enforce the reference policy, verify the expected live tree and gated-rescan generation, and only then remove the matching gate. The shell MAY retrieve expectations through `operationId`; they need not be repeated as caller-controlled parameters. On any mismatch it MUST retain the gate and return a typed failure. A transaction-helper check immediately before release is defense-in-depth and evidence, not sufficient authorization to remove the gate. Because the tree may already have been exchanged, a release mismatch leads to rollback or recovery, never `REJECTED`. Release acknowledgement means these comparisons passed and eligibility was recomputed and published; it does not mean plugin code executed successfully. `plugin-transaction-gate-a-review.md` defines these semantics and the reviewable implementation slices.

## Durable state machine

Every transition is durably recorded before the side effect named by the destination state can be assumed. The affected plugin is not eligible while any durable state from `LOAD_GATED` through `RELEASE_PENDING`, `ROLLBACK_STARTED`, or `RECOVERY_REQUIRED` exists.

| State | Meaning | Permitted next states |
| --- | --- | --- |
| `STAGED` | Exact validated candidate is inert; active state is unchanged. | `COMMIT_PREPARED`, `ABORTED` |
| `COMMIT_PREPARED` | Commit won its plugin-scoped lock; no live mutation yet. | `LOAD_GATED`, `REJECTED`, `RECOVERY_REQUIRED` |
| `LOAD_GATED` | Durable gate exists and shell acknowledged unload/ineligibility. | `LIVE_TREE_EXCHANGED`, `ROLLBACK_STARTED`, `RECOVERY_REQUIRED` |
| `LIVE_TREE_EXCHANGED` | Exact candidate occupies the live namespace; previous exact tree is retained for update. Gate remains closed. | `GATED_RESCAN_COMPLETED`, `ROLLBACK_STARTED`, `RECOVERY_REQUIRED` |
| `GATED_RESCAN_COMPLETED` | Exact live-tree postcheck and operation-bound rescan completed while gated. This does not assert execution. | `RELEASE_PENDING`, `ROLLBACK_STARTED`, `RECOVERY_REQUIRED` |
| `RELEASE_PENDING` | Helper-side final checks passed and durable intent to request conditional shell release is recorded. The gate remains authoritative. | `COMMITTED`, `ROLLBACK_STARTED`, `RECOVERY_REQUIRED` |
| `COMMITTED` | Shell acknowledged release of load eligibility; terminal receipt is durable. | none |
| `ROLLBACK_STARTED` | Gate remains closed while exact pre-operation state is restored and checked. | `ROLLED_BACK`, `MANUAL_ATTENTION`, `RECOVERY_REQUIRED` |
| `ROLLED_BACK` | Exact prior tree or exact absence was restored and acknowledged under the gate; terminal failure receipt is durable. | none |
| `RECOVERY_REQUIRED` | An interruption left a nonterminal outcome requiring exact reconciliation. The affected plugin remains gated whenever exposure may have occurred. | the provably correct forward state, `ROLLBACK_STARTED`, `MANUAL_ATTENTION` |
| `MANUAL_ATTENTION` | Exact safe completion or rollback could not be established. The affected plugin remains ineligible. | none in v1; an explicit future administrative repair procedure is required |
| `ABORTED` | Still-inert operation was cancelled before commit preparation. | none |
| `REJECTED` | A stale or contradictory precondition was detected before any live namespace or eligibility mutation. Nothing was rolled back. | none |

Before `LOAD_GATED`, a stale precondition ends as `REJECTED` with rollback dimension `not-applicable`. After the shell has acknowledged a gate, a failure must either release the unchanged installation safely or enter rollback/recovery; after `LIVE_TREE_EXCHANGED`, any failed tree, configuration, reference, or rescan check MUST enter rollback while the gate remains closed. `ROLLED_BACK` is used only when prior filesystem or eligibility state was actually restored. A crash never implies automatic gate release.

## Result schema

Every response has this envelope:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "operationId": "018f3f62-4d31-4dd0-8fc8-2ee33eaeba2c",
  "pluginId": "example.plugin",
  "state": "COMMITTED",
  "status": "committed",
  "candidateTree": { "algorithm": "omarchy-runtime-tree-sha256-v1", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  "previousTree": { "algorithm": "omarchy-runtime-tree-sha256-v1", "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
  "filesystem": { "state": "candidate-active", "liveTree": { "algorithm": "omarchy-runtime-tree-sha256-v1", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } },
  "configuration": {
    "sourceBefore": { "kind": "user", "identity": "omarchy-shell-config:user:v1" },
    "rawSha256Before": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "sourceAfter": { "kind": "user", "identity": "omarchy-shell-config:user:v1" },
    "rawSha256After": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "referenceProjectionSha256Before": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "referenceProjectionSha256After": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  },
  "reference": { "policy": "preserve-observed", "before": "referenced", "after": "referenced" },
  "registry": { "rescan": "completed", "shellInstance": "<opaque instance ID>", "generation": 42 },
  "loadEligibility": "released",
  "rollback": { "state": "not-applicable", "tree": null },
  "recovery": "not-required",
  "reason": null
}
```

Fields remain separate even on failure. `registry.rescan: completed` means discovery completed for the expected plugin and live tree; it MUST NOT be reported as successful plugin execution. `loadEligibility` is one of `never-granted`, `gated`, `released`, or `blocked-manual-attention`. Rollback state is `not-applicable`, `started`, `completed`, or `failed`. Recovery is `not-required`, `pending`, `completed-forward`, `completed-rollback`, or `manual-attention`.

Terminal `status` values and their typed reasons are:

| Status | Meaning |
| --- | --- |
| `committed` | Exact candidate was committed and eligibility release was acknowledged. |
| `already-current` | At stage time the requested candidate was already the exact active tree; no candidate was exposed and no commit is created. |
| `rejected` | No live namespace or eligibility mutation occurred. `reason` is `stale-candidate`, `stale-installed-revision`, `stale-configuration-source`, `stale-configuration`, or `stale-reference`. `stale-configuration` means the plugin-reference projection changed; unrelated raw-byte changes are evidence only. |
| `aborted` | Still-inert staged operation was explicitly aborted. |
| `rolled-back` | Commit did not complete and exact prior state was restored. `reason` identifies the triggering failure. |
| `indeterminate` | The service cannot yet establish a terminal outcome; durable state is `RECOVERY_REQUIRED` and the affected plugin remains gated if exposure might have occurred. |
| `manual-attention` | Automated recovery cannot prove a correct tree/state; affected plugin remains blocked. `reason` includes `rollback-failed` when exact restoration failed. |

Nonterminal status values mirror the lowercase durable states and are never represented as success. Transport failure is not a transaction result; clients query `status` by operation ID instead of assuming failure or retrying with a new ID.

## Replay, concurrency, and idempotency

The first accepted `stage` request durably binds its complete normalized request digest to `operationId`. Repeating byte-equivalent semantic input for that ID returns the same candidate identity and operation state. Reuse of the ID with any different normalized field returns `operation-id-conflict` and does not alter either operation.

An exact repeated `commit` with the matching operation token returns the current state or original terminal receipt. It never repeats an exchange, rescan release, or rollback. A wrong token returns `invalid-operation-token`. The operation record already binds the exact candidate tree, so a second candidate bearer token enforces no additional property and is deliberately absent.

Only one commit for a plugin ID may hold `COMMIT_PREPARED` or a later nonterminal state. A competing operation returns `plugin-busy` with no secret details. Operations for unrelated plugin IDs may proceed independently unless an implementation documents a bounded global shell-unload section; such an internal limit does not widen the public transaction's authority.

## Required commit observations

The implementation order is normative:

1. Acquire the operation and plugin lifecycle lock; persist `COMMIT_PREPARED`.
2. Recompute the candidate identity and recheck the exact active state, configuration source, plugin-reference projection, reference state, and policy. Record the current raw configuration hash as evidence. A failure reaches `REJECTED` without gating or rollback.
3. Establish the durable plugin load gate; obtain the shell's unload/gate acknowledgement; persist `LOAD_GATED`.
4. Repeat the exact security-relevant precondition checks. If one changed after preflight, restore the prior eligibility state and report `rolled-back`; do not expose the candidate.
5. Atomically expose the install candidate or exchange the update candidate while retaining exact rollback identity; persist `LIVE_TREE_EXCHANGED`.
6. Recompute the identity at the live location and recheck configuration source, plugin-reference projection, and reference state while still gated. Record the raw configuration hash.
7. Request one operation-bound rescan and require acknowledgement for the expected plugin ID and live tree; persist `GATED_RESCAN_COMPLETED`.
8. Recheck configuration source, plugin-reference projection, and reference policy; record the raw configuration hash; persist `RELEASE_PENDING`. This helper-side check does not authorize gate removal.
9. Request conditional shell release. While the gate remains authoritative, the shell itself obtains the current source and projection from the central loader eligibility path, compares them with the operation-bound expectations, enforces the reference policy, and verifies the expected live tree and gated-rescan generation. It removes the gate only if every check passes, as one shell-controlled decision without intervening configuration processing. A mismatch retains the gate and enters rollback or recovery. Only an acknowledged release permits the terminal `COMMITTED` receipt.

There is no valid `expose → ordinary watcher reload → postcheck` path. Watcher events may request work, but the gate prevents evaluation until release. Configuration mutation is either serialized or detected as a typed stale result before release.

## Examples

### Fresh unreferenced install that becomes referenced

Stage accepts exact absence, the accepted configuration source and reference projection, `unreferenced`, and `require-unreferenced`. If the ID becomes referenced before gating, commit reaches `REJECTED` with status `rejected`, reason `stale-reference`, and rollback `not-applicable`. If it becomes referenced after exposure, the exact absence is restored while gated and the terminal status is `rolled-back` with reason `stale-reference`. The candidate is never released.

### Referenced update

Stage binds the exact active tree, configuration source, plugin-reference projection, `referenced`, and `preserve-observed`. Commit exchanges only if those security-relevant observations still match. An unrelated bar option may change the raw file hash without rejecting the transaction; both hashes remain in the receipt. The rescan may discover the new revision, but the plugin stays gated until the final reference check and release acknowledgement.

### Client dies after exchange

The journal shows `LIVE_TREE_EXCHANGED`, so shell startup keeps the plugin gated. Recovery verifies the exact candidate and retained prior tree. It either resumes the gated rescan and reaches `COMMITTED`, restores the exact prior tree and reaches `ROLLED_BACK`, or records `MANUAL_ATTENTION`. It does not infer intent from directory names.

### Response is lost after commit

The caller repeats `status` or the exact `commit` using the same operation ID. Omarchy returns the durable original terminal receipt. A new operation ID is not used to guess whether the first commit happened.

## Future schema-v2 compatibility

PR [omacom/omarchy#8956](https://github.com/omacom/omarchy/pull/8956) is architectural precedent for immutable candidate revisions, inert staging, explicit activation, retained rollback identity, and stale-binding rejection. This protocol does not depend on that PR's branch, code, sandbox, permission broker, worker, providers, or schema-v2 activation service.

A future implementation may advertise `secure-schema-v2-lifecycle/v1` and map staged operation records to immutable revisions internally. It may reuse the operation and exact-identity envelope, but schema-v2 permission review remains a separate authority decision. A client selects an explicitly advertised capability; release numbers or directory layouts are not capability probes.

## Decisions deferred to O-3

O-3 selects the concrete canonical tree profile and identifier, descriptor-pinning and traversal mechanism, atomic install/update primitive, durability barriers, `.git` treatment, helper language, packaging boundary, and fault-injection method. Those decisions may fill implementation-defined identifiers in this contract but MUST NOT weaken its state transitions, exact preconditions, fail-closed recovery, or multidimensional result.
