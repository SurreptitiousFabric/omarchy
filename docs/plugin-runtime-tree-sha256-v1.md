# `omarchy-runtime-tree-sha256-v1`

This document normatively specifies the byte stream hashed by the schema-v1
plugin transaction helper. Implementations MUST produce exactly this stream.

## Integer encoding

`u32be` and `u64be` are unsigned 32-bit and 64-bit integers in network byte
order (most-significant byte first). No native-width integer or locale-dependent
encoding enters the stream.

## Domain

The stream begins with these 31 bytes:

```text
6f 6d 61 72 63 68 79 2d 72 75 6e 74 69 6d 65 2d
74 72 65 65 2d 73 68 61 32 35 36 2d 76 31 00
```

Those bytes are UTF-8/ASCII `omarchy-runtime-tree-sha256-v1` followed by one
NUL byte. They have no length prefix.

## Root and traversal

The supplied root directory itself has no record. Its children are traversed in
depth-first pre-order. At each directory, immediate child names are sorted by
unsigned comparison of their encoded UTF-8 bytes. A directory record is emitted
before any of its descendants. Files emit one record and have no descendants.

Exactly the `.git` entry immediately below the supplied root, including its
contents, is omitted. Any `.git` entry below another directory is invalid rather
than omitted.

## Records

Every accepted directory or regular file emits:

```text
type:u8
path_length:u32be
path:path_length bytes
mode:u32be
content_length:u64be
content:content_length bytes
```

There is no alignment, padding, record count, separator, trailer or root record.
`path` is the UTF-8 relative path from the supplied root, with literal `/` bytes
between components and no leading or trailing `/`.

The type tag is byte `44` hexadecimal (ASCII `D`) for a directory and byte `46`
hexadecimal (ASCII `F`) for a regular file. A directory has mode `000001ed`
hexadecimal (`0755`), zero content length and no content bytes. A regular file
has mode `000001ed` (`0755`) when any source execute bit is set, otherwise
`000001a4` (`0644`). Its content length and exact content bytes follow.

SHA-256 is calculated over the complete concatenation. The external identity is
the lowercase string `omarchy-runtime-tree-sha256-v1:` followed by the 64 digest
hex digits.

## Identity inputs and rejection bounds

Identity includes relative path bytes, type, normalized mode, regular-file
length and regular-file content. It excludes ownership, timestamps, the source
root mode and the root `.git` entry.

The v1 bounds are inclusive: every emitted entry has at most 32 path components
below the unrecorded root. Thus `root/d1/.../d31/file` and
`root/d1/.../d32` are valid level-32 entries, while any file or directory below
`root/d1/.../d32` is an invalid level-33 entry. Other bounds are 4,096 emitted
entries, 1,024 relative-path bytes, 16 MiB per file and 64 MiB total file bytes.
Invalid UTF-8, symlinks, multiply linked regular files, nested `.git`, devices,
FIFOs, sockets, unsupported types, overflow and mutation during traversal are
rejected; no digest is returned.
