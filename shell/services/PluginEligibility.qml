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
  property var acceptedSnapshot: ({
    config: null,
    sourceKind: "absent",
    sourceIdentity: "",
    rawText: "",
    epoch: 0
  })
  readonly property var acceptedConfig: acceptedSnapshot.config
  readonly property string acceptedSourceKind: acceptedSnapshot.sourceKind
  readonly property string acceptedSourceIdentity: acceptedSnapshot.sourceIdentity
  readonly property string acceptedRawText: acceptedSnapshot.rawText
  readonly property int configurationEpoch: acceptedSnapshot.epoch
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
  property var rollbackRescanCallback: null
  property var registryAuthorityProvider: null
  property string shellInstanceId: "shell-" + Date.now().toString(16) + "-" + Math.random().toString(16).slice(2)

  signal eligibilityChanged()
  signal inventoryFinished(bool usable)

  function acceptSnapshot(config, sourceKind, sourceIdentity, rawText) {
    var kind = String(sourceKind || "absent")
    var identity = String(sourceIdentity || "")
    var text = String(rawText || "")
    if (acceptedConfig !== null && acceptedSourceKind === kind
        && acceptedSourceIdentity === identity && acceptedRawText === text) return false
    var copied = config === null || config === undefined
      ? null : JSON.parse(JSON.stringify(config))
    acceptedSnapshot = {
      config: copied,
      sourceKind: kind,
      sourceIdentity: identity,
      rawText: text,
      epoch: configurationEpoch + 1
    }
    eligibilityChanged()
    return true
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

  function stageObservation(pluginId) {
    var key = String(pluginId || "")
    var snapshot = acceptedSnapshot
    var sourceKind = String(snapshot.sourceKind || "absent")
    var sourceIdentity = String(snapshot.sourceIdentity || "")
    if (Number(snapshot.epoch) < 1 || (sourceKind !== "user" && sourceKind !== "default")
        || !sourceIdentity)
      return { valid: false, status: "invalid-accepted-configuration" }
    var entries = Projection.references(snapshot.config, key)
    var projectionBytes = Projection.canonicalBytes(snapshot.config, key)
    if (entries === null || projectionBytes === null)
      return { valid: false, status: "invalid-accepted-configuration" }
    var rawBytes
    try {
      rawBytes = Projection.utf8(String(snapshot.rawText || ""))
    } catch (error) {
      return { valid: false, status: "invalid-accepted-configuration" }
    }
    if (rawBytes.length === 0 || rawBytes.length > 32768 || projectionBytes.length > 4096)
      return { valid: false, status: "accepted-configuration-too-large" }
    return {
      valid: true,
      status: "observed",
      schema: "omarchy-plugin-stage-observation/v1",
      pluginId: key,
      configurationSource: {
        kind: sourceKind,
        identity: sourceIdentity
      },
      rawBase64: Projection.base64(rawBytes),
      referenceProjectionBase64: Projection.base64(projectionBytes),
      referenceState: entries.length === 0 ? "unreferenced" : "referenced"
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

  function memoryGate(record, operationId, pluginId) {
    if (!record || typeof record !== "object"
        || record.operationId !== operationId || record.pluginId !== pluginId
        || !record.expected || !record.rescan || !record.release
        || (record.schema === "omarchy-plugin-transaction-gate/v2"
            ? !/^[0-9a-f]{64}$/.test(String(record.operationBindingSha256 || ""))
            : !/^[0-9a-f]{64}$/.test(String(record.operationJournalSha256 || "")))
        || ["GATED", "UNLOAD_ACKNOWLEDGED", "RESCAN_ACKNOWLEDGED", "RELEASE_AUTHORIZED"].indexOf(record.state) === -1)
      return null
    return {
      valid: true,
      operationId: record.operationId,
      state: record.state,
      schema: String(record.schema || "omarchy-plugin-transaction-gate/v1"),
      operationJournalSha256: String(record.operationJournalSha256),
      operationBindingSha256: String(record.operationBindingSha256 || ""),
      expectedDestination: String(record.expected.destination || ""),
      expectedTree: String(record.expected.tree || ""),
      expectedTargetRole: String(record.expected.targetRole || "candidate"),
      generation: record.rescan.generation,
      scanEpoch: record.rescan.scanEpoch,
      sourceDirectory: String(record.rescan.sourceDirectory || ""),
      shellInstance: String(record.rescan.shellInstance || ""),
      releaseShellInstance: String(record.release.shellInstance || ""),
      releaseGeneration: record.release.generation
    }
  }

  function registryBindingCurrent(pluginId, generation, scanEpoch, sourceDirectory) {
    if (!registryAuthorityProvider) return false
    var current = registryAuthorityProvider(pluginId)
    return current && current.scanning !== true && current.scanSuccessful === true
      && current.unique === true
      && Number(current.generation) === Number(generation)
      && Number(current.scanEpoch) === Number(scanEpoch)
      && String(current.sourceDirectory || "") === String(sourceDirectory || "")
  }

  function rollbackRegistryBindingCurrent(pluginId, generation, scanEpoch, sourceDirectory, targetRole) {
    if (!registryAuthorityProvider) return false
    var current = registryAuthorityProvider(pluginId)
    if (!current || current.scanning === true || current.scanSuccessful !== true
        || Number(current.generation) !== Number(generation)
        || Number(current.scanEpoch) !== Number(scanEpoch)) return false
    if (targetRole === "absence") return Number(current.targetCount) === 0
    return current.unique === true && String(current.sourceDirectory || "") === String(sourceDirectory || "")
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
    if ((candidate.type === "projection" || candidate.type === "release"
         || candidate.type === "rollback-projection" || candidate.type === "rollback-release")
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
    var existing = gates[String(pluginId)]
    if (existing && existing.operationId && existing.operationId !== operationId) {
      setResult(operationId, pluginId, "plugin-gated-by-another-operation", "")
      return "conflict"
    }
    if (!existing) setGateRecord(pluginId, { operationId: operationId, valid: false, state: "AUTHORITY_PENDING" })
    setResult(operationId, pluginId, "gate-pending", "")
    enqueue({ type: "install", operationId: operationId, pluginId: pluginId, priorGate: existing || null,
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
    var gateRecord = gates[String(pluginId)]
    if (!gateRecord || gateRecord.valid !== true || gateRecord.operationId !== operationId
        || gateRecord.state !== "UNLOAD_ACKNOWLEDGED") return "unload-incomplete"
    setResult(operationId, pluginId, "gated-rescan-pending", "")
    if (!rescanCallback || rescanCallback(operationId, pluginId) !== true) {
      setResult(operationId, pluginId, "gated-rescan-busy", "ordinary-or-other scan active")
      return "busy"
    }
    return "pending"
  }

  function acknowledgeRescan(operationId, pluginId, binding) {
    if (!binding || binding.valid !== true) {
      setResult(operationId, pluginId, "gated-rescan-failed", binding ? binding.status : "invalid scan result")
      return
    }
    enqueue({ type: "rescan", operationId: operationId, pluginId: pluginId,
      generation: Number(binding.generation), scanEpoch: Number(binding.scanEpoch),
      sourceDirectory: String(binding.sourceDirectory || ""),
      command: [helperPath, "acknowledge-rescan", operationId, pluginId, shellInstanceId,
        String(binding.generation), String(binding.scanEpoch), String(binding.sourceDirectory || "")] })
  }

  function rollbackPlugin(operationId, pluginId, targetRole, targetIdentity) {
    if (!validOperation(operationId) || !validPlugin(pluginId) || !isGated(pluginId)) return "gate-missing"
    var record = gates[String(pluginId)]
    if (!record || record.valid !== true || record.operationId !== operationId) return "gate-missing"
    if (targetRole !== "prior-tree" && targetRole !== "absence") return "invalid-rollback-target"
    if (targetRole === "prior-tree" && !/^omarchy-runtime-tree-sha256-v1:[0-9a-f]{64}$/.test(String(targetIdentity || ""))) return "invalid-rollback-target"
    setResult(operationId, pluginId, "rollback-target-pending", "")
    enqueue({ type: "rollback-retarget", operationId: operationId, pluginId: pluginId,
      targetRole: targetRole, targetIdentity: String(targetIdentity || ""),
      command: [helperPath, "retarget-rollback", operationId, pluginId, shellInstanceId,
        targetRole, String(targetIdentity || "")] })
    return "pending"
  }

  function rollbackRescan(operationId, pluginId) {
    if (!validOperation(operationId) || !validPlugin(pluginId) || !isGated(pluginId)) return "gate-missing"
    var record = gates[String(pluginId)]
    if (!record || record.valid !== true || record.operationId !== operationId
        || record.state !== "UNLOAD_ACKNOWLEDGED") return "unload-incomplete"
    setResult(operationId, pluginId, "rollback-rescan-pending", "")
    if (!rollbackRescanCallback || rollbackRescanCallback(operationId, pluginId, record.expectedTargetRole || record.expectedRole || record.targetRole) !== true) {
      setResult(operationId, pluginId, "rollback-rescan-busy", "ordinary-or-other scan active")
      return "busy"
    }
    return "pending"
  }

  function acknowledgeRollbackRescan(operationId, pluginId, binding) {
    if (!binding || binding.valid !== true) {
      setResult(operationId, pluginId, "rollback-rescan-failed", binding ? binding.status : "invalid scan result")
      return
    }
    enqueue({ type: "rollback-rescan", operationId: operationId, pluginId: pluginId,
      generation: Number(binding.generation), scanEpoch: Number(binding.scanEpoch),
      sourceDirectory: String(binding.sourceDirectory || ""), targetRole: String(binding.targetRole || "absence"),
      command: [helperPath, "acknowledge-rollback-rescan", operationId, pluginId, shellInstanceId,
        String(binding.generation), String(binding.scanEpoch), String(binding.sourceDirectory || "")] })
  }

  function releasePlugin(operationId, pluginId) {
    if (!validOperation(operationId) || !validPlugin(pluginId) || !isGated(pluginId)) return "gate-missing"
    var gateRecord = gates[String(pluginId)]
    if (!gateRecord || gateRecord.operationId !== operationId || gateRecord.state !== "RESCAN_ACKNOWLEDGED") return "gated-rescan-missing"
    if (!registryBindingCurrent(pluginId, gateRecord.generation, gateRecord.scanEpoch, gateRecord.sourceDirectory)) {
      retainAuthorizedRelease({ operationId: operationId, pluginId: pluginId,
        generation: gateRecord.generation, shellInstance: gateRecord.shellInstance,
        scanEpoch: gateRecord.scanEpoch, sourceDirectory: gateRecord.sourceDirectory,
        operationJournalSha256: gateRecord.operationJournalSha256,
        operationBindingSha256: gateRecord.operationBindingSha256 }, "stale rescan generation")
      return "stale-rescan-generation"
    }
    var snapshot = referenceSnapshot(pluginId)
    if (!snapshot.valid) return "configuration-invalid"
    setResult(operationId, pluginId, "release-comparison-pending", "")
    enqueue({ type: "projection", operationId: operationId, pluginId: pluginId,
      generation: Number(gateRecord.generation), shellInstance: String(gateRecord.shellInstance || ""),
      scanEpoch: Number(gateRecord.scanEpoch), sourceDirectory: String(gateRecord.sourceDirectory || ""),
      operationJournalSha256: String(gateRecord.operationJournalSha256 || ""),
      operationBindingSha256: String(gateRecord.operationBindingSha256 || ""), snapshot: snapshot,
      command: [helperPath, "projection-digest", snapshot.canonicalBase64] })
    return "pending"
  }

  function releaseRollbackPlugin(operationId, pluginId) {
    if (!validOperation(operationId) || !validPlugin(pluginId) || !isGated(pluginId)) return "gate-missing"
    var gateRecord = gates[String(pluginId)]
    if (!gateRecord || gateRecord.operationId !== operationId || gateRecord.state !== "RESCAN_ACKNOWLEDGED") return "rollback-rescan-missing"
    var targetRole = String(gateRecord.expectedTargetRole || gateRecord.targetRole || "")
    if (targetRole !== "absence" && targetRole !== "prior-tree") targetRole = gateRecord.expected && gateRecord.expected.targetRole ? gateRecord.expected.targetRole : ""
    if (!rollbackRegistryBindingCurrent(pluginId, gateRecord.generation, gateRecord.scanEpoch, gateRecord.sourceDirectory, targetRole)) return "stale-rollback-rescan"
    var snapshot = referenceSnapshot(pluginId)
    if (!snapshot.valid) return "configuration-invalid"
    setResult(operationId, pluginId, "rollback-release-comparison-pending", "")
    enqueue({ type: "rollback-projection", operationId: operationId, pluginId: pluginId,
      generation: Number(gateRecord.generation), shellInstance: String(gateRecord.shellInstance || ""),
      scanEpoch: Number(gateRecord.scanEpoch), sourceDirectory: String(gateRecord.sourceDirectory || ""),
      operationJournalSha256: String(gateRecord.operationJournalSha256 || ""),
      operationBindingSha256: String(gateRecord.operationBindingSha256 || ""), targetRole: targetRole, snapshot: snapshot,
      command: [helperPath, "projection-digest", snapshot.canonicalBase64] })
    return "pending"
  }

  function releaseBindingCurrent(command) {
    var gateRecord = gates[String(command.pluginId)]
    var targetRole = command.targetRole || "candidate"
    var registryOk = targetRole === "candidate"
      ? registryBindingCurrent(command.pluginId, command.generation, command.scanEpoch, command.sourceDirectory)
      : rollbackRegistryBindingCurrent(command.pluginId, command.generation, command.scanEpoch, command.sourceDirectory, targetRole)
    return gateRecord && gateRecord.valid === true
      && gateRecord.operationId === command.operationId
      && gateRecord.state === "RESCAN_ACKNOWLEDGED"
      && Number(gateRecord.generation) === Number(command.generation)
      && gateRecord.shellInstance === command.shellInstance
      && Number(gateRecord.scanEpoch) === Number(command.scanEpoch)
      && gateRecord.sourceDirectory === command.sourceDirectory
      && command.shellInstance === shellInstanceId
      && (gateRecord.schema === "omarchy-plugin-transaction-gate/v2"
        ? gateRecord.operationBindingSha256 === command.operationBindingSha256
        : gateRecord.operationJournalSha256 === command.operationJournalSha256)
      && command.snapshot.epoch === configurationEpoch
      && registryOk
      && isGated(command.pluginId)
  }

  function rollbackBindingCurrent(command) {
    return releaseBindingCurrent(command)
  }

  function retainAuthorizedRelease(command, detail) {
    setResult(command.operationId, command.pluginId, "release-retaining", detail)
    enqueue({ type: "retain-release", operationId: command.operationId, pluginId: command.pluginId,
      generation: command.generation, shellInstance: command.shellInstance,
      scanEpoch: command.scanEpoch, sourceDirectory: command.sourceDirectory,
      operationJournalSha256: command.operationJournalSha256,
      operationBindingSha256: command.operationBindingSha256, detail: detail,
      command: [helperPath, "retain-release", command.operationId, command.pluginId,
        command.shellInstance, String(command.generation)] })
  }

  function retainTransactionPlugin(operationId, pluginId) {
    var gateRecord = gates[String(pluginId)]
    if (!gateRecord || gateRecord.valid !== true || gateRecord.operationId !== operationId) return "gate-missing"
    if (gateRecord.state !== "RELEASE_AUTHORIZED") return "not-release-authorized"
    retainAuthorizedRelease({ operationId: operationId, pluginId: pluginId,
      generation: gateRecord.releaseGeneration, shellInstance: gateRecord.releaseShellInstance,
      scanEpoch: gateRecord.scanEpoch, sourceDirectory: gateRecord.sourceDirectory,
      operationJournalSha256: gateRecord.operationJournalSha256,
      operationBindingSha256: gateRecord.operationBindingSha256 }, "explicit retain/re-gate")
    return "pending"
  }

  function terminalReceipt(operationId, pluginId, intendedState) {
    var gateRecord = gates[String(pluginId)]
    if (!gateRecord || gateRecord.valid !== true || gateRecord.operationId !== operationId
        || gateRecord.state !== "RELEASE_AUTHORIZED")
      return "release-not-authorized"
    setResult(operationId, pluginId, "terminal-receipt-pending", "")
    enqueue({ type: "terminal-receipt", operationId: operationId, pluginId: pluginId,
      command: [helperPath, "terminal-receipt", operationId, pluginId, String(intendedState || "COMMITTED")] })
    return "pending"
  }

  function refreshGateFromResult(command, payload) {
    if (command.type === "install") {
      var installedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!installedGate) {
        setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        setResult(command.operationId, command.pluginId, "gate-state-invalid", "invalid helper result")
        return
      }
      setGateRecord(command.pluginId, installedGate)
      if (installedGate.state === "GATED") {
        setPendingUnload(command.operationId, command.pluginId, false)
        if (unloadCallback) unloadCallback(command.pluginId)
        verifyPendingUnload(command.pluginId)
      } else if (installedGate.state === "UNLOAD_ACKNOWLEDGED") {
        clearPendingUnload(command.pluginId)
        setResult(command.operationId, command.pluginId, "gate-installed-unload-acknowledged", "exact durable replay")
      } else if (installedGate.state === "RESCAN_ACKNOWLEDGED"
          && installedGate.shellInstance === shellInstanceId
          && registryBindingCurrent(command.pluginId, installedGate.generation,
            installedGate.scanEpoch, installedGate.sourceDirectory)) {
        clearPendingUnload(command.pluginId)
        setResult(command.operationId, command.pluginId, "gated-rescan-complete", "exact durable replay")
      } else {
        clearPendingUnload(command.pluginId)
        retainAuthorizedRelease({ operationId: command.operationId, pluginId: command.pluginId,
          generation: installedGate.state === "RELEASE_AUTHORIZED"
            ? installedGate.releaseGeneration : installedGate.generation,
          shellInstance: installedGate.state === "RELEASE_AUTHORIZED"
            ? installedGate.releaseShellInstance : installedGate.shellInstance,
          scanEpoch: installedGate.scanEpoch, sourceDirectory: installedGate.sourceDirectory,
          operationJournalSha256: installedGate.operationJournalSha256,
          operationBindingSha256: installedGate.operationBindingSha256 },
          "replayed gate authority requires a fresh gated rescan")
      }
    } else if (command.type === "rollback-retarget") {
      var retargetedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!retargetedGate || retargetedGate.state !== "UNLOAD_ACKNOWLEDGED") {
        setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        setResult(command.operationId, command.pluginId, "gate-state-invalid", "invalid rollback target result")
      } else {
        setGateRecord(command.pluginId, retargetedGate)
        setResult(command.operationId, command.pluginId, "rollback-targeted", "")
      }
    } else if (command.type === "unload") {
      var unloadedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!unloadedGate) {
        setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        setResult(command.operationId, command.pluginId, "gate-state-invalid", "invalid helper result")
        return
      }
      clearPendingUnload(command.pluginId)
      setGateRecord(command.pluginId, unloadedGate)
      if (unloadedGate.state === "UNLOAD_ACKNOWLEDGED")
        setResult(command.operationId, command.pluginId, payload.status || "gate-installed-unload-acknowledged", "")
      else
        setResult(command.operationId, command.pluginId, "gate-state-replayed", unloadedGate.state)
    } else if (command.type === "rescan") {
      var rescannedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!rescannedGate || rescannedGate.state !== "RESCAN_ACKNOWLEDGED") {
        setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        setResult(command.operationId, command.pluginId, "gate-state-invalid", "invalid helper result")
        return
      }
      setGateRecord(command.pluginId, rescannedGate)
      setResult(command.operationId, command.pluginId, payload.status || "gated-rescan-complete", JSON.stringify(payload))
    } else if (command.type === "rollback-rescan") {
      var rollbackRescannedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!rollbackRescannedGate || rollbackRescannedGate.state !== "RESCAN_ACKNOWLEDGED") {
        setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        setResult(command.operationId, command.pluginId, "gate-state-invalid", "invalid rollback rescan result")
      } else {
        setGateRecord(command.pluginId, rollbackRescannedGate)
        setResult(command.operationId, command.pluginId, payload.status || "rollback-rescan-complete", JSON.stringify(payload))
      }
    } else if (command.type === "rollback-projection") {
      var rollbackDigest = String(actionStdout.text || "").trim()
      if (!/^sha256:[0-9a-f]{64}$/.test(rollbackDigest) || !rollbackBindingCurrent(command)) {
        setResult(command.operationId, command.pluginId, "rollback-release-precondition-mismatch", "configuration epoch, registry generation, shell instance, or gate changed")
      } else {
        enqueue({ type: "rollback-release", operationId: command.operationId, pluginId: command.pluginId,
          targetRole: command.targetRole, generation: command.generation, epoch: command.snapshot.epoch,
          snapshot: command.snapshot, scanEpoch: command.scanEpoch, sourceDirectory: command.sourceDirectory,
          shellInstance: command.shellInstance, operationJournalSha256: command.operationJournalSha256,
          operationBindingSha256: command.operationBindingSha256,
          command: [helperPath, "authorize-rollback-release", command.operationId, command.pluginId,
            command.shellInstance, String(command.generation), String(command.snapshot.epoch),
            command.snapshot.sourceKind, command.snapshot.sourceIdentity, rollbackDigest, command.snapshot.state] })
      }
    } else if (command.type === "projection") {
      var digest = String(actionStdout.text || "").trim()
      if (!/^sha256:[0-9a-f]{64}$/.test(digest) || !releaseBindingCurrent(command)) {
        setResult(command.operationId, command.pluginId, "release-precondition-mismatch", "configuration epoch, registry generation, or gate changed")
      } else {
        enqueue({ type: "release", operationId: command.operationId, pluginId: command.pluginId,
          generation: command.generation, epoch: command.snapshot.epoch, snapshot: command.snapshot,
          scanEpoch: command.scanEpoch, sourceDirectory: command.sourceDirectory,
          shellInstance: command.shellInstance, operationJournalSha256: command.operationJournalSha256,
          operationBindingSha256: command.operationBindingSha256,
          command: [helperPath, "authorize-release", command.operationId, command.pluginId,
            command.shellInstance, String(command.generation), String(command.snapshot.epoch),
            command.snapshot.sourceKind, command.snapshot.sourceIdentity, digest, command.snapshot.state] })
      }
    } else if (command.type === "release") {
      var authorizedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!authorizedGate || authorizedGate.state !== "RELEASE_AUTHORIZED") {
        setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        setResult(command.operationId, command.pluginId, "release-retained", "invalid helper result")
      } else if (!rollbackBindingCurrent(command)) {
        setGateRecord(command.pluginId, authorizedGate)
        retainAuthorizedRelease(command, "configuration epoch, registry generation, shell instance, or gate changed")
      } else {
        if (authorizedGate.schema === "omarchy-plugin-transaction-gate/v2") {
          terminalReceipt(command.operationId, command.pluginId, "COMMITTED")
        } else {
          var next = ({})
          for (var key in gates) if (key !== command.pluginId) next[key] = gates[key]
          gates = next
          eligibilityChanged()
          setResult(command.operationId, command.pluginId, "released", "discovery only; execution not observed")
        }
      }
    } else if (command.type === "rollback-release") {
      var rollbackAuthorizedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!rollbackAuthorizedGate || rollbackAuthorizedGate.state !== "RELEASE_AUTHORIZED") {
        setResult(command.operationId, command.pluginId, "rollback-release-retained", "invalid helper result")
      } else if (!releaseBindingCurrent(command)) {
        setGateRecord(command.pluginId, rollbackAuthorizedGate)
        retainAuthorizedRelease(command, "rollback configuration epoch, registry generation, shell instance, or gate changed")
      } else {
        terminalReceipt(command.operationId, command.pluginId, "ROLLED_BACK")
      }
    } else if (command.type === "terminal-receipt") {
      var receiptGate = payload.gate
      if (!receiptGate || typeof receiptGate !== "object"
          || receiptGate.schema !== "omarchy-plugin-transaction-gate/v2"
          || receiptGate.state !== "TERMINAL_RECEIPT"
          || receiptGate.operationId !== command.operationId
          || receiptGate.pluginId !== command.pluginId
          || !/^[0-9a-f]{64}$/.test(String(receiptGate.operationBindingSha256 || ""))
          || !receiptGate.terminalReceipt
          || receiptGate.terminalReceipt.state !== "durable") {
        setResult(command.operationId, command.pluginId, "release-retained", "invalid terminal receipt")
      } else {
        var terminalNext = ({})
        for (var terminalKey in gates) if (terminalKey !== command.pluginId) terminalNext[terminalKey] = gates[terminalKey]
        gates = terminalNext
        eligibilityChanged()
        setResult(command.operationId, command.pluginId, "released", "discovery only; execution not observed")
      }
    } else if (command.type === "retain-release") {
      var retainedGate = memoryGate(payload.gate, command.operationId, command.pluginId)
      if (!retainedGate || retainedGate.state !== "UNLOAD_ACKNOWLEDGED") {
        setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
        setResult(command.operationId, command.pluginId, "release-retained", "invalid helper result")
        return
      }
      setGateRecord(command.pluginId, retainedGate)
      setPendingUnload(command.operationId, command.pluginId, false)
      if (unloadCallback) unloadCallback(command.pluginId)
      verifyPendingUnload(command.pluginId)
      setResult(command.operationId, command.pluginId, "release-retained", command.detail || "release authority changed")
    }
  }

  property Process actionProcess: Process {
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var command = authority.activeCommand
      var payload = ({})
      if (exitCode === 0 && command.type !== "projection" && command.type !== "rollback-projection") {
        try { payload = JSON.parse(actionStdout.text || "{}") } catch (error) { exitCode = 2 }
      }
      if (exitCode === 0) authority.refreshGateFromResult(command, payload)
      else {
        if (command.type === "unload") authority.setPendingUnload(command.operationId, command.pluginId, false)
        if (command.type === "install" && !command.priorGate)
          authority.setGateRecord(command.pluginId, { operationId: command.operationId, valid: false, state: "INVALID" })
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
                  var restored = authority.memoryGate(record, record.operationId, String(item.pluginId))
                  next[String(item.pluginId)] = restored || { valid: false }
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
              scanEpoch: gateRecord.scanEpoch, sourceDirectory: gateRecord.sourceDirectory,
              operationJournalSha256: gateRecord.operationJournalSha256 }, "shell restarted before release completion")
        }
      }
      if (globalFailure) console.warn("Plugin gate inventory failed closed:", inventoryStderr.text || "invalid inventory")
    }
  }
}
