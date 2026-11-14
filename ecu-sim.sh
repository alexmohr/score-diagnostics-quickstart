#!/usr/bin/env bash
# CDA ECU simulator, to test a build with a running classic diagnostic adapter (CDA).
#
#   ./ecu-sim.sh up      build and start the ECU simulator (DoIP/UDS ECUs, control API on 127.0.0.1:8181)
#   ./ecu-sim.sh test    run the gateway and the CDA from the last build-pi output against the simulator
#                        and read the VIN of an ECU through the gateway over SOVD
#   ./ecu-sim.sh down    stop and remove everything this script started
#
# The simulator, its ECU databases (MDD) and the CDA configuration come from the
# eclipse-opensovd/classic-diagnostic-adapter commit that inc_diagnostics pins, so they match
# the CDA in the image. Everything runs on the Docker network "score-ecu-sim" (172.42.0.0/16),
# because the CDA finds the simulated ECUs by DoIP broadcast and that needs one layer-2 network.
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
CDA_URL="https://github.com/eclipse-opensovd/classic-diagnostic-adapter.git"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
  cat > "$work/opensovd-cda.toml" <<'EOF'
[server]
address = "0.0.0.0"
port = 20002

[database]
dir = "/app/databases"
exit_no_database_loaded = true

[doip]
tester_subnet = "255.255.0.0"
EOF

  docker rm -f "$CDA" >/dev/null 2>&1 || true
  # An arm64 container runs the aarch64 binary natively on Apple Silicon. The tester address is
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
  # The gateway has no /authorize yet (it answers 404), so no client can get a token. The CDA here runs
  # in its development mode and accepts any well-formed JWT with sub and exp; this is one. Replace it
  # by the token of the gateway as soon as the gateway issues tokens.
  token="eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0IiwiZXhwIjoyMDAwMDAwMDAwfQ.Q0IP5df7FxVEvVDF2v6soF8uh-j_qA-D_tgYTb3ur3g"
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

down() {
  docker rm -f "$GATEWAY" "$CDA" "$SIM" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}

case "${1:-}" in
  up) sim_up ;;
  test) cda_test ;;
  down) down ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
