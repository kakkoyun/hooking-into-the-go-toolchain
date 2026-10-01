#!/usr/bin/env bash
# stats: the cost of instrumentation on one machine, one run each.
#   plain:  go build -a with the stopwatch wrapper (and without any wrapper)
#   otelc:  otelc --stats go build -a
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build_tools
[[ -x "${OTELC}" ]] || {
  echo "missing ${OTELC}: run 'make otelc-install'" >&2
  exit 1
}
cd "${REPO}/hello"
go_mod_sum="$(shasum -a 256 go.mod)"

# Plain build, no wrapper: the baseline.
fresh_cache stats-baseline
run_capture stats-baseline-time.txt /usr/bin/time -p "${GO}" build -a -o "${CACHE}/hello" .

# Plain build through the stopwatch.
fresh_cache stats-plain
log="${CACHE}/stopwatch.log"
: >"${log}"
run_capture stats-plain-time.txt /usr/bin/time -p \
  env STOPWATCH_LOG="${log}" "${GO}" build -a -toolexec="${TOOLBIN}/stopwatch" -o "${CACHE}/hello" .
norm_copy "${log}" "${CAPTURES}/stats-plain-log.tsv"
awk -F'\t' '
  $4 == "-V=full" { probes++; next }
  { calls[$1]++; ms[$1] += $3; total += $3; n++ }
  END {
    printf "%-10s %6s %10s\n", "tool", "calls", "sum ms"
    for (t in calls) printf "%-10s %6d %10d\n", t, calls[t], ms[t]
    printf "%-10s %6d %10d\n", "total", n, total
    printf "-V=full probes: %d\n", probes
  }' "${log}" | {
  IFS= read -r header
  echo "${header}"
  sort
} | capture_text stats-plain-stopwatch.txt

# otelc with its own per-toolexec stats. otelc v1.1.0 writes them to
# .otelc-build/debug.log, not to the terminal, and appends to that file, so
# start from a clean .otelc-build.
"${OTELC}" cleanup >/dev/null 2>&1 || true
fresh_cache stats-otelc
run_capture stats-otelc.txt /usr/bin/time -p "${OTELC}" --stats go build -a -o "${CACHE}/hello" .
write_exit stats-otelc.txt
grep -v '^go: downloading ' "${CACHE}/stats-otelc.txt.raw" | capture_text stats-otelc.trimmed.txt
grep -e 'msg="toolexec stats"' -e 'msg="setup stats"' -e 'msg="build stats"' .otelc-build/debug.log |
  capture_text stats-otelc-debug-log.txt
# Sum the durations per tool. Go prints them as 1.5s, 12.3ms, 45µs or 7ns.
awk '
  function ms(d,   v) {
    v = d + 0
    if (d ~ /µs$/) return v / 1000
    if (d ~ /ms$/) return v
    if (d ~ /ns$/) return v / 1000000
    if (d ~ /s$/) return v * 1000
    return v
  }
  /msg="setup stats"/ { match($0, /duration=[^ ]+/); setup = substr($0, RSTART + 9, RLENGTH - 9) }
  /msg="build stats"/ { match($0, /duration=[^ ]+/); build = substr($0, RSTART + 9, RLENGTH - 9) }
  /msg="toolexec stats"/ {
    match($0, /tool=[^ ]+/); tool = substr($0, RSTART + 5, RLENGTH - 5)
    match($0, /duration=[^ ]+/); d = substr($0, RSTART + 9, RLENGTH - 9)
    calls[tool]++; sum[tool] += ms(d); n++; total += ms(d)
  }
  END {
    printf "H %-10s %6s %10s\n", "tool", "calls", "sum ms"
    for (t in calls) printf "R %-10s %6d %10d\n", t, calls[t], sum[t]
    printf "R %-10s %6d %10d\n", "total", n, total
    print "S setup phase (otelc): " setup
    print "S build phase (go build with toolexec): " build
  }' .otelc-build/debug.log | sort | sed 's/^. //' | capture_text stats-otelc-totals.txt
"${OTELC}" cleanup >/dev/null 2>&1 || true

{
  echo "one run, one machine ($(uname -sm)), $("${GO}" version | cut -d' ' -f3)"
  echo
  echo "plain, no wrapper:    $(grep '^real' "${CAPTURES}/stats-baseline-time.txt") s"
  echo "plain, stopwatch:     $(grep '^real' "${CAPTURES}/stats-plain-time.txt") s"
  echo "otelc --stats:        $(grep '^real' "${CAPTURES}/stats-otelc.txt") s"
} | capture_text stats-summary.txt

if [[ "$(shasum -a 256 go.mod)" != "${go_mod_sum}" ]]; then
  echo "hello/go.mod changed" >&2
  exit 1
fi
cat "${CAPTURES}/stats-summary.txt" "${CAPTURES}/stats-plain-stopwatch.txt"
cat "${CAPTURES}/stats-otelc-totals.txt"
