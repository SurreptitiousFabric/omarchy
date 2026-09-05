#!/bin/bash
# Sourced by the existing isolated offscreen lifecycle harness. Reuse its
# production shell, native helpers, supervisor, and accepted observation reads.
# shellcheck disable=SC2154,SC2034

rollback_namespace() {
  local prefix=$1 path identity object values=()
  for path in "$case_candidate" "$case_live"; do
    identity=absent object=absent
    if [[ -e $path || -L $path ]]; then
      [[ -d $path && ! -L $path ]] || fail "$case_name unexpected namespace object"
      identity=$("$helper" identity "$path")
      object=$(stat -c '%d:%i' "$path")
    fi
    values+=("$identity" "$object")
  done
  jq -n --arg candidate "${values[0]}" --arg candidateObject "${values[1]}" \
    --arg live "${values[2]}" --arg liveObject "${values[3]}" \
    '{candidate:$candidate,candidateObject:$candidateObject,live:$live,liveObject:$liveObject}' >"$prefix.namespace.json"
  [[ $(realpath -m "$case_candidate") != "$plugin_dir/"* ]] || fail "candidate slot is inside discovery"
  if [[ $case_kind == "update" ]]; then
    [[ $case_live != "$plugin_dir/$case_plugin" && ! -e $plugin_dir/$case_plugin ]] || fail "update adopted an ID-named destination"
  fi
  ! rg -F "O8-CANDIDATE-EVALUATED:$case_plugin" "$log" >/dev/null || fail "$case_name candidate marker evaluated"
}

rollback_counts() {
  local file=$1 output=$2
  jq -Rn --arg op "$case_operation" '
    [inputs | split(" ")] as $calls
    | if all($calls[]; length == 4 and .[0] == $op and (.[3] | test("^[0-9]+$"))) then
      {forward:([$calls[] | select(.[1] == "namespace-mutate" and (.[2] == "install" or .[2] == "exchange"))] | length),
       reverse:([$calls[] | select(.[1] == "namespace-mutate" and (.[2] == "rollback-install" or .[2] == "rollback-exchange"))] | length),
       reconciliation:([$calls[] | select(.[1] == "namespace-reconcile")] | length),total:($calls | length)}
      else error("unexpected operation/call identity") end' <"$file" >"$output"
}

assert_rollback_counts() {
  local file=$1 reverse=$2
  jq -e --argjson reverse "$reverse" \
    '.forward == 0 and .reverse == $reverse and .reconciliation == 0 and .total == $reverse' "$file" >/dev/null
}

rollback_binding_unchanged() {
  jq -e --slurpfile staged "$case_dir/staged.journal.json" --arg binding "$case_binding" \
    '.operationId == $staged[0].operationId and .pluginId == $staged[0].pluginId
     and .normalizedRequest == $staged[0].normalizedRequest
     and .candidate == ($staged[0].candidate + {role:"candidate"})
     and .capabilityHash == $staged[0].capabilityHash and .operationBindingSha256 == $binding' \
    "$case_journal" >/dev/null || fail "$case_name immutable operation authority changed"
  [[ $(configuration_binding "$case_journal") == "$case_binding" ]] || fail "$case_name stable binding payload changed"
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg binding "$case_binding" \
    --arg destination "$case_live" --arg role "$case_role" --argjson target "$case_target" \
    '.operationId == $op and .pluginId == $plugin and .operationBindingSha256 == $binding
     and .expected.destination == $destination and .expected.targetRole == $role
     and .expected.tree == $target.identity and .unload == "acknowledged"' \
    "$case_gate" >/dev/null || fail "$case_name gate lost operation/target binding"
}

rollback_entry() {
  cp "$case_journal" "$case_dir/entry.journal.json"
  cp "$case_gate" "$case_dir/entry.gate.json"
  rollback_binding_unchanged
  jq -e --arg state "$case_intent" --arg outcome "$case_outcome" --arg role "$case_role" \
    --argjson target "$case_target" --arg destination "$case_live" --arg candidate "$case_identity" \
    --arg kind "$case_reverse" --arg slot "$case_operation" '
    .state == "ROLLBACK_STARTED" and .reason == "rescan-request-failed" and .gate == "established"
    and .rollback == "pending" and .namespaceIntent.state == $state and .namespaceIntent.kind == $kind
    and .namespaceIntent.destination == $destination and .namespaceIntent.candidate == $candidate
    and .namespaceIntent.sourceSlot == (if $role == "absence" then "live" else $slot end)
    and .namespaceIntent.prior == $target.identity
    and .rollbackEvidence == {state:$state,targetRole:$role,target:$target,outcome:$outcome}
    and .rescan.outcome == "not-requested" and .release.outcome == "not-requested"
    and .terminalReceipt.state == "not-requested"' "$case_journal" >/dev/null || fail "$case_name incorrect durable entry boundary"
  jq -e '.state == "UNLOAD_ACKNOWLEDGED" and .unload == "acknowledged"
    and .rescan.outcome == "not-requested" and .release.outcome == "not-requested"
    and .terminalReceipt.state == "not-requested"' "$case_gate" >/dev/null || fail "$case_name entry gate was not blocking"
  state "$case_plugin" >"$case_dir/entry.qml-state.json"
  jq -e --arg op "$case_operation" --arg binding "$case_binding" '
    .thirdPartyAllowed == false and .gate.valid == true and .gate.operationId == $op
    and .gate.operationBindingSha256 == $binding and .gate.state == "UNLOAD_ACKNOWLEDGED"
    and .directUrl == "" and .serviceActive == false and .pendingService == false
    and .pendingTerminalHandoff == null
    and all(.rollbackHistory[]; .status != "rollback-rescan-pending" and .status != "released")' \
    "$case_dir/entry.qml-state.json" >/dev/null || fail "$case_name entry QML authority was not blocking"
  [[ ! -s $rollback_runtime/rescan-dispatches ]] || fail "$case_name rollback rescan already reached QML"
  rollback_namespace "$case_dir/entry"
  if [[ $case_boundary == "before-reverse" ]]; then
    jq -e --arg candidate "$case_identity" --arg prior "$case_active_identity" \
      --slurpfile staged "$case_dir/staged.namespace.json" '
      .live == $candidate and .liveObject == $staged[0].candidateObject
      and .candidate == $prior and .candidateObject == $staged[0].liveObject' \
      "$case_dir/entry.namespace.json" >/dev/null || fail "$case_name forward layout is not exact"
  else
    cmp "$case_dir/staged.namespace.json" "$case_dir/entry.namespace.json" || fail "$case_name durable restoration is not exact"
  fi
}

assert_rollback_terminal() {
  local result=$1 qml=$2
  diff -u <(jq -S . "$case_dir/expected-result.json") <(jq -S . "$result") || return 1
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg shell "$case_shell" '
    .thirdPartyAllowed == true and .gate == null and .pendingTerminalHandoff == null
    and .shellInstance == $shell and .results[$op].operationId == $op and .results[$op].pluginId == $plugin
    and .results[$op].status == "terminal-pair-reconciled"
    and ([.rollbackHistory[] | select(.operationId == $op and .pluginId == $plugin
      and .shellInstance == $shell and .status == "terminal-pair-reconciled" and .allowed == true and .blocked == false)] | length) == 1' \
    "$qml" >/dev/null
}

rollback_expected_result() {
  # Literal accepted public-result semantics. Dynamic scan identity comes from
  # separately checked real QML evidence, never from the response mapper.
  local previous='{"state":"absent"}'
  if [[ $case_kind == "update" ]]; then
    previous=$(jq -cn --arg digest "sha256:${case_active_identity#omarchy-runtime-tree-sha256-v1:}" \
      '{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}')
  fi
  jq -n --arg op "$case_operation" --arg plugin "$case_plugin" --arg kind "$case_kind" \
    --arg candidate "sha256:${case_identity#omarchy-runtime-tree-sha256-v1:}" --argjson previous "$previous" \
    --arg role "$case_role" --arg shell "$case_shell" --argjson generation "$case_generation" \
    --argjson scanEpoch "$case_scan_epoch" --argjson epoch "$case_epoch" --arg policy "$case_policy" \
    --arg projection "$(<"$case_dir/before.projection-sha256")" \
    --arg raw "sha256:$(sha256sum "$case_dir/before.accepted.json" | cut -d' ' -f1)" \
    --slurpfile before "$case_dir/before.json" '
    {source:$before[0].configurationSource,rawSha256:$raw,referenceProjectionSha256:$projection,
     referenceState:$before[0].referenceState,referencePolicy:$policy} as $config
    | {protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$op,pluginId:$plugin,
       state:"ROLLED_BACK",status:"rolled-back",reason:"rescan-request-failed",operation:$kind,
       candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$candidate},
       previousTree:$previous,observedActive:$previous,filesystem:{live:$previous,previous:$previous},
       observedConfiguration:$config,configuration:{before:$config,after:$config},
       registry:{state:"completed",rescan:"completed",shellInstance:$shell,generation:$generation,scanEpoch:$scanEpoch},
       release:{outcome:"authorized",shellInstance:$shell,generation:$generation,configurationEpoch:$epoch},
       eligibility:{durableOutcome:"restored",currentShell:"released"},
       rollback:{state:"completed",evidenceState:"completed",targetRole:$role,outcome:"restored",target:$previous},
       recovery:{state:"none",reason:null}}' >"$case_dir/expected-result.json"
}

rollback_qml_completion() {
  state "$case_plugin" >"$case_dir/final.qml-state.json"
  shell_ipc shell transactionPluginState "$case_operation" >"$case_dir/reconciliation.json"
  # This payload is the real rollback-rescan completion reported by QML, with
  # the actual native acknowledgement. No expected result is injected.
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" '
    [.rollbackHistory[] | select(.operationId == $op and .pluginId == $plugin
      and .status == "rollback-rescan-complete")]
    | if length == 1 then .[0].detail | fromjson else error("nonunique rollback rescan") end' \
    "$case_dir/final.qml-state.json" >"$case_dir/qml-rescan.json" || fail "$case_name missing actual QML rollback rescan"
  case_generation=$(jq -r .gate.rescan.generation "$case_dir/qml-rescan.json")
  case_scan_epoch=$(jq -r .gate.rescan.scanEpoch "$case_dir/qml-rescan.json")
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg binding "$case_binding" \
    --arg shell "$case_shell" --arg destination "$case_live" --arg role "$case_role" --argjson target "$case_target" '
    .status == "rollback-rescan-complete" and .gate.operationId == $op and .gate.pluginId == $plugin
    and .gate.operationBindingSha256 == $binding and .gate.state == "RESCAN_ACKNOWLEDGED"
    and .gate.rescan.outcome == "completed" and .gate.rescan.shellInstance == $shell
    and .gate.rescan.sourceDirectory == $destination and .gate.rescan.targetRole == $role
    and .gate.rescan.expectedTree == $target.identity and .gate.rescan.observedTree == $target.identity' \
    "$case_dir/qml-rescan.json" >/dev/null || fail "$case_name QML rescan was not operation/target bound"
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg binding "$case_binding" '
    [.rollbackHistory[] | select(.operationId == $op and .pluginId == $plugin)] as $history
    | ($history | map(.status)) as $statuses
    | ($statuses | index("rollback-rescan-complete")) < ($statuses | index("terminal-receipt-pending"))
    and ($statuses | index("terminal-receipt-pending")) < ($statuses | index("released"))
    and ($statuses | index("released")) < ($statuses | index("terminal-pair-reconciled"))
    and any($history[]; .status == "rollback-rescan-complete" and .blocked and (.allowed | not))
    and any($history[]; .status == "terminal-receipt-pending" and .allowed and (.blocked | not)
      and .gate == null and .handoff.operationId == $op and .handoff.intendedState == "ROLLED_BACK"
      and .handoff.gate.operationBindingSha256 == $binding and .handoff.gate.state == "RELEASE_AUTHORIZED")
    and any($history[]; .status == "released" and .allowed and (.blocked | not) and .handoff == null)' \
    "$case_dir/final.qml-state.json" >/dev/null || fail "$case_name missing real eligibility/receipt publication order"
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" \
    '.operationId == $op and .pluginId == $plugin and .status == "terminal-pair-reconciled"' \
    "$case_dir/reconciliation.json" >/dev/null || fail "$case_name current-shell terminal pair not acknowledged"
  rollback_expected_result
  assert_rollback_terminal "$case_dir/fresh-result.json" "$case_dir/final.qml-state.json" || fail "$case_name terminal result/reconciliation mismatch"
}

rollback_finish_assertions() {
  jq -e --arg operation_id "$case_operation" -f "$SOURCE_ROOT/native/plugin-transaction/validate-journal.jq" \
    "$case_journal" >/dev/null || fail "final journal failed its production validator"
  jq -e --arg plugin_id "$case_plugin" -f "$SOURCE_ROOT/native/plugin-transaction/validate-gate.jq" \
    "$case_gate" >/dev/null || fail "final gate failed its production validator"
  jq -e --slurpfile gate "$case_gate" --arg role "$case_role" --argjson target "$case_target" \
    --arg destination "$case_live" --argjson epoch "$case_epoch" --arg shell "$case_shell" --arg slot "$case_operation" '
    .state == "ROLLED_BACK" and .reason == "rescan-request-failed" and .rollback == "completed"
    and .namespaceIntent.state == "completed" and .namespaceIntent.destination == $destination
    and .rollbackEvidence == {state:"completed",targetRole:$role,target:$target,outcome:"restored"}
    and .rescan.outcome == "completed" and .rescan.sourceDirectory == $destination
    and .rescan.expectedTree == $target.identity and .rescan.observedTree == $target.identity
    and .release.outcome == "authorized" and .release.configurationEpoch == $epoch
    and $gate[0].state == "TERMINAL_RECEIPT" and .terminalReceipt == $gate[0].terminalReceipt
    and .terminalReceipt.state == "durable" and .terminalReceipt.intendedJournalState == "ROLLED_BACK"
    and .terminalReceipt.targetRole == $role and .terminalReceipt.target == $target
    and .terminalReceipt.outcome == "restored" and .terminalReceipt.shellInstance == $shell
    and .rescan.shellInstance == $shell and .release.shellInstance == $shell
    and .rescan.generation == .release.generation and .rescan.generation == .terminalReceipt.generation
    and .rescan.scanEpoch == .terminalReceipt.scanEpoch
    and .release.configurationEpoch == .terminalReceipt.configurationEpoch
    and .terminalReceipt.operationBindingSha256 == .operationBindingSha256
    and .terminalReceipt.operationId == .operationId and .terminalReceipt.pluginId == .pluginId
    and (if $role == "absence" then .retainedPrior == {state:"absent",identity:null,slot:null}
      else .retainedPrior == {state:"restored",identity:$target.identity,slot:$slot} end)' \
    "$case_journal" >/dev/null || fail "$case_name terminal journal/receipt relationships differ"
  configuration_observation "$case_dir/after"
  for observation in entry-observation after; do
    jq -e --slurpfile before "$case_dir/before.json" '
      .configurationSource == $before[0].configurationSource and .rawBase64 == $before[0].rawBase64
      and .referenceProjectionBase64 == $before[0].referenceProjectionBase64
      and .referenceState == $before[0].referenceState and .configurationEpoch == $before[0].configurationEpoch' \
      "$case_dir/$observation.json" >/dev/null || fail "$case_name configuration authority changed"
  done
  rollback_qml_completion
  jq -e --arg kind "$case_kind" --arg destination "$case_live" '
    if $kind == "install" then .directUrl == "" and .serviceActive == false and .pendingService == false
    else .directUrl == ("file://" + $destination + "/Service.qml") end' \
    "$case_dir/final.qml-state.json" >/dev/null || fail "$case_name restored registry entry point differs"
  [[ $(wc -l <"$case_dir/fresh-result.json") == 1 ]] || fail "commit response is not one JSON line"
  cmp "$case_dir/fresh-namespace-calls" "$case_dir/fresh-native-dispatches" || fail "fresh helper did not complete dispatch"
  [[ $(wc -l <"$rollback_runtime/rescan-dispatches") == 1 ]] || fail "rollback rescan dispatch count differs"
  # Read-only status cannot make a claim about this shell. Compare every public
  # result dimension and independently prove the durable pair stayed unchanged.
  jq -cn --arg op "$case_operation" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"status",operationId:$op}' \
    | "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/status-result.json" || fail "read-only rollback status failed"
  diff -u <(jq -S '.action="status" | .eligibility.currentShell="not-observed"' "$case_dir/expected-result.json") \
    <(jq -S . "$case_dir/status-result.json") || fail "read-only status lost exact rollback semantics"
  cmp "$case_dir/final.journal.json" "$case_journal" || fail "status rewrote terminal journal"
  cmp "$case_dir/final.gate.json" "$case_gate" || fail "status rewrote terminal gate"
  state "$active_service_id" >"$case_dir/unrelated.qml-state.json"
  jq -e '.thirdPartyAllowed == true and .directUrl != "" and .serviceActive == true' \
    "$case_dir/unrelated.qml-state.json" >/dev/null || fail "unrelated plugin is unavailable"
  printf 'absent\n' >"$case_dir/candidate-marker-result"

  # Assertion-input controls only; neither QML nor durable files are changed.
  jq --arg op "$case_operation" 'del(.results[$op])
    | .rollbackHistory |= map(select(.status != "terminal-pair-reconciled"))' \
    "$case_dir/final.qml-state.json" >"$case_dir/false-released.qml-state.json"
  if assert_rollback_terminal "$case_dir/fresh-result.json" "$case_dir/false-released.qml-state.json" \
    >"$case_dir/false-released-control.log" 2>&1; then
    fail "assertion accepted released without a matching current-shell reconciliation"
  fi
  printf 'rejected released without matching shell reconciliation\n' >"$case_dir/false-released-detected"
  if [[ $case_kind == "update" ]]; then
    jq '.observedActive.tree.digest="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      | .filesystem.live=.observedActive' "$case_dir/fresh-result.json" >"$case_dir/wrong-prior-result.json"
    if assert_rollback_terminal "$case_dir/wrong-prior-result.json" "$case_dir/final.qml-state.json" \
      >"$case_dir/wrong-prior-control.log" 2>&1; then
      fail "assertion accepted wrong restored-prior identity"
    fi
    printf 'rejected wrong restored-prior identity\n' >"$case_dir/wrong-prior-detected"
  fi
  pass "$case_name fresh coordinator completes exact ROLLED_BACK with $case_reverse_count reverse helper invocations and current-shell reconciliation"
  pass "$case_name assertion controls reject false release and wrong prior where applicable"
}

run_rollback_fresh_case() {
  case_kind=$1 case_boundary=$2
  case_name="$case_kind-$case_boundary"
  case $case_name in
    install-before-reverse) case_operation=65000000-0000-4000-8000-000000000001 ;;
    install-before-rescan) case_operation=65000000-0000-4000-8000-000000000002 ;;
    update-before-reverse) case_operation=65000000-0000-4000-8000-000000000003 ;;
    update-before-rescan) case_operation=65000000-0000-4000-8000-000000000004 ;;
    *) fail "unsupported fresh rollback case" ;;
  esac
  case_plugin="acme.o8-rollback-$case_name"
  case_dir="$TMPDIR/rollback-$case_name"
  case_live="$plugin_dir/$case_plugin"
  case_candidate="$state_dir/omarchy/plugin-candidates-v1/$case_operation/candidate"
  case_journal="$OMARCHY_PLUGIN_TRANSACTION_STATE/journals/$case_operation.journal"
  case_gate="$OMARCHY_PLUGIN_TRANSACTION_STATE/gates/$case_plugin.gate"
  case_active_identity=absent case_policy=require-unreferenced case_role=absence
  case_reverse=rollback-install case_target='{"state":"absent","identity":null}'
  case_intent=intended case_outcome=pending case_reverse_count=1
  if [[ $case_boundary == "before-rescan" ]]; then
    case_intent=completed case_outcome=restored case_reverse_count=0
  fi
  rollback_runtime="$runtime_dir/omarchy-o8-rollback-fresh"
  mkdir -p "$case_dir" "$rollback_runtime" "$case_dir/source"
  printf '%s\n' "$case_operation" >"$rollback_runtime/operation"
  : >"$rollback_runtime/namespace-calls"
  : >"$rollback_runtime/native-dispatches"
  : >"$rollback_runtime/rescan-dispatches"
  mkfifo "$rollback_runtime/before-reverse-resume" "$rollback_runtime/before-rescan-resume"
  # Record expectations before running the production operation. Both normal
  # continuations must finish; a safely blocked response is a failing case.
  jq -n --arg kind "$case_kind" --arg boundary "$case_boundary" --arg intent "$case_intent" \
    --argjson reverse "$case_reverse_count" '
    {kind:$kind,boundary:$boundary,entryJournal:"ROLLBACK_STARTED",entryIntent:$intent,
     entryGate:"UNLOAD_ACKNOWLEDGED",status:"rolled-back",reason:"rescan-request-failed",exit:0,
     finalJournal:"ROLLED_BACK",finalGate:"TERMINAL_RECEIPT",durableEligibility:"restored",currentShell:"released",
     freshHelperCounts:{forward:0,reverse:$reverse,reconciliation:0},
     permittedSideEffects:"exact restoration if still forward, rollback rescan, release, receipt and terminal reconciliation"}' \
    >"$case_dir/expectations.json"
  [[ $(shell_ipc shell testStopLocalPluginWatcher) == stopping ]] || fail "rollback could not stop isolated watcher"
  wait_for "isolated ordinary scan drains" '[[ $(state "$case_plugin" | jq -r .registryScanning) == false ]]'
  [[ $(shell_ipc shell testReleaseUnload "$case_plugin") == ok ]] || fail "could not release test unload hold"
  if [[ $case_kind == "update" ]]; then
    case_live="$plugin_dir/prior-directory-$case_name"
    case_policy=preserve-observed case_role=prior-tree case_reverse=rollback-exchange
    mkdir -p "$case_live"
    jq --arg id "$case_plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
      "$FIXTURE_ROOT/manifest.json" >"$case_live/manifest.json"
    printf 'import QtQuick\nItem { property bool priorOnly: true }\n' >"$case_live/Service.qml"
    case_active_identity=$("$helper" identity "$case_live")
    case_target=$(jq -cn --arg identity "$case_active_identity" '{state:"present",identity:$identity}')
    jq --arg id "$case_plugin" '.plugins += [{id:$id}]' "$config_file" >"$case_dir/next.json"
    configuration_reload
    shell_ipc shell rescanPlugins >/dev/null
    wait_for "unique non-ID update source scanned" \
      '[[ $(shell_ipc shell transactionStageObservation "$case_plugin" | jq -r .activeDiscovery.sourceDirectory) == "$case_live" ]]'
    wait_for "prior service callback pending" '[[ $(state "$case_plugin" | jq -r .deferredService) -gt 0 ]]'
    shell_ipc shell testResumeDeferredService "$case_plugin" 0 >/dev/null
    wait_for "exact prior service is active" '[[ $(state "$case_plugin" | jq -r .serviceActive) == true ]]'
  fi
  # Configuration reload can replace an unrelated service's pending callback.
  # Materialize its current callback after setup, before the transaction starts.
  local unrelated_callback
  unrelated_callback=$(state "$active_service_id" | jq '.deferredService - 1')
  shell_ipc shell testResumeDeferredService "$active_service_id" "$unrelated_callback" >/dev/null
  wait_for "unrelated plugin is active before stage" '[[ $(state "$active_service_id" | jq -r .serviceActive) == true ]]'
  state "$active_service_id" >"$case_dir/unrelated-before.qml-state.json"
  jq --arg id "$case_plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$case_dir/source/manifest.json"
  cat >"$case_dir/source/Service.qml" <<EOF
import QtQuick
Item {
  property bool candidateOnly: { console.warn("O8-CANDIDATE-EVALUATED:$case_plugin"); return true }
}
EOF
  case_identity=$("$helper" identity "$case_dir/source")
  [[ $case_identity != "$case_active_identity" ]] || fail "prior and candidate are not distinct"
  configuration_observation "$case_dir/before"
  jq -e --arg kind "$case_kind" --arg destination "$case_live" '
    .configurationSource == {kind:"user",identity:"omarchy-shell-config:user:v1"}
    and .referenceState == (if $kind == "update" then "referenced" else "unreferenced" end)
    and .activeDiscovery == (if $kind == "update" then {state:"present",sourceDirectory:$destination}
      else {state:"absent"} end)' "$case_dir/before.json" >/dev/null || fail "setup lacks exact initial QML authority"
  case_epoch=$(jq -r .configurationEpoch "$case_dir/before.json")
  case_shell=$(jq -r .shellInstance "$case_dir/before.qml-state.json")
  printf '%s\n' "$QS_PID" >"$case_dir/shell-before.pid"
  local expected_active='{"state":"absent"}' token request commit owner fresh_status
  if [[ $case_kind == "update" ]]; then
    expected_active=$(jq -cn --arg digest "sha256:${case_active_identity#omarchy-runtime-tree-sha256-v1:}" \
      '{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}')
  fi
  token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
  request=$(jq -cn --arg op "$case_operation" --arg token "$token" --arg plugin "$case_plugin" \
    --arg source "$case_dir/source" --arg kind "$case_kind" --arg policy "$case_policy" \
    --arg digest "sha256:${case_identity#omarchy-runtime-tree-sha256-v1:}" --argjson active "$expected_active" \
    --arg projection "$(<"$case_dir/before.projection-sha256")" --slurpfile before "$case_dir/before.json" '
    {protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$op,operationToken:$token,
     operation:$kind,pluginId:$plugin,source:{kind:"directory",path:$source},
     candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},expectedActive:$active,
     expectedConfiguration:{source:$before[0].configurationSource,referenceProjectionSha256:$projection,
       referenceState:$before[0].referenceState,referencePolicy:$policy}}')
  printf '%s' "$request" | "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/stage-result.json" || fail "$case_name production stage failed"
  request=""
  cp "$case_journal" "$case_dir/staged.journal.json"
  case_binding=$(configuration_binding "$case_journal")
  rollback_namespace "$case_dir/staged"
  jq -e --arg candidate "$case_identity" --arg prior "$case_active_identity" \
    '.candidate == $candidate and .live == $prior' "$case_dir/staged.namespace.json" >/dev/null || fail "incorrect staged namespace"
  : >"$rollback_runtime/hold-$case_boundary"
  : >"$OMARCHY_LIFECYCLE_FAIL_GATED_RESCAN"
  commit=$(jq -cn --arg operationId "$case_operation" --arg token "$token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}')
  token=""
  printf '%s' "$commit" | "$PYTHON_BIN" "$FIXTURE_ROOT/load-gated-coordinator.py" \
    "$case_dir/owner-process.json" "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/owner-result.json" 2>"$case_dir/owner-error" &
  owner=$! REPLAY_OWNER_PID=$!
  wait_for "$case_name durable rollback boundary" '[[ -e $rollback_runtime/$case_boundary-ready ]]'
  rollback_entry
  kill "$owner"
  wait "$owner" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  assert_reaped "$case_dir/owner-process.json"
  cmp "$case_dir/entry.journal.json" "$case_journal" || fail "original coordinator advanced after barrier"
  cp "$rollback_runtime/namespace-calls" "$case_dir/original-namespace-calls"
  cp "$rollback_runtime/native-dispatches" "$case_dir/original-native-dispatches"
  rollback_counts "$case_dir/original-namespace-calls" "$case_dir/original-counts.json"
  jq -e '.forward == 1 and .reverse == 1 and .reconciliation == 0 and .total == 2' "$case_dir/original-counts.json" >/dev/null || fail "setup lacked real forward/reverse path"
  rollback_counts "$case_dir/original-native-dispatches" "$case_dir/original-dispatch-counts.json"
  jq -e --arg boundary "$case_boundary" '
    (if $boundary == "before-reverse" then 0 else 1 end) as $reverse
    | .forward == 1 and .reverse == $reverse and .reconciliation == 0 and .total == (1 + $reverse)' \
    "$case_dir/original-dispatch-counts.json" >/dev/null || fail "original native dispatch crossed the wrong boundary"
  configuration_observation "$case_dir/entry-observation"
  rm "$rollback_runtime/hold-$case_boundary"
  if [[ ${OMARCHY_LIFECYCLE_ROLLBACK_REPEAT:-0} == 1 ]]; then
    [[ $case_kind == "update" && $case_boundary == "before-rescan" ]] || fail "invalid no-repeat control selection"
    "$NODE_BIN" "$FIXTURE_ROOT/rollback-fresh-copy.mjs" "$test_root" repeat-reverse
    bash -n "$test_root/bin/omarchy-plugin-transaction"
    : >"$rollback_runtime/hold-before-reverse"
  fi
  # The old process group is gone. A new interpreter/production coordinator
  # receives only the commit identity/capability request, with no staged facts
  # or coordinator variables supplied by the caller.
  : >"$rollback_runtime/namespace-calls"
  : >"$rollback_runtime/native-dispatches"
  printf '%s' "$commit" | "$PYTHON_BIN" "$FIXTURE_ROOT/load-gated-coordinator.py" \
    "$case_dir/fresh-process.json" "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/fresh-result.json" 2>"$case_dir/fresh-error" &
  owner=$! REPLAY_OWNER_PID=$!
  commit=""
  if [[ ${OMARCHY_LIFECYCLE_ROLLBACK_REPEAT:-0} == 1 ]]; then
    wait_for "copied no-repeat defect attempts reverse helper" '[[ -e $rollback_runtime/before-reverse-ready ]]'
    kill "$owner"
    wait "$owner" 2>/dev/null || true
    REPLAY_OWNER_PID=""
    assert_fresh_process "$case_dir/owner-process.json" "$case_dir/fresh-process.json"
    rollback_binding_unchanged
    cp "$case_journal" "$case_dir/negative.journal.json"
    cp "$case_gate" "$case_dir/negative.gate.json"
    state "$case_plugin" >"$case_dir/negative.qml-state.json"
    jq -e '.thirdPartyAllowed == false and .gate.state == "UNLOAD_ACKNOWLEDGED"
      and .directUrl == "" and .serviceActive == false and .pendingService == false' \
      "$case_dir/negative.qml-state.json" >/dev/null || fail "no-repeat negative control lost blocking authority"
    rollback_namespace "$case_dir/negative"
    cmp "$case_dir/entry.namespace.json" "$case_dir/negative.namespace.json" || fail "negative barrier permitted a second native mutation"
    [[ ! -s $rollback_runtime/native-dispatches ]] || fail "negative control reached native mutation"
    cp "$rollback_runtime/namespace-calls" "$case_dir/fresh-namespace-calls"
    rollback_counts "$case_dir/fresh-namespace-calls" "$case_dir/fresh-counts.json"
    jq -e '.forward == 0 and .reverse == 1 and .reconciliation == 0 and .total == 1' "$case_dir/fresh-counts.json" >/dev/null || fail "negative did not reach the intended helper path"
    printf 'pre-native reverse attempt; exact restored namespace preserved\n' >"$case_dir/detected-repeat"
    assert_rollback_counts "$case_dir/fresh-counts.json" 0 || fail "restored rollback reverse helper invocation count must be zero"
    fail "no-repeat control was not detected"
  fi
  fresh_status=0
  wait "$owner" || fresh_status=$?
  REPLAY_OWNER_PID=""
  printf '%s\n' "$fresh_status" >"$case_dir/fresh.exit"
  assert_fresh_process "$case_dir/owner-process.json" "$case_dir/fresh-process.json"
  printf '%s\n' "$QS_PID" >"$case_dir/shell-after.pid"
  cmp "$case_dir/shell-before.pid" "$case_dir/shell-after.pid" || fail "isolated QML process changed"
  cp "$rollback_runtime/namespace-calls" "$case_dir/fresh-namespace-calls"
  cp "$rollback_runtime/native-dispatches" "$case_dir/fresh-native-dispatches"
  rollback_counts "$case_dir/fresh-namespace-calls" "$case_dir/fresh-counts.json"
  assert_rollback_counts "$case_dir/fresh-counts.json" "$case_reverse_count" || fail "$case_name wrong fresh helper invocation count"
  rollback_namespace "$case_dir/final"
  cmp "$case_dir/staged.namespace.json" "$case_dir/final.namespace.json" || fail "$case_name exact prior/absence and candidate were not restored"
  cp "$case_journal" "$case_dir/final.journal.json"
  cp "$case_gate" "$case_dir/final.gate.json"
  state "$case_plugin" >"$case_dir/final.qml-state.json"
  ((fresh_status == 0)) || {
    cat "$case_dir/fresh-result.json" >&2
    fail "$case_name fresh rollback did not complete (exit $fresh_status)"
  }
  rollback_binding_unchanged
  rollback_finish_assertions
}
