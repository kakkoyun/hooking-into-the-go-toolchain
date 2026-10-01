#!/usr/bin/env bash
# step0: go build -a -toolexec=/usr/bin/time ./app
# Shows that -toolexec just puts a program in front of every tool call.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fresh_cache step0
cd "${REPO}"

run_capture step0-stderr.txt \
  "${GO}" build -a -toolexec=/usr/bin/time -o "${CACHE}/app" ./app
write_exit step0-stderr.txt

# /usr/bin/time prints one "real user sys" line per wrapped invocation.
timed="$(grep -c ' real ' "${CACHE}/step0-stderr.txt.raw" || true)"
lines="$(wc -l <"${CACHE}/step0-stderr.txt.raw" | tr -d ' ')"
probes="$(grep -c -e '-V=full' "${CACHE}/step0-stderr.txt.raw" || true)"
{
  echo "lines in stderr:                  ${lines}"
  echo "lines with 'real' (timed calls):  ${timed}"
  echo "lines mentioning -V=full:         ${probes}"
  echo
  echo "/usr/bin/time prints to stderr. cmd/go throws away the stderr of a"
  echo "successful '-V=full' probe and only reads its stdout, so probes are timed"
  echo "but never shown; the lines above belong to real compile/asm/link calls."
} | capture_text step0-summary.txt
cat "${CAPTURES}/step0-summary.txt"
