# Schema-v1 plugin load race discovery

## Scope and baseline

This note records read-only discovery and a harmless deterministic reproduction for issue O-1. The pinned source baseline is upstream `quattro` commit `b686ed892d9c3020c3336203f6d34cc75b544e2b`. No production behavior is changed by this work.

The bounded claim established here is that current Omarchy update and install operations do not serialize live plugin-directory exposure, configuration reference state, validation, and shell reload. It is not a claim that every update is transiently loaded, that the fixture is safe merely because it is harmless, or that same-UID hostile processes are contained.

## Current lifecycle map

### Add

`bin/omarchy-plugin-add` clones into the hidden directory `~/.config/omarchy/plugins/.add.tmp.<pid>`, validates that tree, reads its manifest ID, checks catalog and target conflicts, moves the staged directory to `~/.config/omarchy/plugins/<id>`, and then separately invokes `omarchy-shell shell rescanPlugins`. Optional enablement occurs after that rescan request.

The hidden staging name is ignored by `PluginRegistry.localPluginIdForPath`, so clone and validation are ordinarily inert. The move to the non-hidden target is not coordinated with configuration observation, however. A plugin ID already referenced in `shell.json` becomes eligible when discovery sees the target. The recursive plugin watcher also observes the move independently of the explicit rescan request.

### Update

`bin/omarchy-plugin-update` fetches into the Git checkout already located at `~/.config/omarchy/plugins/<id>`, optionally displays the diff, runs `git merge --ff-only FETCH_HEAD` in that live directory, validates the resulting live tree, and resets to `ORIG_HEAD` if validation fails. Only after successful processing does the command separately invoke `omarchy-shell shell rescanPlugins`.

The recursive watcher subscribes to `close_write`, `create`, `delete`, and `move` below the live plugin directory. It ignores `.git` paths but maps other changed paths to the top-level plugin ID and emits `localPluginChanged`. The shell restarts a 150 ms timer for those events; the timer independently calls `reloadPlugins`. Nothing in the update command prevents this watcher path from starting before post-merge validation finishes. A later reset can restore files, but it cannot prove that the candidate was never observed or evaluated.

### Configuration and reference state

The user `~/.config/omarchy/shell.json` is independently watched by a `FileView`. A change reloads and parses the file, replaces `shellConfig`, increments the registry revision, and emits `pluginsChanged`. `PluginRegistry.isEnabled` decides eligibility from the current configuration: selected bar ID, bar-layout entries, top-level `plugins[]`, and first-party disable rules.

There is no lock or transaction shared by plugin add/update, the configuration watcher, the plugin-directory watcher, registry scanning, or entry-point loading. Therefore a configuration change can alter reference state during directory exposure or reload, and a private installer lock would not serialize the shell.

## Discovery, reload, and execution path

`PluginRegistry.rescan` starts a process that reads first-party manifests and top-level third-party manifests. `parseScanOutput` validates those manifests, replaces `installedPlugins`, increments `registryRevision`, clears `scanning`, emits `pluginsChanged`, and then emits `scanFinished`.

`shell.reloadPlugins` sets `pluginReloading`, unloads panels, services, and plugin widgets, clears the component cache on the next turn, and calls the registry rescan. When `scanFinished` arrives, the shell clears the reload flag and synchronizes services, panel entries, and widgets. If another watcher event or rescan overlaps scanning, `pluginReloadPending` causes another complete reload cycle.

The current third-party execution sites that a future gate must cover are:

| Kind | Eligibility and construction path | Evaluation behavior |
| --- | --- | --- |
| Bar replacement | `selectedBarId` → `activeBarManifest` → `pluginBarLoader` | An enabled non-default bar uses an asynchronous QML `Loader`. |
| Service | `_syncServices` → `ensureService` | An enabled service uses `Qt.createComponent(..., Component.PreferSynchronous)` and `createObject`. |
| Bar widget | `syncPluginWidgets` → `loadPluginWidget` → `BarWidgetRegistry` | An enabled widget uses asynchronous `Qt.createComponent`; registered components are instantiated by bar slots. |
| Panel | `computePanelEntries` → `Instantiator` delegate loader | An enabled panel is evaluated when summoned, or immediately when `keepLoaded` is true. |
| Overlay | Same shared panel-entry loader | An enabled overlay is evaluated when summoned, or immediately when `keepLoaded` is true. |
| Menu | Same shared panel-entry loader | An enabled menu is evaluated when summoned, or immediately when `keepLoaded` is true. |

Discovery and rescan completion do not prove that a plugin executed successfully. Conversely, on-demand panels, overlays, and menus may remain discovered but unevaluated until opened.

## Deterministic reproduction

`test/shell.d/plugin-load-race-discovery-test.sh` runs the real `omarchy-plugin-update` and `omarchy-plugin-add` scripts against disposable homes with bounded stubs for Git, validation, catalog lookup, and shell IPC.

For update, the Git stub writes the candidate fixture into the live installed directory and waits for a watcher process to observe the candidate entry point before allowing `git merge` to return. The resulting event order is candidate exposed in live directory → watcher observed candidate entry point → validation started → explicit rescan requested. This is a controlled schedule permitted by the current production ordering; it does not claim that Git normally waits for the watcher.

For install, the disposable `shell.json` references the candidate ID before installation. The real add command validates the hidden stage, moves it to the live target, and the observer sees the entry point before the separately requested explicit rescan. This demonstrates the separate pre-reference window without changing the real user configuration.

The fixture at `test/shell.d/fixtures/plugin-load-race/Service.qml` has one effect when its entry point is evaluated: if `OMARCHY_PLUGIN_RACE_MARKER` is set, it appends the fixed line `candidate-v2` to that file. O-1 does not launch it in the developer shell. The harness observes candidate visibility rather than presenting simulated observation as actual QML execution.

### Observed command transcript

The focused reproduction ran on 2026-09-01 from the clean feature worktree at the pinned baseline plus the O-1 artifacts:

```text
$ bash test/shell.d/plugin-load-race-discovery-test.sh
ok - live update candidate can be observed before validation
ok - pre-referenced install becomes observable before explicit rescan
ok - race fixture records entry-point evaluation
ok - production watcher independently reloads live checkout mutations
ok - loader inventory covers every third-party entry-point category
```

The complete `./test/shell` run executed 222 test files. The new O-1 test passed. Six unrelated files failed: `bar-icon-geometry-test.sh`, `config-test.sh`, `launch-about-test.sh`, `runtime-smoke-test.sh`, `snapper-test.sh`, and `unowned-system-paths-test.sh`. Each of those six was rerun from a temporary detached worktree at the untouched pinned baseline and failed there with the same assertion. Three failures depended on the live compositor/session, and three required a sibling `omarchy-pkgs` checkout that was not present. The temporary baseline worktree was removed after comparison.

## Proved observations and bounded inferences

Proved directly from source and automated reproduction:

- update writes candidate bytes into the watched live directory before validation begins;
- watcher observation can occur before that validation begins;
- the explicit update rescan occurs only after validation;
- add validates a hidden stage before exposure, but exposure is not bound to configuration reference state;
- a pre-referenced fresh install becomes visible before the explicit add rescan;
- configuration and plugin-directory changes independently drive registry and loader synchronization;
- all six third-party loader categories consult current registry/configuration state but share no transaction gate.

Timing-dependent inference, not claimed as universal behavior:

- on a particular real machine, a watcher-triggered reload may or may not finish before a fast validation or rollback;
- an on-demand panel, overlay, or menu is not evaluated merely because it was discovered unless it is opened or declares `keepLoaded`;
- the static validator accepting a tree does not establish runtime harmlessness;
- restoring `ORIG_HEAD` does not establish that the candidate was never loaded during the preceding interval.

## Required next boundary

Closing this gap requires Omarchy participation. O-2 can use this evidence to specify an inert stage and explicit commit contract, but O-1 makes no protocol or implementation decision.
