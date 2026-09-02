# Schema-v1 plugin loader and configuration authority inventory

This inventory is normative for O-6. It describes the `quattro` shell at
baseline `764ec7de1ba392f27d04023b3680dec4c0b5f19f`. A new third-party QML
creation site must be added here and routed through the central eligibility
decision before the loader-coverage test will accept it.

## Third-party execution paths

| Category | Creation site | Plugin identifier | Present eligibility | Retained instance | Required gate teardown |
| --- | --- | --- | --- | --- | --- |
| selected bar | `shell.qml`, `pluginBarLoader.source` | `activeBarId` | selected manifest plus non-empty `entryPointUrl` | `pluginBarLoader.item` and `shell.bar` | clear the eligible URL/deactivate the loader and observe no item |
| service | `shell.qml`, `ensureService()` | loop or caller ID | `isEnabled()` plus non-empty `entryPointUrl` | `_services[id]` | invalidate an in-flight component, destroy the instance, and observe no map entry |
| panel, overlay, menu | `shell.qml`, `panelEntry.panelLoader.source` | `panelEntry.pluginId` | `computePanelEntries()` plus non-empty `entryPointUrl` | Loader item, `panelLoaders`, open/pending maps | remove the model entry, close/destroy its Loader item, and observe no registered loader |
| bar widget | `shell.qml`, `loadPluginWidget()` and `Bar.qml`, `registryLoader.sourceComponent` | manifest ID / bar slot ID | `isEnabled()` plus non-empty `entryPointUrl` | asynchronous Component, `pluginWidgetComponents`, `BarWidgetRegistry`, and each bar slot Loader | invalidate an in-flight component, unregister it, clear the component map, and observe no registry entry or slot Loader item |

`PluginRegistry.entryPointUrl()` is the only current producer of third-party
entry-point URLs. It is used by all four paths. Built-in Loader sources under
`shell/plugins/` and `shell/Ui/` are first-party shell implementation and are
not routed through schema-v1 transaction gates.

## Schema-v1 configuration references

The accepted parsed configuration can reference a plugin at these stable
logical locations:

* `bar.id` for the selected bar;
* `bar.layout.left[index]`, `bar.layout.center[index]`, and
  `bar.layout.right[index]` for bar widgets; and
* `plugins[index]` for top-level service, panel, overlay, and menu references.

The `disabledPlugins` list changes the implicit eligibility of bundled
first-party infrastructure. It is not a positive third-party plugin reference.
Inline settings do not create an additional reference: they are properties of
the containing layout or `plugins[index]` entry.

## Configuration authority

`shell.qml` owns the two watched `FileView`s and `applyShellConfig()`. A valid
version-1 user file is accepted in full; otherwise the accepted defaults are a
valid version-1 defaults file or the built-in fallback. `shellConfig` is the
parsed snapshot used by `PluginRegistry.isEnabled()` and the loaders. O-6 must
attach the accepted source identity, reference projection, and monotonically
increasing configuration epoch to this same snapshot; a second parser is not
authoritative.

## Watchers and scans

`PluginRegistry.localPluginWatcher` recursively watches the user plugin
directory and emits `localPluginChanged`. `shell.qml` coalesces that signal
through `localPluginReloadTimer`, unloads plugin instances, clears the QML
component cache, and calls `PluginRegistry.rescan()`. The two configuration
`FileView`s reload the accepted snapshot. `PluginRegistry.scanProcess`
discovers manifests asynchronously and emits `scanFinished` after replacing
`installedPlugins`. `registryRevision` is currently a reactive revision only;
there is no operation-bound generation or shell-instance identity.

## Startup boundary

At baseline, `PluginRegistry.Component.onCompleted` creates the plugin
directory and starts an initial rescan, while `shell.qml.Component.onCompleted`
also requests a rescan and synchronizes services. Consequently third-party
URLs can become non-empty before any durable transaction state is read. O-6
must make third-party eligibility false by default, restore the durable gate
inventory first, and only then permit third-party URL resolution.

The reviewed native transaction state root and journal validator are the
boundary for operation expectations. Durable gate files must be read and
written by package-owned native code; QML consumes validated machine output
and never edits those files directly.
