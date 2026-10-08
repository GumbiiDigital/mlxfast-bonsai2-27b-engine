#!/usr/bin/env bash
# Unit test for tools/decoder-staging-paths.sh. Offline, no GPU -- it drives the
# trusted jq reader against the real contract fixture and a few throwaway copies.
#
# Usage: tools/test-decoder-staging-paths.sh
# Exit:  0 all cases pass, 1 a case failed (printed with a FAIL prefix)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
READER="${SCRIPT_DIR}/tools/decoder-staging-paths.sh"
CONTRACT="${SCRIPT_DIR}/fixtures/bonsai2_27b_mlx_v1_track.json"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fails=0

expect_ok() {
  local label="$1" which="$2" want="$3" got rc
  got="$(MLXFAST_TEST_MODE=1 DECODER_STAGING_CONTRACT="${CONTRACT}" "${READER}" "${which}" 2>/dev/null)"
  rc=$?
  if [[ ${rc} -eq 0 && "${got}" == "${want}" ]]; then
    echo "PASS ${label}"
  else
    echo "FAIL ${label}: rc=${rc} got='${got}' want='${want}'"
    fails=$((fails + 1))
  fi
}

expect_ok_production() {
  local label="$1" which="$2" want="$3" got rc
  got="$("${READER}" "${which}" 2>/dev/null)"
  rc=$?
  if [[ ${rc} -eq 0 && "${got}" == "${want}" ]]; then
    echo "PASS ${label}"
  else
    echo "FAIL ${label}: rc=${rc} got='${got}' want='${want}'"
    fails=$((fails + 1))
  fi
}

expect_refuse() {
  local label="$1" contract="$2" which="$3" needle="$4" err rc
  err="$(MLXFAST_TEST_MODE=1 DECODER_STAGING_CONTRACT="${contract}" "${READER}" "${which}" 2>&1 >/dev/null)"
  rc=$?
  if [[ ${rc} -ne 0 && "${err}" == *"${needle}"* ]]; then
    echo "PASS ${label}"
  else
    echo "FAIL ${label}: expected refusal containing '${needle}', got rc=${rc} err='${err}'"
    fails=$((fails + 1))
  fi
}

mtp_want="$(jq -r '.mtp_head.staging_path' "${CONTRACT}")"
dflash_want="$(jq -r '.dflash_drafter.staging_path' "${CONTRACT}")"

expect_ok_production "mtp-head-matches-fixture-no-test-override" mtp-head "${mtp_want}"
expect_ok "mtp-head-matches-fixture" mtp-head "${mtp_want}"
expect_ok "dflash-drafter-matches-fixture" dflash-drafter "${dflash_want}"

missing_field="${WORK}/missing-field.json"
jq 'del(.mtp_head.staging_path)' "${CONTRACT}" > "${missing_field}"
expect_refuse "missing-mtp-staging-path" "${missing_field}" mtp-head "mtp_head.staging_path"

bad_value="${WORK}/bad-value.json"
jq '.mtp_head.staging_path = "../etc/passwd"' "${CONTRACT}" > "${bad_value}"
expect_refuse "bad-staging-path-rejected" "${bad_value}" mtp-head "not a permitted relative path"

dot_component="${WORK}/dot-component.json"
jq '.mtp_head.staging_path = "reference_weights/."' "${CONTRACT}" > "${dot_component}"
expect_refuse "dot-basename-rejected" "${dot_component}" mtp-head "not a permitted relative path"

dotdot_component="${WORK}/dotdot-component.json"
jq '.mtp_head.staging_path = "reference_weights/.."' "${CONTRACT}" > "${dotdot_component}"
expect_refuse "dotdot-basename-rejected" "${dotdot_component}" mtp-head "not a permitted relative path"

newline_embedded="${WORK}/newline-embedded.json"
jq '.mtp_head.staging_path = "reference_weights/ok\n../elsewhere"' "${CONTRACT}" > "${newline_embedded}"
expect_refuse "embedded-newline-rejected" "${newline_embedded}" mtp-head "embedded newlines"
newline_trailing="${WORK}/newline-trailing.json"
jq '.mtp_head.staging_path = "reference_weights/ok\n"' "${CONTRACT}" > "${newline_trailing}"
expect_refuse "trailing-newline-rejected" "${newline_trailing}" mtp-head "embedded newlines"

non_string="${WORK}/non-string.json"
jq '.mtp_head.staging_path = 42' "${CONTRACT}" > "${non_string}"
expect_refuse "non-string-staging-path-rejected" "${non_string}" mtp-head "non-string"

alt_fixture="${WORK}/alt.json"
jq '.mtp_head.staging_path = "reference_weights/Alt-Only-For-Test"' "${CONTRACT}" > "${alt_fixture}"
got_production="$(DECODER_STAGING_CONTRACT="${alt_fixture}" "${READER}" mtp-head 2>/dev/null)"
rc_production=$?
got_test="$(MLXFAST_TEST_MODE=1 DECODER_STAGING_CONTRACT="${alt_fixture}" "${READER}" mtp-head 2>/dev/null)"
rc_test=$?
if [[ ${rc_production} -eq 0 && "${got_production}" == "${mtp_want}" ]]; then
  echo "PASS production-ignores-decoder-staging-contract-without-test-mode"
else
  echo "FAIL production-ignores-decoder-staging-contract-without-test-mode: rc=${rc_production} got='${got_production}' want='${mtp_want}'"
  fails=$((fails + 1))
fi
if [[ ${rc_test} -eq 0 && "${got_test}" == "reference_weights/Alt-Only-For-Test" ]]; then
  echo "PASS test-mode-honors-decoder-staging-contract"
else
  echo "FAIL test-mode-honors-decoder-staging-contract: rc=${rc_test} got='${got_test}'"
  fails=$((fails + 1))
fi

err="$(MLXFAST_TEST_MODE=1 DECODER_STAGING_CONTRACT="${CONTRACT}" bash -c '
  PATH=/usr/bin:/bin
  command() {
    if [[ "$1" == -v && "$2" == jq ]]; then
      return 1
    fi
    builtin command "$@"
  }
  source "'"${READER}"'"
  mtp_head_staging_path
' 2>&1 >/dev/null)"
rc=$?
if [[ ${rc} -ne 0 && "${err}" == *"jq is required"* ]]; then
  echo "PASS missing-jq"
else
  echo "FAIL missing-jq: expected jq refusal, got rc=${rc} err='${err}'"
  fails=$((fails + 1))
fi

if [[ "${fails}" -eq 0 ]]; then
  echo "test-decoder-staging-paths: all cases passed"
  exit 0
fi
echo "test-decoder-staging-paths: ${fails} case(s) failed" >&2
exit 1
