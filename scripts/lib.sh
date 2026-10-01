#!/usr/bin/env bash
# Shared helpers for the step scripts. Source this file; do not run it.
#
# Environment (all optional; the Makefile sets them):
#   GO            go command to use                      (default: go)
#   CAPTURES      directory for the capture files        (default: ./captures)
#   TOOLBIN       directory for stopwatch and toyhook    (default: ./.bin)
#   CACHE_SUFFIX  appended to every .cache/<name> dir    (default: empty)

# shellcheck disable=SC2034  # variables are used by the scripts that source this
set -o errexit -o nounset -o pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO
readonly MODULE="github.com/kakkoyun/hooking-into-the-go-toolchain"

GO="${GO:-go}"
CAPTURES="${CAPTURES:-${REPO}/captures}"
TOOLBIN="${TOOLBIN:-${REPO}/.bin}"
CACHE_SUFFIX="${CACHE_SUFFIX:-}"
OTELC="${REPO}/.bin/otelc"

# Reproducible builds: no user flags, no toolchain switching, no go.work.
export GOFLAGS="" GOTOOLCHAIN=local GOWORK=off

GOROOT_DIR="$("${GO}" env GOROOT)"
GOTOOLDIR="$("${GO}" env GOTOOLDIR)"
readonly GOROOT_DIR GOTOOLDIR

# cmd/go prints source paths relative to the current directory when that is
# shorter (for example ../../../../sdk/go1.26.8/src/os/file.go), so norm_copy
# needs this spelling of GOROOT as well as the absolute one.
GOROOT_REL="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "${GOROOT_DIR}" "${REPO}" 2>/dev/null || true)"
readonly GOROOT_REL

mkdir -p "${CAPTURES}" "${TOOLBIN}"

CACHE=""
LAST_RC=0

# build_tools: build stopwatch and toyhook with $GO into $TOOLBIN, using a
# repo-local cache so the user's GOCACHE is never touched.
build_tools() {
  local cache="${REPO}/.cache/tools${CACHE_SUFFIX}"
  mkdir -p "${cache}"
  (
    cd "${REPO}"
    GOCACHE="${cache}" "${GO}" build -o "${TOOLBIN}/stopwatch" ./cmd/stopwatch
    GOCACHE="${cache}" "${GO}" build -o "${TOOLBIN}/toyhook" ./cmd/toyhook
  )
}

# fresh_cache NAME: an empty repo-local GOCACHE and TMPDIR for one target.
# cmd/go puts its $WORK directory under TMPDIR, so -work output stays here too.
fresh_cache() {
  CACHE="${REPO}/.cache/$1${CACHE_SUFFIX}"
  rm -rf "${CACHE}"
  mkdir -p "${CACHE}/tmp"
  export GOCACHE="${CACHE}/gocache" TMPDIR="${CACHE}/tmp"
}

# escape_sed STRING: escape STRING for use as a literal in a sed regexp.
escape_sed() {
  printf '%s' "$1" | sed 's/[][\.*^$|/]/\\&/g'
}

# norm_copy SRC DST: copy SRC to DST, replacing machine-specific paths with
# $REPO, $GOROOT (absolute, and relative to the repository) and $HOME. This is
# the only edit made to a capture. User and host names are not replaced here,
# because a bare name such as "root" or "localhost" would also match unrelated
# text; see scrub_identity.
norm_copy() {
  local tmp
  local -a rel_args=()
  if [[ "${GOROOT_REL}" == ../* ]]; then
    rel_args=(-e "s|$(escape_sed "${GOROOT_REL}")|\$GOROOT|g")
  fi
  tmp="$(mktemp)"
  sed \
    -e "s|$(escape_sed "${REPO}")|\$REPO|g" \
    -e "s|$(escape_sed "${GOROOT_DIR}")|\$GOROOT|g" \
    ${rel_args[@]+"${rel_args[@]}"} \
    -e "s|$(escape_sed "${HOME}")|\$HOME|g" \
    "$1" >"${tmp}"
  mv "${tmp}" "$2"
  chmod 644 "$2"
}

# scrub_identity FILE: in place, replace the user name and host name with $USER
# and $HOSTNAME, but only where OpenTelemetry resource attributes put them:
# the value of process.owner, the value of host.name, and the "Darwin <host> "
# or "Linux <host> " text inside os.description. Values such as "go", "darwin"
# or "hello" elsewhere in the file can never match.
scrub_identity() {
  local user host tmp attr
  user="$(escape_sed "$(id -un)")"
  host="$(escape_sed "$(hostname)")"
  attr='"Value":\{"Type":"STRING","Value":"'
  tmp="$(mktemp)"
  sed -E \
    -e "s/(\"process\.owner\",${attr})${user}\"/\\1\$USER\"/g" \
    -e "s/(\"host\.name\",${attr})${host}\"/\\1\$HOSTNAME\"/g" \
    -e "s/(Darwin|Linux) ${host} /\\1 \$HOSTNAME /g" \
    "$1" >"${tmp}"
  mv "${tmp}" "$1"
  chmod 644 "$1"
}

# run_capture NAME CMD...: run CMD, save its combined stdout and stderr as
# captures/NAME, and keep its exit status in LAST_RC. Never fails.
run_capture() {
  local name="$1"
  shift
  LAST_RC=0
  "$@" >"${CACHE}/${name}.raw" 2>&1 || LAST_RC=$?
  norm_copy "${CACHE}/${name}.raw" "${CAPTURES}/${name}"
}

# write_exit NAME: record LAST_RC next to captures/NAME as NAME.exit.
write_exit() {
  printf 'exit status: %s\n' "${LAST_RC}" >"${CAPTURES}/${1}.exit"
}

# capture_text NAME: save stdin as captures/NAME, paths normalised.
capture_text() {
  cat >"${CACHE}/${1}.raw"
  norm_copy "${CACHE}/${1}.raw" "${CAPTURES}/${1}"
}

# work_dir LOGFILE: the $WORK directory printed as WORK=... in LOGFILE.
work_dir() {
  awk -F= '/^WORK=/{v=substr($0, 6)} END{print v}' "$1"
}
