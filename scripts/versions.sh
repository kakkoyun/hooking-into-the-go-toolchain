#!/usr/bin/env bash
# versions: record the toolchain versions behind a set of captures.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

{
  echo "go:      $("${GO}" version)"
  if [[ -x "${OTELC}" ]]; then
    echo "otelc:   $("${OTELC}" version --verbose | tr '\n' ' ')"
  else
    echo "otelc:   not installed (make otelc-install)"
  fi
  echo "uname:   $(uname -sm)"
  echo "date:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"${CAPTURES}/versions.raw"
# Not a capture of one command, so it is normalised directly.
norm_copy "${CAPTURES}/versions.raw" "${CAPTURES}/versions.txt"
rm -f "${CAPTURES}/versions.raw"
cat "${CAPTURES}/versions.txt"
