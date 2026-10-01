#!/usr/bin/env bash
# step2: cmd/stopwatch, a -toolexec wrapper that times every tool call.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build_tools
cd "${REPO}"
stopwatch="${TOOLBIN}/stopwatch"
tab=$'\t'

# build_with_stopwatch [go build flags]: build ./app with the stopwatch wrapper.
build_with_stopwatch() {
  "${GO}" build "$@" -toolexec="${stopwatch}" -o "${CACHE}/app" ./app
}

fresh_cache step2
log="${CACHE}/stopwatch.log"
: >"${log}"
run_capture step2-build.txt env STOPWATCH_LOG="${log}" "${GO}" build -a -toolexec="${stopwatch}" -o "${CACHE}/app" ./app
write_exit step2-build.txt
norm_copy "${log}" "${CAPTURES}/step2-log.tsv"

# Per-tool counts, probes separated from real work.
awk -F'\t' '
  $4 == "-V=full" { probes[$1]++; next }
  { runs[$1]++ }
  END {
    for (t in runs) seen[t] = 1
    for (t in probes) seen[t] = 1
    printf "%-10s %8s %10s\n", "tool", "runs", "-V=full"
    for (t in seen) printf "%-10s %8d %10d\n", t, runs[t], probes[t]
  }' "${log}" | {
  IFS= read -r header
  echo "${header}"
  sort
} | capture_text step2-counts.txt
cat "${CAPTURES}/step2-counts.txt"

# Five slowest compile calls, probes excluded. The tab-separated log is
# <tool> TAB <import path> TAB <ms> TAB <summary>.
{
  printf '%6s  %s\n' "ms" "package"
  awk -F'\t' '$1 == "compile" && $4 != "-V=full"' "${log}" |
    sort -t "${tab}" -k3,3nr | head -5 |
    awk -F'\t' '{ printf "%6d  %s\n", $3, $2 }'
} | capture_text step2-slowest.txt
cat "${CAPTURES}/step2-slowest.txt"

# The -V=full probes: how many, one example, and what the wrapper answers.
{
  echo "probes logged: $(awk -F'\t' '$4 == "-V=full"' "${log}" | wc -l | tr -d ' ')"
  echo "example log line (tool, import path, ms, summary):"
  awk -F'\t' '$4 == "-V=full"' "${log}" | head -1 | sed 's/\t/ | /g'
  echo
  echo "answer for 'compile -V=full' through the wrapper:"
  "${stopwatch}" "${GOTOOLDIR}/compile" -V=full
  echo "answer for 'compile -V=full' without the wrapper:"
  "${GOTOOLDIR}/compile" -V=full
} | capture_text step2-vfull.txt
cat "${CAPTURES}/step2-vfull.txt"

# Warm builds in the same cache. The first keeps the output file from the
# cold build; the second deletes it first, so cmd/go must link again.
: >"${log}"
run_capture step2-warm-build.txt env STOPWATCH_LOG="${log}" "${GO}" build -toolexec="${stopwatch}" -o "${CACHE}/app" ./app
warm_kept="$(wc -l <"${log}" | tr -d ' ')"
warm_kept_probes="$(awk -F'\t' '$4 == "-V=full"' "${log}" | wc -l | tr -d ' ')"
cp "${log}" "${CACHE}/warm-kept.log"
: >"${log}"
rm -f "${CACHE}/app"
run_capture step2-warm-build.txt env STOPWATCH_LOG="${log}" "${GO}" build -toolexec="${stopwatch}" -o "${CACHE}/app" ./app
warm_removed="$(wc -l <"${log}" | tr -d ' ')"
{
  echo "second build, same GOCACHE, output file kept:    ${warm_kept} log line(s), ${warm_kept_probes} of them -V=full"
  sed 's/\t/ | /g' "${CACHE}/warm-kept.log"
  echo
  echo "second build, same GOCACHE, output file deleted: ${warm_removed} log line(s)"
  sed 's/\t/ | /g' "${log}"
} | capture_text step2-warm.txt
cat "${CAPTURES}/step2-warm.txt"

# The deliberate stdout bugs. Both run in their own fresh cache.
#
# STOPWATCH_STDOUT=1: the record goes to stdout after the tool has finished.
fresh_cache step2-stdout-after
export STOPWATCH_STDOUT=1
run_capture step2-stdout-after.txt build_with_stopwatch -a
write_exit step2-stdout-after.txt
after_first="$(grep -c "^compile${tab}" "${CACHE}/step2-stdout-after.txt.raw" || true)"
{
  echo "compile lines printed by the first build: ${after_first}"
  echo "answer for 'compile -V=full' (2 lines, the second is the stopwatch record):"
  "${stopwatch}" "${GOTOOLDIR}/compile" -V=full
} | capture_text step2-stdout-after-vfull.txt
# A second build in the same cache: the record contains the elapsed time, so the
# tool ID differs every time and nothing is reused.
run_capture step2-stdout-after-warm.txt build_with_stopwatch
after_warm="$(grep -c "^compile${tab}" "${CACHE}/step2-stdout-after-warm.txt.raw" || true)"
{
  echo "compile lines printed by the first build:  ${after_first}"
  echo "compile lines printed by a second build:   ${after_warm}"
  echo "(a plain warm build runs no compile at all)"
} | capture_text step2-stdout-after-summary.txt
cat "${CAPTURES}/step2-stdout-after-summary.txt"

# STOPWATCH_STDOUT=first: the wrapper prints before the tool answers.
fresh_cache step2-stdout-first
export STOPWATCH_STDOUT=first
run_capture step2-stdout-bug.txt build_with_stopwatch
write_exit step2-stdout-bug.txt
cat "${CAPTURES}/step2-stdout-bug.txt" "${CAPTURES}/step2-stdout-bug.txt.exit"
