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
CDA_URL="https://github.com/eclipse-opensovd/classic-diagnostic-adapter.git"
# Merged PR #766, used only for the native Pi simulator until the CDA pin includes it.
PI_SIM_COMMIT="2c8efb26b19ce03b4a1f471d98ee115f49662c64"

usage() {
  cat <<'HELP'
Usage: ./ecu-sim.sh <command>

  up     build and start the ECU simulator of the classic diagnostic adapter (CDA), control API on
         127.0.0.1:8181, on the Docker network score-ecu-sim (172.42.0.0/16)
  pi     build and run the simulator on the host for a physical Pi (foreground; Java 21 required).
         Set SIM_NETWORK_INTERFACE and SIM_BROADCAST_ADDRESS for the Pi network; see README.md.
  test   run the gateway and the CDA of the last ./dev.sh build-pi in containers on that network and
         read the VIN of the ECU flxc1000 through the gateway (127.0.0.1:7690). The CDA is only
         reachable through the gateway. This does not use the QEMU image.
  test-vm
         with the VM of ./dev.sh run-qemu running on the same network: wait for the diagnostics service
         of the image (the CDA and the gateway, started at boot) and read the same VIN through the
         gateway of the VM (172.42.1.100:7690), from a container on the network. The CDA must not be
         reachable directly.
  down   stop and remove everything this script started

The simulator, its ECU databases and the settings that its ECUs need come from the CDA commit that
inc_diagnostics pins. The CDA finds the simulated ECUs by DoIP broadcast, which needs one layer-2
network. The tests use jq and obtain a token from the gateway's development /authorize endpoint.
Its placeholder credentials and authentication are not suitable for production.
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
  sha="${1:-$(cda_commit)}"
  [[ -n "$sha" ]] || { echo "no classic-diagnostic-adapter commit in inc_diagnostics/MODULE.bazel" >&2; exit 1; }
  if [[ ! -d "$SRC/.git" ]]; then
    mkdir -p "$SRC"
    GIT_MASTER=1 git -C "$SRC" init -q
    GIT_MASTER=1 git -C "$SRC" remote add origin "$CDA_URL"
  fi
  if [[ "$(GIT_MASTER=1 git -C "$SRC" rev-parse -q --verify HEAD || true)" != "$sha" ]]; then
    [[ -z "$(GIT_MASTER=1 git -C "$SRC" status --porcelain)" ]] || {
      echo "simulator source in $SRC has local changes; not switching commits" >&2
      return 1
    }
    GIT_MASTER=1 git -C "$SRC" fetch -q --depth 1 origin "$sha"
    GIT_MASTER=1 git -C "$SRC" checkout -q --detach "$sha"
  fi
  echo "classic-diagnostic-adapter at ${sha:0:12}"
}

# Docker Desktop cannot put a container on the Pi's Ethernet. Build the simulator in Docker,
# then run its JVM on the host, using a separate source checkout from the pinned CDA databases.
sim_pi() {
  local SRC="$OUT/cda-pi-sim-src" image="score-cda-ecu-sim-pi" jar tmp
  [[ -n "${SIM_NETWORK_INTERFACE:-}" && -n "${SIM_BROADCAST_ADDRESS:-}" ]] || {
    echo "set SIM_NETWORK_INTERFACE and SIM_BROADCAST_ADDRESS for the Pi network; see README.md" >&2
    return 1
  }
  command -v java >/dev/null 2>&1 || { echo "Java 21 is required on the host" >&2; return 1; }
  fetch_source "$PI_SIM_COMMIT" || return 1
  local changes
  changes="$(GIT_MASTER=1 git -C "$SRC" status --porcelain)" || return 1
  [[ -z "$changes" ]] || { echo "simulator source in $SRC has local changes; not building it" >&2; return 1; }
  docker build -q -t "$image" -f "$SRC/testcontainer/ecu-sim/docker/Dockerfile" "$SRC/testcontainer/ecu-sim" >/dev/null || return 1
  jar="$OUT/cda-pi-ecu-sim-all.jar"
  tmp="$(mktemp "$OUT/cda-pi-ecu-sim.XXXXXX")"
  if ! docker run --rm --entrypoint cat "$image" /app/ecu-sim-all.jar > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$jar"; then
    rm -f "$tmp"
    return 1
  fi
  echo "Starting native simulator on $SIM_NETWORK_INTERFACE (broadcast $SIM_BROADCAST_ADDRESS); Ctrl-C to stop"
  SIM_NETWORK_INTERFACE="$SIM_NETWORK_INTERFACE" SIM_BROADCAST_ADDRESS="$SIM_BROADCAST_ADDRESS" \
    java -Djava.net.preferIPv4Stack=true -jar "$jar"
}

wait_for() {  # wait_for <seconds> <description> <command...>
  local limit="$1" what="$2" i
  shift 2
  for ((i = 0; i < limit; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "timed out waiting for $what" >&2
  return 1
}

# request_token <base URL> <curl command...>: curl may run locally or on the Docker network.
request_token() {
  local base="$1"
  shift
  "$@" --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    -H 'Content-Type: application/json' --data '{"client_id":"ecu-sim","client_secret":"secret"}' \
    "$base/authorize" | jq -er '.access_token | select(type == "string" and length > 0)'
}

wait_for_token() {  # wait_for_token <seconds> <description> <base URL> <curl command...>
  local limit="$1" what="$2" base="$3" token i
  shift 3
  for ((i = 0; i < limit; i++)); do
    if token="$(request_token "$base" "$@" 2>/dev/null)"; then
      printf '%s\n' "$token"
      return 0
    fi
    (( i + 1 == limit )) || sleep 1
  done
  echo "timed out waiting for $what" >&2
  return 1
}

response_contains() {  # response_contains <text> <command...>
  local expected="$1" response
  shift
  response="$("$@")" || return 1
  [[ "$response" == *"$expected"* ]]
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required for the gateway token" >&2; return 1; }
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
  require_jq
  docker inspect -f '{{.State.Running}}' "$SIM" 2>/dev/null | grep -q true || { echo "run ./ecu-sim.sh up first" >&2; exit 1; }
  [[ -f "$PLATFORM_TAR" ]] || { echo "$PLATFORM_TAR not found, run ./dev.sh build-pi first" >&2; exit 1; }
  local expected actual
  expected="$(cda_commit)"
  actual="$(GIT_MASTER=1 git -C "$SRC" rev-parse HEAD 2>/dev/null)" || actual=""
  [[ -n "$expected" && "$actual" == "$expected" ]] || { echo "simulator source is not at the pinned CDA commit; run ./ecu-sim.sh up" >&2; exit 1; }

  # The CDA exactly as the platform package ships it, plus its databases.
  local work
  work="$(mktemp -d "$OUT/cda-run.XXXXXX")"
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

  # The gateway in front of the CDA: with SOVD_UPSTREAM_URL it forwards what it does not hold to the CDA.
  docker rm -f "$GATEWAY" >/dev/null 2>&1 || true
  docker run -d --name "$GATEWAY" --platform linux/arm64 --network "$NET" -p 127.0.0.1:7690:7690 \
    -e SOVD_URL=http://0.0.0.0:7690/sovd -e "SOVD_UPSTREAM_URL=http://$CDA:20002/vehicle/v15" \
    -v "$work":/app:ro debian:bookworm-slim /app/opensovd-gateway >/dev/null
  local base=http://127.0.0.1:7690/sovd/v1 token components vin
  token="$(wait_for_token 60 "the gateway's authorization endpoint" "$base" curl)" || { docker logs --tail 40 "$GATEWAY"; exit 1; }
  wait_for 60 "the gateway and the CDA behind it" response_contains sovd2uds \
    curl -fsS -H "Authorization: Bearer $token" "$base/apps" || { docker logs --tail 40 "$GATEWAY"; exit 1; }
  # The ECUs are found by DoIP broadcast, so give the CDA a moment.
  wait_for 60 "the simulated ECUs" response_contains flxc1000 \
    curl -fsS -H "Authorization: Bearer $token" "$base/components"
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

# The OpenSOVD stack of the image: waits for the diagnostics service in the VM of ./dev.sh run-qemu
# and reads the VIN of an ECU of the simulator through the gateway, from a container on the network.
vm_test() {
  require_jq
  local image="${SCORE_DEV_IMAGE:-score-dev:aarch64-sim}" base="http://$VM_IP:7690/sovd/v1" token vin=""
  docker image inspect "$image" >/dev/null 2>&1 || { echo "run ./dev.sh build-qemu first ($image is its devcontainer)" >&2; exit 1; }
  docker inspect -f '{{.State.Running}}' "$SIM" 2>/dev/null | grep -q true || { echo "run ./ecu-sim.sh up first" >&2; exit 1; }
  on_net() { docker run --rm -i --platform linux/amd64 --network "$NET" "$image" "$@"; }
  echo "waiting for the VM on $VM_IP (start it with ./dev.sh run-qemu)"
  wait_for 1800 "the VM" on_net bash -c "exec 3<>/dev/tcp/$VM_IP/22"
  # The image starts the CDA on a Unix socket and the gateway on the VM's network address.
  token="$(wait_for_token 600 "the VM gateway's authorization endpoint" "$base" on_net curl)"
  wait_for 600 "the diagnostics service in the VM" response_contains sovd2uds \
    on_net curl -fsS -H "Authorization: Bearer $token" "$base/apps"
  # The ECUs are found by DoIP broadcast from the VM, so give the CDA a moment.
  wait_for 120 "the simulated ECUs through the gateway in the VM" response_contains flxc1000 \
    on_net curl -fsS -H "Authorization: Bearer $token" "$base/components"
  echo "components (through the gateway in the VM): $(on_net curl -fsS -H "Authorization: Bearer $token" "$base/components")"
  for _ in $(seq 1 30); do
    vin="$(on_net curl -sf "$base/components/flxc1000/data/VINDataIdentifier" -H "Authorization: Bearer $token")" && break
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    up) sim_up ;;
    pi) sim_pi ;;
    test) cda_test ;;
    test-vm) vm_test ;;
    down) down ;;
    -h|--help|help) usage 0 ;;
    *) usage 2 ;;
  esac
fi
