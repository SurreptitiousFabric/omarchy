# ADR: Filesystem helper and packaging boundary

## Status

Proposed for Gate A review. This is the O-3 decision record and bounded prototype evidence, not production code.

## Decision

Implement the filesystem and durable-journal critical section as one small Linux-native helper written in C, built as part of the existing `omarchy` package, and invoked by thin hidden Omarchy commands. Keep policy, user interaction, and shell IPC outside the helper. Do not use Bash or Python for security-critical traversal, identity calculation, namespace mutation, or durability.

The helper will live in an explicitly buildable source subtree selected during O-4 rather than under `bin/`; the compiled executable will be package-owned under `/usr/lib/omarchy/` and will not be a directly advertised user command. The public JSON command surface remains in the main Omarchy repository. The sibling `omarchy-pkgs` repository will require a narrow packaging change to compile and install the helper, but no new runtime language package is required because Omarchy's base build environment already includes Clang and LLVM.

## Options considered

| Option | Advantages | Rejected limitations |
| --- | --- | --- |
| Bash and coreutils | Matches current command style; no new runtime. | Cannot hold descriptor-relative traversal across decisions, express `openat`/`O_NOFOLLOW` safely, bind an opened tree rather than a replaceable path, perform `renameat2(RENAME_NOREPLACE|RENAME_EXCHANGE)` portably, or place exact durability and fault points around syscalls. Multiple subprocesses enlarge replacement windows. |
| Mise-selected Python | Clearer structured data and tests; `os.open`, directory FDs, `fsync`, and bounded traversal are available. | Standard library lacks a direct `renameat2` interface; `ctypes` or a compiled extension recreates a native boundary. Shipping would add or rely on a general interpreter and make descriptor/error discipline less reviewable than a purpose-built helper. Python remains suitable for non-production test generation only when project-pinned through Mise. |
| Small C helper | Direct Linux syscall and descriptor semantics; no interpreter; exact error handling, bounds, durability, and fault points; fits package-owned helper model. | Requires careful memory/error review, a build step, architecture builds, and a small `omarchy-pkgs` change. Selected because those costs are explicit and testable. |

Rust would improve memory safety but introduces a new compiler and dependency/toolchain packaging boundary for a very small syscall-oriented helper. It can be reconsidered if maintainers prefer it, but it is not the smallest integration with current Omarchy packaging.

## Canonical tree identity profile

Register the production identifier `omarchy-runtime-tree-sha256-v1`. Its input is a domain-separated canonical byte stream generated from a descriptor-pinned root:

1. Open the supplied root as a directory with `O_NOFOLLOW|O_CLOEXEC`, then traverse only with `openat`/`fstatat(AT_SYMLINK_NOFOLLOW)` relative to already-open directory descriptors.
2. Reject invalid UTF-8, absolute paths, empty components, `.`/`..`, embedded NUL, symlinks, hard-linked regular files with link count other than one, devices, FIFOs, sockets, and any file type not explicitly allowed.
3. Exclude exactly the root `.git` entry and everything beneath it. Reject another `.git` path at any lower level. Git metadata is management state, not runtime content.
4. Sort each directory's UTF-8 names by unsigned encoded byte order. Emit a domain header and length-prefixed records for every directory and regular file, binding relative path bytes, entry type, normalized mode, file length, and file content. Normalize directory mode to `0755`; bind regular files as `0644` or `0755` according to whether any execute bit is set. Ignore ownership and timestamps.
5. Hash the complete stream with SHA-256 and format the result `omarchy-runtime-tree-sha256-v1:<64 lowercase hex>`.
6. Enforce production constants for maximum depth, entry count, individual file size, total bytes, and relative-path bytes. The exact constants are selected and tested in O-4; changing them does not change identity for an accepted tree but can change whether a tree is accepted.
7. Re-stat every opened regular file after reading and reject changes in device, inode, type, size, link count, normalized mode, or modification/change timestamps. Revalidate the resulting live tree from its pinned parent after namespace mutation.

The spike demonstrates the stream shape, byte-order sorting, content and execute-mode sensitivity, `.git` exclusion, bounds, descriptor-relative descent, and hostile-type rejection. O-4 must replace the prototype stream with the fully specified production encoder and internal SHA-256 implementation or a package-owned audited crypto library.

## Git-managed updates

The inert candidate store retains a transaction-private Git checkout so existing update UX can fetch and display diffs. The runtime identity excludes the root `.git` tree. Commit materializes or exchanges a runtime-only snapshot at `~/.config/omarchy/plugins/<id>` and retains the prior runtime directory as rollback content.

Git management metadata must not be placed back into the watched live runtime directory. Durable plugin management state records the repository origin and exact fetched commit separately from the runtime tree identity. The runtime digest is authoritative for exposure and rollback; a Git commit ID is informational and cannot substitute for it.

This changes current update assumptions and must be integrated deliberately in O-10. It avoids `.git` writes inside the watched namespace and prevents mutable Git metadata from contaminating the runtime identity.

## Namespace operations and durability

- Fresh install uses `renameat2(..., RENAME_NOREPLACE)` between Omarchy-controlled directories on the same filesystem. Existing destinations fail without replacement.
- Update uses `renameat2(..., RENAME_EXCHANGE)` so the candidate becomes live and the exact previous directory moves to the retained slot in one namespace operation.
- Candidate store, live plugin root, journal, and rollback store must be checked at initialization for the required same-filesystem relationship. Cross-filesystem fallback copying during commit is prohibited.
- Journal intent is atomically replaced and its file and parent directory are synchronized before the corresponding namespace operation. After rename/exchange, both affected parents are synchronized before advancing the journal.
- A live directory is reopened from its pinned parent with `O_NOFOLLOW`, its exact identity is recomputed, and only then may the gated rescan proceed.

If the filesystem or kernel does not support the required conditional rename semantics and durability, the capability is not advertised. There is no non-atomic compatibility fallback.

## Fault-injection boundary

Production code will expose test-build-only named fault points before and after every journal replacement, gate-state transition, install rename, update exchange, rollback exchange, parent synchronization, live-tree postcheck, rescan acknowledgement, and eligibility release. Fault selection must be unavailable or inert in packaged release builds.

The O-3 prototype has four namespace points: `before-install`, `after-install`, `before-exchange`, and `after-exchange`. Tests prove the before-image and after-image at each injected process exit. O-5 and O-9 expand this to every durable state transition and recovery branch.

## Packaging impact

The source, protocol wrapper, and tests belong in `omacom/omarchy`. The `omarchy` PKGBUILD in `omacom/omarchy-pkgs` must compile the helper for each supported architecture, install it below `/usr/lib/omarchy/`, and run or package the non-graphical tests as appropriate. This is a required small follow-up in the eventual upstream PR series; it is not a separate runtime package and does not belong in `omarchy-settings`.

The O-3 spike uses project-pinned Mise Clang 21.1.8 only for reproducible contributor evidence. The production PKGBUILD should use Arch's pinned build environment and declare its build dependency through normal packaging metadata rather than installing Mise.

## Prototype evidence

The non-shipping source and harness are `test/spikes/plugin-transaction-fs-helper.c` and `test/spikes/plugin-transaction-fs-helper-test.sh`. The harness compiles with `-std=c17 -Wall -Wextra -Werror -O2` through the project-selected Mise compiler and proves:

- repeatable canonical-stream SHA-256, execute-mode sensitivity, and root `.git` exclusion;
- rejection of symlinks and FIFOs, plus enforced depth and total-byte bounds;
- atomic no-replace install with an existing-target failure that preserves both trees;
- atomic exposure with post-operation identity equality and atomic exchange retaining the exact old directory identity;
- parent-directory `fsync` and descriptor-relative live-directory postcheck on successful mutation; and
- observable pre-image or post-image at all four injected namespace fault points.

The spike does not prove the complete production encoder, journal, recovery, cross-architecture builds, package recipe, or shell gate. Those remain bounded work in O-4 through O-9.
