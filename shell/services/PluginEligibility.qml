import QtQuick
import Quickshell
import Quickshell.Io

import "PluginReferenceProjection.js" as Projection

QtObject {
  id: authority

  property string omarchyPath: ""
  property string stateRoot: Quickshell.env("XDG_STATE_HOME")
    ? Quickshell.env("XDG_STATE_HOME") + "/omarchy/plugin-transactions-v1"
    : Quickshell.env("HOME") + "/.local/state/omarchy/plugin-transactions-v1"
  property string helperPath: omarchyPath + "/native/plugin-transaction/shell-gate"
  property var acceptedConfig: null
  property string acceptedSourceKind: "absent"
  property string acceptedSourceIdentity: ""
  property string acceptedRawText: ""
  property int configurationEpoch: 0
  property bool inventoryReady: false
  property bool inventoryBlocksAll: true
  property var gates: ({})
  property var results: ({})
  property var commandQueue: []
  property var activeCommand: null
  property var pendingUnloads: ({})
  property var unloadCallback: null
  property var unloadVerifiedCallback: null
  property var rescanCallback: null
  property var registryGenerationProvider: null
  property string shellInstanceId: "shell-" + Date.now().toString(16) + "-" + Math.random().toString(16).slice(2)

  signal eligibilityChanged()
  signal inventoryFinished(bool usable)

  function acceptSnapshot(config, sourceKind, sourceIdentity, rawText) {
    acceptedConfig = config
    acceptedSourceKind = String(sourceKind || "absent")
    acceptedSourceIdentity = String(sourceIdentity || "")
    acceptedRawText = String(rawText || "")
    configurationEpoch++
    eligibilityChanged()
  }

  function referenceSnapshot(pluginId) {
    var entries = Projection.references(acceptedConfig, pluginId)
    if (entries === null) return { valid: false, epoch: configurationEpoch }
    return {
      valid: true,
      epoch: configurationEpoch,
      sourceKind: acceptedSourceKind,
      sourceIdentity: acceptedSourceIdentity,
      state: entries.length === 0 ? "unreferenced" : "referenced",
      entries: entries,
      canonicalBase64: Projection.base64(Projection.canonicalBytes(acceptedConfig, pluginId))
    }
  }

  function isGated(pluginId) {
    return gates[String(pluginId || "")] !== undefined
  }

  function allows(pluginId, firstParty) {
    if (firstParty === true) return true
    if (!inventoryReady || inventoryBlocksAll) return false
    return !isGated(pluginId)
  }

  function setGateRecord(pluginId, record) {
    var next = ({})
    for (var key in gates) next[key] = gates[key]
    next[String(pluginId)] = record || { valid: false }
    gates = next
    eligibilityChanged()
  }

  function initialize() {
    inventoryReady = false
    inventoryBlocksAll = true
    inventoryProcess.command = [helperPath, "inventory"]
    inventoryProcess.running = true
  }

  function validOperation(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(String(value || ""))
  }

  function validPlugin(value) {
    return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(String(value || ""))
      && String(value).indexOf("..") === -1 && String(value).indexOf("omarchy.") !== 0
  }

  function setResult(operationId, pluginId, status, detail) {
    var next = ({})
    for (var key in results) next[key] = results[key]
    next[String(operationId)] = { operationId: String(operationId), pluginId: String(pluginId), status: String(status), detail: String(detail || "") }
    results = next
  }

  function transactionState(operationId) {
    return JSON.stringify(results[String(operationId)] || { operationId: String(operationId), status: "unknown" })
  }

  function enqueue(item) {
    var next = commandQueue.slice()
    next.push(item)
    commandQueue = next
    runNext()
  }

  function runNext() {
    if (activeCommand || commandQueue.length === 0) return
    var next = commandQueue.slice()
    var candidate = next.shift()
    commandQueue = next
    if ((candidate.type === "projection" || candidate.type === "release")
        && !releaseBindingCurrent(candidate)) {
      setResult(candidate.operationId, candidate.pluginId, "release-precondition-mismatch",
        "configuration epoch, registry generation, or gate changed before helper invocation")
      runNext()
      return
    }
    activeCommand = candidate
    actionProcess.command = activeCommand.command
    actionProcess.running = true
  }

  function gatePlugin(operationId, pluginId) {
    if (!validOperation(operationId) || !validPlugin(pluginId)) return "invalid-identity"
    setResult(operationId, pluginId, "gate-pending", "")
    enqueue({ type: "install", operationId: operationId, pluginId: pluginId,
      command: [helperPath, "install", operationId, pluginId] })
    return "pending"
  }

  function acknowledgeUnload(operationId, pluginId) {
    enqueue({ type: "unload", operationId: operationId, pluginId: pluginId,
      command: [helperPath, "acknowledge-unload", operationId, pluginId, shellInstanceId] })
  }

  function setPendingUnload(operationId, pluginId, acknowledging) {
    var next = ({})
    for (var key in pendingUnloads) next[key] = pendingUnloads[key]
    next[String(pluginId)] = { operationId: String(operationId), acknowledging: acknowledging === true }
    pendingUnloads = next
  }

  function clearPendingUnload(pluginId) {
    var next = ({})
    for (var key in pendingUnloads) if (key !== String(pluginId)) next[key] = pendingUnloads[key]
    pendingUnloads = next
  }

  function verifyPendingUnload(pluginId) {
    var key = String(pluginId)
    var pending = pendingUnloads[key]
    var gateRecord = gates[key]
    if (!pending || pending.acknowledging === true || !gateRecord
        || gateRecord.operationId !== pending.operationId) return
    if (unloadVerifiedCallback && unloadVerifiedCallback(key)) {
      setPendingUnload(pending.operationId, key, true)
      acknowledgeUnload(pending.operationId, key)
    } else {
      setResult(pending.operationId, key, "unload-incomplete", "loader retained an active or pending instance")
    }
  }

  function verifyPendingUnloads() {
    for (var pluginId in pendingUnloads) verifyPendingUnload(pluginId)
  }

  function rescanGated(operationId, pluginId) {
    if (!validOperation(operationId) || !validPlugin(pluginId) || !isGated(pluginId)) return "gate-missing"
    setResult(operationId, pluginId, "gated-rescan-pending", "")
    if (!rescanCallback || rescanCallback(operationId, pluginId) !== true) {
      setResult(operationId, pluginId, "gated-rescan-busy", "ordinary-or-other scan active")
      return "busy"
    }
    return "pending"
  }

  function acknowledgeRescan(operationId, pluginId, generation) {
    enqueue({ type: "rescan", operationId: operationId, pluginId: pluginId,
      command: [helperPath, "acknowledge-rescan", operationId, pluginId, shellInstanceId, String(generation)] })
  }

  function releasePlugin(operationId, pluginId) {
    if (!validOperation(operationId) || !validPlugin(pluginId) || !isGated(pluginId)) return "gate-missing"
    var gateRecord = gates[String(pluginId)]
    if (!gateRecord || gateRecord.operationId !== operationId || gateRecord.state !== "RESCAN_ACKNOWLEDGED") return "gated-rescan-missing"
    if (!registryGenerationProvider || Number(registryGenerationProvider()) !== Number(gateRecord.generation)) {
      setResult(operationId, pluginId, "release-retained", "stale rescan generation")
      return "stale-rescan-generation"
    }
    var snapshot = referenceSnapshot(pluginId)
    if (!snapshot.valid) return "configuration-invalid"
    setResult(operationId, pluginId, "release-comparison-pending", "")
    enqueue({ type: "projection", operationId: operationId, pluginId: pluginId,
      generation: Number(gateRecord.generation), shellInstance: String(gateRecord.shellInstance || ""),
      operationJournalSha256: String(gateRecord.operationJournalSha256 || ""), snapshot: snapshot,
      command: [helperPath, "projection-digest", snapshot.canonicalBase64] })
    return "pending"
  }

  function releaseBindingCurrent(command) {
    var gateRecord = gates[String(command.pluginId)]
    return gateRecord && gateRecord.valid === true
      && gateRecord.operationId === command.operationId
      && gateRecord.state === "RESCAN_ACKNOWLEDGED"
      && Number(gateRecord.generation) === Number(command.generation)
      && gateRecord.shellInstance === command.shellInstance
      && command.shellInstance === shellInstanceId
      && gateRecord.operationJournalSha256 === command.operationJournalSha256
      && command.snapshot.epoch === configurationEpoch
      && registryGenerationProvider
      && Number(registryGenerationProvider()) === Number(command.generation)
      && isGated(command.pluginId)
  }

  function retainAuthorizedRelease(command, detail) {
    setResult(command.operationId, command.pluginId, "release-retaining", detail)
    enqueue({ type: "retain-release", operationId: command.operationId, pluginId: command.pluginId,
      generation: command.generation, shellInstance: command.shellInstance,
      operationJournalSha256: command.operationJournalSha256, detail: detail,
      command: [helperPath, "retain-release", command.operationId, command.pluginId,
        command.shellInstance, String(command.generation)] })
  }

  function refreshGateFromResult(command, payload) {
    if (command.type === "install") {
      setGateRecord(command.pluginId, { operationId: command.operationId, valid: true, state: "GATED",
        operationJournalSha256: String(payload.operationJournalSha256 || "") })
      setPendingUnload(command.operationId, command.pluginId, false)
      if (unloadCallback) unloadCallback(command.pluginId)
      verifyPendingUnload(command.pluginId)
    } else if (command.type === "unload") {
      clearPendingUnload(command.pluginId)
      setGateRecord(command.pluginId, { operationId: command.operationId, valid: true, state: "UNLOAD_ACKNOWLEDGED",
        operationJournalSha256: String(payload.operationJournalSha256 || "") })
      setResult(command.operationId, command.pluginId, payload.status || "gate-installed-unload-acknowledged", "")
    } else if (command.type === "rescan") {
      setGateRecord(command.pluginId, { operationId: command.operationId, valid: true, state: "RESCAN_ACKNOWLEDGED",
        generation: payload.generation, shellInstance: String(payload.shellInstance || ""),
        operationJournalSha256: String(payload.operationJournalSha256 || "") })
      setResult(command.operationId, command.pluginId, payload.status || "gated-rescan-complete", JSON.stringify(payload))
    } else if (command.type === "projection") {
      var digest = String(actionStdout.text || "").trim()
      if (!/^sha256:[0-9a-f]{64}$/.test(digest) || !releaseBindingCurrent(command)) {
        setResult(command.operationId, command.pluginId, "release-precondition-mismatch", "configuration epoch, registry generation, or gate changed")
      } else {
        enqueue({ type: "release", operationId: command.operationId, pluginId: command.pluginId,
          generation: command.generation, epoch: command.snapshot.epoch, snapshot: command.snapshot,
          shellInstance: command.shellInstance, operationJournalSha256: command.operationJournalSha256,
          command: [helperPath, "authorize-release", command.operationId, command.pluginId,
            command.shellInstance, String(command.generation), String(command.snapshot.epoch),
            command.snapshot.sourceKind, command.snapshot.sourceIdentity, digest, command.snapshot.state] })
      }
    } else if (command.type === "release") {
      if (!releaseBindingCurrent(command)) {
        retainAuthorizedRelease(command, "configuration epoch, registry generation, shell instance, or gate changed")
      } else {
        var next = ({})
        for (var key in gates) if (key !== command.pluginId) next[key] = gates[key]
        gates = next
        eligibilityChanged()
        setResult(command.operationId, command.pluginId, "released", "discovery only; execution not observed")
      }
    } else if (command.type === "retain-release") {
      setGateRecord(command.pluginId, { operationId: command.operationId, valid: true, state: "UNLOAD_ACKNOWLEDGED",
        operationJournalSha256: String(payload.operationJournalSha256 || command.operationJournalSha256 || "") })
      setResult(command.operationId, command.pluginId, "release-retained", command.detail || "release authority changed")
    }
  }

  property Process actionProcess: Process {
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var command = authority.activeCommand
      var payload = ({})
      if (exitCode === 0 && command.type !== "projection") {
        try { payload = JSON.parse(actionStdout.text || "{}") } catch (error) { exitCode = 2 }
      }
      if (exitCode === 0) authority.refreshGateFromResult(command, payload)
      else {
        if (command.type === "unload") authority.setPendingUnload(command.operationId, command.pluginId, false)
        if (command.type === "retain-release")
          authority.setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        authority.setResult(command.operationId, command.pluginId,
          command.type.indexOf("release") !== -1 || command.type === "projection" ? "release-retained" : "gate-operation-failed",
          String(actionStderr.text || "invalid helper result").trim())
      }
      authority.activeCommand = null
      authority.runNext()
    }
  }

  property Process inventoryProcess: Process {
    stdout: StdioCollector { id: inventoryStdout; waitForEnd: true }
    stderr: StdioCollector { id: inventoryStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var next = ({})
      var globalFailure = exitCode !== 0
      if (!globalFailure) {
        try {
          var result = JSON.parse(inventoryStdout.text || "")
          globalFailure = result.schema !== "omarchy-plugin-gate-inventory/v1" || result.status !== "ok"
          if (Array.isArray(result.gates)) {
            for (var index = 0; index < result.gates.length; index++) {
              var item = result.gates[index]
              if (item && item.pluginId) {
                if (item.valid) {
                  var record = item.record
                  next[String(item.pluginId)] = {
                    valid: true,
                    operationId: record.operationId,
                    state: record.state,
                    generation: record.rescan ? record.rescan.generation : null,
                    shellInstance: record.rescan ? String(record.rescan.shellInstance || "") : "",
                    operationJournalSha256: String(record.operationJournalSha256 || ""),
                    releaseShellInstance: record.release ? String(record.release.shellInstance || "") : "",
                    releaseGeneration: record.release ? record.release.generation : null
                  }
                } else next[String(item.pluginId)] = { valid: false }
              }
            }
          }
        } catch (error) {
          globalFailure = true
        }
      }
      gates = next
      inventoryBlocksAll = globalFailure
      inventoryReady = true
      eligibilityChanged()
      inventoryFinished(!globalFailure)
      if (!globalFailure) {
        for (var pluginId in next) {
          var gateRecord = next[pluginId]
          if (gateRecord.valid === true && gateRecord.state === "RELEASE_AUTHORIZED")
            authority.retainAuthorizedRelease({ operationId: gateRecord.operationId, pluginId: pluginId,
              generation: gateRecord.releaseGeneration, shellInstance: gateRecord.releaseShellInstance,
              operationJournalSha256: gateRecord.operationJournalSha256 }, "shell restarted before release completion")
        }
      }
      if (globalFailure) console.warn("Plugin gate inventory failed closed:", inventoryStderr.text || "invalid inventory")
    }
  }
}
