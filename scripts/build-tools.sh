#!/usr/bin/env bash
# Build stopwatch and toyhook into $TOOLBIN.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rm -rf "${REPO}/.cache/tools${CACHE_SUFFIX}"
build_tools
echo "built ${TOOLBIN}/stopwatch and ${TOOLBIN}/toyhook with $("${GO}" version)"
