#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_path="$repo_root/Packages/RoamPiCore"

python3 "$repo_root/scripts/validate-json-schema.py" \
    "$repo_root/docs/roampi.schema.json" \
    "$repo_root/docs/examples/minimal.roampi" \
    "$repo_root/docs/examples/developer-dashboard.roampi" \
    "$repo_root/docs/examples/project.roampi"
python3 "$repo_root/scripts/validate-json-schema.py" --expect-invalid \
    "$repo_root/docs/roampi.schema.json" \
    "$repo_root/docs/examples/invalid/control-character-name.roampi" \
    "$repo_root/docs/examples/invalid/forward-version.roampi" \
    "$repo_root/docs/examples/invalid/jobs-without-source.roampi" \
    "$repo_root/docs/examples/invalid/secret-field.roampi" \
    "$repo_root/docs/examples/invalid/unsafe-path.roampi" \
    "$repo_root/docs/examples/invalid/unknown-component.roampi"

swift build --package-path "$package_path" --product RoamPiConfigValidator >/dev/null
bin_path="$(swift build --package-path "$package_path" --show-bin-path)"
validator="$bin_path/RoamPiConfigValidator"

run_validator() {
    local output
    output="$("$validator" "$@")"
    if [[ "$output" == *"$repo_root"* || "$output" == *"/Users/developer/Projects"* ]]; then
        echo "validator output exposed a project path" >&2
        return 1
    fi
    printf '%s\n' "$output"
}

run_validator --machine "$repo_root/docs/examples/minimal.roampi"
run_validator --machine "$repo_root/docs/examples/developer-dashboard.roampi"
run_validator --project-root /Users/developer/Projects/SampleService "$repo_root/docs/examples/project.roampi"

run_validator --expect 'invalid_value@$.machine.homeHost.name' --machine "$repo_root/docs/examples/invalid/control-character-name.roampi"
run_validator --expect 'unsupported_version@$.version' --machine "$repo_root/docs/examples/invalid/forward-version.roampi"
run_validator --expect 'duplicate_identifier@$.machine.machines[0].id' --machine "$repo_root/docs/examples/invalid/duplicate-identifiers.roampi"
run_validator --expect 'missing_value@$.pages[0].blocks[0].jobID' --project-root /Users/developer/Projects/MissingJobSource "$repo_root/docs/examples/invalid/jobs-without-source.roampi"
run_validator --expect 'secret_field@$[?]' --machine "$repo_root/docs/examples/invalid/secret-field.roampi"
run_validator --expect 'unsafe_path@$.machine.projects[0].path' --machine "$repo_root/docs/examples/invalid/unsafe-path.roampi"
run_validator --expect 'undeclared_type@$.pages[0].blocks[0].type' --project-root /Users/developer/Projects/Unknown "$repo_root/docs/examples/invalid/unknown-component.roampi"

echo "RoamPi configuration examples passed."
