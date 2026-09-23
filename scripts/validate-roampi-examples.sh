#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_path="$repo_root/Packages/RoamPiCore"

python3 "$repo_root/scripts/validate-json-schema.py" \
    "$repo_root/docs/roampi.schema.json" \
    "$repo_root/docs/examples/minimal.roampi" \
    "$repo_root/docs/examples/developer-dashboard.roampi" \
    "$repo_root/docs/examples/deep-valid-result-schema.roampi" \
    "$repo_root/docs/examples/project.roampi"
python3 "$repo_root/scripts/validate-json-schema.py" --expect-invalid \
    "$repo_root/docs/roampi.schema.json" \
    "$repo_root/docs/examples/invalid/boolean-version.roampi" \
    "$repo_root/docs/examples/invalid/canonical-duplicate-key.roampi" \
    "$repo_root/docs/examples/invalid/control-character-name.roampi" \
    "$repo_root/docs/examples/invalid/control-character-identifier.roampi" \
    "$repo_root/docs/examples/invalid/duplicate-json-key.roampi" \
    "$repo_root/docs/examples/invalid/duplicate-identifiers.roampi" \
    "$repo_root/docs/examples/invalid/duplicate-project-overrides.roampi" \
    "$repo_root/docs/examples/invalid/deep-result-schema.roampi" \
    "$repo_root/docs/examples/invalid/empty-optional-content.roampi" \
    "$repo_root/docs/examples/invalid/forward-version.roampi" \
    "$repo_root/docs/examples/invalid/fractional-required.roampi" \
    "$repo_root/docs/examples/invalid/hostile-exponent.roampi" \
    "$repo_root/docs/examples/invalid/inverted-widths.roampi" \
    "$repo_root/docs/examples/invalid/invalid-supplied-schema-branch.roampi" \
    "$repo_root/docs/examples/invalid/jobs-without-source.roampi" \
    "$repo_root/docs/examples/invalid/missing-action-reference.roampi" \
    "$repo_root/docs/examples/invalid/missing-required-property.roampi" \
    "$repo_root/docs/examples/invalid/non-finite-number.roampi" \
    "$repo_root/docs/examples/invalid/non-string-identifier.roampi" \
    "$repo_root/docs/examples/invalid/non-string-schema.roampi" \
    "$repo_root/docs/examples/invalid/nested-duplicate-identifiers.roampi" \
    "$repo_root/docs/examples/invalid/out-of-range-number.roampi" \
    "$repo_root/docs/examples/invalid/oversized-integer.roampi" \
    "$repo_root/docs/examples/invalid/rounded-width.roampi" \
    "$repo_root/docs/examples/invalid/rounded-inverted-width.roampi" \
    "$repo_root/docs/examples/invalid/rounded-number-kind.roampi" \
    "$repo_root/docs/examples/invalid/secret-field.roampi" \
    "$repo_root/docs/examples/invalid/session-declared-project.roampi" \
    "$repo_root/docs/examples/invalid/too-many-required.roampi" \
    "$repo_root/docs/examples/invalid/underflow-number.roampi" \
    "$repo_root/docs/examples/invalid/underflow-width.roampi" \
    "$repo_root/docs/examples/invalid/unicode-format-name.roampi" \
    "$repo_root/docs/examples/invalid/unpaired-surrogate.roampi" \
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
run_validator --machine "$repo_root/docs/examples/deep-valid-result-schema.roampi"
run_validator --project validation-host /Users/developer/Projects/SampleService "$repo_root/docs/examples/project.roampi"

run_validator --expect 'invalid_value@$.version' --machine "$repo_root/docs/examples/invalid/boolean-version.roampi"
run_validator --expect 'duplicate_key@$[?]' --machine "$repo_root/docs/examples/invalid/canonical-duplicate-key.roampi"
run_validator --expect 'invalid_value@$.machine.homeHost.name' --machine "$repo_root/docs/examples/invalid/control-character-name.roampi"
run_validator --expect 'invalid_value@$.machine.homeHost.id' --machine "$repo_root/docs/examples/invalid/control-character-identifier.roampi"
run_validator --expect 'unsupported_version@$.version' --machine "$repo_root/docs/examples/invalid/forward-version.roampi"
run_validator --expect 'invalid_value@$.dataSources[0].resultSchema.required[0]' --machine "$repo_root/docs/examples/invalid/fractional-required.roampi"
run_validator --expect 'malformed_json@$' --machine "$repo_root/docs/examples/invalid/hostile-exponent.roampi"
run_validator --expect 'duplicate_key@$[?]' --machine "$repo_root/docs/examples/invalid/duplicate-json-key.roampi"
run_validator --expect 'invalid_value@$.dataSources[0].resultSchema.items.items.items.items.items.items.items.items.items.items.items.items.items.items.items.items.items' --machine "$repo_root/docs/examples/invalid/deep-result-schema.roampi"
run_validator --expect 'invalid_value@$.pages[0].blocks[0].content' --machine "$repo_root/docs/examples/invalid/empty-optional-content.roampi"
run_validator --expect 'duplicate_identifier@$.machine.machines[0].id' --machine "$repo_root/docs/examples/invalid/duplicate-identifiers.roampi"
run_validator --expect 'duplicate_identifier@$.machine.projectOverrides[1].projectID' --machine "$repo_root/docs/examples/invalid/duplicate-project-overrides.roampi"
run_validator --expect 'invalid_value@$.pages[0].blocks[0].layout.preferredWidth' --project validation-host /Users/developer/Projects/InvertedWidths "$repo_root/docs/examples/invalid/inverted-widths.roampi"
run_validator --expect 'missing_value@$.dataSources[0].resultSchema.properties[?].items' --machine "$repo_root/docs/examples/invalid/invalid-supplied-schema-branch.roampi"
run_validator --expect 'missing_value@$.pages[0].blocks[0].jobID' --project validation-host /Users/developer/Projects/MissingJobSource "$repo_root/docs/examples/invalid/jobs-without-source.roampi"
run_validator --expect 'invalid_reference@$.pages[0].blocks[0].actionID' --machine "$repo_root/docs/examples/invalid/missing-action-reference.roampi"
run_validator --expect 'invalid_reference@$.dataSources[0].resultSchema.required[0]' --machine "$repo_root/docs/examples/invalid/missing-required-property.roampi"
run_validator --expect 'malformed_json@$' --machine "$repo_root/docs/examples/invalid/non-finite-number.roampi"
run_validator --expect 'invalid_value@$.dataSources[0].id' --machine "$repo_root/docs/examples/invalid/non-string-identifier.roampi"
run_validator --expect 'invalid_value@$.$schema' --machine "$repo_root/docs/examples/invalid/non-string-schema.roampi"
run_validator --expect 'duplicate_identifier@$.pages[0].blocks[0].blocks[1].id' --machine "$repo_root/docs/examples/invalid/nested-duplicate-identifiers.roampi"
run_validator --expect 'malformed_json@$' --machine "$repo_root/docs/examples/invalid/out-of-range-number.roampi"
run_validator --expect 'invalid_value@$.dataSources[0].value' --machine "$repo_root/docs/examples/invalid/oversized-integer.roampi"
run_validator --expect 'invalid_value@$[?]' --machine "$repo_root/docs/examples/invalid/rounded-width.roampi"
run_validator --expect 'invalid_value@$[?]' --machine "$repo_root/docs/examples/invalid/rounded-inverted-width.roampi"
run_validator --expect 'invalid_value@$[?]' --machine "$repo_root/docs/examples/invalid/rounded-number-kind.roampi"
run_validator --expect 'secret_field@$.dataSources[0].value[?]' --machine "$repo_root/docs/examples/invalid/secret-field.roampi"
run_validator --expect 'invalid_value@$.machine.projects[0].discovery' --machine "$repo_root/docs/examples/invalid/session-declared-project.roampi"
run_validator --expect 'invalid_value@$.dataSources[0].resultSchema.required' --machine "$repo_root/docs/examples/invalid/too-many-required.roampi"
run_validator --expect 'invalid_value@$[?]' --machine "$repo_root/docs/examples/invalid/underflow-number.roampi"
run_validator --expect 'invalid_value@$[?]' --project validation-host /Users/developer/Projects/UnderflowWidth "$repo_root/docs/examples/invalid/underflow-width.roampi"
run_validator --expect 'invalid_value@$.machine.homeHost.name' --machine "$repo_root/docs/examples/invalid/unicode-format-name.roampi"
run_validator --expect 'malformed_json@$' --machine "$repo_root/docs/examples/invalid/unpaired-surrogate.roampi"
run_validator --expect 'unsafe_path@$.machine.projects[0].path' --machine "$repo_root/docs/examples/invalid/unsafe-path.roampi"
run_validator --expect 'undeclared_type@$.pages[0].blocks[0].type' --project validation-host /Users/developer/Projects/Unknown "$repo_root/docs/examples/invalid/unknown-component.roampi"

oversized_document="$(mktemp -t roampi-oversized.XXXXXX)"
deep_document="$(mktemp -t roampi-deep.XXXXXX)"
trap 'rm -f "$oversized_document" "$deep_document"' EXIT
python3 - "$repo_root/docs/examples/minimal.roampi" "$oversized_document" "$deep_document" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    document = json.load(source)
oversized = json.loads(json.dumps(document))
oversized["dataSources"] = [{"id": "oversized", "type": "static", "value": "x" * 1_048_576}]
with open(sys.argv[2], "w") as destination:
    json.dump(oversized, destination)
serialized = json.dumps(document)
serialized = serialized[:-1] + ', "untrusted": ' + ('[' * 1100) + '0' + (']' * 1100) + '}'
with open(sys.argv[3], "w") as destination:
    destination.write(serialized)
PY
python3 "$repo_root/scripts/validate-json-schema.py" --expect-invalid \
    "$repo_root/docs/roampi.schema.json" "$oversized_document" "$deep_document"
run_validator --expect 'document_too_large@$' --machine "$oversized_document"
rm -f "$oversized_document" "$deep_document"
trap - EXIT

echo "RoamPi configuration examples passed."
