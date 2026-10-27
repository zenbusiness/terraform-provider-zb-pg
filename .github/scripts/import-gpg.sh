#!/usr/bin/env bash
# Import GPG_PRIVATE_KEY and cache PASSPHRASE with gpg-agent.
# Later gpg --batch --detach-sign calls can then sign without a prompt.
set -euo pipefail

if [[ -z "${GPG_PRIVATE_KEY:-}" || -z "${PASSPHRASE:-}" ]]; then
  echo "GPG_PRIVATE_KEY and PASSPHRASE are required" >&2
  exit 1
fi
if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
  echo "GITHUB_OUTPUT is required" >&2
  exit 1
fi

install -m 700 -d "${HOME}/.gnupg"
printf '%s\n' 'allow-preset-passphrase' 'default-cache-ttl 21600' 'max-cache-ttl 31536000' > "${HOME}/.gnupg/gpg-agent.conf"
gpg-connect-agent reloadagent /bye >/dev/null

key_file="$(mktemp)"
trap 'rm -f "$key_file"' EXIT
printf '%s\n' "$GPG_PRIVATE_KEY" > "$key_file"
chmod 600 "$key_file"
gpg --batch --yes --import "$key_file"

fingerprint="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print toupper($10); exit }')"
if [[ -z "${fingerprint}" ]]; then
  echo "imported key has no fingerprint" >&2
  exit 1
fi

pass_hex="$(printf '%s' "$PASSPHRASE" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]')"
grips="$(gpg --batch --with-colons --with-keygrip --list-secret-keys "$fingerprint" | awk -F: '$1 == "grp" { print $10 }')"
if [[ -z "${grips}" ]]; then
  echo "signing key has no keygrip" >&2
  exit 1
fi
while read -r grip; do
  reply="$(gpg-connect-agent "PRESET_PASSPHRASE ${grip} -1 ${pass_hex}" /bye)"
  if [[ "${reply}" == *"ERR "* ]]; then
    echo "could not unlock the signing key" >&2
    exit 1
  fi
done <<< "${grips}"

{
  echo "fingerprint=${fingerprint}"
  echo "keyid=${fingerprint: -16}"
} >> "$GITHUB_OUTPUT"
