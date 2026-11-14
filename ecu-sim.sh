#!/usr/bin/env bash
# CDA ECU simulator: ./ecu-sim.sh help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/out"
SRC="$OUT/cda-src"
NET="score-ecu-sim"
SIM="score-ecu-sim"
CDA="score-cda"
GATEWAY="score-gateway"
SIM_IMAGE="score-cda-ecu-sim"
PLATFORM_TAR="$OUT/score-platform-linux-aarch64.tar"
VM_IP=172.42.1.100  # address of the QEMU VM of ./dev.sh run-qemu on the network of the simulator
# The gateway has no /authorize yet (it answers 404), so no client can get a token. The CDA runs in its
# development mode and accepts any well-formed JWT with sub and exp; this is one. Replace it by the
# token of the gateway as soon as the gateway issues tokens.
DEV_TOKEN="eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0IiwiZXhwIjoyMDAwMDAwMDAwfQ.Q0IP5df7FxVEvVDF2v6soF8uh-j_qA-D_tgYTb3ur3g"
CDA_URL="https://github.com/eclipse-opensovd/classic-diagnostic-adapter.git"

usage() {
  cat <<'HELP'
Usage: ./ecu-sim.sh <command>

  up     build and start the ECU simulator of the classic diagnostic adapter (CDA), control API on
         127.0.0.1:8181, on the Docker network score-ecu-sim (172.42.0.0/16)
  test   run the gateway and the CDA of the last ./dev.sh build-pi in containers on that network and
         read the VIN of the ECU flxc1000 through the gateway (127.0.0.1:7690). The CDA is only
         reachable through the gateway. This does not use the QEMU image.
  test-vm
         with the VM of ./dev.sh run-qemu running on the same network: start the CDA and the gateway
         of the image in it and read the same VIN through the gateway of the VM (172.42.1.100:7690),
         from a container on the network. The CDA must not be reachable directly.
  down   stop and remove everything this script started

The simulator, its ECU databases and the settings that its ECUs need come from the CDA commit that
inc_diagnostics pins. The CDA finds the simulated ECUs by DoIP broadcast, which needs one layer-2
network. The gateway has no /authorize yet, so the tests send a fixed development token, which the CDA
accepts in its development mode.
HELP
  exit "${1:-0}"
}

# The CDA commit that inc_diagnostics uses (git_override in its MODULE.bazel).
cda_commit() {
  awk '/module_name = "classic-diagnostic-adapter"/ {found=1}
       found && /commit = / {gsub(/[",]/, "", $3); print $3; exit}' "$ROOT/inc_diagnostics/MODULE.bazel"
}

fetch_source() {
  local sha
  sha="$(cda_commit)"
  [[ -n "$sha" ]] || { echo "no classic-diagnostic-adapter commit in inc_diagnostics/MODULE.bazel" >&2; exit 1; }
  if [[ ! -d "$SRC/.git" ]]; then
    mkdir -p "$SRC"
    GIT_MASTER=1 git -C "$SRC" init -q
    GIT_MASTER=1 git -C "$SRC" remote add origin "$CDA_URL"
  fi
  if [[ "$(GIT_MASTER=1 git -C "$SRC" rev-parse -q --verify HEAD || true)" != "$sha" ]]; then
    GIT_MASTER=1 git -C "$SRC" fetch -q --depth 1 origin "$sha"
    GIT_MASTER=1 git -C "$SRC" checkout -q --detach "$sha"
  fi
  echo "classic-diagnostic-adapter at ${sha:0:12}"
}

wait_for() {  # wait_for <seconds> <description> <command...>
  local limit="$1" what="$2"
  shift 2
  for ((i = 0; i < limit; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "timed out waiting for $what" >&2
  return 1
}

sim_up() {
  fetch_source
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet 172.42.0.0/16 "$NET" >/dev/null
  docker build -q -t "$SIM_IMAGE" -f "$SRC/testcontainer/ecu-sim/docker/Dockerfile" "$SRC/testcontainer/ecu-sim" >/dev/null
  docker rm -f "$SIM" >/dev/null 2>&1 || true
  # The simulator adds one IP address per simulated ECU to eth0, hence NET_ADMIN.
  # The control API is published on the loopback interface only.
  docker run -d --name "$SIM" --network "$NET" --cap-add NET_ADMIN \
    -e USE_MULTIPLE_IPS=true -e SIM_NETWORK_INTERFACE=eth0 \
    -p 127.0.0.1:8181:8181 "$SIM_IMAGE" >/dev/null
  wait_for 90 "the ECU simulator" curl -sf http://127.0.0.1:8181/
  echo "ECU simulator running, control API on http://127.0.0.1:8181 (docker network $NET)"
}

cda_test() {
  docker inspect -f '{{.State.Running}}' "$SIM" 2>/dev/null | grep -q true || { echo "run ./ecu-sim.sh up first" >&2; exit 1; }
  [[ -f "$PLATFORM_TAR" ]] || { echo "$PLATFORM_TAR not found, run ./dev.sh build-pi first" >&2; exit 1; }

  # The CDA exactly as the platform package ships it, plus its databases.
  local work="$OUT/cda-run"
  rm -rf "$work"
  mkdir -p "$work/databases"
  tar -xf "$PLATFORM_TAR" -C "$work" '*usr/bin/diagnostics/opensovd-cda' '*usr/bin/diagnostics/opensovd-gateway'
  local name bin
  for name in opensovd-cda opensovd-gateway; do
    bin="$(find "$work" -name "$name" -type f | head -1)"
    [[ -n "$bin" ]] || { echo "$name is not in $PLATFORM_TAR" >&2; exit 1; }
    [[ "$(od -An -tx1 -j18 -N2 "$bin" | tr -d ' ')" == "b700" ]] || { echo "$bin is not an aarch64 binary" >&2; exit 1; }
    cp "$bin" "$work/$name"
  done
  cp "$SRC"/testcontainer/odx/*.mdd "$work/databases/"
  # The paths and the address of this run, and the settings of the ECUs of the simulator that its ECUs need.
  mkdir -p "$work/flash"
  {
    cat <<'TOML'
flash_files_path = "/app/flash"

[database]
dir = "/app/databases"
exit_no_database_loaded = true

[server]
address = "0.0.0.0"
port = 20002

TOML
    cat "$ROOT/inc_diagnostics/score/opensovd-cda/cda-ecu-sim.toml"
  } > "$work/opensovd-cda.toml"

  docker rm -f "$CDA" >/dev/null 2>&1 || true
  # A linux/arm64 container runs the aarch64 binary natively on an arm64 host. The tester address is
  # the container's own address, as in the CDA's own test image.
  docker run -d --name "$CDA" --platform linux/arm64 --network "$NET" \
    -v "$work":/app:ro -e CDA_CONFIG_FILE=/app/opensovd-cda.toml debian:bookworm-slim \
    sh -c 'exec /app/opensovd-cda --tester-address "$(hostname -i | cut -d" " -f1)"' >/dev/null
  # The CDA is not published on the host: it is reached only through the gateway, which issues the tokens.

  # The gateway in front of the CDA: with SCORE_UPSTREAM_URL it forwards what it does not hold to the CDA.
  docker rm -f "$GATEWAY" >/dev/null 2>&1 || true
  docker run -d --name "$GATEWAY" --platform linux/arm64 --network "$NET" -p 127.0.0.1:7690:7690 \
    -e SCORE_GATEWAY_ADDRESS=0.0.0.0:7690 -e "SCORE_UPSTREAM_URL=http://$CDA:20002/vehicle/v15" \
    -v "$work":/app:ro debian:bookworm-slim /app/opensovd-gateway >/dev/null
  local base=http://127.0.0.1:7690/sovd/v1 token components vin
  wait_for 60 "the gateway and the CDA behind it" bash -c "curl -sf '$base/apps' | grep -q sovd2uds" || { docker logs --tail 40 "$GATEWAY"; exit 1; }
  token="$DEV_TOKEN"
  # The ECUs are found by DoIP broadcast, so give the CDA a moment.
  wait_for 60 "the simulated ECUs" bash -c "curl -sf '$base/components' -H 'Authorization: Bearer $token' | grep -q flxc1000"
  components="$(curl -sf "$base/components" -H "Authorization: Bearer $token")"
  echo "components (through the gateway): $components"
  # A component is listed before the CDA has detected the variant of its ECU, so retry the read.
  vin=""
  for _ in $(seq 1 30); do
    vin="$(curl -sf "$base/components/flxc1000/data/VINDataIdentifier" -H "Authorization: Bearer $token")" && break
    sleep 1
  done
  echo "VIN:        $vin"
  grep -q SCEDT26T8BD005261 <<<"$vin" || { echo "unexpected VIN" >&2; docker logs --tail 40 "$CDA"; exit 1; }
  echo "OK: the gateway forwarded to the CDA, which read the VIN of a simulated ECU"
}

# The OpenSOVD stack of the image: starts the CDA and the gateway in the VM of ./dev.sh run-qemu and
# reads the VIN of an ECU of the simulator through the gateway, from a container on the network.
vm_test() {
  local image="${SCORE_DEV_IMAGE:-score-dev:aarch64-sim}" base="http://$VM_IP:7690/sovd/v1" vin
  docker image inspect "$image" >/dev/null 2>&1 || { echo "run ./dev.sh build-qemu first ($image is its devcontainer)" >&2; exit 1; }
  docker inspect -f '{{.State.Running}}' "$SIM" 2>/dev/null | grep -q true || { echo "run ./ecu-sim.sh up first" >&2; exit 1; }
  on_net() { docker run --rm -i --platform linux/amd64 --network "$NET" "$image" "$@"; }
  echo "waiting for the VM on $VM_IP (start it with ./dev.sh run-qemu)"
  wait_for 1800 "the VM" on_net bash -c "exec 3<>/dev/tcp/$VM_IP/22"
  # The launch manager of the showcase starts the CDA, which listens on the loopback address of the
  # VM, and then the gateway, which listens on all addresses: clients use the gateway.
  on_net ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$VM_IP" "
    killall launch_manager opensovd-cda opensovd-gateway 2>/dev/null
    cd /showcases/data/diagnostics && (nohup /usr/bin/launch_manager >/tmp/launch_manager.log 2>&1 &)"
  # The ECUs are found by DoIP broadcast from the VM, so give the CDA a moment.
  wait_for 120 "the simulated ECUs through the gateway in the VM" on_net bash -c "curl -sf '$base/components' | grep -q flxc1000"
  echo "components (through the gateway in the VM): $(on_net curl -sf "$base/components")"
  for _ in $(seq 1 30); do
    vin="$(on_net curl -sf "$base/components/flxc1000/data/VINDataIdentifier" -H "Authorization: Bearer $DEV_TOKEN")" && break
    sleep 2
  done
  echo "VIN:        $vin"
  grep -q SCEDT26T8BD005261 <<<"$vin" || { echo "unexpected VIN" >&2; exit 1; }
  if on_net curl -s -m 4 -o /dev/null "http://$VM_IP:20002/health/ready"; then echo "the CDA is reachable directly, it must not be" >&2; exit 1; fi
  echo "OK: the gateway in the image reached the CDA in the image, which read the VIN of a simulated ECU; the CDA is not reachable directly"
}

down() {
  docker rm -f "$GATEWAY" "$CDA" "$SIM" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}

case "${1:-}" in
  up) sim_up ;;
  test) cda_test ;;
  test-vm) vm_test ;;
  down) down ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
