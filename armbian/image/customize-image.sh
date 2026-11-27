#!/usr/bin/env bash
set -euo pipefail

# Template for Armbian's userpatches/customize-image.sh. The actual payload and
# support files are supplied through userpatches/overlay -> /tmp/overlay.
# arguments: RELEASE LINUXFAMILY BOARD BUILD_DESKTOP

# BEGIN mi50-arm image integration
if [ ! -x /tmp/overlay/mi50-customize-image.sh ]; then
  echo "mi50-arm: /tmp/overlay/mi50-customize-image.sh is missing" >&2
  exit 1
fi
exec /tmp/overlay/mi50-customize-image.sh "$@"
# END mi50-arm image integration
