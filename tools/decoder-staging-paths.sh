#!/usr/bin/env bash
# Decoder staging paths are pinned once in fixtures/bonsai2_27b_mlx_v1_track.json
# (`mtp_head.staging_path`, `dflash_drafter.staging_path`). Shell control flow
# reads them through jq, like tools/spec-declaration.sh.
#
# Usage:
#   source tools/decoder-staging-paths.sh
#   tools/decoder-staging-paths.sh mtp-head
#   tools/decoder-staging-paths.sh dflash-drafter
#
# Tests may set DECODER_STAGING_CONTRACT only when MLXFAST_TEST_MODE=1.
# Production and ranked runs always read the tree fixture; ranked preflight
# refuses DECODER_STAGING_CONTRACT and MLXFAST_TEST_MODE in the job environment.
_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_REPO_ROOT="$(cd "${_TOOLS_DIR}/.." && pwd -P)"
_DECODER_STAGING_CONTRACT="${_REPO_ROOT}/fixtures/bonsai2_27b_mlx_v1_track.json"
if [[ -n "${DECODER_STAGING_CONTRACT:-}" ]]; then
  if [[ "${MLXFAST_TEST_MODE:-}" == "1" ]]; then
    _DECODER_STAGING_CONTRACT="${DECODER_STAGING_CONTRACT}"
  fi
fi

_decoder_staging_fail() {
  echo "decoder-staging-paths.sh: $*" >&2
  return 1
}

_decoder_staging_jq_key() {
  case "${1:-}" in
    mtp-head) printf '%s' '.mtp_head.staging_path' ;;
    dflash-drafter) printf '%s' '.dflash_drafter.staging_path' ;;
    *) _decoder_staging_fail "unknown decoder '${1:-}'"; return 1 ;;
  esac
}

_decoder_staging_validate_raw() {
  local raw="$1"
  local jq_key="$2"
  [[ "${raw}" != *$'\n'* && "${raw}" != *$'\r'* ]] \
    || { _decoder_staging_fail "staging_path ${jq_key} must be a single line (no embedded newlines)"; return 1; }
  [[ "${raw}" =~ ^reference_weights/[A-Za-z0-9._+-]+$ ]] \
    || { _decoder_staging_fail "staging_path '${raw}' is not a permitted relative path under reference_weights/"; return 1; }
  local base="${raw#reference_weights/}"
  [[ "${base}" != "." && "${base}" != ".." ]] \
    || { _decoder_staging_fail "staging_path '${raw}' is not a permitted relative path under reference_weights/"; return 1; }
  return 0
}

_decoder_staging_read() {
  local which="$1"
  local jq_key raw
  command -v jq >/dev/null 2>&1 \
    || { _decoder_staging_fail "jq is required to read the track contract fixture"; return 1; }
  [[ -f "${_DECODER_STAGING_CONTRACT}" ]] \
    || { _decoder_staging_fail "track contract fixture missing: ${_DECODER_STAGING_CONTRACT}"; return 1; }
  jq_key="$(_decoder_staging_jq_key "${which}")" || return 1
  jq -e "${jq_key} | type == \"string\"" "${_DECODER_STAGING_CONTRACT}" >/dev/null 2>&1 \
    || { _decoder_staging_fail "missing or non-string ${jq_key} in ${_DECODER_STAGING_CONTRACT}"; return 1; }
  # Reject CR/LF inside jq: $(...) strips trailing newlines before the shell
  # check below could see them.
  jq -e "${jq_key} | test(\"[\\\\r\\\\n]\") | not" "${_DECODER_STAGING_CONTRACT}" >/dev/null 2>&1 \
    || { _decoder_staging_fail "${jq_key} contains embedded newlines in ${_DECODER_STAGING_CONTRACT}"; return 1; }
  raw="$(jq -e -r "${jq_key}" "${_DECODER_STAGING_CONTRACT}" 2>/dev/null)" \
    || { _decoder_staging_fail "missing or unreadable ${jq_key} in ${_DECODER_STAGING_CONTRACT}"; return 1; }
  [[ -n "${raw}" ]] \
    || { _decoder_staging_fail "missing or empty ${jq_key} in ${_DECODER_STAGING_CONTRACT}"; return 1; }
  _decoder_staging_validate_raw "${raw}" "${jq_key}" || return 1
  printf '%s' "${raw}"
}

mtp_head_staging_path() {
  _decoder_staging_read mtp-head
}

dflash_drafter_staging_path() {
  _decoder_staging_read dflash-drafter
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
    mtp-head) mtp_head_staging_path ;;
    dflash-drafter) dflash_drafter_staging_path ;;
    *)
      echo "usage: decoder-staging-paths.sh mtp-head|dflash-drafter" >&2
      exit 2
      ;;
  esac
  exit 0
fi
