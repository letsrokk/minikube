#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $(basename "$0") <helmfile-command> [environment]" >&2
  exit 1
fi

command_name=$1
environment_name=${2:-default}

script_dir=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)

helm_cache_root=${HELM_CACHE_HOME:-"$script_dir/.helm/cache"}
helm_config_root=${HELM_CONFIG_HOME:-"$script_dir/.helm/config"}

mkdir -p "$helm_cache_root" "$helm_config_root"

export HELM_CACHE_HOME=$helm_cache_root
export HELM_CONFIG_HOME=$helm_config_root

env_file="$script_dir/.env"

if [[ -f "$env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
fi

exec helmfile -f "$script_dir/helmfile.yaml" -e "$environment_name" "$command_name"
