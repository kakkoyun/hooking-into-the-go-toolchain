#!/usr/bin/env bash
# step3: cmd/toyhook rewrites //demo:log functions of the main package.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build_tools
cd "${REPO}"
fresh_cache step3

run_capture step3-build.txt \
  env TOYHOOK_MODE=rewrite TOYHOOK_VERBOSE=1 \
  "${GO}" build -work -toolexec="${TOOLBIN}/toyhook" -o "${CACHE}/app" ./app
write_exit step3-build.txt

# toyhook says where it wrote the rewritten file: $WORK/bNNN/main.go.
work="$(work_dir "${CACHE}/step3-build.txt.raw")"
# shellcheck disable=SC2016  # $WORK is literal text in the log
rel="$(grep -o '\$WORK/b[0-9]*/main.go' "${CACHE}/step3-build.txt.raw" | head -1)"
rewritten="${work}/${rel#\$WORK/}"
capture_text step3-rewritten-main.go.txt <"${rewritten}"
{ diff -u --label app/main.go --label "${rel}" app/main.go "${rewritten}" || true; } |
  capture_text step3-diff.txt

run_capture step3-run.txt "${CACHE}/app"
cat "${CAPTURES}/step3-build.txt" "${CAPTURES}/step3-diff.txt" "${CAPTURES}/step3-run.txt" | cut -c1-200
