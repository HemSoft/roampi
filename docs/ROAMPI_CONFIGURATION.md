# `.roampi` configuration version 1

RoamPi reads one machine configuration from `~/.pi/agent/.roampi` on the selected home host and an optional project configuration from `<repository>/.roampi`. Both files are untrusted JSON. RoamPi validates the entire update before replacing the last-known-good configuration.

The normative schema is [`roampi.schema.json`](roampi.schema.json). The Swift models and behavioral validator live in `RoamPiCore/Configuration`.

## Scope

A document has `version: 1` and one scope:

- `kind: "machine"` defines the home host, participating machines, explicit projects, project overrides, global pages, data sources, actions, and durable jobs.
- `kind: "project"` contributes pages, data sources, actions, and jobs only within the project named by `project.id`.

Configuration is declarative. Version 1 has no JavaScript, Swift, HTML, downloaded view code, fixed pixel positioning, credentials, tokens, passwords, private keys, or stored approvals. Command and prompt strings are inert until the user approves the resolved action through the app's action trust flow.

Settings and configuration recovery are fixed native routes. Configuration cannot rename, replace, or hide them.

## Composition

Pages form a navigation tree through `children`. A page contains native blocks with these declared types:

- `section` and `grid` contain nested blocks;
- `list` and `status` read a declared data source;
- `markdown` displays bounded Markdown text;
- `input` declares text, secure-text, toggle, or selection input;
- `sessions` and `jobs` display RoamPi session or job state; and
- `action` invokes a declared action after the applicable confirmation.

Every block declares `compactSpan` and `regularSpan` from 1 through 12. Optional `minimumWidth` and `preferredWidth` values are semantic layout hints, not fixed coordinates. A preferred width cannot be smaller than its minimum width.

Data sources are one of:

- `static`, containing JSON;
- `builtin`, naming typed RoamPi machine, project, session, job, or connection state; or
- `command`, naming a remote command, target machine, working directory, and result schema.

Actions are either `prompt` or `command`. They declare a target machine and working directory, prompt delivery (`immediate`, `followUp`, or `steering`), presentation, inline or durable execution, cancellation policy, and concurrency policy.

## Merge and precedence

RoamPi merges a complete update atomically:

1. The machine document contributes first in file order.
2. Project documents sort by `project.id`, then source path.
3. Every project identifier is rewritten into `project.<project-id>.<local-id>`. References are rewritten with it, so one project cannot address another project's contributions.
4. Session-discovered projects sort by machine ID, path, then project ID. Explicit machine declarations win when IDs match.
5. Machine `projectOverrides` apply last. They may rename, regroup, hide, disable all contributions from a project, or disable named local contributions.

Duplicate project documents fail the whole update. If any source is malformed or invalid, RoamPi keeps the previous effective configuration and returns bounded diagnostics. An initial invalid update produces no effective configuration but still leaves fixed Settings and recovery UI available.

## Trust identity

Approval never lives in a remote `.roampi` file. RoamPi computes an action trust identity from length-prefixed values:

- source file path;
- action ID;
- action type and prompt or command content;
- resolved host;
- resolved working directory; and
- SHA-256 hash of the canonical validated configuration.

Changing any bound value changes the identity and invalidates a prior approval.

## Diagnostics

Diagnostics contain only a fixed code and a bounded JSON location. They do not include source values. Version 1 reports unsupported versions, malformed or oversized JSON, missing or invalid values, duplicate identifiers, unsafe paths, undeclared fields or component types, invalid references, scope violations, and secret-bearing fields.

## Examples

- [`examples/minimal.roampi`](examples/minimal.roampi) is the smallest machine configuration.
- [`examples/developer-dashboard.roampi`](examples/developer-dashboard.roampi) is a fictional multi-machine dashboard with native blocks, data sources, actions, and a durable job.
- [`examples/project.roampi`](examples/project.roampi) is a fictional repository contribution. Validate it with the developer dashboard to exercise merging and namespace isolation.
- [`examples/invalid`](examples/invalid) contains fixtures for forward versions, duplicate identifiers, secret fields, unsafe paths, and undeclared components.

Validate the schema, every valid example, and every expected invalid fixture with:

```bash
./scripts/validate-roampi-examples.sh
```
