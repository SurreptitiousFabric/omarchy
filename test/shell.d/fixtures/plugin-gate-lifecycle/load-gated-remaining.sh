#!/bin/bash
# Five bounded continuations of the existing offscreen lifecycle harness.
# Shared paths, configuration helpers and cleanup ownership come from it.
# shellcheck disable=SC2154,SC2034

remaining_no_forward() {
  [[ ! -s $1 ]] || fail "$case_name forward namespace-helper invocation count must be zero"
}

remaining_gate_binding() {
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg binding "$case_binding" \
    --arg destination "$case_live" '
    .operationId == $op and .pluginId == $plugin
    and .state == "UNLOAD_ACKNOWLEDGED" and .operationBindingSha256 == $binding
    and .expected.destination == $destination and .unload == "acknowledged"
    and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested"' \
    "$1" >/dev/null || fail "$case_name gate owner/binding must remain exact"
}

remaining_destination() {
  jq -e --arg destination "$case_live" '
    .normalizedRequest.facts.destination == $destination
    and .namespaceIntent.destination == $destination' "$1" >/dev/null || fail "$case_name immutable destination must remain original"
}

remaining_records() {
  local prefix=$1
  cp "$case_journal" "$prefix.journal.json"
  cp "$case_gate" "$prefix.gate.json"
  remaining_gate_binding "$prefix.gate.json"
  remaining_destination "$prefix.journal.json"
  jq -e --arg op "$case_operation" --arg plugin "$case_plugin" --arg binding "$case_binding" '
    .operationId == $op and .pluginId == $plugin and .operationBindingSha256 == $binding
    and (.state == "LOAD_GATED" or .state == "RECOVERY_REQUIRED")
    and .gate == "established" and .registry == "not-requested"
    and .release.outcome == "not-requested" and .terminalReceipt.state == "not-requested"' \
    "$prefix.journal.json" >/dev/null || fail "$case_name journal authority/success claim changed"
  [[ $(configuration_binding "$prefix.journal.json") == "$case_binding" ]] || fail "$case_name stable payload binding changed"
}

remaining_qml_blocked() {
  local prefix=$1
  state "$case_plugin" >"$prefix.qml-state.json"
  jq -e --arg op "$case_operation" --arg binding "$case_binding" '
    .gate.operationId == $op and .gate.operationBindingSha256 == $binding
    and .gate.state == "UNLOAD_ACKNOWLEDGED" and .thirdPartyAllowed == false
    and .directUrl == "" and .serviceActive == false and .serviceOwnerActive == false
    and .pendingService == false and .pendingWidget == false and .widgetRegistered == false' \
    "$prefix.qml-state.json" >/dev/null || fail "$case_name QML candidate eligibility is not blocked"
  ! rg -F "O8-CANDIDATE-EVALUATED:$case_plugin" "$log" >/dev/null || fail "$case_name candidate marker evaluated"
}

remaining_namespace() {
  local prefix=$1 directory identity object
  # Reuse the accepted exact candidate/original-destination snapshot, then
  # include every direct discovery child. This covers the deliberately added
  # duplicate and moved source as well as absence at both possible destinations.
  configuration_namespace "$prefix"
  : >"$prefix.discovery.jsonl"
  for directory in "$plugin_dir"/*; do
    [[ -d $directory && ! -L $directory ]] || fail "unexpected discovery fixture type"
    identity=$("$helper" identity "$directory")
    object=$(stat -c '%d:%i' "$directory")
    jq -cn --arg path "$directory" --arg identity "$identity" --arg object "$object" \
      '{path:$path,identity:$identity,object:$object}' >>"$prefix.discovery.jsonl"
  done
}

remaining_scan() {
  local prior_epoch
  prior_epoch=$(state "$case_plugin" | jq -r .registryAuthority.scanEpoch)
  shell_ipc shell rescanPlugins >/dev/null
  wait_for "$case_name completes real registry scan" \
    'state "$case_plugin" >"$case_dir/scan.json" && jq -e --argjson epoch "$prior_epoch" ".registryAuthority.scanning == false and .registryAuthority.scanSuccessful == true and .registryAuthority.scanEpoch > \$epoch" "$case_dir/scan.json" >/dev/null'
}

remaining_configuration_unchanged() {
  diff -u <(jq -S '{configurationEpoch,acceptedSourceKind,acceptedSourceIdentity,acceptedRawText,acceptedConfig,referenceSnapshot,shellInstance}' "$case_dir/before.qml-state.json") \
    <(jq -S '{configurationEpoch,acceptedSourceKind,acceptedSourceIdentity,acceptedRawText,acceptedConfig,referenceSnapshot,shellInstance}' "$1") \
    || fail "$case_name changed unrelated configuration/reference authority"
  cmp "$config_file" "$case_dir/before.accepted.json" || fail "$case_name configuration file changed"
}

remaining_error_result() {
  local status=$1 reason=$2 output=$3
  # The documented unavailable path is the seven-field error envelope. It
  # makes no durable transition or current-shell claim; inspect both records
  # independently instead of treating this as a durable-result response.
  jq -cnS --arg op "$case_operation" --arg plugin "$case_plugin" --arg status "$status" --arg reason "$reason" '
    {protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$op,
     pluginId:$plugin,state:"LOAD_GATED",status:$status,reason:$reason}' >"$output"
}

remaining_assertion_controls() {
  local control="$case_dir/assertion-controls" name status
  mkdir "$control"
  # Only assertion-input copies change. Never modify a durable journal/gate.
  printf 'exchange 123\n' >"$control/nonzero-count"
  jq '.operationId="63000000-0000-4000-8000-000000000099"' "$case_gate" >"$control/wrong-owner.json"
  jq '.operationBindingSha256=("0" * 64)' "$case_gate" >"$control/wrong-binding.json"
  jq --arg destination "$case_other" '.normalizedRequest.facts.destination=$destination | .namespaceIntent.destination=$destination' \
    "$case_journal" >"$control/adopted-destination.json"
  for name in nonzero-count wrong-owner wrong-binding adopted-destination; do
    status=0
    (
      case $name in
        nonzero-count) remaining_no_forward "$control/$name" ;;
        wrong-owner | wrong-binding) remaining_gate_binding "$control/$name.json" ;;
        adopted-destination) remaining_destination "$control/$name.json" ;;
      esac
    ) >"$control/$name.log" 2>&1 || status=$?
    [[ $status == 1 ]] || fail "$name assertion control was not detected"
    case $name in
      nonzero-count) needle="$case_name forward namespace-helper invocation count must be zero" ;;
      wrong-owner | wrong-binding) needle="$case_name gate owner/binding must remain exact" ;;
      adopted-destination) needle="$case_name immutable destination must remain original" ;;
    esac
    rg -Fx "not ok - $needle" "$control/$name.log" >/dev/null || fail "$name failed for an unrelated reason"
    pass "assertion-input control rejects $name"
  done
}

run_remaining_authority_case() {
  case_name=$1 case_kind=update case_policy=preserve-observed
  # Set all expectations before staging or observing an outcome. Registry
  # ambiguity is a valid unavailable observation, not a confirmed stale fact.
  case $case_name in
    active-tree)
      case_operation=63000000-0000-4000-8000-000000000030
      case_reason=pre-exposure-stale-active-tree
      expected_status=indeterminate expected_exit=5 expected_state=RECOVERY_REQUIRED
      ;;
    duplicate-id)
      case_operation=63000000-0000-4000-8000-000000000031
      case_reason=shell-authority-unavailable
      expected_status=unavailable expected_exit=4 expected_state=LOAD_GATED
      ;;
    moved-source)
      case_operation=63000000-0000-4000-8000-000000000032
      case_reason=pre-exposure-registry-source-ambiguous
      expected_status=indeterminate expected_exit=5 expected_state=RECOVERY_REQUIRED
      ;;
    malformed-observation)
      case_operation=63000000-0000-4000-8000-000000000033
      case_reason=invalid-shell-observation
      expected_status=unavailable expected_exit=4 expected_state=LOAD_GATED
      ;;
    shell-unavailable)
      case_operation=63000000-0000-4000-8000-000000000034
      case_reason=shell-authority-unavailable
      expected_status=unavailable expected_exit=4 expected_state=LOAD_GATED
      ;;
    *) fail "unknown remaining authority case" ;;
  esac
  case_plugin="acme.o8-remaining-$case_name"
  case_dir="$TMPDIR/remaining-$case_name"
  # Deliberately exercise the supported basename != manifest-id contract.
  case_live="$plugin_dir/slot-$case_name"
  case_other="$plugin_dir/other-$case_name"
  case_candidate="$state_dir/omarchy/plugin-candidates-v1/$case_operation/candidate"
  case_journal="$OMARCHY_PLUGIN_TRANSACTION_STATE/journals/$case_operation.journal"
  case_gate="$OMARCHY_PLUGIN_TRANSACTION_STATE/gates/$case_plugin.gate"
  load_runtime="$runtime_dir/omarchy-o8-load-gated"
  mkdir -p "$case_dir/source" "$case_live" "$load_runtime"
  jq -n --arg status "$expected_status" --arg reason "$case_reason" --argjson exit "$expected_exit" \
    --arg state "$expected_state" '{status:$status,reason:$reason,exit:$exit,journal:$state,
      gate:"UNLOAD_ACKNOWLEDGED",namespaceHelperInvocations:0,candidateMarker:"not-evaluated",
      permittedSideEffects:(if $state == "RECOVERY_REQUIRED" then ["durable recovery transition"] else [] end)}' >"$case_dir/expectations.json"
  printf 'case %s: expected %s/%s, exit %s, %s/UNLOAD_ACKNOWLEDGED, zero forward helpers\n' \
    "$case_name" "$expected_status" "$case_reason" "$expected_exit" "$expected_state"
  local token request commit owner status identity
  shell_ipc shell testStopLocalPluginWatcher >/dev/null
  wait_for "stop watcher before explicit registry scans" '[[ $(state "$service_id" | jq -r .pluginWatcherRunning) == false ]]'
  jq --arg id "$case_plugin" '.id=$id | .kinds=["service"] | .entryPoints={service:"Service.qml"}' \
    "$FIXTURE_ROOT/manifest.json" >"$case_dir/source/manifest.json"
  cp "$case_dir/source/manifest.json" "$case_live/manifest.json"
  printf 'import QtQuick\nItem {}\n' >"$case_live/Service.qml"
  printf 'import QtQuick\nItem {\n  property bool entryPointEvaluated: { console.warn("O8-CANDIDATE-EVALUATED:%s"); return true }\n}\n' \
    "$case_plugin" >"$case_dir/source/Service.qml"
  jq --arg id "$case_plugin" '.plugins += [{id:$id}]' "$initial_config" >"$case_dir/next.json"
  configuration_reload
  remaining_scan
  configuration_observation "$case_dir/before"
  jq -e --arg destination "$case_live" --arg plugin "$case_plugin" '
    .activeDiscovery == {state:"present",sourceDirectory:$destination}
    and .referenceState == "referenced" and ($destination | endswith("/" + $plugin) | not)' \
    "$case_dir/before.json" >/dev/null || fail "initial authoritative source is not the exact non-ID slot"
  case_active_identity=$("$helper" identity "$case_live")
  case_identity=$("$helper" identity "$case_dir/source")
  [[ $case_identity != "$case_active_identity" ]] || fail "candidate must differ from active tree"
  token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
  request=$(jq -cn --arg op "$case_operation" --arg token "$token" --arg plugin "$case_plugin" \
    --arg path "$case_dir/source" --arg candidate "sha256:${case_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg prior "sha256:${case_active_identity#omarchy-runtime-tree-sha256-v1:}" \
    --arg projection "$(<"$case_dir/before.projection-sha256")" --slurpfile before "$case_dir/before.json" '
    {protocol:"legacy-schema-v1-transaction/v1",action:"stage",operationId:$op,operationToken:$token,
     operation:"update",pluginId:$plugin,source:{kind:"directory",path:$path},
     candidateTree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$candidate},
     expectedActive:{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$prior}},
     expectedConfiguration:{source:$before[0].configurationSource,referenceProjectionSha256:$projection,
       referenceState:"referenced",referencePolicy:"preserve-observed"}}')
  printf '%s' "$request" | "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/stage-result.json" || fail "$case_name production stage failed"
  request=""
  jq -e '.state == "STAGED" and .status == "ok"' "$case_dir/stage-result.json" >/dev/null || fail "$case_name stage was not durable"
  jq -e --arg destination "$case_live" '.normalizedRequest.facts.destination == $destination' \
    "$case_journal" >/dev/null || fail "stage did not bind the actual registry destination"
  [[ $(shell_ipc shell testReleaseUnload "$case_plugin") == "ok" ]] || fail "existing test unload timing release failed"
  commit=$(jq -cn --arg op "$case_operation" --arg token "$token" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$op,operationToken:$token}')
  token=""
  printf '%s\n' "$case_operation" >"$load_runtime/operation"
  : >"$load_runtime/namespace-calls"
  : >"$load_runtime/hold-before-namespace"
  mkfifo "$load_runtime/namespace-resume"
  printf '%s' "$commit" | "$PYTHON_BIN" "$FIXTURE_ROOT/load-gated-coordinator.py" \
    "$case_dir/owner-process.json" "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/owner-result.json" 2>"$case_dir/owner-error" &
  owner=$!
  REPLAY_OWNER_PID=$owner
  wait_for "$case_name production LOAD_GATED barrier" \
    '[[ -e $load_runtime/namespace-ready && $(jq -r .state "$case_journal") == LOAD_GATED ]] && kill -0 "$owner"'
  [[ $(wc -l <"$load_runtime/namespace-calls") == 1 ]] || fail "original coordinator did not reach exactly one helper barrier"
  case_binding=$(configuration_binding "$case_journal")
  configuration_gate "$case_dir/gated" LOAD_GATED
  remaining_records "$case_dir/gated"
  remaining_qml_blocked "$case_dir/gated"
  remaining_namespace "$case_dir/gated"
  [[ $(jq -r .candidate "$case_dir/gated.namespace.json") == "$case_identity" &&
  $(jq -r .live "$case_dir/gated.namespace.json") == "$case_active_identity" && ! -e $case_other ]] || fail "incorrect pre-exposure layout"
  kill "$owner"
  wait "$owner" 2>/dev/null || true
  REPLAY_OWNER_PID=""
  assert_reaped "$case_dir/owner-process.json"
  cmp "$case_journal" "$case_dir/gated.journal.json" || fail "original coordinator advanced after barrier"
  rm "$load_runtime/hold-before-namespace" "$load_runtime/namespace-ready" "$load_runtime/namespace-resume"

  case $case_name in
    active-tree)
      printf '// changed active bytes after LOAD_GATED\n' >>"$case_live/Service.qml"
      identity=$("$helper" identity "$case_live")
      [[ $identity != "$case_active_identity" && $identity != "$case_identity" ]] || fail "changed active identity must differ from prior and candidate"
      [[ $(jq -r .id "$case_live/manifest.json") == "$case_plugin" ]] || fail "active mutation changed manifest ID"
      ;;
    duplicate-id)
      cp -a "$case_live" "$case_other"
      remaining_scan
      jq -e --arg original "$case_live" --arg other "$case_other" '
        .registryAuthority.targetCount == 2 and .registryAuthority.unique == false
        and .registryAuthority.sourceDirectory == ""
        and (.registrySources | sort) == ([$original,$other] | sort)' "$case_dir/scan.json" >/dev/null || fail "real scan did not expose duplicate multiplicity"
      [[ $(jq -r .id "$case_other/manifest.json") == "$case_plugin" &&
      $(jq -r .id "$case_live/manifest.json") == "$case_plugin" ]] || fail "both duplicate sources must exist with the same ID"
      ;;
    moved-source)
      mv "$case_live" "$case_other"
      remaining_scan
      jq -e --arg other "$case_other" '
        .registryAuthority.targetCount == 1 and .registryAuthority.unique == true
        and .registryAuthority.sourceDirectory == $other and .registrySources == [$other]' \
        "$case_dir/scan.json" >/dev/null || fail "real registry did not select the unique moved source"
      [[ $("$helper" identity "$case_other") == "$case_active_identity" &&
      $(stat -c '%d:%i' "$case_other") == $(jq -r .liveObject "$case_dir/gated.namespace.json") &&
      ! -e $case_live ]] || fail "test move did not preserve exact tree/object identity"
      ;;
  esac
  shell_ipc shell transactionStageObservation "$case_plugin" >"$case_dir/after.json"
  remaining_qml_blocked "$case_dir/after"
  remaining_configuration_unchanged "$case_dir/after.qml-state.json"
  case $case_name in
    duplicate-id)
      jq -e '. == {valid:false,status:"registry-target-ambiguous"}' "$case_dir/after.json" >/dev/null || fail "duplicate producer outcome differs from authority contract"
      ;;
    *)
      jq -e --arg destination "$(if [[ $case_name == moved-source ]]; then printf '%s' "$case_other"; else printf '%s' "$case_live"; fi)" \
        '.valid == true and .status == "observed" and .activeDiscovery == {state:"present",sourceDirectory:$destination}' \
        "$case_dir/after.json" >/dev/null || fail "real producer did not report the selected source"
      ;;
  esac
  remaining_records "$case_dir/setup"
  remaining_namespace "$case_dir/setup"
  cmp "$case_dir/gated.journal.json" "$case_dir/setup.journal.json" || fail "test setup changed durable journal"
  cmp "$case_dir/gated.gate.json" "$case_dir/setup.gate.json" || fail "test setup changed durable gate"
  [[ $(jq -r .candidate "$case_dir/setup.namespace.json") == "$case_identity" ]] || fail "setup altered candidate"
  if [[ $case_name == "moved-source" ]]; then remaining_assertion_controls; fi
  if [[ $case_name == "malformed-observation" ]]; then : >"$load_runtime/truncate-observation"; fi
  if [[ $case_name == "shell-unavailable" ]]; then
    # This PID is the harness-owned child launched with the exact copied QML
    # path and isolated XDG runtime. Never enumerate or signal desktop PIDs.
    jq -n --argjson pid "$QS_PID" --arg shell "$test_root/shell" --arg runtime "$runtime_dir" \
      '{pid:$pid,shellPath:$shell,runtimeDirectory:$runtime}' >"$case_dir/isolated-shell.json"
    tr '\0' '\n' <"/proc/$QS_PID/cmdline" >"$case_dir/isolated-shell-command"
    rg -Fx "$test_root/shell" "$case_dir/isolated-shell-command" >/dev/null || fail "QML PID does not identify this copied shell"
    kill "$QS_PID"
    wait "$QS_PID" 2>/dev/null || true
    ! kill -0 "$QS_PID" 2>/dev/null || fail "isolated QML was not reaped"
    printf 'reaped; current-shell eligibility not observed after exit\n' >"$case_dir/isolated-shell-reaped"
  fi
  if [[ ${OMARCHY_LIFECYCLE_REMAINING_BYPASS:-} == "active-tree" ]]; then
    [[ $case_name == "active-tree" ]] || fail "bypass must target only active-tree case"
    "$NODE_BIN" "$FIXTURE_ROOT/bypass-load-gated-active-tree.mjs" "$test_root/bin/omarchy-plugin-transaction"
    bash -n "$test_root/bin/omarchy-plugin-transaction"
  fi

  # The no-mutation baseline is AFTER the deliberate active/source changes.
  # Reset only after the original coordinator and all its helpers are reaped.
  : >"$load_runtime/namespace-calls"
  printf '%s\n' "$case_plugin" >"$load_runtime/observe-replay"
  local started=$EPOCHREALTIME finished pid
  printf '%s' "$commit" | "$PYTHON_BIN" "$FIXTURE_ROOT/load-gated-coordinator.py" \
    "$case_dir/fresh-process.json" "$test_root/bin/omarchy-plugin-transaction" >"$case_dir/fresh-result.json" 2>"$case_dir/fresh-error" &
  owner=$!
  REPLAY_OWNER_PID=$owner
  commit=""
  set +e
  wait "$owner"
  status=$?
  set -e
  finished=$EPOCHREALTIME
  REPLAY_OWNER_PID=""
  printf '%s\n' "$status" >"$case_dir/fresh-exit"
  jq -n --argjson start "$started" --argjson end "$finished" '{elapsedSeconds:($end-$start)}' >"$case_dir/fresh-timing.json"
  for record in "$case_dir/owner-process.json" "$case_dir/fresh-process.json"; do
    jq -e '. as $record | .allChildrenReaped == true and (.reaped | index($record.coordinatorPid)) != null' \
      "$record" >/dev/null || fail "coordinator did not reap its children"
    for pid in $(jq -r '.reaped[]' "$record"); do
      ! kill -0 "$pid" 2>/dev/null || fail "coordinator/helper survives replay"
    done
  done
  [[ $(jq -r .coordinatorPid "$case_dir/owner-process.json") != $(jq -r .coordinatorPid "$case_dir/fresh-process.json") ]] || fail "replay coordinator is not new"
  cp "$load_runtime/namespace-calls" "$case_dir/namespace-calls"
  cp "$load_runtime/replay-observation.json" "$case_dir/fresh-observation.json"
  cp "$load_runtime/observation-timing" "$case_dir/observation-timing"
  remaining_no_forward "$case_dir/namespace-calls"
  remaining_records "$case_dir/final"
  remaining_namespace "$case_dir/final"
  cmp "$case_dir/setup.namespace.json" "$case_dir/final.namespace.json" || fail "coordinator changed candidate/original namespace identities"
  cmp "$case_dir/setup.discovery.jsonl" "$case_dir/final.discovery.jsonl" || fail "coordinator changed post-setup discovery identities"
  cmp "$case_dir/setup.gate.json" "$case_dir/final.gate.json" || fail "coordinator changed blocking gate"
  diff -u <(jq -S .normalizedRequest "$case_dir/setup.journal.json") \
    <(jq -S .normalizedRequest "$case_dir/final.journal.json") || fail "coordinator changed immutable expectations"
  ! rg -F "O8-CANDIDATE-EVALUATED:$case_plugin" "$log" >/dev/null || fail "$case_name candidate marker evaluated"
  if [[ $case_name == "shell-unavailable" ]]; then
    ! kill -0 "$QS_PID" 2>/dev/null || fail "isolated shell unexpectedly restarted"
    # qs may print a no-instance diagnostic on stdout with its nonzero exit.
    # Retain that transport output as such; it is not an accepted observation.
    mv "$case_dir/fresh-observation.json" "$case_dir/unavailable-ipc-output"
    ! jq -e 'type == "object" and has("valid")' "$case_dir/unavailable-ipc-output" >/dev/null 2>&1 || fail "terminated shell returned an authority observation"
    read -r started finished status_ipc bound <"$case_dir/observation-timing"
    [[ $bound == 5 && $status_ipc != 0 ]] || fail "unavailable replay bypassed package-owned IPC bound"
    jq -ne --argjson start "$started" --argjson end "$finished" '$end - $start <= 6' >/dev/null || fail "IPC exceeded five-second timeout plus one-second kill grace"
    jq -e '.elapsedSeconds <= 6' "$case_dir/fresh-timing.json" >/dev/null || fail "unavailable replay exceeded package bound"
  else
    assert_fresh_process "$case_dir/owner-process.json" "$case_dir/fresh-process.json"
    remaining_qml_blocked "$case_dir/final"
    remaining_configuration_unchanged "$case_dir/final.qml-state.json"
    diff -u <(jq -S . "$case_dir/after.json") <(jq -S . "$case_dir/fresh-observation.json") || fail "coordinator IPC did not obtain actual post-setup observation"
  fi
  if [[ $case_name == "malformed-observation" ]]; then
    cp "$load_runtime/transport-observation" "$case_dir/transport-observation"
    [[ $(<"$case_dir/transport-observation") == "$(sed '$s/.$//' "$case_dir/fresh-observation.json")" ]] || fail "fault was not truncation of the actual QML response"
    ! jq -e . "$case_dir/transport-observation" >/dev/null 2>&1 || fail "transport fault was not malformed"
    [[ ! -e "$load_runtime/truncate-observation" ]] || fail "transport fault was not consumed exactly once"
  fi
  [[ $(wc -l <"$case_dir/fresh-result.json") == 1 ]] || fail "response must be one JSON line"
  if [[ ${OMARCHY_LIFECYCLE_REMAINING_BYPASS:-} == "active-tree" ]]; then
    # The one skipped comparison changes the decision path. The independent
    # namespace classifier still refuses exposure; no further check is bypassed.
    remaining_error_result indeterminate namespace-layout-ambiguous "$case_dir/bypass-expected-result.json"
    diff -u "$case_dir/bypass-expected-result.json" "$case_dir/fresh-result.json" || fail "single-check bypass did not reach the independent layout safeguard"
    ((status == 5)) || fail "single-check bypass failed outside the expected decision path"
    cmp "$case_dir/setup.journal.json" "$case_dir/final.journal.json" || fail "layout safeguard changed durable journal bytes"
    printf 'active-tree comparison bypassed; independent namespace-layout check blocked exposure\n' >"$case_dir/detected-comparison-bypass"
    # Invoke the same primary exact-result assertion: its failure is required
    # evidence that this test detects the changed production decision path.
    configuration_result
    fail "active-tree comparison bypass escaped the primary result assertion"
  fi
  ((status == expected_exit)) || fail "$case_name returned the wrong documented exit class"
  [[ $(jq -r .state "$case_journal") == "$expected_state" ]] || fail "$case_name returned the wrong durable journal state"
  if [[ $expected_state == "RECOVERY_REQUIRED" ]]; then
    configuration_result
    [[ $(jq -r .reason "$case_journal") == "$case_reason" ]] || fail "recovery reason differs from response"
    diff -u <(jq -S 'del(.state,.reason)' "$case_dir/setup.journal.json") \
      <(jq -S 'del(.state,.reason)' "$case_dir/final.journal.json") || fail "recovery changed fields outside its permitted transition"
  else
    remaining_error_result "$expected_status" "$case_reason" "$case_dir/expected-result.json"
    diff -u "$case_dir/expected-result.json" "$case_dir/fresh-result.json" || fail "$case_name documented error envelope differs"
    cmp "$case_dir/setup.journal.json" "$case_dir/final.journal.json" || fail "unavailable observation rewrote the journal"
  fi
  pass "$case_name: $expected_status/$case_reason, exit $status, $expected_state/UNLOAD_ACKNOWLEDGED; zero forward helpers, exact post-setup namespace, no candidate marker"
}
