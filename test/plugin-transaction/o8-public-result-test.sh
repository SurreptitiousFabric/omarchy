#!/bin/bash
set -euo pipefail

# Independent public-result vectors.  The expected values below are literal
# protocol facts; this suite never invokes the production response jq filter to
# construct its expectations.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/interface-test-lib.sh"

ROOT=$(interface_test_root)
TEST_ROOT=$(mktemp -d)
trap 'find "$TEST_ROOT" -mindepth 1 -delete; rmdir "$TEST_ROOT"' EXIT
INSTALL_ROOT="$TEST_ROOT/install/share/omarchy"
HOME_DIR="$TEST_ROOT/home"
STATE_HOME="$TEST_ROOT/state"
STATE_ROOT="$STATE_HOME/omarchy/plugin-transactions-v1"
DISCOVERY="$HOME_DIR/.config/omarchy/plugins"
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PROJECTION=sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432
BINDING=0000000000000000000000000000000000000000000000000000000000000000
RAW=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

build_interface_install "$ROOT" "$INSTALL_ROOT"
initialize_transaction_state "$STATE_ROOT"
mkdir -p "$HOME_DIR" "$DISCOVERY"

stage_direct() {
  local operation=$1 plugin=$2 source=$3 kind=$4 active=$5 active_identity=${6:-}
  local destination=${7:-$DISCOVERY/$plugin}
  local identity
  identity=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$source")
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" OMARCHY_PATH="$INSTALL_ROOT" \
    OMARCHY_PLUGIN_TREE_HELPER="$INSTALL_ROOT/native/plugin-transaction/plugin-tree" \
    OMARCHY_PLUGIN_VALIDATOR="$ROOT/bin/omarchy-plugin-validate" \
    OMARCHY_PLUGIN_JOURNAL_VALIDATOR="$INSTALL_ROOT/native/plugin-transaction/validate-journal.jq" \
    OMARCHY_PLUGIN_CANDIDATE_STORE="$STATE_HOME/omarchy/plugin-candidates-v1" \
    OMARCHY_PLUGIN_TRANSACTION_STATE="$STATE_ROOT" \
    OMARCHY_PLUGIN_DISCOVERY_DIR="$DISCOVERY" OMARCHY_PLUGIN_OPERATION_KIND="$kind" \
    OMARCHY_PLUGIN_SOURCE_KIND=directory OMARCHY_PLUGIN_CALLER_CANDIDATE_IDENTITY="$identity" \
    OMARCHY_PLUGIN_EXPECTED_ACTIVE_STATE="$active" OMARCHY_PLUGIN_EXPECTED_ACTIVE_IDENTITY="$active_identity" \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_KIND=user \
    OMARCHY_PLUGIN_EXPECTED_CONFIG_SOURCE_IDENTITY=omarchy-shell-config:user:v1 \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_PROJECTION="$PROJECTION" \
    OMARCHY_PLUGIN_EXPECTED_REFERENCE_STATE=unreferenced \
    OMARCHY_PLUGIN_REFERENCE_POLICY=require-unreferenced \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_SOURCE=shell-authoritative-o7 \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_RAW_SHA256="$RAW" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_PROJECTION="$PROJECTION" \
    OMARCHY_PLUGIN_STAGE_OBSERVATION_REFERENCE_STATE=unreferenced \
    OMARCHY_PLUGIN_DESTINATION="$destination" \
    "$INSTALL_ROOT/native/plugin-transaction/stage-candidate" "$operation" "$plugin" "$source" <<<"$TOKEN" >/dev/null
}

make_plugin() {
  local destination=$1 plugin=$2
  make_interface_plugin "$ROOT" "$destination" "$plugin"
}

make_v2() {
  local operation=$1 kind=$2 plugin=$3 source=$4 destination
  destination=${5:-$DISCOVERY/$plugin}
  local journal="$STATE_ROOT/journals/$operation.journal"
  jq -cS --arg binding "$BINDING" --arg destination "$destination" --arg kind "$kind" \
    --arg shell "vector-shell" --argjson epoch 1 '
    .schema="omarchy-plugin-transaction-journal/v2"
    | .operationBindingSha256=$binding
    | .candidate.role="candidate"
    | .retainedPrior={state:"not-captured",identity:null,slot:null}
    | .namespaceIntent={kind:(if $kind=="install" then "install" else "exchange" end),state:"none",sourceSlot:.candidate.completedSlot,destination:$destination,candidate:.candidate.observed,prior:(if .normalizedRequest.facts.expectedActive.state=="present" then .normalizedRequest.facts.expectedActive.identity else null end)}
    | .rescan={outcome:"not-requested",shellInstance:null,generation:null,scanEpoch:null,sourceDirectory:null,expectedTree:null,observedTree:null}
    | .release={outcome:"not-requested",shellInstance:null,generation:null,configurationEpoch:null,source:null,rawSha256:null,referenceProjection:null,referenceState:null,referencePolicy:null}
    | .rollback="not-applicable"
    | .rollbackEvidence={state:"not-started",targetRole:"none",target:null,outcome:"not-applicable"}
    | .terminalReceipt={state:"not-requested",intendedJournalState:null,operationBindingSha256:null,operationId:null,pluginId:null,targetRole:"none",target:null,shellInstance:null,generation:null,scanEpoch:null,configurationEpoch:null,outcome:"not-requested"}
    | .preExposureEvidence=null
    | .state="STAGED" | .reason=null | .gate="not-established" | .registry="not-requested" | .corruptEvidenceSha256=null
  ' "$journal" >"$journal.next"
  chmod 0600 "$journal.next"
  mv "$journal.next" "$journal"
  "$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$source" >/dev/null
  jq -e --arg operation_id "$operation" -f "$INSTALL_ROOT/native/plugin-transaction/validate-journal.jq" "$journal" >/dev/null
}

status() {
  local operation=$1
  jq -cnS --arg operationId "$operation" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:"status",operationId:$operationId}' |
    HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" "$INSTALL_ROOT/bin/omarchy-plugin-transaction"
}

assert_stdout_file() {
  local output_file=$1
  [[ $(wc -l <"$output_file") == 1 ]] || { printf 'response did not contain exactly one line\n' >&2; return 1; }
  [[ $(tail -c 1 "$output_file" | od -An -t x1) == *0a* ]] || { printf 'response did not end with LF\n' >&2; return 1; }
  jq -e 'type == "object"' "$output_file" >/dev/null
}

assert_common() {
  local result=$1 name=$2 operation=$3 plugin=$4 state=$5 status_value=$6 durable=$7 candidate_digest=$8 previous_digest=${9:-}
  local expected
  expected=$(expected_result "$name" status "$operation" "$plugin" "$state" "$status_value" "$durable" \
    not-observed "$candidate_digest" "$previous_digest")
  diff -u <(jq -S . <<<"$expected") <(jq -S . <<<"$result")
}

# This is the complete expected-response table.  Its state-specific values are
# authored here rather than obtained from the journal or the production mapper.
expected_result() {
  local name=$1 action=$2 operation=$3 plugin=$4 state=$5 status_value=$6 durable=$7 current_shell=$8 candidate_digest=$9 previous_digest=${10:-}
  local reason=null kind=install previous='{"state":"absent"}' active='{"state":"absent"}'
  local registry='{"state":"not-requested","rescan":"not-requested","shellInstance":null,"generation":null,"scanEpoch":null}'
  local release='{"outcome":"not-requested","shellInstance":null,"generation":null,"configurationEpoch":null}'
  local rollback='{"state":"not-applicable","evidenceState":"not-started","targetRole":"none","outcome":"not-applicable","target":null}'
  local recovery='{"state":"none","reason":null}' after=null
  local candidate previous_tree active_tree
  candidate=$(jq -cnS --arg digest "$candidate_digest" '{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}')
  previous_tree=$(jq -cnS --arg digest "$previous_digest" '{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}')

  case "$name" in
    *-update|rejected-update|rollback-restored-prior|rolled-back-update) kind=update ;;
  esac
  case "$name" in
    staged-install|commit-prepared-install|load-gated-install|live-tree-exchanged-install|gated-rescan|release-pending|committed|rollback-start|rollback-restored|rollback-rescan|rolled-back|rejected|recovery|manual|aborted|rollback-release-pending|recovery-restored)
      previous='{"state":"absent"}' ;;
    *)
      previous=$previous_tree ;;
  esac
  case "$name" in
    live-tree-exchanged-install|gated-rescan|release-pending|committed|live-tree-exchanged-update)
      active=$(jq -cnS --arg digest "$candidate_digest" '{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}') ;;
    rollback-restored|rollback-rescan|rolled-back|rollback-release-pending)
      active='{"state":"absent"}' ;;
    rollback-restored-prior|rolled-back-update)
      active=$previous_tree ;;
    rollback-start|recovery|manual|recovery-restored)
      active=null ;;
    staged-update|commit-prepared-update|load-gated-update|rejected-update)
      active=$previous_tree ;;
  esac
  case "$name" in
    rejected|rejected-update) reason='"stale-candidate"' ;;
    recovery) reason='"pre-exposure-stale-candidate"' ; recovery='{"state":"required","reason":"pre-exposure-stale-candidate"}' ;;
    recovery-restored) reason='"namespace-compensated"' ; recovery='{"state":"required","reason":"namespace-compensated"}' ;;
    manual) reason='"manual-attention"' ; recovery='{"state":"manual-attention","reason":"manual-attention"}' ;;
    aborted) reason='"owner-aborted"' ;;
  esac
  case "$name" in
    gated-rescan|release-pending|committed)
      registry='{"state":"not-requested","rescan":"completed","shellInstance":"vector-shell","generation":1,"scanEpoch":1}' ;;
    rollback-rescan|rolled-back|rollback-release-pending|rolled-back-update)
      registry='{"state":"not-requested","rescan":"completed","shellInstance":"vector-shell","generation":2,"scanEpoch":2}' ;;
  esac
  case "$name" in
    release-pending) release='{"outcome":"not-requested","shellInstance":null,"generation":null,"configurationEpoch":1}' ;;
    committed) release='{"outcome":"authorized","shellInstance":"vector-shell","generation":1,"configurationEpoch":1}' ;;
    rolled-back|rolled-back-update) release='{"outcome":"authorized","shellInstance":"vector-shell","generation":2,"configurationEpoch":2}' ;;
    rollback-release-pending) release='{"outcome":"not-requested","shellInstance":"vector-shell","generation":2,"configurationEpoch":2}' ;;
  esac
  case "$name" in
    rollback-start) rollback='{"state":"pending","evidenceState":"intended","targetRole":"absence","outcome":"pending","target":{"state":"absent"}}' ;;
    rollback-restored|rollback-rescan|rollback-release-pending|recovery-restored) rollback='{"state":"pending","evidenceState":"completed","targetRole":"absence","outcome":"restored","target":{"state":"absent"}}' ;;
    rolled-back) rollback='{"state":"completed","evidenceState":"completed","targetRole":"absence","outcome":"restored","target":{"state":"absent"}}' ;;
    rollback-restored-prior) rollback=$(jq -cnS --arg digest "$previous_digest" '{state:"pending",evidenceState:"completed",targetRole:"prior-tree",outcome:"restored",target:{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}}') ;;
    rolled-back-update) rollback=$(jq -cnS --arg digest "$previous_digest" '{state:"completed",evidenceState:"completed",targetRole:"prior-tree",outcome:"restored",target:{state:"present",tree:{algorithm:"omarchy-runtime-tree-sha256-v1",digest:$digest}}}') ;;
  esac
  case "$name" in
    committed) after='{"source":{"kind":"user","identity":"omarchy-shell-config:user:v1"},"rawSha256":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","referenceProjectionSha256":"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432","referenceState":"unreferenced","referencePolicy":"require-unreferenced"}' ;;
    rolled-back|rolled-back-update) after='{"source":{"kind":"user","identity":"omarchy-shell-config:user:v1"},"rawSha256":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","referenceProjectionSha256":"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432","referenceState":"unreferenced","referencePolicy":"require-unreferenced"}' ;;
  esac
  jq -cnS --arg action "$action" --arg operationId "$operation" --arg kind "$kind" --arg plugin "$plugin" --arg state "$state" --arg status "$status_value" \
    --argjson reason "$reason" --argjson candidate "$candidate" --argjson previous "$previous" --argjson active "$active" \
    --argjson registry "$registry" --argjson release "$release" --argjson rollback "$rollback" --argjson recovery "$recovery" --argjson after "$after" \
    --arg raw "$RAW" --arg projection "$PROJECTION" --arg durable "$durable" --arg currentShell "$current_shell" \
    '{protocol:"legacy-schema-v1-transaction/v1",action:$action,operationId:$operationId,pluginId:$plugin,state:$state,status:$status,reason:$reason,operation:$kind,
      candidateTree:$candidate,previousTree:$previous,observedActive:$active,filesystem:{live:$active,previous:$previous},
      observedConfiguration:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:$raw,referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"},
      configuration:{before:{source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:$raw,referenceProjectionSha256:$projection,referenceState:"unreferenced",referencePolicy:"require-unreferenced"},after:$after},
      registry:$registry,release:$release,eligibility:{durableOutcome:$durable,currentShell:$currentShell},rollback:$rollback,recovery:$recovery}'
}

make_plugin "$TEST_ROOT/install-source" acme.vector-install
install_identity=$("$INSTALL_ROOT/native/plugin-transaction/plugin-tree" identity "$TEST_ROOT/install-source")
install_digest="sha256:${install_identity#omarchy-runtime-tree-sha256-v1:}"
stage_direct 85000000-0000-4000-8000-000000000001 acme.vector-install "$TEST_ROOT/install-source" install absent
make_v2 85000000-0000-4000-8000-000000000001 install acme.vector-install "$TEST_ROOT/install-source"
install_journal="$STATE_ROOT/journals/85000000-0000-4000-8000-000000000001.journal"
cp "$install_journal" "$TEST_ROOT/install-base.journal"

set_state() {
  local journal=$1 operation=$2 base=$3 filter=$4
  cp "$base" "$journal"
  jq -cS "$filter" "$journal" >"$journal.next"
  chmod 0600 "$journal.next"; mv "$journal.next" "$journal"
  jq -e --arg operation_id "$operation" -f "$INSTALL_ROOT/native/plugin-transaction/validate-journal.jq" "$journal" >/dev/null
}

vector() {
  local name operation plugin journal base state filter expected_status previous live durable after candidate_digest previous_digest
  if (( $# >= 14 )); then
    name=$1; operation=$2; plugin=$3; journal=$4; base=$5; state=$6; filter=$7; expected_status=$8; previous=$9; live=${10}; durable=${11}; after=${12}; candidate_digest=${13}; previous_digest=${14:-}
  else
    name=$1; state=$2; filter=$3; expected_status=$4; previous=$5; live=$6; durable=$7; after=${8:-null}
    operation=85000000-0000-4000-8000-000000000001; plugin=acme.vector-install; journal="$install_journal"; base="$TEST_ROOT/install-base.journal"; candidate_digest=$install_digest; previous_digest=
  fi
  set_state "$journal" "$operation" "$base" "$filter"
  local result_file="$TEST_ROOT/$name.json"
  status "$operation" >"$result_file"
  assert_stdout_file "$result_file"
  local result; result=$(<"$result_file")
  assert_common "$result" "$name" "$operation" "$plugin" "$state" "$expected_status" "$durable" "$candidate_digest" "$previous_digest"
  printf 'ok - public vector %s\n' "$name"
}

vector staged-install STAGED '.' ok absent absent not-gated null
vector commit-prepared-install COMMIT_PREPARED '.state="COMMIT_PREPARED"' in-progress absent absent blocked null
vector load-gated-install LOAD_GATED '.state="LOAD_GATED" | .gate="established" | .namespaceIntent.state="intended"' in-progress absent absent blocked null
vector live-tree-exchanged-install LIVE_TREE_EXCHANGED '.state="LIVE_TREE_EXCHANGED" | .gate="established" | .namespaceIntent.state="completed" | .namespaceIntent.kind="install" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}' in-progress absent present blocked null
vector gated-rescan GATED_RESCAN_COMPLETED '.state="GATED_RESCAN_COMPLETED" | .gate="established" | .namespaceIntent.state="completed" | .namespaceIntent.kind="install" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:1,scanEpoch:1,sourceDirectory:(.normalizedRequest.facts.destination),expectedTree:.candidate.observed,observedTree:.candidate.observed}' in-progress absent present blocked null
vector release-pending RELEASE_PENDING '.state="RELEASE_PENDING" | .gate="established" | .namespaceIntent.state="completed" | .namespaceIntent.kind="install" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:1,scanEpoch:1,sourceDirectory:(.normalizedRequest.facts.destination),expectedTree:.candidate.observed,observedTree:.candidate.observed} | .release={outcome:"not-requested",shellInstance:null,generation:null,configurationEpoch:1,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"}' in-progress absent present blocked null
  vector committed COMMITTED '.state="COMMITTED" | .gate="established" | .namespaceIntent.state="completed" | .namespaceIntent.kind="install" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:1,scanEpoch:1,sourceDirectory:(.normalizedRequest.facts.destination),expectedTree:.candidate.observed,observedTree:.candidate.observed} | .release={outcome:"authorized",shellInstance:"vector-shell",generation:1,configurationEpoch:1,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"} | .terminalReceipt={state:"durable",intendedJournalState:"COMMITTED",operationBindingSha256:"0000000000000000000000000000000000000000000000000000000000000000",operationId:.operationId,pluginId:.pluginId,targetRole:"candidate",target:{state:"present",identity:.candidate.observed},shellInstance:"vector-shell",generation:1,scanEpoch:1,configurationEpoch:1,outcome:"authorized"}' committed absent present authorized present
vector rollback-start ROLLBACK_STARTED '.state="ROLLBACK_STARTED" | .gate="established" | .namespaceIntent.kind="rollback-install" | .namespaceIntent.state="intended" | .namespaceIntent.sourceSlot="live" | .rollbackEvidence={state:"intended",targetRole:"absence",target:{state:"absent",identity:null},outcome:"pending"} | .rollback="pending" | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}' in-progress absent null blocked null
vector rollback-restored ROLLBACK_STARTED '.state="ROLLBACK_STARTED" | .gate="established" | .namespaceIntent.kind="rollback-install" | .state="ROLLBACK_STARTED" | .namespaceIntent.state="completed" | .namespaceIntent.sourceSlot="live" | .rollbackEvidence={state:"completed",targetRole:"absence",target:{state:"absent",identity:null},outcome:"restored"} | .rollback="pending" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}' in-progress absent absent blocked null
vector rollback-rescan ROLLBACK_STARTED '.state="ROLLBACK_STARTED" | .gate="established" | .namespaceIntent.kind="rollback-install" | .namespaceIntent.state="completed" | .namespaceIntent.sourceSlot="live" | .rollbackEvidence={state:"completed",targetRole:"absence",target:{state:"absent",identity:null},outcome:"restored"} | .rollback="pending" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:2,scanEpoch:2,sourceDirectory:(.normalizedRequest.facts.destination),expectedTree:null,observedTree:null}' in-progress absent absent blocked null
vector rolled-back ROLLED_BACK '.state="ROLLED_BACK" | .gate="established" | .namespaceIntent.kind="rollback-install" | .namespaceIntent.state="completed" | .namespaceIntent.sourceSlot="live" | .rollbackEvidence={state:"completed",targetRole:"absence",target:{state:"absent",identity:null},outcome:"restored"} | .rollback="completed" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:2,scanEpoch:2,sourceDirectory:(.normalizedRequest.facts.destination),expectedTree:null,observedTree:null} | .release={outcome:"authorized",shellInstance:"vector-shell",generation:2,configurationEpoch:2,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"} | .terminalReceipt={state:"durable",intendedJournalState:"ROLLED_BACK",operationBindingSha256:"0000000000000000000000000000000000000000000000000000000000000000",operationId:.operationId,pluginId:.pluginId,targetRole:"absence",target:{state:"absent",identity:null},shellInstance:"vector-shell",generation:2,scanEpoch:2,configurationEpoch:2,outcome:"restored"}' rolled-back absent absent restored present
vector rejected REJECTED '.state="REJECTED" | .reason="stale-candidate" | .gate="not-established" | .namespaceIntent.state="none" | .rollback="not-applicable" | .rollbackEvidence={state:"not-started",targetRole:"none",target:null,outcome:"not-applicable"} | .terminalReceipt.state="not-requested" | .preExposureEvidence=null' rejected absent absent not-gated null
vector recovery RECOVERY_REQUIRED '.state="RECOVERY_REQUIRED" | .reason="pre-exposure-stale-candidate" | .gate="established" | .namespaceIntent.state="none" | .rollback="not-applicable" | .rollbackEvidence={state:"not-started",targetRole:"none",target:null,outcome:"not-applicable"} | .terminalReceipt.state="not-requested" | .preExposureEvidence=null' indeterminate absent null indeterminate null
vector manual MANUAL_ATTENTION '.state="MANUAL_ATTENTION" | .reason="manual-attention" | .gate="established" | .namespaceIntent.state="none" | .rollback="not-applicable" | .rollbackEvidence={state:"not-started",targetRole:"none",target:null,outcome:"not-applicable"} | .terminalReceipt.state="not-requested" | .preExposureEvidence=null' manual-attention absent null indeterminate null
vector aborted ABORTED '.state="ABORTED" | .reason="owner-aborted" | .gate="not-established" | .namespaceIntent.state="none" | .rollback="not-applicable" | .rollbackEvidence={state:"not-started",targetRole:"none",target:null,outcome:"not-applicable"} | .terminalReceipt.state="not-requested" | .preExposureEvidence=null' aborted absent absent not-gated null
printf 'ok - install durable public-result vectors cover O-8 state and rollback dimensions\n'

# Independent update operation: its selected destination intentionally has a
# basename different from the plugin id, and its expected active tree is the
# prior identity.  This covers the update-specific previousTree semantics.
make_plugin "$TEST_ROOT/update-source" acme.vector-update
make_plugin "$TEST_ROOT/prior-source" acme.vector-update
printf '// prior tree fixture\n' >>"$TEST_ROOT/prior-source/Service.qml"
prior_identity=$($INSTALL_ROOT/native/plugin-transaction/plugin-tree identity "$TEST_ROOT/prior-source")
prior_digest="sha256:${prior_identity#omarchy-runtime-tree-sha256-v1:}"
stage_direct 85000000-0000-4000-8000-000000000002 acme.vector-update "$TEST_ROOT/update-source" update present "$prior_identity" "$DISCOVERY/authoritative-basename"
update_identity=$($INSTALL_ROOT/native/plugin-transaction/plugin-tree identity "$TEST_ROOT/update-source")
update_digest="sha256:${update_identity#omarchy-runtime-tree-sha256-v1:}"
make_v2 85000000-0000-4000-8000-000000000002 update acme.vector-update "$TEST_ROOT/update-source" "$DISCOVERY/authoritative-basename"
update_journal="$STATE_ROOT/journals/85000000-0000-4000-8000-000000000002.journal"
cp "$update_journal" "$TEST_ROOT/update-base.journal"
vector staged-update 85000000-0000-4000-8000-000000000002 acme.vector-update "$update_journal" "$TEST_ROOT/update-base.journal" STAGED '.' ok present present not-gated null "$update_digest" "$prior_digest"
vector commit-prepared-update 85000000-0000-4000-8000-000000000002 acme.vector-update "$update_journal" "$TEST_ROOT/update-base.journal" COMMIT_PREPARED '.state="COMMIT_PREPARED"' in-progress present present blocked null "$update_digest" "$prior_digest"
vector load-gated-update 85000000-0000-4000-8000-000000000002 acme.vector-update "$update_journal" "$TEST_ROOT/update-base.journal" LOAD_GATED '.state="LOAD_GATED" | .gate="established" | .namespaceIntent.state="intended"' in-progress present present blocked null "$update_digest" "$prior_digest"
vector live-tree-exchanged-update 85000000-0000-4000-8000-000000000002 acme.vector-update "$update_journal" "$TEST_ROOT/update-base.journal" LIVE_TREE_EXCHANGED '.state="LIVE_TREE_EXCHANGED" | .gate="established" | .namespaceIntent.state="completed" | .retainedPrior={state:"captured",identity:.normalizedRequest.facts.expectedActive.identity,slot:.candidate.completedSlot} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}' in-progress present present blocked null "$update_digest" "$prior_digest"
vector rollback-restored-prior 85000000-0000-4000-8000-000000000002 acme.vector-update "$update_journal" "$TEST_ROOT/update-base.journal" ROLLBACK_STARTED '.state="ROLLBACK_STARTED" | .gate="established" | .namespaceIntent={kind:"rollback-exchange",state:"completed",sourceSlot:.candidate.completedSlot,destination:.normalizedRequest.facts.destination,candidate:.candidate.observed,prior:.normalizedRequest.facts.expectedActive.identity} | .rollbackEvidence={state:"completed",targetRole:"prior-tree",target:{state:"present",identity:.normalizedRequest.facts.expectedActive.identity},outcome:"restored"} | .rollback="pending" | .retainedPrior={state:"restored",identity:.normalizedRequest.facts.expectedActive.identity,slot:.candidate.completedSlot} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}' in-progress present present blocked null "$update_digest" "$prior_digest"
vector rolled-back-update 85000000-0000-4000-8000-000000000002 acme.vector-update "$update_journal" "$TEST_ROOT/update-base.journal" ROLLED_BACK '.state="ROLLED_BACK" | .gate="established" | .namespaceIntent={kind:"rollback-exchange",state:"completed",sourceSlot:.candidate.completedSlot,destination:.normalizedRequest.facts.destination,candidate:.candidate.observed,prior:.normalizedRequest.facts.expectedActive.identity} | .rollbackEvidence={state:"completed",targetRole:"prior-tree",target:{state:"present",identity:.normalizedRequest.facts.expectedActive.identity},outcome:"restored"} | .rollback="completed" | .retainedPrior={state:"restored",identity:.normalizedRequest.facts.expectedActive.identity,slot:.candidate.completedSlot} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:2,scanEpoch:2,sourceDirectory:.normalizedRequest.facts.destination,expectedTree:.normalizedRequest.facts.expectedActive.identity,observedTree:.normalizedRequest.facts.expectedActive.identity} | .release={outcome:"authorized",shellInstance:"vector-shell",generation:2,configurationEpoch:2,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"} | .terminalReceipt={state:"durable",intendedJournalState:"ROLLED_BACK",operationBindingSha256:.operationBindingSha256,operationId:.operationId,pluginId:.pluginId,targetRole:"prior-tree",target:{state:"present",identity:.normalizedRequest.facts.expectedActive.identity},shellInstance:"vector-shell",generation:2,scanEpoch:2,configurationEpoch:2,outcome:"restored"} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}' rolled-back present present restored present "$update_digest" "$prior_digest"
printf 'ok - update public-result vectors cover update previous-tree and rollback semantics\n'

vector rejected-update 85000000-0000-4000-8000-000000000002 acme.vector-update "$update_journal" "$TEST_ROOT/update-base.journal" REJECTED '.state="REJECTED" | .reason="stale-candidate"' rejected present present not-gated null "$update_digest" "$prior_digest"
vector rollback-release-pending 85000000-0000-4000-8000-000000000001 acme.vector-install "$install_journal" "$TEST_ROOT/install-base.journal" ROLLBACK_STARTED '.state="ROLLBACK_STARTED" | .gate="established" | .namespaceIntent={kind:"rollback-install",state:"completed",sourceSlot:"live",destination:.normalizedRequest.facts.destination,candidate:.candidate.observed,prior:null} | .rollbackEvidence={state:"completed",targetRole:"absence",target:{state:"absent",identity:null},outcome:"restored"} | .rollback="pending" | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:2,scanEpoch:2,sourceDirectory:.normalizedRequest.facts.destination,expectedTree:null,observedTree:null} | .release={outcome:"not-requested",shellInstance:"vector-shell",generation:2,configurationEpoch:2,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}' in-progress absent absent blocked null "$install_digest" ""
vector recovery-restored 85000000-0000-4000-8000-000000000001 acme.vector-install "$install_journal" "$TEST_ROOT/install-base.journal" RECOVERY_REQUIRED '.state="RECOVERY_REQUIRED" | .gate="established" | .reason="namespace-compensated" | .namespaceIntent={kind:"rollback-install",state:"completed",sourceSlot:"live",destination:.normalizedRequest.facts.destination,candidate:.candidate.observed,prior:null} | .rollbackEvidence={state:"completed",targetRole:"absence",target:{state:"absent",identity:null},outcome:"restored"} | .rollback="pending" | .retainedPrior={state:"absent",identity:null,slot:null}' indeterminate absent null indeterminate null "$install_digest" ""

# Terminal result variants use an independently authored durable journal and a
# copied shell helper.  The failing helper proves that current-shell
# reconciliation is not inferred from the terminal journal; the succeeding
# helper proves that only an explicit terminal-pair acknowledgement yields
# currentShell=released.
terminal_shell="$INSTALL_ROOT/bin/omarchy-shell"
terminal_calls="$TEST_ROOT/terminal-calls"
terminal_commit_filter='.state="COMMITTED" | .gate="established" | .namespaceIntent.state="completed" | .namespaceIntent.kind="install" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:1,scanEpoch:1,sourceDirectory:.normalizedRequest.facts.destination,expectedTree:.candidate.observed,observedTree:.candidate.observed} | .release={outcome:"authorized",shellInstance:"vector-shell",generation:1,configurationEpoch:1,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"} | .terminalReceipt={state:"durable",intendedJournalState:"COMMITTED",operationBindingSha256:.operationBindingSha256,operationId:.operationId,pluginId:.pluginId,targetRole:"candidate",target:{state:"present",identity:.candidate.observed},shellInstance:"vector-shell",generation:1,scanEpoch:1,configurationEpoch:1,outcome:"authorized"}'
terminal_rollback_filter='.state="ROLLED_BACK" | .gate="established" | .namespaceIntent={kind:"rollback-install",state:"completed",sourceSlot:"live",destination:.normalizedRequest.facts.destination,candidate:.candidate.observed,prior:null} | .rollbackEvidence={state:"completed",targetRole:"absence",target:{state:"absent",identity:null},outcome:"restored"} | .rollback="completed" | .retainedPrior={state:"absent",identity:null,slot:null} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:2,scanEpoch:2,sourceDirectory:.normalizedRequest.facts.destination,expectedTree:null,observedTree:null} | .release={outcome:"authorized",shellInstance:"vector-shell",generation:2,configurationEpoch:2,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"} | .terminalReceipt={state:"durable",intendedJournalState:"ROLLED_BACK",operationBindingSha256:.operationBindingSha256,operationId:.operationId,pluginId:.pluginId,targetRole:"absence",target:{state:"absent",identity:null},shellInstance:"vector-shell",generation:2,scanEpoch:2,configurationEpoch:2,outcome:"restored"}'
terminal_request() { jq -cn --arg operationId "$1" --arg token "$TOKEN" '{protocol:"legacy-schema-v1-transaction/v1",action:"commit",operationId:$operationId,operationToken:$token}'; }
write_terminal_shell() {
  local mode=$1
  if [[ $mode == fail ]]; then
    printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "$*" >>"'"$terminal_calls"'"' 'exit 1' >"$terminal_shell"
  else
    printf '%s\n' '#!/bin/bash' 'case "$2" in' \
      '  transactionTerminalReconcile) printf "%s\\n" "$*" >>"'"$terminal_calls"'"; printf "%s\\n" pending ;;' \
      '  transactionPluginState) printf "%s\\n" "$*" >>"'"$terminal_calls"'"; jq -cn --arg operation "$3" '\''{operationId:$operation,status:"terminal-pair-reconciled"}'\'' ;;' \
      '  *) exit 1 ;;' 'esac' >"$terminal_shell"
  fi
  chmod 0755 "$terminal_shell"
}
terminal_commit() {
  local operation=$1 expected_shell=$2 expected_status=$3 expected_state=$4 expected_durable=$5 expected_code=$6 result code
  set +e
  local result_file="$TEST_ROOT/terminal-$expected_state-$expected_shell.json"
  terminal_request "$operation" | HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" "$INSTALL_ROOT/bin/omarchy-plugin-transaction" >"$result_file"
  code=$?
  set -e
  [[ $code == "$expected_code" ]] || { printf 'terminal result exit=%s expected=%s\n' "$code" "$expected_code" >&2; return 1; }
  assert_stdout_file "$result_file"
  result=$(<"$result_file")
  local name=committed
  [[ $expected_state == COMMITTED ]] || name=rolled-back
  local candidate_digest=$install_digest
  local expected
  expected=$(expected_result "$name" commit "$operation" acme.vector-install "$expected_state" "$expected_status" "$expected_durable" \
    "$expected_shell" "$candidate_digest")
  diff -u <(jq -S . <<<"$expected") <(jq -S . <<<"$result")
}

set_state "$install_journal" 85000000-0000-4000-8000-000000000001 "$TEST_ROOT/install-base.journal" "$terminal_commit_filter"
write_terminal_shell success
terminal_commit 85000000-0000-4000-8000-000000000001 released committed COMMITTED authorized 0
printf 'ok - committed commit response reports released only after shell reconciliation\n'
terminal_status_before=$(sha256sum "$install_journal" | cut -d' ' -f1)
write_terminal_shell fail
terminal_commit 85000000-0000-4000-8000-000000000001 reconciliation-required committed COMMITTED authorized 5
terminal_status_after=$(sha256sum "$install_journal" | cut -d' ' -f1)
[[ $terminal_status_before == "$terminal_status_after" ]] || { printf 'terminal reconciliation failure rewrote COMMITTED journal\n' >&2; exit 1; }
printf 'ok - committed reconciliation failure retains complete durable result\n'
terminal_calls_before=$(wc -l <"$terminal_calls")
status_result_file="$TEST_ROOT/terminal-committed-status.json"
status 85000000-0000-4000-8000-000000000001 >"$status_result_file"
assert_stdout_file "$status_result_file"
status_result=$(<"$status_result_file")
assert_common "$status_result" committed 85000000-0000-4000-8000-000000000001 acme.vector-install COMMITTED committed authorized "$install_digest"
[[ $(wc -l <"$terminal_calls") == "$terminal_calls_before" ]] || { printf 'status unexpectedly called shell\n' >&2; exit 1; }
printf 'ok - committed read-only status does not infer current-shell release\n'

set_state "$install_journal" 85000000-0000-4000-8000-000000000001 "$TEST_ROOT/install-base.journal" "$terminal_rollback_filter"
write_terminal_shell success
terminal_commit 85000000-0000-4000-8000-000000000001 released rolled-back ROLLED_BACK restored 0
printf 'ok - rolled-back commit response reports released only after shell reconciliation\n'
terminal_status_before=$(sha256sum "$install_journal" | cut -d' ' -f1)
write_terminal_shell fail
terminal_commit 85000000-0000-4000-8000-000000000001 reconciliation-required rolled-back ROLLED_BACK restored 5
terminal_status_after=$(sha256sum "$install_journal" | cut -d' ' -f1)
[[ $terminal_status_before == "$terminal_status_after" ]] || { printf 'terminal reconciliation failure rewrote ROLLED_BACK journal\n' >&2; exit 1; }
printf 'ok - rolled-back reconciliation failure retains complete durable result\n'
terminal_calls_before=$(wc -l <"$terminal_calls")
status_result_file="$TEST_ROOT/terminal-rolled-back-status.json"
status 85000000-0000-4000-8000-000000000001 >"$status_result_file"
assert_stdout_file "$status_result_file"
status_result=$(<"$status_result_file")
assert_common "$status_result" rolled-back 85000000-0000-4000-8000-000000000001 acme.vector-install ROLLED_BACK rolled-back restored "$install_digest"
[[ $(wc -l <"$terminal_calls") == "$terminal_calls_before" ]] || { printf 'status unexpectedly called shell\n' >&2; exit 1; }
printf 'ok - rolled-back read-only status does not infer current-shell release\n'

# Copied-install negative control: replacing the authoritative previous-tree
# mapping with null must fail the literal install-absence invariant.
broken_install="$TEST_ROOT/broken-install"
cp -a "$INSTALL_ROOT" "$broken_install"
sed -i 's/previousTree:public_previous(\$facts)/previousTree:null/; s/previous:public_previous(\$facts)/previous:null/' \
  "$broken_install/bin/omarchy-plugin-transaction"
broken_result=$(jq -cnS --arg operationId 85000000-0000-4000-8000-000000000001 \
  '{protocol:"legacy-schema-v1-transaction/v1",action:"status",operationId:$operationId}' |
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_HOME" "$broken_install/bin/omarchy-plugin-transaction")
if jq -e '.previousTree == {state:"absent"} and .filesystem.previous == {state:"absent"}' <<<"$broken_result" >/dev/null; then
  printf 'negative control failed to detect null previousTree mapping\n' >&2
  exit 1
fi
printf 'ok - copied-install negative control detects missing known previous absence\n'

# Assertion negative controls deliberately corrupt captured responses.  Each
# mutation is checked by the same whole-object comparator used above.
assert_rejects_corruption() {
  local label=$1 source=$2 mutation=$3 candidate_digest=$4 previous_digest=${5:-} corrupted
  corrupted=$(jq -c "$mutation" <<<"$source")
  [[ $corrupted != "$source" ]] || { printf 'negative control did not mutate %s\n' "$label" >&2; exit 1; }
  if assert_common "$corrupted" committed 85000000-0000-4000-8000-000000000001 "acme.vector-install" COMMITTED committed authorized "$candidate_digest" "$previous_digest" >/dev/null 2>&1; then
    printf 'negative control accepted %s\n' "$label" >&2
    exit 1
  fi
  printf 'ok - assertion negative control rejects %s\n' "$label"
}

set_state "$install_journal" 85000000-0000-4000-8000-000000000001 "$TEST_ROOT/install-base.journal" "$terminal_commit_filter"
negative_status_file="$TEST_ROOT/negative-status.json"
status 85000000-0000-4000-8000-000000000001 >"$negative_status_file"
assert_stdout_file "$negative_status_file"
negative_committed=$(<"$negative_status_file")
assert_rejects_corruption wrong-reason "$negative_committed" '.reason="wrong-reason"' "$install_digest"
assert_rejects_corruption wrong-live-tree "$negative_committed" '.filesystem.live.tree.digest="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "$install_digest"
assert_rejects_corruption wrong-registry-generation "$negative_committed" '.registry.generation=99' "$install_digest"
assert_rejects_corruption wrong-registry-scan-epoch "$negative_committed" '.registry.scanEpoch=99' "$install_digest"
assert_rejects_corruption configuration-after-copied-before "$negative_committed" '.configuration.after=.configuration.before' "$install_digest"
assert_rejects_corruption current-shell-released-in-status "$negative_committed" '.eligibility.currentShell="released"' "$install_digest"
assert_rejects_corruption missing-result-section "$negative_committed" 'del(.rollback)' "$install_digest"
assert_rejects_corruption unexpected-extra-field "$negative_committed" '.unexpected="not-contract"' "$install_digest"

set_state "$update_journal" 85000000-0000-4000-8000-000000000002 "$TEST_ROOT/update-base.journal" \
  '.state="ROLLED_BACK" | .gate="established" | .namespaceIntent={kind:"rollback-exchange",state:"completed",sourceSlot:.candidate.completedSlot,destination:.normalizedRequest.facts.destination,candidate:.candidate.observed,prior:.normalizedRequest.facts.expectedActive.identity} | .rollbackEvidence={state:"completed",targetRole:"prior-tree",target:{state:"present",identity:.normalizedRequest.facts.expectedActive.identity},outcome:"restored"} | .rollback="completed" | .retainedPrior={state:"restored",identity:.normalizedRequest.facts.expectedActive.identity,slot:.candidate.completedSlot} | .rescan={outcome:"completed",shellInstance:"vector-shell",generation:2,scanEpoch:2,sourceDirectory:.normalizedRequest.facts.destination,expectedTree:.normalizedRequest.facts.expectedActive.identity,observedTree:.normalizedRequest.facts.expectedActive.identity} | .release={outcome:"authorized",shellInstance:"vector-shell",generation:2,configurationEpoch:2,source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced"} | .terminalReceipt={state:"durable",intendedJournalState:"ROLLED_BACK",operationBindingSha256:.operationBindingSha256,operationId:.operationId,pluginId:.pluginId,targetRole:"prior-tree",target:{state:"present",identity:.normalizedRequest.facts.expectedActive.identity},shellInstance:"vector-shell",generation:2,scanEpoch:2,configurationEpoch:2,outcome:"restored"} | .preExposureEvidence={source:{kind:"user",identity:"omarchy-shell-config:user:v1"},rawSha256:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",referenceProjection:"sha256:d1b70136d50b542b1c5646d3235047314bd09a2074c5e73e6c2389b7c3209432",referenceState:"unreferenced",referencePolicy:"require-unreferenced",configurationEpoch:1}'
negative_update_file="$TEST_ROOT/negative-update.json"
status 85000000-0000-4000-8000-000000000002 >"$negative_update_file"
assert_stdout_file "$negative_update_file"
negative_update=$(<"$negative_update_file")
if assert_common "$(jq -c '.rollback.target.tree.digest="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' <<<"$negative_update")" rolled-back-update 85000000-0000-4000-8000-000000000002 acme.vector-update ROLLED_BACK rolled-back restored "$update_digest" "$prior_digest" >/dev/null 2>&1; then
  printf 'negative control accepted wrong rollback target identity\n' >&2
  exit 1
fi
printf 'ok - assertion negative control rejects wrong rollback target identity\n'

printf 'ok - complete public-result vectors cover 25 O-8 durable states and rollback variants\n'
exit 0
