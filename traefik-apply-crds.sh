#!/usr/bin/env bash

set -euo pipefail

script_dir=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)
helm_cache_root=${HELM_CACHE_HOME:-"$script_dir/.helm/cache"}
helm_config_root=${HELM_CONFIG_HOME:-"$script_dir/.helm/config"}

mkdir -p "$helm_cache_root" "$helm_config_root"
export HELM_CACHE_HOME=$helm_cache_root
export HELM_CONFIG_HOME=$helm_config_root

helm show crds traefik \
  --repo https://traefik.github.io/charts \
  --version 41.2.0 \
  | kubectl apply \
    --server-side \
    --force-conflicts \
    --field-manager=helmfile-traefik-crds \
    -f -
