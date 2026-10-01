#!/usr/bin/env bash
# step5: //go:linkname from the standard library's os.ReadFile to hooks.OnReadFile.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build_tools
cd "${REPO}"
fresh_cache step5

# -a: os must be recompiled, otherwise the wrapper never sees it.
run_capture step5-build.txt \
  env TOYHOOK_MODE=linkname TOYHOOK_VERBOSE=1 \
  "${GO}" build -a -tags toyhook -work -toolexec="${TOOLBIN}/toyhook" -o "${CACHE}/app" ./app
write_exit step5-build.txt
work="$(work_dir "${CACHE}/step5-build.txt.raw")"
raw="${CACHE}/step5-build.txt.raw"

# The compile arguments for package os before and after the wrapper edited
# them (verbose output), then one argument per line so they can be diffed.
{
  grep 'compile os before:' "${raw}"
  grep 'compile os after:' "${raw}"
} | capture_text step5-compile-args.txt
for which in before after; do
  grep "compile os ${which}:" "${raw}" | sed "s/^.*compile os ${which}: //" | tr ' ' '\n' >"${CACHE}/args-${which}.txt"
done
{ diff -u --label before --label after "${CACHE}/args-before.txt" "${CACHE}/args-after.txt" || true; } |
  capture_text step5-compile-args.diff

# The injected file, and the rewritten os.ReadFile.
# shellcheck disable=SC2016  # $WORK is literal text in the log
dir="$(grep -o '\$WORK/b[0-9]*/toyhook_linkname.go' "${raw}" | head -1)"
dir="${work}/${dir#\$WORK/}"
capture_text step5-toyhook_linkname.go.txt <"${dir}"
rewritten="$(dirname "${dir}")/file.go"
{ diff -u --label os/file.go --label "rewritten os/file.go" "${GOROOT_DIR}/src/os/file.go" "${rewritten}" || true; } |
  capture_text step5-os-file.diff

# Was -complete passed to the os compile, and did the wrapper strip it?
{
  if grep 'compile os before:' "${raw}" | grep -q -e ' -complete '; then
    echo "cmd/go passed -complete to the os compile: yes"
  else
    echo "cmd/go passed -complete to the os compile: no"
  fi
  grep 'toyhook: \(stripped -complete\|-complete not present\)' "${raw}" | sed 's/^/wrapper: /'
  echo
  echo "cmd/go's reason (cmd/go/internal/work/gc.go, $("${GO}" env GOVERSION)):"
  grep -n -B2 -A14 'extFiles := len' "${GOROOT_DIR}/src/cmd/go/internal/work/gc.go" |
    grep -v '^--$'
} | capture_text step5-complete.txt

run_capture step5-run.txt "${CACHE}/app"

# Without the blank import nothing links hooks.OnReadFile, so the reference
# that was compiled into os cannot be resolved. Same cache, -a, no toyhook tag.
run_capture step5-nohook.txt \
  env TOYHOOK_MODE=linkname TOYHOOK_VERBOSE=1 \
  "${GO}" build -a -toolexec="${TOOLBIN}/toyhook" -o "${CACHE}/app-nohook" ./app
write_exit step5-nohook.txt

cat "${CAPTURES}/step5-complete.txt" "${CAPTURES}/step5-toyhook_linkname.go.txt" "${CAPTURES}/step5-run.txt"
grep -v 'toyhook: compile' "${CAPTURES}/step5-nohook.txt" | cut -c1-250
cat "${CAPTURES}/step5-nohook.txt.exit"
