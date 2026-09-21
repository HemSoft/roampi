#!/usr/bin/env bash
set -euo pipefail

resolved_file="RoamPi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [[ ! -f "$resolved_file" ]]; then
  if grep -q "XCRemoteSwiftPackageReference" RoamPi.xcodeproj/project.pbxproj; then
    echo "Dependency audit failed: Package.resolved is missing for declared dependencies."
    exit 1
  fi
  echo "Dependency audit passed: the project has no Swift package dependencies."
  exit 0
fi

python3 - "$resolved_file" <<'PY'
import json
import os
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

pins = payload.get("pins") or payload.get("object", {}).get("pins", [])
failures = []
repositories = []
for index, pin in enumerate(pins, start=1):
    location = pin.get("location") or pin.get("repositoryURL", "")
    parsed = urlparse(location)
    parts = [part for part in parsed.path.split("/") if part]

    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or len(parts) != 2
    ):
        failures.append(f"pin {index}: location is not a credential-free GitHub repository URL")
        continue

    owner, repository = parts
    repository = re.sub(r"\.git$", "", repository, flags=re.IGNORECASE)
    if not owner or not repository:
        failures.append(f"pin {index}: repository owner or name is missing")
        continue
    repositories.append((index, owner, repository))

headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "RoamPi-dependency-audit",
    "X-GitHub-Api-Version": "2022-11-28",
}
token = os.environ.get("GITHUB_TOKEN")
if token:
    headers["Authorization"] = f"Bearer {token}"

for index, owner, repository in repositories:
    endpoint = f"https://api.github.com/repos/{quote(owner, safe='')}/{quote(repository, safe='')}"
    try:
        with urlopen(Request(endpoint, headers=headers), timeout=20) as response:
            metadata = json.load(response)
    except HTTPError as error:
        failures.append(f"pin {index}: GitHub visibility check returned HTTP {error.code}")
        continue
    except URLError:
        failures.append(f"pin {index}: GitHub visibility check could not connect")
        continue

    if metadata.get("private") is not False:
        failures.append(f"pin {index}: repository is private or visibility is unknown")

if failures:
    print("Dependency audit failed:")
    for failure in failures:
        print(f"- {failure}")
    raise SystemExit(1)

print(f"Dependency audit passed: {len(pins)} package(s) resolve from public GitHub repositories.")
PY
