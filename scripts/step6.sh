#!/usr/bin/env bash
# step6: build-cache poisoning, and the fix.
#   poison: toyhook rewrites greet while building ./app and answers -V=full
#           unchanged; a plain build of ./other in the same GOCACHE picks the
#           rewritten greet out of the cache.
#   fixed:  toyhook appends a marker to the -V=full answer, which changes every
#           cache key, so the plain build does not see the rewritten greet.
# Usage: step6.sh poison|fixed
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build_tools
cd "${REPO}"

variant="${1:-}"
case "${variant}" in
poison) mark=0 ;;
fixed) mark=1 ;;
*)
  echo "usage: step6.sh poison|fixed" >&2
  exit 2
  ;;
esac
prefix="step6-${variant}"

# The rules toyhook runs with. The marker hash is derived from them, so the
# builds and the -V=full capture below must use exactly the same ones.
toyhook_rules=(TOYHOOK_MODE=rewrite "TOYHOOK_TARGET=${MODULE}/greet" "TOYHOOK_MARK=${mark}")

# wrapped_build OUT PKG: go build with toyhook rewriting greet.
wrapped_build() {
  env "${toyhook_rules[@]}" TOYHOOK_VERBOSE=1 \
    "${GO}" build -toolexec="${TOOLBIN}/toyhook" -o "${CACHE}/$1" "$2"
}

# verdict LABEL FILE: does the program output contain the injected line?
verdict() {
  if grep -q '^→ Hello at ' "$2"; then
    echo "${1}: injected code PRESENT"
  else
    echo "${1}: injected code absent"
  fi
}

# Order 1: wrapped build of ./app first, then a plain build of ./other.
fresh_cache "${prefix}"
run_capture "${prefix}-1-build-app.txt" wrapped_build app ./app
run_capture "${prefix}-1-run-app.txt" "${CACHE}/app"
run_capture "${prefix}-1-build-other.txt" "${GO}" build -o "${CACHE}/other" ./other
run_capture "${prefix}-1-run-other.txt" "${CACHE}/other"

# Order 2 (reverse), own cache: plain ./other first, then the wrapped ./app.
fresh_cache "${prefix}-reverse"
run_capture "${prefix}-2-build-other.txt" "${GO}" build -o "${CACHE}/other" ./other
run_capture "${prefix}-2-run-other.txt" "${CACHE}/other"
run_capture "${prefix}-2-build-app.txt" wrapped_build app ./app
run_capture "${prefix}-2-run-app.txt" "${CACHE}/app"

{
  echo "order 1: wrapped ./app, then plain ./other (same GOCACHE)"
  verdict "  app  " "${CAPTURES}/${prefix}-1-run-app.txt"
  verdict "  other" "${CAPTURES}/${prefix}-1-run-other.txt"
  echo "order 2: plain ./other, then wrapped ./app (same GOCACHE)"
  verdict "  other" "${CAPTURES}/${prefix}-2-run-other.txt"
  verdict "  app  " "${CAPTURES}/${prefix}-2-run-app.txt"
  echo "greet rewritten by the wrapper in order 1: $(grep -c 'rewrote' "${CAPTURES}/${prefix}-1-build-app.txt" || true) time(s)"
  echo "greet rewritten by the wrapper in order 2: $(grep -c 'rewrote' "${CAPTURES}/${prefix}-2-build-app.txt" || true) time(s)"
} | capture_text "${prefix}-verdict.txt"

# The -V=full answers for compile: plain, and through the wrapper.
{
  echo "plain:"
  "${GOTOOLDIR}/compile" -V=full
  echo "through toyhook (TOYHOOK_MARK=${mark}):"
  env "${toyhook_rules[@]}" "${TOOLBIN}/toyhook" "${GOTOOLDIR}/compile" -V=full
  echo "link, through toyhook (TOYHOOK_MARK=${mark}):"
  env "${toyhook_rules[@]}" "${TOOLBIN}/toyhook" "${GOTOOLDIR}/link" -V=full
} | capture_text "${prefix}-vfull.txt"

cat "${CAPTURES}/${prefix}-verdict.txt" "${CAPTURES}/${prefix}-vfull.txt"
