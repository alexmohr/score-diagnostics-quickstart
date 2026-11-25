#!/usr/bin/env bash
# Tests native simulator setup without Docker or a Pi.
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ecu-sim.sh
source "$TEST_ROOT/ecu-sim.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/score-ecu-sim-pi-test.XXXXXX")"
trap 'rm -f "$test_dir/cda-pi-ecu-sim-all.jar"; rmdir "$test_dir"' EXIT

(
  OUT="$test_dir"
  unset SIM_NETWORK_INTERFACE SIM_BROADCAST_ADDRESS
  if sim_pi >/dev/null 2>&1; then
    echo "accepted missing Pi network settings" >&2
    exit 1
  fi
  SIM_NETWORK_INTERFACE=en7
  if sim_pi >/dev/null 2>&1; then
    echo "accepted missing broadcast address" >&2
    exit 1
  fi

  fetch_source() {
    [[ "$1" == "$PI_SIM_COMMIT" && "$SRC" == "$OUT/cda-pi-sim-src" ]]
  }
  git() {
    [[ "$*" == "-C $OUT/cda-pi-sim-src status --porcelain" ]] || return 1
    [[ "${DIRTY_SOURCE:-0}" != 1 ]] || printf ' M simulator-source\n'
  }
  docker() {
    case "$1" in
      build) [[ "$*" == *"$OUT/cda-pi-sim-src/testcontainer/ecu-sim"* ]] ;;
      run)
        [[ "$*" == 'run --rm --entrypoint cat score-cda-ecu-sim-pi /app/ecu-sim-all.jar' ]] || return 1
        [[ "${FAIL_EXTRACT:-0}" != 1 ]] || return 1
        printf 'simulator jar'
        ;;
      *) return 1 ;;
    esac
  }
  java() {
    [[ "$SIM_NETWORK_INTERFACE" == en7 && "$SIM_BROADCAST_ADDRESS" == 192.168.7.255 ]]
    [[ "$*" == "-Djava.net.preferIPv4Stack=true -jar $OUT/cda-pi-ecu-sim-all.jar" ]]
    [[ "$(cat "$OUT/cda-pi-ecu-sim-all.jar")" == 'simulator jar' ]]
  }
  SIM_BROADCAST_ADDRESS=192.168.7.255
  sim_pi >/dev/null
  DIRTY_SOURCE=1
  if sim_pi >/dev/null 2>&1; then
    echo "accepted a modified simulator source" >&2
    exit 1
  fi
  DIRTY_SOURCE=0
  FAIL_EXTRACT=1
  if sim_pi >/dev/null 2>&1; then
    echo "accepted a failed jar extraction" >&2
    exit 1
  fi
  [[ "$(cat "$OUT/cda-pi-ecu-sim-all.jar")" == 'simulator jar' ]]
)
echo "native Pi simulator setup tests passed"
