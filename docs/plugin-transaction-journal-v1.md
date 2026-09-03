# Plugin transaction journal v1

## Scope

`omarchy-plugin-transaction-journal/v1` is the authoritative O-5/O-7 record for one staged schema-v1 plugin operation. It records inert candidate publication and an optional explicit abort while that candidate is still inert. It does not represent activation, a shell gate, a rescan, live-tree mutation, rollback, or trust in plugin code.

## Storage

The state root is outside ordinary plugin discovery and has mode `0700`, independent of caller umask. It contains `journals`, `locks/operations`, and `locks/plugins`, each a real non-symlink directory with mode `0700`. The authoritative record is `journals/<operation-id>.journal`, mode `0600`, a singly linked regular file. Candidate paths recorded by the journal are relative names beneath the separately verified candidate store.

Temporary journals are created in `journals` with `O_CREAT|O_EXCL`, written completely, synchronized, renamed over the authoritative name, and followed by synchronization of `journals`. A temporary file is never read as an operation record. A successful state transition is not reported until the parent synchronization succeeds. Failure of that post-rename synchronization is `journal-indeterminate`, not proof that either the old or new version survived. A later invocation, while holding the operation lock, must synchronize `journals` and then reopen and revalidate the authoritative record before it can use visible bytes as durable state. Newly created state-directory entries are likewise followed by synchronization of their containing directory.

Corrupt authoritative bytes are copied, not renamed away. The byte-for-byte evidence copy is synchronized and published under a SHA-256-derived no-replace name before a canonical corruption `MANUAL_ATTENTION` tombstone replaces the authoritative record. Until that replacement is durable, the corrupt bytes remain authoritative and the operation ID cannot be reused. The tombstone records caller-derived identity and capability fields as null because corrupt bytes cannot establish their original values; the caller that discovers corruption never becomes the operation owner.

## Canonical encoding

The journal is one compact JSON object followed by one LF. Its schema is `omarchy-plugin-transaction-journal/v1`. Objects are serialized with keys in encoded-byte order and no insignificant whitespace. Every object has an exact expected key set and every value has an exact expected JSON type; unknown or missing keys are rejected. A reader parses the bounded file, applies the complete schema/type checks, serializes it with `jq -cS`, and requires byte-for-byte equality with the stored file including the final LF. Duplicate keys, alternate whitespace, alternate key order, or other noncanonical representations therefore fail closed even though `jq` ordinarily resolves duplicate keys while parsing.

The top-level fields are `schema`, `operationId`, `pluginId`, `normalizedRequest`, `capabilityHash`, `candidate`, `publication`, `gate`, `registry`, `rollback`, `retainedPrior`, `state`, `reason`, and `corruptEvidenceSha256`. `normalizedRequest.facts` contains the exact immutable protocol, operation, source, caller candidate, expected active/configuration/reference facts, explicitly labelled stage-observation provenance, and destination. `candidate` contains the expected and observed identities plus exact temporary and completed slot names. Later lifecycle dimensions use only the precise O-5 initial values `not-established`, `not-requested`, `not-applicable`, and `not-captured`.

The normalized request digest is SHA-256 over `omarchy-plugin-transaction-request/v1` followed by NUL and the canonical compact JSON immutable request object plus its final LF, excluding candidate observations produced during import. The operation capability hash is SHA-256 over `omarchy-plugin-transaction-capability/v1` followed by NUL and the unpadded base64url capability text read from the private input channel. These digests and the candidate tree identity are distinct facts.

## States and transitions

- `REQUEST_BOUND`: the immutable request, capability hash, and one exact deterministic operation-owned temporary slot are durable; no candidate identity or publication is claimed. Import creates and populates only that slot. A restart may remove and recreate that exact incomplete slot, but never scans for or removes another artifact. It may advance to `PUBLICATION_INTENT` or `MANUAL_ATTENTION`.
- `PUBLICATION_INTENT`: the exact validated candidate identity and exact temporary/completed slots are durable before publication. It may advance to `STAGED`, `RECOVERY_REQUIRED`, or `MANUAL_ATTENTION`.
- `STAGED`: the exact candidate is verified at the completed slot, candidate-store parent synchronization succeeded, and this journal state is durable. O-7 may advance it to `ABORTED` only while the gate, registry, rollback, and retained-prior dimensions remain at their inert initial values and the exact candidate is still present. A later verification that proves the record and candidate contradictory may replace it with `MANUAL_ATTENTION`; that fail-closed corruption response is not normal transaction progression.
- `ABORTED`: the owner explicitly aborted an exact still-inert `STAGED` operation. Candidate identity remains recorded, publication remains `completed-durable`, gate remains `not-established`, registry remains `not-requested`, rollback remains `not-applicable`, retained prior remains `not-captured`, and reason is exactly `owner-aborted`. The candidate remains retained. This state has no O-7 transition.
- `RECOVERY_REQUIRED`: publication outcome is indeterminate and exact reconciliation is required. It may advance to `PUBLICATION_INTENT`, `STAGED`, or `MANUAL_ATTENTION`.
- `MANUAL_ATTENTION`: exact reconciliation cannot establish a safe O-5 outcome, or corrupt/contradictory evidence was found. It has no automatic O-5 transition.

Only `STAGED` is a successful stage result. `ABORTED` is a terminal owner result, not a successful restage. A journal claiming either state without the exact completed candidate is contradictory. O-5/O-7 does not gate the ordinary shell.

## Locks

The operation lock is `locks/operations/<operation-id>.lock`. It is acquired in blocking mode for stage and exact replay and is held from journal read/create through the response generated from the durable record. The plugin lifecycle lock is `locks/plugins/<sha256("omarchy-plugin-transaction-plugin-lock/v1" || NUL || plugin-id)>`; package-owned native code derives that filename from the canonical plugin ID, so callers never select it. It is acquired nonblocking and returns `plugin-busy` on conflict. When both are required, the universal order is operation lock then plugin lifecycle lock. O-7 abort holds both in that order through validation, transition, parent synchronization, readback, and result generation. Inert stage retains the O-5 operation-lock-only behavior.

Locks are advisory and disappear when the holding process exits. Lock-file existence, PID values, timestamps, and deletion are never transaction evidence. The journal plus exact candidate identities determines reconciliation.

## Publication reconciliation

Reconciliation inspects only the exact temporary and completed slots recorded by the journal and recomputes their exact runtime-tree identities. An exact temporary candidate with an absent completed slot resumes publication. An exact completed candidate is actively synchronized and may then advance durably to `STAGED`. Both slots, a wrong identity, a symlink/wrong type, an absent candidate after publication intent, or ownership that cannot be established advances to `MANUAL_ATTENTION` without deleting evidence. No scan for plausible operation-named directories is permitted.

## Retention and nonclaims

Staged and aborted candidates, indeterminate artifacts, corrupt evidence, and future retained-prior facts are retained. O-5/O-7 performs no expiry, garbage collection, age/PID inference, live plugin mutation, activation, rescan, rollback, signer verification, or safety assessment. O-7 reads the authoritative accepted shell snapshot but does not parse or mutate configuration. Same-UID processes remain able to alter user-owned state; exact revalidation detects changes at the observation point but is not an operating-system security boundary.
