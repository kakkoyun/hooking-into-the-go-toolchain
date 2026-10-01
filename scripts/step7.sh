#!/usr/bin/env bash
# step7: otelc v1.1.0 builds ./hello with compile-time instrumentation.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -x "${OTELC}" ]] || {
  echo "missing ${OTELC}: run 'make otelc-install'" >&2
  exit 1
}
for tool in jq curl python3; do
  command -v "${tool}" >/dev/null || {
    echo "missing tool: ${tool}" >&2
    exit 1
  }
done

cd "${REPO}/hello"
fresh_cache step7
readonly PORT=18080
app_pid=""

# alive PID: true while PID runs. A zombie that has not been waited for yet
# counts as gone.
alive() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  [[ -n "${state}" && "${state}" != Z* ]]
}

# wait_gone PID TENTHS: wait up to TENTHS tenths of a second for PID to exit.
wait_gone() {
  local i
  for ((i = 0; i < $2; i++)); do
    alive "$1" || return 0
    sleep 0.1
  done
  ! alive "$1"
}

# stop_app: stop the background server without ever hanging. An otelc-built
# binary flushes its telemetry on the first SIGTERM and leaves the exit to the
# application (pkg/runtime/setup.go in otelc v1.1.0), so: TERM, wait up to
# 6 seconds, TERM again, wait up to 3 seconds, KILL.
stop_app() {
  [[ -n "${app_pid}" ]] || return 0
  kill -TERM "${app_pid}" 2>/dev/null || true
  if ! wait_gone "${app_pid}" 60; then
    echo "stop_app: still running after 6s, sending a second TERM" >&2
    kill -TERM "${app_pid}" 2>/dev/null || true
  fi
  if ! wait_gone "${app_pid}" 30; then
    echo "stop_app: still running after the second TERM, sending KILL" >&2
    kill -KILL "${app_pid}" 2>/dev/null || true
  fi
  wait "${app_pid}" 2>/dev/null || true
  app_pid=""
}
trap stop_app EXIT

# serve BIN OUT ERR: start BIN in the background with console span export.
serve() {
  # Fail early if something else listens. SO_REUSEADDR, like Go's listener,
  # ignores connections left in TIME_WAIT by the previous server.
  python3 -c "import socket; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('localhost', ${PORT})); s.close()"
  OTEL_SERVICE_NAME=hello OTEL_TRACES_EXPORTER=console \
    OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
    "$1" >"$2" 2>"$3" &
  app_pid=$!
  sleep 2
}

# go_files_hash: go.mod and go.sum state, "absent" if there is no file.
go_files_hash() {
  for f in go.mod go.sum; do
    if [[ -f "${f}" ]]; then shasum -a 256 "${f}"; else echo "absent  ${f}"; fi
  done
}

go_files_hash >"${CACHE}/gomod-before.txt"

# 1. Default rules: HTTP server and client instrumentation.
run_capture step7-build.txt "${OTELC}" go build -work -o "${CACHE}/hello" .
write_exit step7-build.txt
grep -v '^go: downloading ' "${CACHE}/step7-build.txt.raw" | capture_text step7-build.trimmed.txt
work="$(work_dir "${CACHE}/step7-build.txt.raw")"

# Rules otelc matched, and the matched.json it wrote for the toolexec phase.
# Rule objects are the ones with a target; other name fields (e.g. the struct
# fields add_gls_field adds) are not rules.
jq -r '.. | objects | select(has("target")) | .name' .otelc-build/matched.json | sort -u | capture_text step7-matched.txt
norm_copy .otelc-build/matched.json "${CAPTURES}/step7-matched.json"

# The rewritten serverHandler.ServeHTTP and the linkname declarations otelc
# generated for its hooks, both found in the preserved $WORK directory. The
# pattern names the hooks: net/http has a linkname of its own for ServeHTTP
# (badServeHTTP, in server.go) which is not otelc's.
target="$(grep -rl --include='*.go' 'OtelBeforeTrampoline_ServeHTTP' "${work}" | head -n 1)"
grep -A12 'func (sh serverHandler) ServeHTTP(' "${target}" | capture_text step7-serverhandler.txt
grep -rhE -A1 --include='*.go' 'go:linkname (Before|After)ServeHTTP ' "${work}" | capture_text step7-linkname.txt

# otelc answers the -V=full probe the way cmd/go asks for it.
{
  echo "plain:"
  "${GOTOOLDIR}/compile" -V=full
  echo "through otelc toolexec:"
  "${OTELC}" toolexec "${GOTOOLDIR}/compile" -V=full
} | capture_text step7-vfull.txt

# Run it: one request to /hello makes three spans.
serve "${CACHE}/hello" "${CACHE}/spans.json" "${CACHE}/stderr.txt"
curl -sS --max-time 10 -o "${CACHE}/curl.txt" "http://localhost:${PORT}/hello"
sleep 6 # the console exporter writes in batches
stop_app
norm_copy "${CACHE}/curl.txt" "${CAPTURES}/step7-curl.txt"
norm_copy "${CACHE}/spans.json" "${CAPTURES}/step7-spans.txt"
scrub_identity "${CAPTURES}/step7-spans.txt"
norm_copy "${CACHE}/stderr.txt" "${CAPTURES}/step7-stderr.txt"
jq -s -r '.[] | select(has("SpanContext")) |
  [.Name, (.SpanKind | tostring), .SpanContext.TraceID, (.SpanContext.SpanID), (.Parent.SpanID // "")] | @tsv' \
  "${CACHE}/spans.json" | capture_text step7-spans.tsv
{
  echo "spans:            $(jq -s '[.[] | select(has("SpanContext"))] | length' "${CACHE}/spans.json")"
  echo "distinct traces:  $(jq -s '[.[] | select(has("SpanContext")) | .SpanContext.TraceID] | unique | length' "${CACHE}/spans.json")"
} | capture_text step7-span-count.txt

# go.mod and go.sum must be byte-identical after the build.
go_files_hash >"${CACHE}/gomod-after.txt"
{
  echo "before the build:"
  cat "${CACHE}/gomod-before.txt"
  echo "after the build:"
  cat "${CACHE}/gomod-after.txt"
  if cmp -s "${CACHE}/gomod-before.txt" "${CACHE}/gomod-after.txt"; then
    echo "result: go.mod and go.sum are byte-identical"
  else
    echo "result: go.mod or go.sum CHANGED"
  fi
} | capture_text step7-gomod-check.txt

# 2. Directive rule: expand //demo:log in package main (log.otelc.yml).
run_capture step7-log-build.txt "${OTELC}" --rules log.otelc.yml go build -o "${CACHE}/hello-log" .
write_exit step7-log-build.txt
grep -v '^go: downloading ' "${CACHE}/step7-log-build.txt.raw" | capture_text step7-log-build.trimmed.txt
serve "${CACHE}/hello-log" "${CACHE}/log-stdout.txt" "${CACHE}/log-stderr.txt"
curl -sS --max-time 10 -o "${CACHE}/log-curl.txt" "http://localhost:${PORT}/hello"
sleep 1
stop_app
norm_copy "${CACHE}/log-curl.txt" "${CAPTURES}/step7-log-curl.txt"
norm_copy "${CACHE}/log-stderr.txt" "${CAPTURES}/step7-log-run.txt"
go_files_hash >"${CACHE}/gomod-after-log.txt"
if cmp -s "${CACHE}/gomod-before.txt" "${CACHE}/gomod-after-log.txt"; then
  echo "result: go.mod and go.sum are byte-identical after the directive build too" | capture_text step7-log-gomod-check.txt
else
  echo "result: go.mod or go.sum CHANGED by the directive build" | capture_text step7-log-gomod-check.txt
fi

# 3. Remove .otelc-build again.
run_capture step7-cleanup.txt "${OTELC}" cleanup

cat "${CAPTURES}/step7-matched.txt" "${CAPTURES}/step7-span-count.txt" \
  "${CAPTURES}/step7-gomod-check.txt" "${CAPTURES}/step7-vfull.txt" \
  "${CAPTURES}/step7-log-run.txt" "${CAPTURES}/step7-log-gomod-check.txt"
