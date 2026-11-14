#!/usr/bin/env bash
# S-CORE build helper. Builds run in the official devcontainer (linux/amd64) because the
# hermetic toolchains are x86_64-Linux only.
#
#   ./dev.sh build-pi      build the Raspberry Pi packages (platform + showcases, incl. diagnostics)
#   ./dev.sh build-qemu    build the QEMU image (EB corbos Linux for Safety Applications, aarch64)
#   ./dev.sh run-qemu      boot the QEMU image (SSH on 127.0.0.1:2222, login root/linux)
#
# reference_integration is built from a clone inside the Docker volume "score-ref-int",
# because the repository cannot be checked out completely on a case-insensitive macOS
# volume. The clone follows the commit that the reference_integration submodule points to.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="${SCORE_DEVCONTAINER_IMAGE:-ghcr.io/eclipse-score/devcontainer:v1.12.0}"
IMAGE="score-dev:aarch64-headers"
SRC_VOL="${SCORE_SOURCE_VOLUME:-score-ref-int}"
CACHE_VOL="${SCORE_BAZEL_CACHE_VOLUME:-score-bazel-cache}"
OUT_DIR="$ROOT/out"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# The devcontainer plus the aarch64 glibc headers that the iceoryx2 bindgen step needs
# when cross-compiling for Raspberry Pi (see the reference_integration README).
ensure_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 && return
  docker build -q --platform linux/amd64 -t "$IMAGE" - <<EOF
FROM --platform=linux/amd64 $BASE_IMAGE
RUN apt-get update -qq \\
 && apt-get install -y -qq --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross \\
 && rm -rf /var/lib/apt/lists/*
EOF
}

docker_run() {  # docker_run <extra docker args...> -- <command...>
  local extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
  shift
  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-it)
  ensure_image
  docker run --rm "${tty[@]}" --platform linux/amd64 \
    -v "$SRC_VOL":/work -v "$CACHE_VOL":/root/.cache \
    -e HOME=/root -w /work/reference_integration \
    "${extra[@]}" "$IMAGE" "$@"
}

# Make the clone in the volume match the commit the submodule points to.
sync_source() {
  local sha url
  sha="$(GIT_MASTER=1 git -C "$ROOT" ls-files -s reference_integration | awk '{print $2}')"
  url="$(GIT_MASTER=1 git config -f "$ROOT/.gitmodules" submodule.reference_integration.url)"
  [[ -n "$sha" && -n "$url" ]] || { echo "reference_integration submodule not found" >&2; exit 1; }
  docker_run -w /work -- bash -c '
    set -e
    export GIT_MASTER=1
    if [ ! -d reference_integration/.git ]; then
      git init -q reference_integration
      git -C reference_integration remote add origin "'"$url"'"
    fi
    cd reference_integration
    if [ "$(git rev-parse -q --verify HEAD || true)" != "'"$sha"'" ]; then
      git fetch -q --depth 1 origin "'"$sha"'"
      git checkout -q --detach "'"$sha"'"
    fi
    echo "reference_integration at $(git rev-parse --short HEAD)"'
}

case "${1:-}" in
  build-pi)
    sync_source
    mkdir -p "$OUT_DIR"
    docker_run -v "$OUT_DIR":/out -- bash -c '
      set -e
      bazel build --config=linux-aarch64 //deploy:platform_tar //showcases:showcases_pkg_tar
      cp -L bazel-bin/deploy/platform_tar.tar /out/score-platform-linux-aarch64.tar
      cp -L bazel-bin/showcases/showcases_pkg_tar.tar /out/score-showcases-linux-aarch64.tar'
    echo "Raspberry Pi packages: $OUT_DIR"
    ;;
  build-qemu)
    sync_source
    docker_run -- bazel build --config=eb-aarch64 //images/ebclfsa_aarch64:image
    ;;
  run-qemu)
    sync_source
    # Ports are published on the loopback interface only: the image allows passwordless root SSH.
    docker_run -p 127.0.0.1:2222:2222 -p 127.0.0.1:3333:3333 -- \
      bazel run --config=eb-aarch64 //images/ebclfsa_aarch64:run
    ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
