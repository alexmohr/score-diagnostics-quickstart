#!/usr/bin/env bash
# Tests the gateway token and VM request flow without starting Docker containers.
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ecu-sim.sh
source "$TEST_ROOT/ecu-sim.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/score-ecu-sim-test.XXXXXX")"
trap 'rm -f "$test_dir/attempt"; rmdir "$test_dir"' EXIT

fake_curl() {
  local payload="" content_type="" url=""
  while (( $# )); do
    case "$1" in
      --data) payload="$2"; shift 2 ;;
      -H) content_type="$2"; shift 2 ;;
      http*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  [[ "$payload" == '{"client_id":"ecu-sim","client_secret":"secret"}' ]] || return 1
  [[ "$content_type" == 'Content-Type: application/json' ]] || return 1
  [[ "$url" == 'http://gateway/sovd/v1/authorize' || "$url" == "http://$VM_IP:7690/sovd/v1/authorize" ]] || return 1
  printf '%s\n' '{"access_token":"test.jwt.token"}'
}

flaky_curl() {
  if [[ ! -e "$test_dir/attempt" ]]; then
    : > "$test_dir/attempt"
    return 1
  fi
  fake_curl "$@"
}

invalid_curl() { printf '%s\n' '{"access_token":""}'; }
bad_json_curl() { printf '%s\n' 'not json'; }
sleep() { :; }

[[ "$(request_token http://gateway/sovd/v1 fake_curl)" == 'test.jwt.token' ]]
[[ "$(wait_for_token 2 gateway http://gateway/sovd/v1 flaky_curl)" == 'test.jwt.token' ]]
if request_token http://gateway/sovd/v1 invalid_curl >/dev/null 2>&1; then
  echo "accepted an empty token" >&2
  exit 1
fi
if request_token http://gateway/sovd/v1 bad_json_curl >/dev/null 2>&1; then
  echo "accepted invalid JSON" >&2
  exit 1
fi
if wait_for_token 1 gateway http://gateway/sovd/v1 invalid_curl >/dev/null 2>&1; then
  echo "accepted a failed authorization" >&2
  exit 1
fi

# The VM uses docker-run curl. Require a bearer token on every protected request.
docker() {
  case "$1" in
    image) return 0 ;;
    inspect) printf '%s\n' true ;;
    run)
      while [[ "$1" != "${SCORE_DEV_IMAGE:-score-dev:aarch64-sim}" ]]; do shift; done
      shift
      [[ "$1" != bash ]] || return 0
      [[ "$1" == curl ]] || return 1
      shift
      case "$*" in
        */authorize*) fake_curl "$@" ;;
        *:20002/health/ready*) return 7 ;;
        *)
          [[ "$*" == *'Authorization: Bearer test.jwt.token'* ]] || return 1
          case "$*" in
            */apps*) printf '%s\n' '{"items":[{"id":"sovd2uds"}]}' ;;
            */components/flxc1000/data/VINDataIdentifier*) printf '%s\n' '{"data":{"VIN":"SCEDT26T8BD005261"}}' ;;
            */components*) printf '%s\n' '{"items":[{"id":"flxc1000"}]}' ;;
            *) return 1 ;;
          esac
          ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

vm_output="$(vm_test)"
[[ "$vm_output" == *'SCEDT26T8BD005261'* ]]
[[ "$vm_output" == *'the CDA is not reachable directly'* ]]
echo "ecu-sim token and VM request tests passed"
