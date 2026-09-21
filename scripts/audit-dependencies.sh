#!/usr/bin/env bash
set -euo pipefail

resolved_file="RoamPi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [[ ! -f "$resolved_file" ]]; then
  echo "Dependency audit passed: the project has no Swift package dependencies."
  exit 0
fi

python3 - "$resolved_file" <<'PY'
import json
import sys
from urllib.parse import urlparse

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

pins = payload.get("pins") or payload.get("object", {}).get("pins", [])
rejected = []
for pin in pins:
    location = pin.get("location") or pin.get("repositoryURL", "")
    parsed = urlparse(location)
    if parsed.scheme != "https" or parsed.hostname != "github.com":
        rejected.append(location or "<missing location>")

if rejected:
    print("Dependency audit failed. Packages must use public https://github.com URLs:")
    for location in rejected:
        print(f"- {location}")
    raise SystemExit(1)

print(f"Dependency audit passed: {len(pins)} package(s) resolve from public GitHub URLs.")
PY
