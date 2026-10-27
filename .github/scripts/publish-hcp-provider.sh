#!/usr/bin/env bash
# Publish a GoReleaser build of this provider to an HCP Terraform private registry.
#
# The private registry does not ingest GitHub Releases. This script registers the
# provider and signing key if needed, creates the version, and uploads the
# checksum, signature, and platform archives.
#
# API reference:
# https://developer.hashicorp.com/terraform/cloud-docs/registry/publish-providers
#
# Required environment:
#   HCP_TERRAFORM_TOKEN          Team or user token with Manage Private Registry
#   HCP_TERRAFORM_ORGANIZATION   HCP Terraform organization name
#   GPG_FINGERPRINT              Fingerprint of the key that signed the checksum
#   GPG_KEY_ID                   Long key id (16 hex chars) of that key
#   GITHUB_REF_NAME              Tag being published, for example v1.26.0-zb.1
#
# Optional environment:
#   HCP_TERRAFORM_HOSTNAME       Defaults to app.terraform.io
#   DIST_DIR                     Directory containing the release assets. Defaults to dist
#   PROVIDER_NAME                Registry provider name. Defaults to postgresql
#   PROJECT_NAME                 GoReleaser project name. Defaults to terraform-provider-postgresql
#
# This provider is built with terraform-plugin-sdk v2, which speaks protocol 5.0.
set -euo pipefail

die() {
  echo "publish-hcp-provider: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "missing ${name}"
  fi
}

api() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local response_file="$4"
  local status

  if [[ -n "${body}" ]]; then
    status="$(
      curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
        --request "${method}" \
        --header "Authorization: Bearer ${HCP_TERRAFORM_TOKEN}" \
        --header 'Content-Type: application/vnd.api+json' \
        --data "${body}" \
        "${url}"
    )" || die "HTTP request failed: ${method} ${url}"
  else
    status="$(
      curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
        --request "${method}" \
        --header "Authorization: Bearer ${HCP_TERRAFORM_TOKEN}" \
        --header 'Content-Type: application/vnd.api+json' \
        "${url}"
    )" || die "HTTP request failed: ${method} ${url}"
  fi

  printf '%s' "${status}"
}

fail_response() {
  local status="$1"
  local response_file="$2"
  local action="$3"

  echo "publish-hcp-provider: ${action} failed with HTTP ${status}" >&2
  cat "${response_file}" >&2
  echo >&2
  exit 1
}

json_link() {
  local response_file="$1"
  local key="$2"

  jq -er --arg key "${key}" '.data.links[$key] // .links[$key] // empty' "${response_file}"
}

upload_file() {
  local file="$1"
  local url="$2"

  curl --silent --show-error --fail-with-body --retry 2 \
    --request PUT \
    --upload-file "${file}" \
    "${url}" \
    >/dev/null || die "upload failed for ${file}"
}

require_env HCP_TERRAFORM_TOKEN
require_env HCP_TERRAFORM_ORGANIZATION
require_env GPG_FINGERPRINT
require_env GPG_KEY_ID
require_env GITHUB_REF_NAME

if [[ "${HCP_TERRAFORM_ORGANIZATION}" == "REPLACE_ME" ]]; then
  die "HCP_TERRAFORM_ORGANIZATION is still the placeholder REPLACE_ME. Set that repository variable to the HCP Terraform organization before publishing."
fi

hostname="${HCP_TERRAFORM_HOSTNAME:-app.terraform.io}"
hostname="${hostname#https://}"
hostname="${hostname#http://}"
hostname="${hostname%%/*}"
if [[ -z "${hostname}" || "${hostname}" == "REPLACE_ME" ]]; then
  die "HCP_TERRAFORM_HOSTNAME is empty or still a placeholder"
fi

provider_name="${PROVIDER_NAME:-postgresql}"
project_name="${PROJECT_NAME:-terraform-provider-postgresql}"
dist_dir="${DIST_DIR:-dist}"
tag="${GITHUB_REF_NAME}"
version="${tag#v}"
key_id="$(printf '%s' "${GPG_KEY_ID}" | tr '[:lower:]' '[:upper:]')"
# terraform-plugin-sdk v2.
protocols='["5.0"]'

if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.+]+)?$ ]]; then
  die "tag ${tag} is not a vMAJOR.MINOR.PATCH release tag"
fi

api_root="https://${hostname}/api/v2"
registry_root="https://${hostname}/api/registry/private/v2"
provider_url="${api_root}/organizations/${HCP_TERRAFORM_ORGANIZATION}/registry-providers/private/${HCP_TERRAFORM_ORGANIZATION}/${provider_name}"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

echo "Publishing ${provider_name} ${version} to ${hostname}/${HCP_TERRAFORM_ORGANIZATION}"

provider_status="$(api GET "${provider_url}" "" "${workdir}/provider.json")"
if [[ "${provider_status}" == "404" ]]; then
  echo "Creating private provider ${provider_name}"
  create_body="$(
    jq -n --arg name "${provider_name}" --arg namespace "${HCP_TERRAFORM_ORGANIZATION}" \
      '{data:{type:"registry-providers",attributes:{name:$name,namespace:$namespace,"registry-name":"private"}}}'
  )"
  provider_status="$(
    api POST "${api_root}/organizations/${HCP_TERRAFORM_ORGANIZATION}/registry-providers" \
      "${create_body}" "${workdir}/provider.json"
  )"
  if [[ "${provider_status}" != "201" ]]; then
    fail_response "${provider_status}" "${workdir}/provider.json" "create provider"
  fi
elif [[ "${provider_status}" != "200" ]]; then
  fail_response "${provider_status}" "${workdir}/provider.json" "look up provider"
else
  echo "Private provider ${provider_name} already exists"
fi

public_key="$(gpg --batch --armor --export "${GPG_FINGERPRINT}")" \
  || die "could not export the public key for ${GPG_FINGERPRINT}"

gpg_url="${registry_root}/gpg-keys/${HCP_TERRAFORM_ORGANIZATION}/${key_id}"
gpg_status="$(api GET "${gpg_url}" "" "${workdir}/gpg.json")"
if [[ "${gpg_status}" == "404" ]]; then
  echo "Uploading GPG public key ${key_id}"
  gpg_body="$(
    jq -n --arg namespace "${HCP_TERRAFORM_ORGANIZATION}" --arg armor "${public_key}" \
      '{data:{type:"gpg-keys",attributes:{namespace:$namespace,"ascii-armor":$armor}}}'
  )"
  gpg_status="$(api POST "${registry_root}/gpg-keys" "${gpg_body}" "${workdir}/gpg.json")"
  if [[ "${gpg_status}" != "201" ]]; then
    fail_response "${gpg_status}" "${workdir}/gpg.json" "upload GPG key"
  fi
elif [[ "${gpg_status}" != "200" ]]; then
  fail_response "${gpg_status}" "${workdir}/gpg.json" "look up GPG key"
else
  echo "GPG key ${key_id} is already registered"
fi

registered_key_id="$(jq -er '.data.attributes["key-id"]' "${workdir}/gpg.json")"
if [[ "${registered_key_id}" != "${key_id}" ]]; then
  echo "Using registry key id ${registered_key_id} (local key id is ${key_id})"
fi

sums_file="${dist_dir}/${project_name}_${version}_SHA256SUMS"
if [[ ! -f "${sums_file}" ]]; then
  die "checksum file not found: ${sums_file}"
fi

shopt -s nullglob
sig_files=("${dist_dir}/${project_name}_${version}_SHA256SUMS"*.sig)
shopt -u nullglob
if [[ "${#sig_files[@]}" -ne 1 ]]; then
  die "expected one signature file for ${sums_file}, found ${#sig_files[@]}"
fi
sig_file="${sig_files[0]}"

echo "Creating provider version ${version}"
version_body="$(
  jq -n --arg version "${version}" --arg key_id "${registered_key_id}" --argjson protocols "${protocols}" \
    '{data:{type:"registry-provider-versions",attributes:{version:$version,"key-id":$key_id,protocols:$protocols}}}'
)"
version_status="$(api POST "${provider_url}/versions" "${version_body}" "${workdir}/version.json")"
if [[ "${version_status}" != "201" ]]; then
  fail_response "${version_status}" "${workdir}/version.json" "create version ${version}"
fi

shasums_upload="$(json_link "${workdir}/version.json" "shasums-upload")" \
  || die "create version response did not include shasums-upload"
shasums_sig_upload="$(json_link "${workdir}/version.json" "shasums-sig-upload")" \
  || die "create version response did not include shasums-sig-upload"

echo "Uploading checksum and signature"
upload_file "${sums_file}" "${shasums_upload}"
upload_file "${sig_file}" "${shasums_sig_upload}"

while read -r checksum filename || [[ -n "${checksum}${filename}" ]]; do
  [[ -z "${checksum}" || "${checksum}" == \#* ]] && continue
  filename="${filename#\*}"
  filename="${filename//$'\r'/}"
  [[ "${filename}" == *.zip ]] || continue

  archive="${dist_dir}/${filename}"
  [[ -f "${archive}" ]] || die "archive listed in the checksum file was not downloaded: ${filename}"

  rest="${filename#"${project_name}"_"${version}"_}"
  rest="${rest%.zip}"
  os="${rest%%_*}"
  arch="${rest#*_}"
  [[ -n "${os}" && -n "${arch}" && "${os}" != "${rest}" ]] || die "could not parse os and arch from ${filename}"

  echo "Uploading ${os}/${arch}"
  platform_body="$(
    jq -n --arg os "${os}" --arg arch "${arch}" --arg shasum "${checksum}" --arg filename "${filename}" \
      '{data:{type:"registry-provider-version-platforms",attributes:{os:$os,arch:$arch,shasum:$shasum,filename:$filename}}}'
  )"
  platform_status="$(
    api POST "${provider_url}/versions/${version}/platforms" \
      "${platform_body}" "${workdir}/platform.json"
  )"
  if [[ "${platform_status}" != "201" ]]; then
    fail_response "${platform_status}" "${workdir}/platform.json" "create platform ${os}/${arch}"
  fi

  binary_upload="$(json_link "${workdir}/platform.json" "provider-binary-upload")" \
    || die "create platform response did not include provider-binary-upload"
  upload_file "${archive}" "${binary_upload}"
done < "${sums_file}"

echo "Published ${HCP_TERRAFORM_ORGANIZATION}/${provider_name} ${version}"
