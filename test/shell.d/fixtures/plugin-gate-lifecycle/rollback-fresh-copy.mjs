import fs from 'node:fs'
import path from 'node:path'

// Observations only, in the temporary installation. All decisions, callbacks,
// native results, and durable replacements still run their production code.
const root = process.argv[2]
const mode = process.argv[3] || 'observe'
function replace(file, anchor, replacement) {
  const source = fs.readFileSync(file, 'utf8')
  if (source.split(anchor).length !== 2) throw new Error(`nonunique anchor in ${file}`)
  fs.writeFileSync(file, source.replace(anchor, replacement))
}

if (mode === 'repeat-reverse') {
  // One copied branch defect. The test stops the resulting helper call before
  // native dispatch; native safety checks are never bypassed.
  replace(path.join(root, 'bin/omarchy-plugin-transaction'),
    '  if [[ $namespace_state != completed && $rollback_layout == forward ]]; then\n',
    '  if [[ $rollback_layout == forward || $rollback_layout == restored ]]; then\n')
} else if (mode === 'observe') {
  replace(path.join(root, 'shell/services/PluginEligibility.qml'),
    '  function setResult(operationId, pluginId, status, detail) {\n',
    `  property var testRollbackHistory: []
  function setResult(operationId, pluginId, status, detail) {
    var history = testRollbackHistory.slice()
    history.push({operationId: String(operationId), pluginId: String(pluginId),
      status: String(status), detail: String(detail || ""),
      shellInstance: shellInstanceId, configurationEpoch: configurationEpoch,
      blocked: isGated(pluginId), allowed: allows(pluginId, false),
      gate: gates[String(pluginId)] || null,
      handoff: pendingTerminalHandoffs[String(pluginId)] || null})
    testRollbackHistory = history
`)
  replace(path.join(root, 'shell/shell.qml'),
    '        results: shell.pluginEligibility.results,\n',
    `        rollbackHistory: shell.pluginEligibility.testRollbackHistory.filter(function(event) { return event.pluginId === key }),
        pendingTerminalHandoff: shell.pluginEligibility.pendingTerminalHandoffs[key] || null,
        results: shell.pluginEligibility.results,
`)
} else {
  throw new Error(`unknown copied-install mode: ${mode}`)
}
