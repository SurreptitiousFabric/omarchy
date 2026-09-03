# Schema-v1 plugin loader and configuration authority inventory

This inventory is normative for O-6. Its loader and reference inventory was established against `quattro` at baseline `764ec7de1ba392f27d04023b3680dec4c0b5f19f`; the authority descriptions below describe the O-6 implementation. A new third-party QML creation site must be added here and routed through the central eligibility decision before the loader-coverage test will accept it.

## Third-party execution paths

| Category | Creation site | Plugin identifier | Present eligibility | Retained instance | Required gate teardown |
| --- | --- | --- | --- | --- | --- |
| selected bar | `shell.qml`, `pluginBarLoader.source` | `activeBarId` | selected manifest plus non-empty `entryPointUrl` | `pluginBarLoader.item` and `shell.bar` | clear the eligible URL/deactivate the loader and observe no item |
| service | `shell.qml`, `ensureService()` | loop or caller ID | `isEnabled()` plus non-empty `entryPointUrl` | `_services[id]` | invalidate an in-flight component, destroy the instance, and observe no map entry |
| panel, overlay, menu | `shell.qml`, `panelEntry.panelLoader.source` | `panelEntry.pluginId` | `computePanelEntries()` plus non-empty `entryPointUrl` | Loader item, `panelLoaders`, open/pending maps | remove the model entry, close/destroy its Loader item, and observe no registered loader |
| bar widget | `shell.qml`, `loadPluginWidget()` and `Bar.qml`, `registryLoader.sourceComponent` | manifest ID / bar slot ID | `isEnabled()` plus non-empty `entryPointUrl` | asynchronous Component, `pluginWidgetComponents`, `BarWidgetRegistry`, and each bar slot Loader | invalidate an in-flight component, unregister it, clear the component map, and observe no registry entry or slot Loader item |

`PluginRegistry.entryPointUrl()` is the only current producer of third-party entry-point URLs. It is used by all four paths. Built-in Loader sources under `shell/plugins/` and `shell/Ui/` are first-party shell implementation and are not routed through schema-v1 transaction gates.

## Schema-v1 configuration references

The accepted parsed configuration can reference a plugin at these stable logical locations:

- `bar.id` for the selected bar.
- `bar.layout.left[index]`, `bar.layout.center[index]`, and `bar.layout.right[index]` for bar widgets.
- `plugins[index]` for top-level service, panel, overlay, and menu references.

The `disabledPlugins` list changes the implicit eligibility of bundled first-party infrastructure. It is not a positive third-party plugin reference. Inline settings do not create an additional reference: they are properties of the containing layout or `plugins[index]` entry.

## Configuration authority

`shell.qml` owns the two watched `FileView`s and publishes every accepted configuration through `PluginEligibility.acceptSnapshot()`. A valid version-1 user file is accepted in full; otherwise the accepted defaults are a valid version-1 defaults file or the built-in fallback. The accepted snapshot owns the parsed configuration, source kind, an opaque package-issued source identity, raw text evidence, and monotonically increasing configuration epoch. The identities distinguish the user, packaged-default, and built-in-default authorities without exposing or treating their filesystem paths as identity. `shellConfig` is a readonly view of that parsed configuration, so loaders and release consume one snapshot.

Programmatic mutation serializes one payload, completes the atomic `FileView` write, and publishes that same payload synchronously before returning to the event loop. A failed write retains the preceding snapshot. An external watcher reload uses the same publication function; notification for already accepted bytes is an idempotent no-op. The canonical per-plugin reference projection is derived from this accepted parsed object rather than from a second parser.

## Watchers and scans

`PluginRegistry.localPluginWatcher` recursively watches the user plugin directory and emits `localPluginChanged`. `shell.qml` coalesces that signal through `localPluginReloadTimer`, unloads plugin instances, clears the QML component cache, and calls `PluginRegistry.rescan()`. The two configuration `FileView`s reload through the accepted-snapshot authority.

`PluginRegistry.scanProcess` discovers manifests asynchronously. Scan start increments `scanEpoch` before the subprocess begins; successful completion increments `registryGeneration`. The retained scan result includes process outcome, context, every valid third-party source for each manifest ID, and invalid source directories. Duplicate third-party IDs are not collapsed into one loadable manifest. An operation-bound acknowledgement requires a successful scan, one exact manifest ID, and its selected source directory equal to the gate's expected destination. A later scan start invalidates that acknowledgement before its process can complete.

## Startup boundary

At baseline, `PluginRegistry.Component.onCompleted` creates the plugin directory and starts an initial rescan, while `shell.qml.Component.onCompleted` also requests a rescan and synchronizes services. O-6 keeps third-party eligibility false by default, restores the durable gate inventory, and only then permits third-party URL resolution. Scanning and manifest inspection may finish while inventory is pending, but their URLs remain ineligible.

The reviewed native transaction state root and journal validator are the boundary for operation expectations. Durable gate files must be read and written by package-owned native code; QML consumes validated machine output and never edits those files directly.
