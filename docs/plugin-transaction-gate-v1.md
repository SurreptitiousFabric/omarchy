# Plugin transaction shell gate v1

## Authority and storage

`omarchy-plugin-transaction-gate/v1` is the one durable shell gate record for one third-party plugin. It is stored as canonical compact JSON plus LF at `gates/<plugin-id>.gate` beneath the verified mode-0700 transaction state root. The filename independently identifies the affected plugin. Records are singly linked regular files of mode 0600. Native code writes a temporary file, synchronizes it, renames it over the authoritative name, and synchronizes the `gates` directory before the shell may acknowledge the transition.

Every mutating gate action acquires the operation lock and then the canonical plugin lifecycle lock. Package-owned native code derives the plugin lock filename as SHA-256 over `omarchy-plugin-transaction-plugin-lock/v1`, NUL, and the canonical plugin ID. The locks remain held through gate synchronization, record and operation validation, transition validation, replacement, parent synchronization, readback, and result generation. Exact same-operation retries wait for their operation lock; a different operation contending for the same plugin receives `plugin-gated-by-another-operation`. Unrelated plugin locks remain independent. Locks are advisory and are not durable transaction evidence.

Every record state is blocking at startup. In particular, `RELEASE_AUTHORIZED` records are not proof that a new shell instance published eligibility. A restart restores the gate and requires a fresh operation-bound rescan and conditional release. Before that rescan, the shell atomically returns the exact `RELEASE_AUTHORIZED` record to `UNLOAD_ACKNOWLEDGED` and clears its old rescan and release evidence. The same transition is used when configuration, registry generation, scan epoch, shell instance, or gate authority changes after native authorization but before in-memory eligibility publication. Unknown inventory entries or an unreadable inventory block all third-party plugins. A malformed record whose valid filename identifies a plugin blocks that plugin and is retained.

## Canonical record

The exact top-level fields are `schema`, `operationId`, `pluginId`, `operationJournalSha256`, `state`, `expected`, `unload`, `rescan`, and `release`. `operationJournalSha256` binds the validated authoritative operation record without copying it. `expected` contains `tree`, `destination`, `configurationSource` (`kind`, `identity`), `referenceProjection`, `referenceState`, and `referencePolicy`. `unload` is `pending` or `acknowledged`. `rescan` contains nullable `shellInstance`, `generation`, `scanEpoch`, `sourceDirectory`, `expectedTree`, `observedTree`, and `outcome`. A completed source directory equals `expected.destination`; the scan epoch makes an acknowledgement stale as soon as any later scan starts, before that scan completes. `release` contains nullable `shellInstance`, `generation`, `configurationEpoch`, and `outcome`.

Allowed states are:

- `GATED`: durable gate installed; unload not yet acknowledged.
- `UNLOAD_ACKNOWLEDGED`: every host loader reports no retained active or pending instance.
- `RESCAN_ACKNOWLEDGED`: exact-tree discovery completed while gated and is bound to one shell instance, current registry generation, scan epoch, and exact source directory.
- `RELEASE_AUTHORIZED`: the same shell instance compared the current accepted source, reference projection and policy, tree, registry generation, scan epoch, configuration epoch, and gate identity. It may publish in-memory eligibility only if all authority remains unchanged when the native write completes.

An exact retry reconstructs these exact durable facts. It does not synthesize `GATED`: `GATED` repeats unload verification, `UNLOAD_ACKNOWLEDGED` remains ready for a gated rescan, a current `RESCAN_ACKNOWLEDGED` preserves its acknowledgement, and stale rescan or `RELEASE_AUTHORIZED` evidence is durably returned to `UNLOAD_ACKNOWLEDGED` before another rescan.

## Configuration and scan authority

One accepted snapshot supplies both loader eligibility and release comparison. It contains the parsed configuration, accepted source kind and identity, exact raw text evidence, and monotonically increasing configuration epoch. Programmatic changes serialize once, complete the atomic FileView write, and synchronously publish this snapshot before returning to the event loop. Failed writes retain the preceding accepted snapshot. External FileView reloads publish through the same function; a notification for bytes already accepted is an idempotent no-op.

The authoritative registry outcome includes the scan subprocess exit status, scan epoch, generation, scan context, every valid third-party source observed for each manifest ID, and invalid source directories. A successful gated acknowledgement requires a successful scanner process, exactly one valid manifest for the requested ID, the requested manifest ID, the registry-selected source equal to the gate's expected destination, and the native runtime-tree identity of that destination equal to the expected tree. Duplicate, missing, malformed, failed, or source-mismatched discovery remains gated. A new scan increments the scan epoch before its process begins, so release cannot use an older acknowledgement while a later scan is in progress.

Schema v1 permits a top-level plugin directory basename to differ from its manifest ID. O-6 preserves that compatibility and binds operation-bound discovery to the exact expected source directory instead of imposing a new basename rule.

## Durability and nonclaims

The native replacement boundary exposes deterministic test-only points before and after write, file synchronization, rename, and parent synchronization. A pre-rename interruption leaves the previous authoritative gate; a post-rename interruption can expose the new gate. A new process first synchronizes the gate directory, reopens and validates the exact visible record, and reconciles from that record rather than from the previous process's exit status. `gate-indeterminate` blocks the affected plugin in the current shell until this exact reconciliation succeeds. Temporary gate records are never authoritative.

There is no physical gate deletion in O-6. This makes every interruption between durable comparison evidence and in-memory release restart as gated. Gate records contain no operation capability and make no plugin-safety, execution, signature, sandbox, or hostile-same-UID claim.
