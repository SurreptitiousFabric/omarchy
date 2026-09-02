# Plugin transaction shell gate v1

## Authority and storage

`omarchy-plugin-transaction-gate/v1` is the one durable shell gate record for
one third-party plugin. It is stored as canonical compact JSON plus LF at
`gates/<plugin-id>.gate` beneath the verified mode-0700 transaction state root.
The filename independently identifies the affected plugin. Records are
singly-linked regular files of mode 0600. Native code writes a temporary file,
synchronizes it, renames it over the authoritative name, and synchronizes the
`gates` directory before the shell may acknowledge the transition.

Every record state is blocking at startup. In particular,
`RELEASE_AUTHORIZED` records are not proof that a new shell instance published
eligibility. A restart restores the gate and requires a fresh operation-bound
rescan and conditional release. Unknown inventory entries or an unreadable
inventory block all third-party plugins. A malformed record whose valid
filename identifies a plugin blocks that plugin and is retained.

## Canonical record

The exact top-level fields are `schema`, `operationId`, `pluginId`,
`operationJournalSha256`, `state`, `expected`, `unload`, `rescan`, and
`release`. `operationJournalSha256` binds the validated authoritative operation
record without copying it. `expected` contains `tree`, `destination`,
`configurationSource` (`kind`, `identity`), `referenceProjection`,
`referenceState`, and `referencePolicy`. `unload` is `pending` or
`acknowledged`. `rescan` contains nullable `shellInstance`, `generation`,
`expectedTree`, `observedTree`, and `outcome`. `release` contains nullable
`shellInstance`, `generation`, `configurationEpoch`, and `outcome`.

Allowed states are:

* `GATED`: durable gate installed; unload not yet acknowledged;
* `UNLOAD_ACKNOWLEDGED`: every host loader reports no retained instance;
* `RESCAN_ACKNOWLEDGED`: exact-tree discovery completed while gated; and
* `RELEASE_AUTHORIZED`: the same shell instance compared the current source,
  projection, policy, tree, generation, epoch, and gate identity. It may
  publish in-memory eligibility only if the epoch and gate identity remain
  unchanged when the native write completes.

There is no physical gate deletion in O-6. This makes every interruption
between durable comparison evidence and in-memory release restart as gated.
Gate records contain no operation capability and make no safety, execution,
signature, sandbox, or hostile-same-UID claim.
