#!/usr/bin/env bash
# S-CORE build helper: ./dev.sh help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="${SCORE_DEVCONTAINER_IMAGE:-ghcr.io/eclipse-score/devcontainer:v1.12.0}"
IMAGE="score-dev:aarch64-sim"
SIM_NET="${SCORE_SIM_NETWORK:-score-ecu-sim}"
SRC_VOL="${SCORE_SOURCE_VOLUME:-score-ref-int}"
CACHE_VOL="${SCORE_BAZEL_CACHE_VOLUME:-score-bazel-cache}"
OUT_DIR="$ROOT/out"

usage() {
  cat <<'HELP'
Usage: ./dev.sh <command>

  build-pi     build the S-CORE image for the Raspberry Pi 4B, out/score-image-rpi4b.wic: the EB corbos
               image of the toolkit with the platform, the showcases and the diagnostics service
               deployed in it, like the QEMU image. Flash it to an SD card.
  build-qemu   build the QEMU image (EB corbos Linux for Safety Applications, aarch64)
  run-qemu     boot the QEMU image; log in as root over ssh, without a password

Builds run in the official devcontainer as linux/amd64, because the hermetic toolchains only run
on x86_64 Linux. reference_integration is built from a clone in the Docker volume score-ref-int,
at the commit that its submodule points to: the repository cannot be checked out completely on a
case-insensitive file system.

Network of run-qemu
  The VM is a host on the Docker network score-ecu-sim (172.42.0.0/16, created if it does not exist;
  ./ecu-sim.sh up starts the ECU simulator on it). It gets an address of its own there, 172.42.1.100,
  when it has booted, and finds the simulated ECUs by DoIP broadcast. Nothing of the VM is published on the
  host: reach it by that address, for example
    ssh root@172.42.1.100
    curl http://172.42.1.100:7690/sovd/v1/components   (gateway)
  Where the host has no route to Docker networks (Docker Desktop), run the client on the network:
    docker run --rm --network score-ecu-sim curlimages/curl -s http://172.42.1.100:7690/sovd/v1/components
HELP
  exit "${1:-0}"
}

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
    # The image is built like the QEMU image. The packages are also left in out/ for ecu-sim.sh test.
    docker_run -v "$OUT_DIR":/out -- bash -c '
      set -e
      bazel build --config=linux-aarch64 //deploy:platform_tar //showcases:showcases_pkg_tar
      cp -L bazel-bin/deploy/platform_tar.tar /out/score-platform-linux-aarch64.tar
      cp -L bazel-bin/showcases/showcases_pkg_tar.tar /out/score-showcases-linux-aarch64.tar
      bazel build --config=eb-aarch64 //images/ebclfsa_rpi4b:image
      cp -L bazel-bin/images/ebclfsa_rpi4b/build/ebcl-rpi4b-deployed/fastdev-trixie-ebclfsa-rpi4b.wic /out/score-image-rpi4b.wic'
    echo "Raspberry Pi 4B image: $OUT_DIR/score-image-rpi4b.wic"
    ;;
  build-qemu)
    sync_source
    docker_run -- bazel build --config=eb-aarch64 //images/ebclfsa_aarch64:image
    ;;
  run-qemu)
    sync_source
    docker network inspect "$SIM_NET" >/dev/null 2>&1 \
      || docker network create --subnet 172.42.0.0/16 "$SIM_NET" >/dev/null
    # The VM joins the network as a host, see qemu-sim-net.sh. Nothing is published on the host.
    docker_run --cap-add NET_ADMIN --device /dev/net/tun --network "$SIM_NET" \
      -v "$ROOT/qemu-sim-net.sh":/qemu-sim-net.sh:ro -- bash /qemu-sim-net.sh
    ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
