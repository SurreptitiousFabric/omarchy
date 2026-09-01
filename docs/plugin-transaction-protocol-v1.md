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
| `operationToken` | At least 256 bits from a cryptographically secure generator, returned once by stage as unpadded base64url. It is required for mutating calls. |
| `candidateToken` | Omarchy-generated opaque unpadded base64url value with at least 256 bits of entropy. It names the imported snapshot, not a pathname. |
| `pluginId` | Canonical manifest ID accepted by the current schema-v1 validator. It MUST equal the request ID and is compared exactly. |
| `operation` | `install` or `update`. Removal is not part of v1. |
| `treeIdentity` | `{ "algorithm": string, "digest": string }`. The algorithm names a complete canonicalization profile, not merely its hash primitive. O-3 MUST register the first supported profile before implementation; a peer MUST reject unsupported profiles. |
| `configSource` | `{ "kind": "user" | "default" | "absent", "identity": string }`. `identity` is an Omarchy-issued stable source identifier, not a caller-selected filesystem path. |
| `configSha256` | SHA-256 of the exact raw bytes read from the accepted source, formatted `sha256:<64 lowercase hex>`. The empty byte sequence has its ordinary SHA-256; `null` is used only when `configSource.kind` is `absent`. |
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
  "treeIdentityAlgorithms": ["implementation-selected-in-o-3"],
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
  "operation": "update",
  "pluginId": "example.plugin",
  "source": { "kind": "directory", "path": "/caller/private/candidate" },
  "candidateTree": {
    "algorithm": "implementation-selected-in-o-3",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "expectedActive": {
    "state": "present",
    "tree": {
      "algorithm": "implementation-selected-in-o-3",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  },
  "expectedConfiguration": {
    "source": { "kind": "user", "identity": "omarchy-user-shell-config/v1" },
    "rawSha256": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "referenceState": "referenced",
    "referencePolicy": "preserve-observed"
  }
}
```

For `install`, `expectedActive` MUST be `{ "state": "absent" }` and `referencePolicy` MUST be `require-unreferenced`. For `update`, `expectedActive.state` MUST be `present` with an exact tree identity; either reference policy is allowed. `preserve-observed` means the commit observation MUST equal `expectedConfiguration.referenceState`. `require-unreferenced` means both the staged observation and every commit/postcheck observation MUST be `unreferenced`.

Omarchy independently observes the current active tree and configuration during stage. A mismatch returns a typed stale result and creates no staged operation. A successful response is:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "operationId": "018f3f62-4d31-4dd0-8fc8-2ee33eaeba2c",
  "pluginId": "example.plugin",
  "state": "STAGED",
  "operationToken": "<opaque bearer token>",
  "candidateToken": "<opaque candidate token>",
  "candidateTree": {
    "algorithm": "implementation-selected-in-o-3",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "activeObserved": {
    "state": "present",
    "tree": {
      "algorithm": "implementation-selected-in-o-3",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  },
  "configurationObserved": {
    "source": { "kind": "user", "identity": "omarchy-user-shell-config/v1" },
    "rawSha256": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "referenceState": "referenced"
  }
}
```

The token-bearing response SHOULD be mode-restricted and MUST NOT be written to ordinary logs. Status and terminal receipts redact `operationToken`.

## Commit, status, abort, and recover

Commit request:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "action": "commit",
  "operationId": "018f3f62-4d31-4dd0-8fc8-2ee33eaeba2c",
  "operationToken": "<opaque bearer token>",
  "candidateToken": "<opaque candidate token>"
}
```

The commit authorizes only the already-recorded immutable operation. No field can replace its plugin, candidate, operation, expected active state, configuration observation, or reference policy.

`status` takes the protocol and operation ID and is read-only. It returns the current durable state and redacted facts. Implementations MAY require the operation token for nonterminal status, but terminal receipts MUST be retrievable for an exact operation ID by the same local user so a client that loses its response can reconcile safely.

`abort` requires the operation ID and operation token. It succeeds only from `STAGED`, records `ABORTED`, and makes only that inert candidate eligible for later garbage collection. It MUST NOT change the active tree, configuration, registry, or gate. Abort after commit preparation returns `operation-in-progress`; recovery owns the outcome from then on.

`recover` requests reconciliation of one nonterminal operation. It never supplies replacement identities or a desired outcome. Recovery uses the durable journal and exact observed identities to complete, roll back, or enter manual attention.

## Durable state machine

Every transition is durably recorded before the side effect named by the destination state can be assumed. The affected plugin is not eligible while any durable state from `LOAD_GATED` through `RELEASE_PENDING`, `ROLLBACK_STARTED`, or `RECOVERY_REQUIRED` exists.

| State | Meaning | Permitted next states |
| --- | --- | --- |
| `STAGED` | Exact validated candidate is inert; active state is unchanged. | `COMMIT_PREPARED`, `ABORTED` |
| `COMMIT_PREPARED` | Commit won its plugin-scoped lock; no live mutation yet. | `LOAD_GATED`, `RECOVERY_REQUIRED` |
| `LOAD_GATED` | Durable gate exists and shell acknowledged unload/ineligibility. | `LIVE_TREE_EXCHANGED`, `ROLLBACK_STARTED`, `RECOVERY_REQUIRED` |
| `LIVE_TREE_EXCHANGED` | Exact candidate occupies the live namespace; previous exact tree is retained for update. Gate remains closed. | `GATED_RESCAN_COMPLETED`, `ROLLBACK_STARTED`, `RECOVERY_REQUIRED` |
| `GATED_RESCAN_COMPLETED` | Exact live-tree postcheck and operation-bound rescan completed while gated. This does not assert execution. | `RELEASE_PENDING`, `ROLLBACK_STARTED`, `RECOVERY_REQUIRED` |
| `RELEASE_PENDING` | All final config/reference checks passed and durable intent to release is recorded. | `COMMITTED`, `RECOVERY_REQUIRED` |
| `COMMITTED` | Shell acknowledged release of load eligibility; terminal receipt is durable. | none |
| `ROLLBACK_STARTED` | Gate remains closed while exact pre-operation state is restored and checked. | `ROLLED_BACK`, `MANUAL_ATTENTION`, `RECOVERY_REQUIRED` |
| `ROLLED_BACK` | Exact prior tree or exact absence was restored and acknowledged under the gate; terminal failure receipt is durable. | none |
| `RECOVERY_REQUIRED` | An interruption left a nonterminal outcome requiring exact reconciliation. The affected plugin remains gated whenever exposure may have occurred. | the provably correct forward state, `ROLLBACK_STARTED`, `MANUAL_ATTENTION` |
| `MANUAL_ATTENTION` | Exact safe completion or rollback could not be established. The affected plugin remains ineligible. | none in v1; an explicit future administrative repair procedure is required |
| `ABORTED` | Still-inert operation was cancelled before commit preparation. | none |

Before `LIVE_TREE_EXCHANGED`, a stale precondition can end as `ROLLED_BACK` with rollback dimension `not-required`; no namespace restoration occurred. After exposure, any failed tree, configuration, reference, or rescan check MUST enter rollback while the gate remains closed. A crash never implies automatic gate release.

## Result schema

Every response has this envelope:

```json
{
  "protocol": "legacy-schema-v1-transaction/v1",
  "operationId": "018f3f62-4d31-4dd0-8fc8-2ee33eaeba2c",
  "pluginId": "example.plugin",
  "state": "COMMITTED",
  "status": "committed",
  "candidateTree": { "algorithm": "implementation-selected-in-o-3", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
  "previousTree": { "algorithm": "implementation-selected-in-o-3", "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
  "filesystem": { "state": "candidate-active", "liveTree": { "algorithm": "implementation-selected-in-o-3", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } },
  "configuration": {
    "sourceBefore": { "kind": "user", "identity": "omarchy-user-shell-config/v1" },
    "rawSha256Before": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "sourceAfter": { "kind": "user", "identity": "omarchy-user-shell-config/v1" },
    "rawSha256After": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  },
  "reference": { "policy": "preserve-observed", "before": "referenced", "after": "referenced" },
  "registry": { "rescan": "completed", "shellInstance": "<opaque instance ID>", "generation": 42 },
  "loadEligibility": "released",
  "rollback": { "state": "not-required", "tree": null },
  "recovery": "not-required",
  "reason": null
}
```

Fields remain separate even on failure. `registry.rescan: completed` means discovery completed for the expected plugin and live tree; it MUST NOT be reported as successful plugin execution. `loadEligibility` is one of `never-granted`, `gated`, `released`, or `blocked-manual-attention`. Rollback state is `not-required`, `started`, `completed`, or `failed`. Recovery is `not-required`, `pending`, `completed-forward`, `completed-rollback`, or `manual-attention`.

Terminal `status` values are:

| Status | Meaning |
| --- | --- |
| `committed` | Exact candidate was committed and eligibility release was acknowledged. |
| `already-current` | At stage time the requested candidate was already the exact active tree; no candidate was exposed and no commit is created. |
| `stale-candidate` | Supplied or imported candidate identity did not match. |
| `stale-installed-revision` | Exact active-tree presence or identity precondition failed. |
| `stale-configuration-source` | Accepted configuration source changed. |
| `stale-configuration` | Raw configuration bytes changed. |
| `stale-reference` | Reference policy or expected reference state failed. |
| `aborted` | Still-inert staged operation was explicitly aborted. |
| `rolled-back` | Commit did not complete and exact prior state was restored. `reason` identifies the triggering failure. |
| `rollback-failed` | Exact rollback could not be established; affected plugin remains blocked. |
| `indeterminate` | The service cannot yet establish a terminal outcome; durable state is `RECOVERY_REQUIRED` and the affected plugin remains gated if exposure might have occurred. |
| `manual-attention` | Automated recovery cannot prove a correct tree/state; affected plugin remains blocked. |

Nonterminal status values mirror the lowercase durable states and are never represented as success. Transport failure is not a transaction result; clients query `status` by operation ID instead of assuming failure or retrying with a new ID.

## Replay, concurrency, and idempotency

The first accepted `stage` request durably binds its complete normalized request digest to `operationId`. Repeating byte-equivalent semantic input for that ID returns the same candidate identity and operation state. Reuse of the ID with any different normalized field returns `operation-id-conflict` and does not alter either operation.

An exact repeated `commit` with the matching operation and candidate tokens returns the current state or original terminal receipt. It never repeats an exchange, rescan release, or rollback. A wrong token returns `invalid-operation-token` without revealing whether another candidate token is valid.

Only one commit for a plugin ID may hold `COMMIT_PREPARED` or a later nonterminal state. A competing operation returns `plugin-busy` with no secret details. Operations for unrelated plugin IDs may proceed independently unless an implementation documents a bounded global shell-unload section; such an internal limit does not widen the public transaction's authority.

## Required commit observations

The implementation order is normative:

1. Acquire the operation and plugin lifecycle lock; persist `COMMIT_PREPARED`.
2. Establish the durable plugin load gate; obtain the shell's unload/gate acknowledgement; persist `LOAD_GATED`.
3. Recompute the candidate identity and recheck the exact active state, configuration source, raw bytes, reference state, and policy.
4. Atomically expose the install candidate or exchange the update candidate while retaining exact rollback identity; persist `LIVE_TREE_EXCHANGED`.
5. Recompute the identity at the live location and recheck configuration and reference state while still gated.
6. Request one operation-bound rescan and require acknowledgement for the expected plugin ID and live tree; persist `GATED_RESCAN_COMPLETED`.
7. Recheck configuration source, raw bytes, and reference policy; persist `RELEASE_PENDING`.
8. Release eligibility and require shell acknowledgement; persist the terminal `COMMITTED` receipt.

There is no valid `expose → ordinary watcher reload → postcheck` path. Watcher events may request work, but the gate prevents evaluation until release. Configuration mutation is either serialized or detected as a typed stale result before release.

## Examples

### Fresh unreferenced install that becomes referenced

Stage accepts exact absence, the accepted raw configuration, `unreferenced`, and `require-unreferenced`. If the ID becomes referenced before or during commit, commit returns `stale-reference`. Before exposure, rollback is `not-required`; after exposure, the exact absence is restored while gated and the terminal status is `rolled-back` with reason `stale-reference`. The candidate is never released.

### Referenced update

Stage binds the exact active tree, exact raw configuration, `referenced`, and `preserve-observed`. Commit exchanges only if those observations still match. The rescan may discover the new revision, but the plugin stays gated until the final configuration check and release acknowledgement. The result separately records the old tree, new tree, reference state, rescan generation, eligibility release, and rollback disposition.

### Client dies after exchange

The journal shows `LIVE_TREE_EXCHANGED`, so shell startup keeps the plugin gated. Recovery verifies the exact candidate and retained prior tree. It either resumes the gated rescan and reaches `COMMITTED`, restores the exact prior tree and reaches `ROLLED_BACK`, or records `MANUAL_ATTENTION`. It does not infer intent from directory names.

### Response is lost after commit

The caller repeats `status` or the exact `commit` using the same operation ID. Omarchy returns the durable original terminal receipt. A new operation ID is not used to guess whether the first commit happened.

## Future schema-v2 compatibility

PR [omacom/omarchy#8956](https://github.com/omacom/omarchy/pull/8956) is architectural precedent for immutable candidate revisions, inert staging, explicit activation, retained rollback identity, and stale-binding rejection. This protocol does not depend on that PR's branch, code, sandbox, permission broker, worker, providers, or schema-v2 activation service.

A future implementation may advertise `secure-schema-v2-lifecycle/v1` and map candidate tokens to immutable revisions internally. It may reuse the operation and exact-identity envelope, but schema-v2 permission review remains a separate authority decision. A client selects an explicitly advertised capability; release numbers or directory layouts are not capability probes.

## Decisions deferred to O-3

O-3 selects the concrete canonical tree profile and identifier, descriptor-pinning and traversal mechanism, atomic install/update primitive, durability barriers, `.git` treatment, helper language, packaging boundary, and fault-injection method. Those decisions may fill implementation-defined identifiers in this contract but MUST NOT weaken its state transitions, exact preconditions, fail-closed recovery, or multidimensional result.
