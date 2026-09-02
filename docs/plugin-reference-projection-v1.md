# Schema-v1 plugin reference projection v1

The authoritative shell configuration snapshot produces a projection for one
canonical plugin ID. Its digest identifier is `sha256:` followed by SHA-256 of
the canonical byte stream below.

The stream starts with these 47 domain bytes (the final byte is NUL):

```
omarchy-schema-v1-reference-projection/v1\0
```

Each matching reference is encoded as three fields, in this order:

```
kind-length:u32be kind:utf8
location-length:u32be location:utf8
plugin-id-length:u32be plugin-id:utf8
```

Records are sorted by the unsigned bytes of their complete encoding. There is
no root record, terminator, count, padding, locale collation, or normalization
of UTF-8 bytes. The stable kinds and logical locations are:

* `selected-bar`, location `bar.id`;
* `bar-widget`, location `bar.layout.left[N]`,
  `bar.layout.center[N]`, or `bar.layout.right[N]`; and
* `plugin`, location `plugins[N]`.

`N` is the zero-based array index written as canonical decimal without leading
zeroes. Duplicate IDs at different locations remain separate records. Inline
settings and unrelated configuration values are not encoded. Invalid accepted
configuration produces no projection and cannot authorize eligibility or
release.

The empty projection digest is
`sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432`.
It is SHA-256 of the domain bytes alone.

The accepted configuration source, parsed snapshot, projection, reference
state, raw-byte evidence hash, and configuration epoch are one shell-owned
observation. A projection digest computed for an earlier epoch is stale.
