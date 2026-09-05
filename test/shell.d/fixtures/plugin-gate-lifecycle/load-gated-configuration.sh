#!/bin/bash
# Sourced only by the existing isolated real-QML lifecycle harness.
# The harness supplies paths/functions and reads REPLAY_OWNER_PID during
# cleanup; wait_for evaluates predicates in this function's variable scope.
# shellcheck disable=SC2154,SC2034

assert_reaped() {
  local record=$1 pid
  jq -e '. as $record | .allChildrenReaped == true and (.reaped | index($record.coordinatorPid)) != null' \
    "$record" >/dev/null || fail "coordinator was not reaped"
  for pid in $(jq -r '.reaped[]' "$record"); do
    ! kill -0 "$pid" 2>/dev/null || fail "owned coordinator/helper still exists: $pid"
  done
  kill -0 "$QS_PID" || fail "isolated QML shell did not survive coordinator exit"
}

assert_fresh_process() {
  assert_reaped "$1"
  assert_reaped "$2"
  [[ $(jq -r .coordinatorPid "$1") != $(jq -r .coordinatorPid "$2") ]] || fail "replay reused original coordinator PID"
}

configuration_observation() {
  local prefix=$1
  shell_ipc shell transactionStageObservation "$case_plugin" >"$prefix.json"
  state "$case_plugin" >"$prefix.qml-state.json"
  jq -e --arg plugin "$case_plugin" --arg discovery "$plugin_dir" --arg root "$OMARCHY_PLUGIN_TRANSACTION_STATE" \
    '.valid == true and .status == "observed" and .pluginId == $plugin
     and .discoveryDirectory == $discovery and .transactionStateRoot == $root' \
    "$prefix.json" >/dev/null || fail "$case_name observation is not actual accepted QML authority"
  jq -r .rawBase64 "$prefix.json" | base64 -d >"$prefix.accepted.json"
  jq -r .referenceProjectionBase64 "$prefix.json" | base64 -d >"$prefix.projection"
  printf 'sha256:%s\n' "$(sha256sum "$prefix.projection" | cut -d' ' -f1)" >"$prefix.projection-sha256"
  jq -e --slurpfile observation "$prefix.json" --slurpfile accepted "$prefix.accepted.json" \
    '.configurationEpoch == $observation[0].configurationEpoch
     and .acceptedSourceKind == $observation[0].configurationSource.kind
     and .acceptedSourceIdentity == $observation[0].configurationSource.identity
     and .acceptedConfig == $accepted[0]
     and .referenceSnapshot.canonicalBase64 == $observation[0].referenceProjectionBase64
     and .referenceSnapshot.state == $observation[0].referenceState' \
    "$prefix.qml-state.json" >/dev/null || fail "$case_name accepted snapshot is not coherent"
}

configuration_binding() {
  # Independent construction of the documented stable-binding payload. The
  # existing native helper supplies only domain hashing, not comparison/reason.
  jq -cS '{operationId,pluginId,operation:.normalizedRequest.facts.operation,
    requestDigest:.normalizedRequest.digest,candidateExpected:.candidate.expected,
    candidateObserved:.candidate.observed,candidateSlot:.candidate.completedSlot,
    expectedActive:.normalizedRequest.facts.expectedActive,destination:.normalizedRequest.facts.destination}' "$1" \
    | "$helper" domain-hash omarchy-plugin-transaction-operation-binding/v1
}

configuration_namespace() {
  local prefix=$1 candidate_identity live_identity=absent
  candidate_identity=$("$helper" identity "$case_candidate")
  if [[ -e $case_live || -L $case_live ]]; then live_identity=$("$helper" identity "$case_live"); fi
  jq -n --arg candidate "$candidate_identity" --arg live "$live_identity" \
    --arg candidateObject "$(stat -c '%d:%i' "$case_candidate")" \
    --arg liveObject "$(if [[ -e $case_live ]]; then stat -c '%d:%i' "$case_live"; else printf absent; fi)" \
    '{candidate:$candidate,live:$live,candidateObject:$candidateObject,liveObject:$liveObject}' >"$prefix.namespace.json"
  [[ $(realpath "$case_candidate") != "$plugin_dir/"* ]] || fail "candidate entered discovery"
}

configuration_gate() {
  local prefix=$1 expected_state=$2
  cp "$case_journal" "$prefix.journal.json"
  cp "$case_gate" "$prefix.gate.json"
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg state "$expected_state" \
    --arg binding "$case_binding" --arg policy "$case_policy" \
    --arg projection "$(<"$case_dir/before.projection-sha256")" --slurpfile before "$case_dir/before.json" \
    '.operationId == $op and .pluginId == $plugin and .state == $state
     and .state != "REJECTED" and .gate == "established"
     and .operationBindingSha256 == $binding
     and .normalizedRequest.facts.expectedConfiguration.referencePolicy == $policy
     and .normalizedRequest.facts.expectedConfiguration.referenceProjection == $projection
     and .normalizedRequest.facts.expectedConfiguration.source == $before[0].configurationSource
     and .normalizedRequest.facts.expectedConfiguration.referenceState == $before[0].referenceState
     and .normalizedRequest.facts.stageObservation.provenance == "shell-authoritative-o7"' \
    "$case_journal" >/dev/null || fail "$case_name journal state/binding changed"
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg binding "$case_binding" \
    '.operationId == $op and .pluginId == $plugin and .state == "UNLOAD_ACKNOWLEDGED"
     and .operationBindingSha256 == $binding' "$case_gate" >/dev/null || fail "$case_name gate lost stable binding"
  [[ $(configuration_binding "$case_journal") == "$case_binding" ]] || fail "stable binding payload disagrees"
  state "$case_plugin" >"$prefix.eligibility.json"
  jq -e --arg op "$case_operation" --arg binding "$case_binding" \
    '.gate.operationId == $op and .gate.operationBindingSha256 == $binding
     and .gate.state == "UNLOAD_ACKNOWLEDGED" and .thirdPartyAllowed == false
     and .directUrl == "" and .serviceActive == false and .pendingService == false' \
    "$prefix.eligibility.json" >/dev/null || fail "$case_name candidate became eligible while gated"
  ! rg -F "O8-CANDIDATE-EVALUATED:$case_plugin" "$log" >/dev/null || fail "$case_name candidate entry point evaluated"
}

configuration_reload() {
  mv "$case_dir/next.json" "$config_file"
  [[ $(shell_ipc shell reloadConfig) == "ok" ]] || fail "production FileView reload failed"
  local expected_raw
  expected_raw=$(base64 -w0 "$config_file")
  wait_for "$case_name accepted user FileView reload" \
    '[[ $(shell_ipc shell transactionStageObservation "$case_plugin" | jq -r .rawBase64) == "$expected_raw" ]]'
}

configuration_result() {
  # Complete literal durable-result vector, independent of the production
  # response filter. RECOVERY_REQUIRED deliberately makes no live-tree or
  # current-shell release claim, even though this test separately reads both.
  local previous='{"state":"absent"}'
  if [[ $case_kind == "update" ]]; then
    previous=$(jq -cn --arg digest "sha256:${case_active_identity#omarchy-runtime-tree-sha256-v1:}" \
      '{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}')
  fi
  jq -n --arg op "$case_operation" --arg plugin "$case_plugin" --arg kind "$case_kind" \
    --arg reason "$case_reason" --arg digest "sha256:${case_identity#omarchy-runtime-tree-sha256-v1:}" \
    --argjson previous "$previous" --arg policy "$case_policy" \
    --arg projection "$(<"$case_dir/before.projection-sha256")" \
    --arg raw "sha256:$(sha256sum "$case_dir/before.accepted.json" | cut -d' ' -f1)" \
    --slurpfile before "$case_dir/before.json" '
    {source:$before[0].configurationSource,rawSha256:$raw,referenceProjectionSha256:$projection,
     referenceState:$before[0].referenceState,referencePolicy:$policy} as $configuration
    | {protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$op,pluginId:$plugin,
       state:"RECOVERY_REQUIRED",status:"indeterminate",reason:$reason,operation:$kind,
       candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},
       previousTree:$previous,observedActive:null,filesystem:{live:null,previous:$previous},
       observedConfiguration:$configuration,configuration:{before:$configuration,after:null},
       registry:{state:"not-requested",rescan:"not-requested",shellInstance:null,generation:null,scanEpoch:null},
       release:{outcome:"not-requested",shellInstance:null,generation:null,configurationEpoch:null},
       eligibility:{durableOutcome:"indeterminate",currentShell:"not-observed"},
       rollback:{state:"not-applicable",evidenceState:"not-started",targetRole:"none",outcome:"not-applicable",target:null},
       recovery:{state:"required",reason:$reason}}' >"$case_dir/expected-result.json"
  [[ $(wc -l <"$case_dir/fresh-result.json") == 1 ]] || fail "$case_name response must be one JSON line"
  diff -u <(jq -S . "$case_dir/expected-result.json") <(jq -S . "$case_dir/fresh-result.json") \
    || fail "$case_name post-gate response lost exact durable-result dimensions"
}

run_configuration_case() {
  case_name=$1 case_kind=$2 case_policy=$3 case_reason=$4 case_operation=$5
  case_plugin="acme.o8-authority-$case_name"
  case_dir="$TMPDIR/configuration-$case_name"
  case_live="$plugin_dir/$case_plugin"
  case_candidate="$state_dir/omarchy/plugin-candidates-v1/$case_operation/candidate"
  case_journal="$OMARCHY_PLUGIN_TRANSACTION_STATE/journals/$case_operation.journal"
  case_gate="$OMARCHY_PLUGIN_TRANSACTION_STATE/gates/$case_plugin.gate"
  case_active_identity=absent
  load_runtime="$runtime_dir/omarchy-o8-load-gated"
  mkdir -p "$case_dir/source" "$load_runtime"
  printf '%s\n' "$case_reason" >"$case_dir/expected-reason"
  printf 'case %s: expected %s (source, projection, then state/policy)\n' "$case_name" "$case_reason"
  jq --arg id "$case_plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$case_dir/source/manifest.json"
  printf 'import QtQuick\nItem {\n  property bool entryPointEvaluated: { console.warn("O8-CANDIDATE-EVALUATED:%s"); return true }\n}\n' \
    "$case_plugin" >"$case_dir/source/Service.qml"
  local expected_active='{"state":"absent"}' token request commit owner status
  if [[ $case_kind == "update" ]]; then
    mkdir "$case_live"
    cp "$case_dir/source/manifest.json" "$case_live/manifest.json"
    printf 'import QtQuick\nItem {}\n' >"$case_live/Service.qml"
    case_active_identity=$("$helper" identity "$case_live")
    expected_active=$(jq -cn --arg digest "sha256:${case_active_identity#omarchy-runtime-tree-sha256-v1:}" \
      '{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}')
    jq --arg id "$case_plugin" '.plugins += [{id:$id}]' "$initial_config" >"$case_dir/next.json"
  else
    cp "$initial_config" "$case_dir/next.json"
  fi
  configuration_reload
  shell_ipc shell rescanPlugins >/dev/null
  wait_for "$case_name real registry observes pre-exposure layout" \
    'shell_ipc shell transactionStageObservation "$case_plugin" >"$case_dir/ready.json" && jq -e --arg state "$(if [[ $case_kind == update ]]; then printf present; else printf absent; fi)" ".valid == true and .activeDiscovery.state == \$state" "$case_dir/ready.json" >/dev/null'
  configuration_observation "$case_dir/before"
  case_identity=$("$helper" identity "$case_dir/source")
  # The capability stays in memory/stdin; no request or token is retained.
  token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
  request=$(jq -cn --arg op "$case_operation" --arg token "$token" --arg id "$case_plugin" \
    --arg kind "$case_kind" --arg path "$case_dir/source" --arg policy "$case_policy" \
    --arg digest "sha256:${case_identity#omarchy-runtime-tree-sha256-v1:}" --argjson active "$expected_active" \
    --arg projection "$(<"$case_dir/before.projection-sha256")" --slurpfile observation "$case_dir/before.json" '
    {protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$op,operationToken:$token,
     operation:$kind,pluginId:$id,source:{kind:"directory",path:$path},
     candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest},expectedActive:$active,
     expectedConfiguration:{source:$observation[0].configurationSource,referenceProjectionSha256:$projection,
       referenceState:$observation[0].referenceState,referencePolicy:$policy}}')
  printf '%s' "$request" | "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/stage-result.json" || fail "$case_name production stage failed"
  jq -e '.state == "STAGED" and .status == "ok"' "$case_dir/stage-result.json" >/dev/null || fail "$case_name was not staged"
  request=""
  [[ $(shell_ipc shell testReleaseUnload "$case_plugin") == "ok" ]] || fail "test unload timing release failed"
  commit=$(jq -cn --arg op "$case_operation" --arg token "$token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$op,operationToken:$token}')
  token=""
  printf '%s\n' "$case_operation" >"$load_runtime/operation"
  : >"$load_runtime/namespace-calls"
  : >"$load_runtime/hold-before-namespace"
  rm -f "$load_runtime/namespace-ready" "$load_runtime/namespace-resume"
  mkfifo "$load_runtime/namespace-resume"
  printf '%s' "$commit" | "$PYTHON_BIN" "$FIXTURE_ROOT/load-gated-coordinator.py" \
    "$case_dir/owner-process.json" "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/owner-result.json" 2>"$case_dir/owner-error" &
  owner=$!
  REPLAY_OWNER_PID=$owner
  wait_for "$case_name production LOAD_GATED barrier" \
    '[[ -e $load_runtime/namespace-ready && $(jq -r .state "$case_journal") == LOAD_GATED ]] && kill -0 "$owner"'
  [[ $(wc -l <"$load_runtime/namespace-calls") == 1 ]] || fail "original coordinator did not reach one forward helper barrier"
  case_binding=$(configuration_binding "$case_journal")
  configuration_gate "$case_dir/gated" LOAD_GATED
  configuration_namespace "$case_dir/gated"
  [[ $(jq -r .candidate "$case_dir/gated.namespace.json") == "$case_identity" ]] || fail "gated candidate identity differs"
  [[ $(jq -r .live "$case_dir/gated.namespace.json") == "${case_active_identity:-absent}" ]] || fail "gated live identity differs"
  kill "$owner"
  wait "$owner" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  assert_reaped "$case_dir/owner-process.json"
  [[ $(jq -r .state "$case_journal") == "LOAD_GATED" ]] || fail "owner advanced after barrier"
  : >"$load_runtime/namespace-calls"
  rm -f "$load_runtime/hold-before-namespace" "$load_runtime/namespace-ready" "$load_runtime/namespace-resume"

  case $case_name in
    source)
      # An empty user file follows the ordinary FileView fallback path to the
      # unchanged, valid packaged default. The target remains unreferenced.
      : >"$config_file"
      shell_ipc shell reloadConfig >/dev/null
      wait_for "accepted packaged-default source" \
        '[[ $(shell_ipc shell transactionStageObservation "$case_plugin" | jq -r .configurationSource.identity) == omarchy-shell-config:packaged-default:v1 ]]'
      ;;
    projection)
      jq '.plugins |= reverse' "$case_dir/before.accepted.json" >"$case_dir/next.json"
      configuration_reload
      ;;
    update-reference)
      jq --arg id "$case_plugin" '.plugins |= map(select(.id != $id))' "$case_dir/before.accepted.json" >"$case_dir/next.json"
      configuration_reload
      ;;
    install-reference)
      jq --arg id "$case_plugin" '.plugins += [{id:$id}]' "$case_dir/before.accepted.json" >"$case_dir/next.json"
      configuration_reload
      ;;
  esac
  configuration_observation "$case_dir/after"
  jq -e --slurpfile before "$case_dir/before.json" \
    '.configurationEpoch > $before[0].configurationEpoch' "$case_dir/after.json" >/dev/null || fail "real accepted change did not advance epoch"
  [[ $(jq -r .shellInstance "$case_dir/before.qml-state.json") == $(jq -r .shellInstance "$case_dir/after.qml-state.json") ]] || fail "configuration change restarted QML shell"
  if [[ $case_name == "source" ]]; then
    jq -e '.configurationSource == {kind:"default",identity:"omarchy-shell-config:packaged-default:v1"}
      and .referenceState == "unreferenced"' "$case_dir/after.json" >/dev/null || fail "source fallback was not accepted"
    jq -e '.configurationSource == {kind:"user",identity:"omarchy-shell-config:user:v1"}
      and .referenceState == "unreferenced"' "$case_dir/before.json" >/dev/null || fail "source case did not begin at user configuration"
    cmp "$case_dir/before.projection" "$case_dir/after.projection" || fail "source case did not isolate source comparison"
    cmp "$case_dir/after.accepted.json" "$test_root/config/omarchy/shell.json" || fail "fallback raw bytes are not actual packaged defaults"
  else
    jq -e --slurpfile before "$case_dir/before.json" \
      '.configurationSource == $before[0].configurationSource' "$case_dir/after.json" >/dev/null || fail "reference case changed source"
    ! cmp -s "$case_dir/before.projection" "$case_dir/after.projection" || fail "real reference change did not change projection bytes"
    [[ $(<"$case_dir/before.projection-sha256") != $(<"$case_dir/after.projection-sha256") ]] || fail "projection hash did not change"
    local before_state=referenced after_state=referenced
    [[ $case_name != "update-reference" ]] || after_state=unreferenced
    [[ $case_name != "install-reference" ]] || before_state=unreferenced
    [[ $(jq -r .referenceState "$case_dir/before.json") == "$before_state" &&
    $(jq -r .referenceState "$case_dir/after.json") == "$after_state" ]] || fail "reference-state transition differs from case"
  fi
  configuration_gate "$case_dir/changed" LOAD_GATED
  configuration_namespace "$case_dir/changed"
  cmp "$case_dir/gated.namespace.json" "$case_dir/changed.namespace.json" || fail "configuration change altered namespace"

  if [[ -n ${OMARCHY_LIFECYCLE_AUTHORITY_BYPASS:-} ]]; then
    [[ $OMARCHY_LIFECYCLE_AUTHORITY_BYPASS == "$case_name" && ($case_name == "source" || $case_name == "projection") ]] || fail "invalid targeted comparison bypass"
    "$NODE_BIN" "$FIXTURE_ROOT/bypass-load-gated-comparison.mjs" "$test_root/bin/omarchy-plugin-transaction" "$case_name"
    bash -n "$test_root/bin/omarchy-plugin-transaction"
    : >"$load_runtime/hold-before-namespace"
    mkfifo "$load_runtime/namespace-resume"
  fi
  # Reset after the old coordinator and every owned helper are reaped. Only
  # this fresh invocation can now contribute to the operation's counter.
  : >"$load_runtime/namespace-calls"
  printf '%s\n' "$case_plugin" >"$load_runtime/observe-replay"
  printf '%s' "$commit" | "$PYTHON_BIN" "$FIXTURE_ROOT/load-gated-coordinator.py" \
    "$case_dir/fresh-process.json" "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/fresh-result.json" 2>"$case_dir/fresh-error" &
  owner=$!
  REPLAY_OWNER_PID=$owner
  commit=""
  if [[ -n ${OMARCHY_LIFECYCLE_AUTHORITY_BYPASS:-} ]]; then
    # Keep the existing pre-native barrier: detection requires a real forward
    # helper call, so a syntax/startup failure or a later valid check is never
    # accepted as evidence. No additional safeguard is bypassed.
    wait_for "$case_name bypass attempts forward namespace exposure" '[[ -e $load_runtime/namespace-ready ]]'
    kill "$owner"
    wait "$owner" 2>/dev/null || true
    REPLAY_OWNER_PID=""
    assert_fresh_process "$case_dir/owner-process.json" "$case_dir/fresh-process.json"
    configuration_gate "$case_dir/final" LOAD_GATED
    configuration_namespace "$case_dir/final"
    cmp "$case_dir/changed.namespace.json" "$case_dir/final.namespace.json" || fail "negative barrier failed to retain namespace"
    cp "$load_runtime/namespace-calls" "$case_dir/namespace-calls"
    [[ $(wc -l <"$case_dir/namespace-calls") == 1 ]] || fail "negative control did not attempt exactly one forward helper call"
    printf '%s\n' "$case_name" >"$case_dir/detected-comparison-bypass"
  else
    set +e
    wait "$owner"
    status=$?
    set -e
    REPLAY_OWNER_PID=""
    printf '%s\n' "$status" >"$case_dir/fresh-exit"
    assert_fresh_process "$case_dir/owner-process.json" "$case_dir/fresh-process.json"
    cp "$load_runtime/namespace-calls" "$case_dir/namespace-calls"
  fi
  cp "$load_runtime/replay-observation.json" "$case_dir/fresh-observation.json"
  rm "$load_runtime/observe-replay"
  diff -u <(jq -S . "$case_dir/after.json") <(jq -S . "$case_dir/fresh-observation.json") || fail "fresh coordinator did not read the changed QML authority"
  [[ ! -s "$case_dir/namespace-calls" ]] || fail "$case_name no-exposure invariant: namespace-helper invocation count must be zero"
  ((status == 5)) || fail "$case_name exact post-gate exit must be 5"
  configuration_result
  configuration_gate "$case_dir/final" RECOVERY_REQUIRED
  configuration_namespace "$case_dir/final"
  cmp "$case_dir/changed.namespace.json" "$case_dir/final.namespace.json" || fail "fresh replay changed exact namespace identities"
  diff -u <(jq -S '.normalizedRequest' "$case_dir/gated.journal.json") \
    <(jq -S '.normalizedRequest' "$case_dir/final.journal.json") || fail "immutable expected configuration changed"
  [[ $(jq -r .reason "$case_journal") == "$case_reason" ]] || fail "journal reason disagrees with exact response"
  pass "real-QML $case_name: $case_reason, RECOVERY_REQUIRED/UNLOAD_ACKNOWLEDGED, zero namespace-helper invocations, no candidate marker"
}

run_configuration_cases() {
  # Literal expected reasons follow documented source -> projection -> state /
  # policy precedence. The two state-changing cases also change projection;
  # neither claims independent coverage of the later state/policy branch.
  local selected=${OMARCHY_LIFECYCLE_AUTHORITY_CASE:-all}
  shell_ipc shell testStopLocalPluginWatcher >/dev/null
  wait_for "test watcher stopped before explicit registry scans" \
    '[[ $(state "$service_id" | jq -r .pluginWatcherRunning) == false ]]'
  if [[ $selected == "all" || $selected == "source" ]]; then
    run_configuration_case source install require-unreferenced pre-exposure-stale-configuration-source 63000000-0000-4000-8000-000000000020
  fi
  if [[ $selected == "all" || $selected == "projection" ]]; then
    run_configuration_case projection update preserve-observed pre-exposure-stale-reference-projection 63000000-0000-4000-8000-000000000021
  fi
  if [[ $selected == "all" || $selected == "update-reference" ]]; then
    run_configuration_case update-reference update preserve-observed pre-exposure-stale-reference-projection 63000000-0000-4000-8000-000000000022
  fi
  if [[ $selected == "all" || $selected == "install-reference" ]]; then
    run_configuration_case install-reference install require-unreferenced pre-exposure-stale-reference-projection 63000000-0000-4000-8000-000000000023
  fi
  [[ $selected == "all" || $selected == "source" || $selected == "projection" || $selected == "update-reference" || $selected == "install-reference" ]] || fail "unknown configuration case"
}
