#!/usr/bin/env bash
# Focused regressions for the Stage 0 Firstmate-owned extension host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/bin/fm-extension.sh"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_fake_no_mistakes() {
  local file=$1
  cat > "$file" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "${NM_HOME:-}" "${NO_MISTAKES_NO_UPDATE_CHECK:-}" "$*" >> "${FM_FAKE_NM_LOG:?}"
if [ "${1:-}" = "--version" ]; then
  printf 'no-mistakes version %s\n' "${FM_FAKE_NM_VERSION:-v1.40.1}"
  exit 0
fi
if [ "${1:-}" = "axi" ] && [ "${2:-}" = "status" ]; then
  printf 'fake-status\n'
  exit 0
fi
if [ "${1:-}" = "axi" ] && [ "${2:-}" = "logs" ]; then
  printf 'fake-logs\n'
  exit 0
fi
printf 'unexpected no-mistakes call: %s\n' "$*" >&2
exit 2
SH
  chmod 700 "$file"
}

write_config() {
  local manifest_hash=$1
  mkdir -p "$(dirname "$CASE_CONFIG")"
  cat > "$CASE_CONFIG" <<JSON
{
  "api_version": "firstmate.extension.config/v1",
  "id": "$CASE_ID",
  "manifest_path": "$CASE_MANIFEST",
  "manifest_sha256": "$manifest_hash"
}
JSON
  chmod 600 "$CASE_CONFIG"
}

write_manifest_config() {
  local capabilities_json=${1:-'"no_mistakes.repo_command", "no_mistakes.axi_observe"'}
  local permissions_json=${2:-'"network": false, "read": [], "write": []'}
  local entry_path=${3:-bin/lint-wrapper}
  local entry_hash=${4:-$CASE_ENTRY_HASH}
  local requires_json=${5:-'{ "firstmate": ">=0.0.0", "no_mistakes": ">=1.40.1" }'}
  local source_path=${6:-.}
  cat > "$CASE_MANIFEST" <<JSON
{
  "api_version": "firstmate.extension/v1",
  "id": "$CASE_ID",
  "version": "0.1.0",
  "source": { "type": "local_path", "path": "$source_path" },
  "requires": $requires_json,
  "capabilities": [ $capabilities_json ],
  "permissions": { $permissions_json },
  "entrypoints": {
    "lint": {
      "path": "$entry_path",
      "sha256": "$entry_hash",
      "capabilities": ["no_mistakes.repo_command"],
      "no_mistakes_command": "lint"
    }
  }
}
JSON
  chmod 600 "$CASE_MANIFEST"
  CASE_MANIFEST_HASH=$(sha256_file "$CASE_MANIFEST")
  write_config "$CASE_MANIFEST_HASH"
}

setup_case() {
  local tmp=$1
  local wrapper_kind=${2:-pass}
  CASE_ID=owned-nm-policy
  CASE_HOME="$tmp/fm-home"
  CASE_EXT="$tmp/extension"
  CASE_MANIFEST="$CASE_EXT/extension.json"
  CASE_CONFIG="$CASE_HOME/config/extensions.d/$CASE_ID.json"
  CASE_FAKE_NM="$tmp/fake-no-mistakes"
  CASE_FAKE_NM_LOG="$tmp/fake-no-mistakes.log"
  mkdir -p "$CASE_HOME/config/extensions.d" "$CASE_EXT/bin"
  chmod 700 "$CASE_HOME" "$CASE_HOME/config" "$CASE_HOME/config/extensions.d" "$CASE_EXT" "$CASE_EXT/bin"
  : > "$CASE_FAKE_NM_LOG"
  write_fake_no_mistakes "$CASE_FAKE_NM"
  case "$wrapper_kind" in
    pass)
      cat > "$CASE_EXT/bin/lint-wrapper" <<'SH'
#!/usr/bin/env bash
printf 'lint-wrapper cwd=%s nm=%s network=%s writes=%s entry=%s\n' \
  "$PWD" "${NM_HOME:-}" "${FM_EXTENSION_NETWORK:-}" "${FM_EXTENSION_WRITE_ROOTS:-}" "${FM_EXTENSION_ENTRYPOINT:-}"
SH
      ;;
    fail)
      cat > "$CASE_EXT/bin/lint-wrapper" <<'SH'
#!/usr/bin/env bash
printf 'wrapper failed intentionally\n' >&2
exit 42
SH
      ;;
    *)
      fail "unknown wrapper kind: $wrapper_kind"
      ;;
  esac
  chmod 700 "$CASE_EXT/bin/lint-wrapper"
  CASE_ENTRY_HASH=$(sha256_file "$CASE_EXT/bin/lint-wrapper")
  write_manifest_config
}

fm_ext() {
  FM_FAKE_NM_LOG="$CASE_FAKE_NM_LOG" "$EXT" \
    --home "$CASE_HOME" \
    --config "$CASE_CONFIG" \
    --no-mistakes-bin "$CASE_FAKE_NM" \
    "$@"
}

expect_fm_ext_fail() {
  local label=$1 expected=$2 out rc
  shift 2
  out=$(fm_ext "$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label should fail"
  assert_contains "$out" "$expected" "$label"
  pass "$label"
}

refresh_manifest_hash() {
  CASE_MANIFEST_HASH=$(sha256_file "$CASE_MANIFEST")
  write_config "$CASE_MANIFEST_HASH"
}

test_valid_manifest_doctor() {
  local tmp out
  tmp=$(fm_test_tmproot fm-extension-valid)
  setup_case "$tmp"
  out=$(fm_ext doctor "$CASE_ID") || fail "doctor should accept a valid extension"
  assert_contains "$out" "fm-extension: ok $CASE_ID 0.1.0" "doctor did not report valid extension"
  assert_contains "$out" "no_mistakes.axi_observe,no_mistakes.repo_command" "doctor did not report capabilities"
  pass "valid firstmate.extension/v1 manifest validates"
}

test_manifest_security_rejections() {
  local tmp

  tmp=$(fm_test_tmproot fm-extension-bad-json)
  setup_case "$tmp"
  printf '{not json\n' > "$CASE_MANIFEST"
  chmod 600 "$CASE_MANIFEST"
  refresh_manifest_hash
  expect_fm_ext_fail "malformed manifest JSON is rejected" "malformed JSON" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-bad-cap)
  setup_case "$tmp"
  write_manifest_config '"no_mistakes.repo_command", "unknown.capability"'
  expect_fm_ext_fail "unknown capabilities are rejected" "capability is unknown" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-traversal)
  setup_case "$tmp"
  write_manifest_config '"no_mistakes.repo_command"' '"network": false, "read": [], "write": []' "../outside"
  expect_fm_ext_fail "path traversal entrypoints are rejected" "escapes the extension source root" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-symlink)
  setup_case "$tmp"
  mv "$CASE_EXT/bin/lint-wrapper" "$CASE_EXT/bin/real-wrapper"
  ln -s real-wrapper "$CASE_EXT/bin/lint-wrapper"
  CASE_ENTRY_HASH=$(sha256_file "$CASE_EXT/bin/lint-wrapper")
  write_manifest_config
  expect_fm_ext_fail "symlink entrypoints are rejected" "must not be a symlink" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-entry-mode)
  setup_case "$tmp"
  chmod 720 "$CASE_EXT/bin/lint-wrapper"
  write_manifest_config
  expect_fm_ext_fail "group-writable entrypoints are rejected" "must not be group- or world-writable" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-root-mode)
  setup_case "$tmp"
  chmod 777 "$CASE_EXT"
  expect_fm_ext_fail "world-writable extension roots are rejected" "source root must not be group- or world-writable" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-manifest-hash)
  setup_case "$tmp"
  write_config "0000000000000000000000000000000000000000000000000000000000000000"
  expect_fm_ext_fail "manifest hash mismatches are rejected" "manifest hash mismatch" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-entry-hash)
  setup_case "$tmp"
  write_manifest_config '"no_mistakes.repo_command"' '"network": false, "read": [], "write": []' "bin/lint-wrapper" "0000000000000000000000000000000000000000000000000000000000000000"
  expect_fm_ext_fail "entrypoint hash mismatches are rejected" "entrypoint lint hash mismatch" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-version)
  setup_case "$tmp"
  FM_FAKE_NM_VERSION=v1.39.0 expect_fm_ext_fail "incompatible No Mistakes versions are rejected" "does not satisfy >=1.40.1" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-network)
  setup_case "$tmp"
  write_manifest_config '"no_mistakes.repo_command"' '"network": true, "read": [], "write": []'
  expect_fm_ext_fail "explicit network permission is rejected" "permissions.network must be false" doctor "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-write)
  setup_case "$tmp"
  write_manifest_config '"no_mistakes.repo_command"' "\"network\": false, \"read\": [], \"write\": [\"\$WORKTREE\"]"
  expect_fm_ext_fail "explicit write permission is rejected" "permissions.write must be empty" doctor "$CASE_ID"
}

test_activation_and_deactivation_markers() {
  local tmp generated wrapper unowned out
  tmp=$(fm_test_tmproot fm-extension-unowned-marker)
  setup_case "$tmp"
  generated="$CASE_HOME/state/extensions/$CASE_ID/generated"
  mkdir -p "$generated"
  printf '{"api_version":"other","id":"someone-else"}\n' > "$generated/.owner.json"
  expect_fm_ext_fail "activation refuses unowned generated owner markers" \
    "refusing to overwrite unowned generated owner marker" activate "$CASE_ID"

  tmp=$(fm_test_tmproot fm-extension-activate)
  setup_case "$tmp"
  out=$(fm_ext activate "$CASE_ID") || fail "activate should succeed: $out"
  generated="$CASE_HOME/state/extensions/$CASE_ID/generated"
  wrapper="$generated/wrappers/lint"
  assert_present "$generated/.owner.json" "activation did not write owner marker"
  assert_present "$wrapper" "activation did not write generated wrapper"
  [ -x "$wrapper" ] || fail "generated wrapper is not executable"
  assert_grep "firstmate-extension-generated firstmate.extension.generated/v1 id=$CASE_ID" "$wrapper" \
    "generated wrapper lacks owner marker"
  out=$(fm_ext render-no-mistakes "$CASE_ID") || fail "render-no-mistakes should succeed"
  assert_contains "$out" "commands:" "render-no-mistakes did not print commands root"
  assert_contains "$out" "lint:" "render-no-mistakes did not print lint command"

  unowned="$generated/wrappers/unowned"
  printf 'do not remove me\n' > "$unowned"
  out=$(fm_ext deactivate "$CASE_ID") || fail "deactivate should succeed: $out"
  assert_absent "$wrapper" "deactivate removed no generated wrapper"
  assert_absent "$generated/.owner.json" "deactivate did not remove owner marker"
  assert_present "$unowned" "deactivate removed unowned material"
  rm -f "$unowned"
  out=$(fm_ext deactivate "$CASE_ID") || fail "second deactivate should clean empty dirs: $out"
  assert_absent "$generated" "deactivate did not remove empty generated directory"
  pass "activation and deactivation honor owner markers"
}

test_wrapper_failure_behavior() {
  local tmp wrapper rc
  tmp=$(fm_test_tmproot fm-extension-wrapper-fail)
  setup_case "$tmp" fail
  fm_ext activate "$CASE_ID" >/dev/null || fail "activate should succeed for failing wrapper"
  wrapper="$CASE_HOME/state/extensions/$CASE_ID/generated/wrappers/lint"
  FM_FAKE_NM_LOG="$CASE_FAKE_NM_LOG" "$wrapper" >/dev/null 2>"$tmp/err"
  rc=$?
  [ "$rc" -eq 42 ] || fail "generated wrapper should propagate entrypoint exit 42, got $rc"
  assert_grep "wrapper failed intentionally" "$tmp/err" "wrapper stderr was not preserved"
  pass "wrapper failures propagate through the host"
}

test_isolated_nm_home_repo_command_wrapper() {
  local tmp wrapper scratch nm_home out rendered
  tmp=$(fm_test_tmproot fm-extension-nm-home)
  setup_case "$tmp"
  fm_ext activate "$CASE_ID" >/dev/null || fail "activate should succeed"
  wrapper="$CASE_HOME/state/extensions/$CASE_ID/generated/wrappers/lint"
  scratch="$tmp/scratch-repo"
  nm_home="$tmp/isolated-nm-home"
  mkdir -p "$nm_home"
  fm_git_init_commit "$scratch"
  rendered=$(fm_ext render-no-mistakes "$CASE_ID") || fail "render-no-mistakes should succeed"
  printf '%s\n' "$rendered" > "$scratch/.no-mistakes.yaml"

  out=$(cd "$scratch" && FM_FAKE_NM_LOG="$CASE_FAKE_NM_LOG" NM_HOME="$nm_home" "$wrapper") \
    || fail "generated lint wrapper should run from scratch repo"
  assert_contains "$out" "cwd=$scratch" "wrapper did not preserve the scratch repository CWD"
  assert_contains "$out" "nm=$nm_home" "wrapper did not preserve isolated NM_HOME"
  assert_contains "$out" "network=0" "wrapper did not receive default-deny network env"
  assert_contains "$out" "writes= entry=lint" "wrapper did not receive default-deny write env and entrypoint"
  assert_grep "$nm_home"$'\t'"1"$'\t'"--version" "$CASE_FAKE_NM_LOG" \
    "version check did not use the isolated No Mistakes home"
  pass "repo-command wrapper works in a scratch repo with isolated NM_HOME"
}

test_read_only_no_mistakes_observability() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-extension-observe)
  setup_case "$tmp"
  out=$(fm_ext observe-no-mistakes "$CASE_ID" status -- --json) \
    || fail "observe-no-mistakes status should succeed"
  assert_contains "$out" "fake-status" "status observation did not relay no-mistakes output"
  assert_grep "axi status --json" "$CASE_FAKE_NM_LOG" "status observation did not call read-only AXI status"

  out=$(fm_ext observe-no-mistakes "$CASE_ID" logs -- --step lint) \
    || fail "observe-no-mistakes logs should succeed"
  assert_contains "$out" "fake-logs" "logs observation did not relay no-mistakes output"
  assert_grep "axi logs --step lint" "$CASE_FAKE_NM_LOG" "logs observation did not call read-only AXI logs"

  out=$(fm_ext observe-no-mistakes "$CASE_ID" respond 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "respond observation should fail with usage exit 2, got $rc"
  assert_contains "$out" "only permits read-only AXI actions" "respond refusal was not explicit"

  write_manifest_config '"no_mistakes.repo_command"'
  out=$(fm_ext observe-no-mistakes "$CASE_ID" status 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "observe should fail without no_mistakes.axi_observe capability"
  assert_contains "$out" "not granted no_mistakes.axi_observe" "capability denial was not explicit"
  pass "No Mistakes AXI observability is read-only and capability-gated"
}

test_valid_manifest_doctor
test_manifest_security_rejections
test_activation_and_deactivation_markers
test_wrapper_failure_behavior
test_isolated_nm_home_repo_command_wrapper
test_read_only_no_mistakes_observability
