#!/usr/bin/env bash
# step0-replay: golang/go#27628. The build cache stores the stderr of a tool
# run and replays it on a later build, even a plain one without -toolexec.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fresh_cache step0-replay
cd "${REPO}"

run_capture step0-replay-1-cold.raw \
  "${GO}" build -toolexec=/usr/bin/time -o "${CACHE}/app" ./app
run_capture step0-replay-2-plain.raw "${GO}" build -o "${CACHE}/app" ./app
run_capture step0-replay-3-x.raw "${GO}" build -x -o "${CACHE}/app" ./app
# run_capture also wrote copies into CAPTURES; the sections are kept together
# in one file instead.
rm -f "${CAPTURES}"/step0-replay-?-*.raw

raw() { cat "${CACHE}/step0-replay-$1.raw.raw"; }
{
  echo "### 1. cold: go build -toolexec=/usr/bin/time ./app (fresh GOCACHE)"
  raw 1-cold
  echo "### 2. plain: go build ./app (no -toolexec, same GOCACHE)"
  raw 2-plain
  echo "### 3. go build -x ./app (no -toolexec, same GOCACHE)"
  raw 3-x
} | capture_text step0-replay.txt

cold="${CACHE}/step0-replay-1-cold.raw.raw"
plain="${CACHE}/step0-replay-2-plain.raw.raw"
xlog="${CACHE}/step0-replay-3-x.raw.raw"
{
  echo "timed lines (' real ') in the cold build:                    $(grep -c ' real ' "${cold}" || true)"
  echo "timed lines (' real ') in the plain build with no -toolexec:  $(grep -c ' real ' "${plain}" || true)"
  echo "timed lines (' real ') in the go build -x build:              $(grep -c ' real ' "${xlog}" || true)"
  echo "lines in the -x log ending in ' # internal':                  $(grep -c ' # internal$' "${xlog}" || true)"
  echo "compile/asm/link commands run by the -x build:                $(grep -c -e '/compile ' -e '/asm ' -e '/link ' "${xlog}" || true)"
  echo "lines in the -x log starting with 'cat ':                $(grep -c '^cat ' "${xlog}" || true)"
  echo "lines in the -x log starting with 'echo ':               $(grep -c '^echo ' "${xlog}" || true)"
  echo
  echo "first 6 ' # internal' lines of the -x log (cmd/go replays each cached tool output by cat-ing the cache file):"
  grep -n ' # internal$' "${xlog}" | head -6 || true
} | capture_text step0-replay-summary.txt
cat "${CAPTURES}/step0-replay-summary.txt"
