#!/usr/bin/env bash
# Tests Docker environment forwarding without starting a container.
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=dev.sh
source "$TEST_ROOT/dev.sh"

test_file="$(mktemp "${TMPDIR:-/tmp}/score-dev-test.XXXXXX")"
trap 'rm -f "$test_file"' EXIT
ensure_image() { :; }
docker() {
  printf '%s\n' "$@" > "$test_file"
  local name
  for name in SCORE_PI_ADDRESS SCORE_PI_GATEWAY SCORE_PI_DNS SCORE_PI_MDNS; do
    [[ -z "${!name+x}" ]] || printf 'ENV:%s=%s\n' "$name" "${!name}" >> "$test_file"
  done
}

unset SCORE_PI_ADDRESS SCORE_PI_GATEWAY SCORE_PI_DNS SCORE_PI_MDNS
docker_run -- true
if grep -qx 'SCORE_PI_MDNS' "$test_file"; then
  echo "forwarded an unset mDNS setting" >&2
  exit 1
fi

export SCORE_PI_ADDRESS=10.0.0.20/24 SCORE_PI_GATEWAY=10.0.0.1 SCORE_PI_DNS=10.0.0.1
export SCORE_PI_MDNS='Test Vehicle'
docker_run -- true
grep -Fxq 'SCORE_PI_ADDRESS' "$test_file"
grep -Fxq 'SCORE_PI_GATEWAY' "$test_file"
grep -Fxq 'SCORE_PI_DNS' "$test_file"
grep -Fxq 'SCORE_PI_MDNS' "$test_file"
grep -Fxq 'ENV:SCORE_PI_ADDRESS=10.0.0.20/24' "$test_file"
grep -Fxq 'ENV:SCORE_PI_GATEWAY=10.0.0.1' "$test_file"
grep -Fxq 'ENV:SCORE_PI_DNS=10.0.0.1' "$test_file"
grep -Fxq 'ENV:SCORE_PI_MDNS=Test Vehicle' "$test_file"

SCORE_PI_MDNS=''
docker_run -- true
grep -Fxq 'SCORE_PI_MDNS' "$test_file"
grep -Fxq 'ENV:SCORE_PI_MDNS=' "$test_file"
echo "dev.sh environment forwarding tests passed"
