#!/bin/bash

interface_test_root() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
}

build_interface_install() {
  local root=$1 install_root=$2
  local sanitizer_value=${OMARCHY_PLUGIN_TREE_SANITIZER_FLAGS:-}
  local -a sanitizer_flags=()
  read -r -a sanitizer_flags <<<"$sanitizer_value"
  mkdir -p "$install_root/bin" "$install_root/native/plugin-transaction"
  cp "$root/bin/omarchy" "$root/bin/omarchy-plugin-transaction" \
    "$root/bin/omarchy-plugin-validate" "$root/bin/omarchy-shell" "$install_root/bin/"
  cp "$root/native/plugin-transaction/stage-candidate" \
    "$root/native/plugin-transaction/validate-request.jq" \
    "$root/native/plugin-transaction/validate-stage-observation.jq" \
    "$root/native/plugin-transaction/validate-journal.jq" \
    "$root/native/plugin-transaction/validate-gate.jq" \
    "$install_root/native/plugin-transaction/"
  mise exec -- clang -std=c17 -Wall -Wextra -Werror -Wconversion -Wshadow -O2 \
    -DOMARCHY_PLUGIN_TREE_TEST_HOOKS \
    "${sanitizer_flags[@]}" \
    "$root/native/plugin-transaction/plugin-tree.c" \
    -o "$install_root/native/plugin-transaction/plugin-tree"
}

initialize_transaction_state() {
  local state_root=$1
  mkdir -p "$state_root/journals" "$state_root/gates" \
    "$state_root/locks/operations" "$state_root/locks/plugins"
  chmod 0700 "$state_root" "$state_root/journals" "$state_root/gates" \
    "$state_root/locks" "$state_root/locks/operations" "$state_root/locks/plugins"
}

make_interface_plugin() {
  local root=$1 destination=$2 plugin_id=$3
  mkdir -p "$destination"
  cp "$root/test/shell.d/fixtures/plugin-load-race/Service.qml" "$destination/Service.qml"
  jq --arg id "$plugin_id" '.id = $id' \
    "$root/test/shell.d/fixtures/plugin-load-race/manifest.json" >"$destination/manifest.json"
}

empty_projection_base64() {
  printf 'omarchy-schema-v1-reference-projection/v1\0' | base64 -w0
}
