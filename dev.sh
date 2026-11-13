#!/usr/bin/env bash
# Run commands inside the S-CORE devcontainer (linux/amd64) + QEMU helpers.
#
# The hermetic S-CORE toolchains (GCC 12.2, Ferrocene) are x86_64-Linux hosted, so on an
# Apple Silicon Mac the container must run as linux/amd64 (emulated). Targets are
# cross-compiled for Raspberry Pi (aarch64) from there.
#
# Usage:
#   ./dev.sh                       interactive shell in inc_diagnostics/
#   ./dev.sh <repo> <cmd...>       run a command in <repo> (inc_diagnostics | reference_integration | score)
#   ./dev.sh pi [bazel args]       cross-build inc_diagnostics for Raspberry Pi (aarch64)
#   ./dev.sh qemu <bazel-bin path> [args]
#                                  run an aarch64 binary from the pi build under qemu-user
#                                  e.g. ./dev.sh qemu score/mw/diag/future_test
#   ./dev.sh qemu-test             run every aarch64 unit test of inc_diagnostics under qemu-user
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="${SCORE_DEVCONTAINER_IMAGE:-ghcr.io/eclipse-score/devcontainer:v1.12.0}"
IMAGE="score-dev:local"
CACHE_VOL="${SCORE_BAZEL_CACHE_VOLUME:-score-bazel-cache}"
CFG=score_diag_aarch64_linux

ensure_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 && return
  docker build --platform linux/amd64 --build-arg BASE="$BASE_IMAGE" -t "$IMAGE" "$ROOT"
}

run() {
  local workdir="$1"; shift
  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-it)
  ensure_image
  docker run --rm "${tty[@]}" --platform linux/amd64 \
    -v "$ROOT":/workspaces/score \
    -v "$CACHE_VOL":/root/.cache \
    -w "/workspaces/score/$workdir" \
    -e HOME=/root \
    "$IMAGE" "$@"
}

# Shell snippet: resolves the aarch64 sysroot matching the Bazel GCC toolchain's glibc.
SYSROOT_SNIPPET='SYS=$(echo /root/.cache/bazel/_bazel_root/*/external/score_bazel_cpp_toolchains++gcc+score_gcc_aarch64_toolchain_pkg/aarch64-unknown-linux-gnu/sysroot)'

case "${1:-}" in
  "")  run inc_diagnostics bash ;;
  pi)  run inc_diagnostics bazel build --config=$CFG //examples/... //score/... "${@:2}" ;;
  qemu)
       [[ $# -ge 2 ]] || { echo "usage: $0 qemu <path under bazel-bin> [args]" >&2; exit 2; }
       bin="$2"; shift 2
       run inc_diagnostics bash -c "$SYSROOT_SNIPPET; exec qemu-aarch64 -L \"\$SYS\" \"bazel-bin/$bin\" \"\$@\"" _ "$@" ;;
  qemu-test)
       run inc_diagnostics bash -c "$SYSROOT_SNIPPET"'
         rc=0
         for t in $(bazel query "kind(cc_test, //score/...)" 2>/dev/null | sed "s#^//##; s#:#/#"); do
           echo "== $t"; qemu-aarch64 -L "$SYS" "bazel-bin/$t" 2>&1 | tail -3 || rc=1
         done; exit $rc' ;;
  *)   repo="$1"; shift; run "$repo" "${@:-bash}" ;;
esac
