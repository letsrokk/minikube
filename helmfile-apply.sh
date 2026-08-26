#!/usr/bin/env bash

set -euo pipefail

script_dir=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)

"$script_dir/traefik-apply-crds.sh"
exec "$script_dir/helmfile-common.sh" apply "${1:-default}"
