#!/usr/bin/env bash

set -euo pipefail

script_dir=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)
certificate_dir="$script_dir/.certs/traefik"
ca_versions_dir="$certificate_dir/ca-versions"
ca_current_link="$certificate_dir/ca-current"
versions_dir="$certificate_dir/versions"
current_link="$certificate_dir/current"
ca_key="$ca_current_link/ca.key"
ca_certificate="$ca_current_link/ca.crt"
legacy_ca_key="$certificate_dir/ca.key"
legacy_ca_certificate="$certificate_dir/ca.crt"

renew_server=false
if [[ "${1:-}" == "--renew-server" && "$#" -eq 1 ]]; then
  renew_server=true
elif [[ "$#" -ne 0 ]]; then
  echo "Usage: $(basename "$0") [--renew-server]" >&2
  exit 1
fi

generate_server_certificate() {
  local output_dir=$1

  openssl genrsa -out "$output_dir/localhost.key" 2048
  openssl req -new -sha256 \
    -key "$output_dir/localhost.key" \
    -out "$output_dir/localhost.csr" \
    -subj "/CN=*.minikube.localhost"

  printf '%s\n' \
    '[server_certificate]' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage=serverAuth' \
    'subjectAltName=DNS:*.minikube.localhost' \
    >"$output_dir/server-extensions.cnf"

  openssl x509 -req -sha256 -days 397 \
    -in "$output_dir/localhost.csr" \
    -CA "$ca_certificate" \
    -CAkey "$ca_key" \
    -CAserial "$output_dir/ca.srl" \
    -CAcreateserial \
    -extfile "$output_dir/server-extensions.cnf" \
    -extensions server_certificate \
    -out "$output_dir/localhost.crt"

  awk 'FNR == 1 && NR != 1 { print "" } { print }' \
    "$output_dir/localhost.crt" \
    "$ca_certificate" \
    >"$output_dir/localhost-chain.crt"
}

replace_symlink() {
  local replacement_link=$1
  local target_link=$2

  if mv --version >/dev/null 2>&1; then
    mv -Tf "$replacement_link" "$target_link"
  else
    mv -fh "$replacement_link" "$target_link"
  fi
}

verify_ca_version() {
  local ca_dir=$1
  local version_ca_key="$ca_dir/ca.key"
  local version_ca_certificate="$ca_dir/ca.crt"

  chmod 0600 "$version_ca_key"
  chmod 0644 "$version_ca_certificate"

  openssl x509 -in "$version_ca_certificate" -noout -checkend 0 >/dev/null
  ca_details=$(openssl x509 -in "$version_ca_certificate" -noout -text)
  if [[ "$ca_details" != *'CA:TRUE'* || "$ca_details" != *'Certificate Sign, CRL Sign'* ]]; then
    echo "$version_ca_certificate is not a signing CA certificate" >&2
    exit 1
  fi

  ca_key_modulus=$(openssl rsa -in "$version_ca_key" -noout -modulus 2>/dev/null)
  ca_certificate_modulus=$(openssl x509 -in "$version_ca_certificate" -noout -modulus)
  [[ "$ca_key_modulus" == "$ca_certificate_modulus" ]] || {
    echo "CA certificate does not match $version_ca_key" >&2
    exit 1
  }
}

verify_ca() {
  verify_ca_version "$ca_current_link"
}

verify_server_version() {
  local server_dir=$1
  local server_key="$server_dir/localhost.key"
  local server_certificate="$server_dir/localhost.crt"
  local server_chain="$server_dir/localhost-chain.crt"

  for server_file in "$server_key" "$server_certificate" "$server_chain"; do
    if [[ ! -f "$server_file" ]]; then
      echo "Server certificate version is incomplete: $server_dir" >&2
      exit 1
    fi
  done

  chmod 0600 "$server_key"
  chmod 0644 "$server_certificate" "$server_chain"

  openssl x509 -in "$server_certificate" -noout -checkend 0 >/dev/null
  openssl verify -CAfile "$ca_certificate" "$server_certificate" >/dev/null
  openssl x509 -in "$server_certificate" -noout -checkhost seaweedfs-filer.minikube.localhost >/dev/null
  openssl x509 -in "$server_certificate" -noout -checkhost seaweedfs-s3.minikube.localhost >/dev/null

  certificate_sans=$(
    openssl x509 -in "$server_certificate" -noout -ext subjectAltName \
      | tail -n 1 \
      | tr -d ' '
  )
  if [[ "$certificate_sans" != 'DNS:*.minikube.localhost' ]]; then
    echo "Server certificate SAN must be exactly DNS:*.minikube.localhost" >&2
    exit 1
  fi

  server_key_modulus=$(openssl rsa -in "$server_key" -noout -modulus 2>/dev/null)
  server_certificate_modulus=$(openssl x509 -in "$server_certificate" -noout -modulus)
  [[ "$server_key_modulus" == "$server_certificate_modulus" ]] || {
    echo "Server certificate does not match $server_key" >&2
    exit 1
  }

  certificate_count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$server_chain")
  if [[ "$certificate_count" -ne 2 ]] || ! cmp -s \
    <(awk 'FNR == 1 && NR != 1 { print "" } { print }' "$server_certificate" "$ca_certificate") \
    "$server_chain"; then
    echo "Server chain must contain the current leaf followed by the local CA" >&2
    exit 1
  fi
}

publish_ca_version() {
  local staging_dir
  local staging_name
  local version_name
  local version_dir
  local replacement_link

  staging_dir=$(mktemp -d "$ca_versions_dir/.generate.XXXXXX")
  cleanup_dir="$staging_dir"
  openssl genrsa -out "$staging_dir/ca.key" 4096

  printf '%s\n' \
    '[req]' \
    'distinguished_name=distinguished_name' \
    'x509_extensions=ca_certificate' \
    'prompt=no' \
    '[distinguished_name]' \
    'CN=Minikube Local Development CA' \
    '[ca_certificate]' \
    'basicConstraints=critical,CA:TRUE' \
    'keyUsage=critical,keyCertSign,cRLSign' \
    'subjectKeyIdentifier=hash' \
    >"$staging_dir/ca-extensions.cnf"

  openssl req -x509 -new -sha256 -days 3650 \
    -key "$staging_dir/ca.key" \
    -out "$staging_dir/ca.crt" \
    -config "$staging_dir/ca-extensions.cnf" \
    -extensions ca_certificate

  verify_ca_version "$staging_dir"
  rm "$staging_dir/ca-extensions.cnf"

  staging_name=${staging_dir##*/}
  version_name=${staging_name#.generate.}
  version_dir="$ca_versions_dir/$version_name"
  mv "$staging_dir" "$version_dir"
  cleanup_dir=

  replacement_link="$certificate_dir/.ca-current.$version_name"
  ln -s "ca-versions/$version_name" "$replacement_link"
  replace_symlink "$replacement_link" "$ca_current_link"
  verify_ca
}

migrate_legacy_ca() {
  local staging_dir
  local staging_name
  local version_name
  local version_dir
  local replacement_link

  verify_ca_version "$certificate_dir"

  if [[ -L "$ca_current_link" ]]; then
    verify_ca
    if ! cmp -s "$legacy_ca_key" "$ca_key" || ! cmp -s "$legacy_ca_certificate" "$ca_certificate"; then
      echo "Legacy and versioned CA files differ; preserving both for manual recovery" >&2
      exit 1
    fi
  else
    staging_dir=$(mktemp -d "$ca_versions_dir/.migrate.XXXXXX")
    cleanup_dir="$staging_dir"
    cp "$legacy_ca_key" "$staging_dir/ca.key"
    cp "$legacy_ca_certificate" "$staging_dir/ca.crt"
    verify_ca_version "$staging_dir"

    staging_name=${staging_dir##*/}
    version_name=${staging_name#.migrate.}
    version_dir="$ca_versions_dir/$version_name"
    mv "$staging_dir" "$version_dir"
    cleanup_dir=

    replacement_link="$certificate_dir/.ca-current.$version_name"
    ln -s "ca-versions/$version_name" "$replacement_link"
    replace_symlink "$replacement_link" "$ca_current_link"
    verify_ca
  fi

  rm "$legacy_ca_key" "$legacy_ca_certificate"
  echo "Migrated existing local CA to the atomic certificate layout"
}

publish_server_version() {
  local staging_dir
  local staging_name
  local version_name
  local version_dir
  local replacement_link

  staging_dir=$(mktemp -d "$versions_dir/.generate.XXXXXX")
  cleanup_dir="$staging_dir"
  generate_server_certificate "$staging_dir"
  verify_server_version "$staging_dir"

  rm "$staging_dir/localhost.csr" \
    "$staging_dir/server-extensions.cnf" \
    "$staging_dir/ca.srl"

  staging_name=${staging_dir##*/}
  version_name=${staging_name#.generate.}
  version_dir="$versions_dir/$version_name"
  mv "$staging_dir" "$version_dir"
  cleanup_dir=

  replacement_link="$certificate_dir/.current.$version_name"
  ln -s "versions/$version_name" "$replacement_link"
  replace_symlink "$replacement_link" "$current_link"
  verify_server_version "$current_link"
}

mkdir -p "$certificate_dir" "$ca_versions_dir" "$versions_dir"
umask 077
cleanup_dir=
trap 'if [[ -n "$cleanup_dir" ]]; then rm -rf "$cleanup_dir"; fi' EXIT

if [[ -e "$ca_current_link" && ! -L "$ca_current_link" ]]; then
  echo "$ca_current_link must be a symlink managed by this script" >&2
  exit 1
fi

legacy_ca_file_count=0
for legacy_ca_file in "$legacy_ca_key" "$legacy_ca_certificate"; do
  if [[ -e "$legacy_ca_file" ]]; then
    legacy_ca_file_count=$((legacy_ca_file_count + 1))
  fi
done

if [[ "$legacy_ca_file_count" -eq 1 ]]; then
  echo "Legacy local CA is incomplete in $certificate_dir" >&2
  echo "Preserving the existing CA file; restore its pair before retrying." >&2
  exit 1
elif [[ "$legacy_ca_file_count" -eq 2 ]]; then
  migrate_legacy_ca
fi

if [[ ! -L "$ca_current_link" ]]; then
  publish_ca_version
fi

verify_ca

if [[ -e "$current_link" && ! -L "$current_link" ]]; then
  echo "$current_link must be a symlink managed by this script" >&2
  exit 1
fi

if [[ "$renew_server" == true || ! -L "$current_link" ]]; then
  publish_server_version
  if [[ "$renew_server" == true ]]; then
    echo "Renewed Traefik server certificate with the existing local CA"
  else
    echo "Generated Traefik certificates in $certificate_dir"
  fi
else
  verify_server_version "$current_link"
  echo "Validated existing Traefik certificates in $certificate_dir"
fi

echo "Trust this CA certificate locally: $ca_certificate"
