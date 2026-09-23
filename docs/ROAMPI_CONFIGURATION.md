# `.roampi` configuration version 1

RoamPi reads one machine configuration from `~/.pi/agent/.roampi` on the selected home host and an optional project configuration from `<repository>/.roampi`. The loader binds each project file to the machine from which it was read; that source machine remains the effective project's SSH destination. Both files are untrusted JSON. RoamPi validates the entire update before replacing the last-known-good configuration.

The normative schema is [`roampi.schema.json`](roampi.schema.json). The Swift models and behavioral validator live in `RoamPiCore/Configuration`. Documents are limited to 1,048,576 UTF-8 bytes by `x-roampi-max-document-bytes` and 64 nested JSON container levels by `x-roampi-max-document-depth`; both limits are enforced before adoption. Contract entity identifiers are document-wide unique under `x-roampi-unique-identifiers`. The `x-roampi-valid-references` rule checks local data-source, action, job, and machine references before adoption. `x-roampi-no-secret-fields` recursively rejects credential-bearing keys in arbitrary JSON. `x-roampi-preserve-number-kind` rejects nonintegral source numbers that binary64 would round to an integer, preventing silent number-kind changes. Bounded names, hosts, usernames, and paths declare `x-roampi-no-control-characters`, covering Unicode control and format characters.

## Scope

A document has `version: 1` and one scope:

- `kind: "machine"` defines the home host, participating machines, explicit projects, project overrides, global pages, data sources, actions, and durable jobs.
- `kind: "project"` contributes pages, data sources, actions, and jobs only within the project named by `project.id`.

Configuration is declarative. Version 1 has no JavaScript, Swift, HTML, downloaded view code, fixed pixel positioning, credentials, tokens, passwords, private keys, or stored approvals. Command and prompt strings are inert until the user approves the resolved action or command-backed data source through the app's trust flow.

Settings and configuration recovery are fixed native routes. Configuration cannot rename, replace, or hide them.

## Composition

Pages form a navigation tree through `children`. A page contains native blocks with these declared types:

- `section` and `grid` contain nested blocks;
- `list` and `status` read a declared data source;
- `markdown` displays bounded Markdown text;
- `input` declares text, secure-text, toggle, or selection input;
- `sessions` and `jobs` display RoamPi session or job state; and
- `action` invokes a declared action after the applicable confirmation.

Every block declares `compactSpan` and `regularSpan` from 1 through 12. Optional `minimumWidth` and `preferredWidth` values are semantic layout hints, not fixed coordinates. A preferred width cannot be smaller than its minimum width. The schema marks this cross-field rule with `x-roampi-width-order`; the repository schema validator and Swift runtime both enforce it.

Data sources are one of:

- `static`, containing strict JSON; integral values use the exact signed-or-unsigned 64-bit range, while nonintegral values must fit finite binary64;
- `builtin`, naming typed RoamPi machine, project, session, job, or connection state; or
- `command`, naming a bounded remote command, target machine, required working directory, and result schema. Result schemas allow at most 16 nested `items`/`properties` levels, declared by `x-roampi-max-schema-depth`. The `x-roampi-required-properties` rule requires every `required` name to exist in the same schema's `properties` map. RoamPi must obtain approval for its trust identity before first execution or execution after an identity change; opening or refreshing a page cannot bypass that gate.

Actions are either `prompt` or `command`. They declare a target machine and working directory, prompt delivery (`immediate`, `followUp`, or `steering`), presentation, inline or durable execution, cancellation policy, and concurrency policy.

## Merge and precedence

RoamPi merges a complete update atomically:

1. The machine document contributes first in file order.
2. Project documents sort by `project.id`, then source path.
3. Every project identifier is rewritten into `project%<escaped-project-id>%<escaped-local-id>`. Dots become `%2E`; source identifiers cannot contain `%`, so the separators and mapping are collision-free, including against machine identifiers. References are rewritten with the same rule, and one project cannot address another project's contributions.
4. Session-discovered projects must have globally unique bounded identifiers and names plus safe absolute paths. An update with the same discovered identifier on two machines is rejected rather than silently dropping a project. Valid discoveries sort by machine ID, path, then project ID. Machine-declared projects must use `discovery: "explicit"` and win when IDs match. A matching project file may enrich a discovered project's optional name, group, and visibility.
5. Machine `projectOverrides` apply last. They may rename, regroup, hide, disable all contributions from a project, or disable named local contributions.

Duplicate project documents fail the whole update. A project file whose ID already exists must match that project's declared or discovered source machine and root; unknown machines and source mismatches fail the update. If any source is malformed or invalid, RoamPi keeps the previous effective configuration and returns bounded diagnostics. An initial invalid update produces no effective configuration but still leaves fixed Settings and recovery UI available.

## Trust identity

Approval never lives in a remote `.roampi` file. RoamPi computes a trust identity for every action and command-backed data source from length-prefixed values:

- source file path;
- action or data-source ID;
- action type plus prompt or command content;
- resolved SSH host, username, and port;
- resolved working directory; and
- SHA-256 hash of the canonical validated configuration.

Changing any bound value changes the identity and invalidates a prior approval. Each effective action and data source retains its validated source path and canonical configuration hash, including when the store returns a last-known-good configuration after a rejected update.

## Diagnostics

Diagnostics contain only a fixed code and a bounded JSON location. They do not include source values. The standalone validator emits fixed labels or fixture basenames rather than supplied file or project-root paths. Version 1 reports unsupported versions, malformed or oversized JSON, duplicate object keys, missing or invalid values, duplicate identifiers, unsafe paths, undeclared fields or component types, invalid references, scope violations, and secret-bearing fields.

## Examples

- [`examples/minimal.roampi`](examples/minimal.roampi) is the smallest machine configuration.
- [`examples/developer-dashboard.roampi`](examples/developer-dashboard.roampi) is a fictional multi-machine dashboard with native blocks, data sources, actions, and a durable job.
- [`examples/project.roampi`](examples/project.roampi) is a fictional repository contribution. Validate it with the developer dashboard to exercise merging and namespace isolation.
- [`examples/invalid`](examples/invalid) contains fixtures for control-character names, forward versions, duplicate identifiers, inverted or rounded widths, over-deep result schemas, missing jobs sources, duplicate keys, invalid schema metadata, non-finite, underflowing or out-of-range numbers and widths, oversized integers, secret fields, unsafe paths, and undeclared components.

Validate the schema, every valid example, and every expected invalid fixture with:

```bash
./scripts/validate-roampi-examples.sh
```
