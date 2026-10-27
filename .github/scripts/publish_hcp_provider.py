#!/usr/bin/env python3
"""Upload a signed provider release to the HCP Terraform private registry.

The registry does not ingest GitHub Releases. A version tag's checksum file
lists each platform archive. Those files are uploaded with PUT, using
Content-Type binary/octet-stream and a filename disposition. Prerelease
versions such as 1.26.0-zb.1 stay intact; a MAJOR.MINOR.PATCH-only pattern
would drop them.

This provider uses terraform-plugin-sdk v2, protocol 5.0.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+]+)?")
PROTOCOLS = ["5.0"]


def die(message):
    print(f"publish-hcp-provider: {message}", file=sys.stderr)
    raise SystemExit(1)


def setting(name, default=None):
    value = os.environ.get(name, "").strip()
    if value:
        return value
    if default is not None:
        return default
    die(f"missing {name}")


def release_version(tag):
    if TAG.fullmatch(tag) is None:
        die(f"tag {tag} is not a vMAJOR.MINOR.PATCH release tag")
    return tag[1:]


def parse_platforms(sums_text, version):
    """Return (sha256, filename, os, arch) for each zip named in SHA256SUMS."""
    marker = f"_{version}_"
    platforms = []
    for line in sums_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        checksum, filename = line.split(None, 1)
        filename = filename.removeprefix("*").strip()
        if not filename.endswith(".zip"):
            continue
        os_arch = filename[: -len(".zip")].split(marker, 1)
        if len(os_arch) != 2 or "_" not in os_arch[1]:
            die(f"could not parse os and arch from {filename}")
        os_name, arch = os_arch[1].split("_", 1)
        platforms.append((checksum, filename, os_name, arch))
    if not platforms:
        die("checksum file listed no platform archives")
    return platforms


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def decode(raw):
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"raw": raw.decode(errors="replace")}


def api(method, url, token, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/vnd.api+json",
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, decode(response.read())
    except urllib.error.HTTPError as error:
        return error.code, decode(error.read())


def expect(status, payload, allowed, action):
    if status not in allowed:
        die(f"{action} failed with HTTP {status}: {payload}")
    return payload


def upload(url, path):
    request = urllib.request.Request(
        url,
        data=path.read_bytes(),
        method="PUT",
        headers={
            "Content-Type": "binary/octet-stream",
            "Content-Disposition": f'attachment; filename="{path.name}"',
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            response.read()
    except urllib.error.HTTPError as error:
        die(f"upload failed for {path.name}: HTTP {error.code}: {error.read().decode(errors='replace')}")


def link(payload, key):
    links = payload.get("data", {}).get("links") or payload.get("links") or {}
    value = links.get(key)
    if not value:
        die(f"response did not include {key}")
    return value


def ensure_provider(hostname, token, organization, name):
    root = f"https://{hostname}/api/v2/organizations/{organization}"
    provider_url = f"{root}/registry-providers/private/{organization}/{name}"
    status, payload = api("GET", provider_url, token)
    if status == 200:
        print(f"Private provider {name} already exists")
        return provider_url
    if status != 404:
        expect(status, payload, (), "look up provider")
    print(f"Creating private provider {name}")
    status, payload = api(
        "POST",
        f"{root}/registry-providers",
        token,
        {
            "data": {
                "type": "registry-providers",
                "attributes": {"name": name, "namespace": organization, "registry-name": "private"},
            }
        },
    )
    expect(status, payload, (201,), "create provider")
    return provider_url


def ensure_key(hostname, token, organization, key_id, fingerprint):
    public_key = subprocess.check_output(
        ["gpg", "--batch", "--armor", "--export", fingerprint],
        text=True,
    )
    url = f"https://{hostname}/api/registry/private/v2/gpg-keys"
    status, payload = api("GET", f"{url}/{organization}/{key_id}", token)
    if status == 404:
        print(f"Uploading GPG public key {key_id}")
        status, payload = api(
            "POST",
            url,
            token,
            {"data": {"type": "gpg-keys", "attributes": {"namespace": organization, "ascii-armor": public_key}}},
        )
        expect(status, payload, (201,), "upload GPG key")
    else:
        expect(status, payload, (200,), "look up GPG key")
        print(f"GPG key {key_id} is already registered")
    return payload["data"]["attributes"]["key-id"]


def main():
    organization = setting("HCP_TERRAFORM_ORGANIZATION")
    if organization == "REPLACE_ME":
        die("HCP_TERRAFORM_ORGANIZATION is still the placeholder REPLACE_ME")
    hostname = setting("HCP_TERRAFORM_HOSTNAME", "app.terraform.io")
    hostname = hostname.removeprefix("https://").removeprefix("http://").split("/", 1)[0]
    if not hostname or hostname == "REPLACE_ME":
        die("HCP_TERRAFORM_HOSTNAME is empty or still a placeholder")

    token = setting("HCP_TERRAFORM_TOKEN")
    version = release_version(setting("GITHUB_REF_NAME"))
    provider = setting("PROVIDER_NAME", "postgresql")
    project = setting("PROJECT_NAME", "terraform-provider-postgresql")
    dist = Path(setting("DIST_DIR", "dist"))
    key_id = setting("GPG_KEY_ID").upper()

    print(f"Publishing {provider} {version} to {hostname}/{organization}")
    provider_url = ensure_provider(hostname, token, organization, provider)
    registered_key_id = ensure_key(hostname, token, organization, key_id, setting("GPG_FINGERPRINT"))

    sums_path = dist / f"{project}_{version}_SHA256SUMS"
    signatures = sorted(dist.glob(f"{project}_{version}_SHA256SUMS*.sig"))
    if not sums_path.is_file():
        die(f"checksum file not found: {sums_path}")
    if len(signatures) != 1:
        die(f"expected one signature file for {sums_path.name}, found {len(signatures)}")

    print(f"Creating provider version {version}")
    status, payload = api(
        "POST",
        f"{provider_url}/versions",
        token,
        {
            "data": {
                "type": "registry-provider-versions",
                "attributes": {"version": version, "key-id": registered_key_id, "protocols": PROTOCOLS},
            }
        },
    )
    expect(status, payload, (201,), f"create version {version}")
    print("Uploading checksum and signature")
    upload(link(payload, "shasums-upload"), sums_path)
    upload(link(payload, "shasums-sig-upload"), signatures[0])

    for checksum, filename, os_name, arch in parse_platforms(sums_path.read_text(), version):
        archive = dist / filename
        if not archive.is_file():
            die(f"archive listed in the checksum file was not downloaded: {filename}")
        if file_sha256(archive) != checksum.lower():
            die(f"checksum mismatch for {filename}")
        print(f"Uploading {os_name}/{arch}")
        status, payload = api(
            "POST",
            f"{provider_url}/versions/{version}/platforms",
            token,
            {
                "data": {
                    "type": "registry-provider-version-platforms",
                    "attributes": {"os": os_name, "arch": arch, "shasum": checksum, "filename": filename},
                }
            },
        )
        expect(status, payload, (201,), f"create platform {os_name}/{arch}")
        upload(link(payload, "provider-binary-upload"), archive)

    print(f"Published {organization}/{provider} {version}")


if __name__ == "__main__":
    main()
