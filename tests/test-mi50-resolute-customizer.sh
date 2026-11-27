#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null 2>&1 || {
  echo "docker is required for the Resolute ARM64 customizer integration test" >&2
  exit 1
}

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64) ;;
  *) echo "This test must run on a native ARM64 runner (found $HOST_ARCH)" >&2; exit 1 ;;
esac

docker run --rm --pull=always --platform linux/arm64 \
  -v "$REPO_ROOT:/workspace:ro" \
  -v "$REPO_ROOT/tests/fixtures/mi50-resolute:/ci-fixtures:ro" \
  ubuntu:26.04 bash /ci-fixtures/run-customizer-inside-resolute.sh
