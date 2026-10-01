#!/usr/bin/env bash
# step1: go build -a -x -work ./app
# Shows what cmd/go runs, and the importcfg each compile is given.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fresh_cache step1
cd "${REPO}"

run_capture step1-x.txt "${GO}" build -a -x -work -o "${CACHE}/app" ./app
write_exit step1-x.txt

work="$(work_dir "${CACHE}/step1-x.txt.raw")"
printf '%s\n' "$(grep '^WORK=' "${CACHE}/step1-x.txt.raw")" | capture_text step1-work.txt

# The main package is the first action, so its directory is b001.
capture_text step1-importcfg.txt <"${work}/b001/importcfg"

# cmd/go marks the heredoc that writes each importcfg with "# internal".
{
  grep -n ' # internal$' "${CACHE}/step1-x.txt.raw" || echo "(no '# internal' lines in this log)"
} | capture_text step1-internal.txt

{
  echo "lines in the -x log:                  $(wc -l <"${CACHE}/step1-x.txt.raw" | tr -d ' ')"
  echo "compile invocations:                  $(grep -c '/compile ' "${CACHE}/step1-x.txt.raw" || true)"
  echo "asm invocations:                      $(grep -c '/asm ' "${CACHE}/step1-x.txt.raw" || true)"
  echo "link invocations:                     $(grep -c '/link ' "${CACHE}/step1-x.txt.raw" || true)"
  echo "'# internal' lines:                   $(grep -c ' # internal$' "${CACHE}/step1-x.txt.raw" || true)"
  echo "packagefile lines in app importcfg:   $(grep -c '^packagefile ' "${work}/b001/importcfg")"
} | capture_text step1-summary.txt
cat "${CAPTURES}/step1-summary.txt"
