#!/usr/bin/env bash
# step4-broken: the injected code uses log/slog, which the app does not import.
# step4:        toyhook patches the compile and link importcfg to fix that.
# Usage: step4.sh broken|fixed
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build_tools
cd "${REPO}"

case "${1:-}" in
broken)
  fresh_cache step4-broken
  run_capture step4-broken.txt \
    env TOYHOOK_MODE=slog TOYHOOK_VERBOSE=1 \
    "${GO}" build -work -toolexec="${TOOLBIN}/toyhook" -o "${CACHE}/app" ./app
  write_exit step4-broken.txt
  cat "${CAPTURES}/step4-broken.txt" "${CAPTURES}/step4-broken.txt.exit"
  ;;
fixed)
  fresh_cache step4
  run_capture step4-build.txt \
    env TOYHOOK_MODE=slog TOYHOOK_IMPORTCFG=patch TOYHOOK_VERBOSE=1 \
    TOYHOOK_STATE="${CACHE}/state" \
    "${GO}" build -work -toolexec="${TOOLBIN}/toyhook" -o "${CACHE}/app" ./app
  write_exit step4-build.txt
  work="$(work_dir "${CACHE}/step4-build.txt.raw")"

  # toyhook leaves the original importcfg alone and writes <name>.toyhook.
  compile_cfg="$(find "${work}" -name importcfg.toyhook | head -1)"
  link_cfg="$(find "${work}" -name importcfg.link.toyhook | head -1)"
  for kind in compile link; do
    if [[ "${kind}" == compile ]]; then after="${compile_cfg}"; else after="${link_cfg}"; fi
    before="${after%.toyhook}"
    capture_text "step4-${kind}-importcfg-before.txt" <"${before}"
    capture_text "step4-${kind}-importcfg-after.txt" <"${after}"
    {
      echo "lines before: $(wc -l <"${before}" | tr -d ' ')"
      echo "lines after:  $(wc -l <"${after}" | tr -d ' ')"
      echo "added lines that mention log/slog:"
      diff "${before}" "${after}" | grep '^>' | grep -e ' log/slog=' | sed 's/^> //' || true
    } | capture_text "step4-${kind}-importcfg-summary.txt"
  done

  run_capture step4-run.txt "${CACHE}/app"
  cat "${CAPTURES}/step4-compile-importcfg-summary.txt" \
    "${CAPTURES}/step4-link-importcfg-summary.txt" "${CAPTURES}/step4-run.txt" | cut -c1-220
  ;;
*)
  echo "usage: step4.sh broken|fixed" >&2
  exit 2
  ;;
esac
