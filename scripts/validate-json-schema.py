#!/usr/bin/env python3
"""Validate repository fixtures against the bounded JSON Schema subset used by RoamPi."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import unicodedata
from decimal import Decimal, DecimalException
from pathlib import Path
from typing import Any


def reject_nonstandard_constant(value: str) -> None:
    raise ValueError(f"non-standard JSON constant: {value}")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def strict_json_loads(value: str) -> Any:
    return json.loads(
        value,
        parse_constant=reject_nonstandard_constant,
        parse_float=Decimal,
        object_pairs_hook=reject_duplicate_keys,
    )


def resolve_ref(root: dict[str, Any], reference: str) -> Any:
    if not reference.startswith("#/"):
        raise ValueError("only local schema references are supported")
    value: Any = root
    for part in reference[2:].split("/"):
        value = value[part.replace("~1", "/").replace("~0", "~")]
    return value


def is_json_integer(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, Decimal) and value == value.to_integral_value()


def is_json_number(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, Decimal))


def json_equal(left: Any, right: Any) -> bool:
    if is_json_number(left) and is_json_number(right):
        return left == right
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(json_equal(a, b) for a, b in zip(left, right))
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(json_equal(left[key], right[key]) for key in left)
    return left == right


def type_matches(value: Any, expected: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": is_json_integer(value),
        "number": is_json_number(value),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }[expected]


def contract_identifiers(value: Any) -> list[tuple[str, str]]:
    if not isinstance(value, dict):
        return []
    identifiers: list[tuple[str, str]] = []

    def add(item: Any, path: str) -> None:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            identifiers.append((item["id"], f"{path}.id"))

    def add_blocks(blocks: Any, path: str) -> None:
        if not isinstance(blocks, list):
            return
        for index, block in enumerate(blocks):
            block_path = f"{path}[{index}]"
            add(block, block_path)
            if isinstance(block, dict):
                add_blocks(block.get("blocks"), f"{block_path}.blocks")

    def add_pages(pages: Any, path: str) -> None:
        if not isinstance(pages, list):
            return
        for index, page in enumerate(pages):
            page_path = f"{path}[{index}]"
            add(page, page_path)
            if isinstance(page, dict):
                add_blocks(page.get("blocks"), f"{page_path}.blocks")
                add_pages(page.get("children"), f"{page_path}.children")

    machine = value.get("machine")
    if isinstance(machine, dict):
        add(machine.get("homeHost"), "$.machine.homeHost")
        for collection in ("machines", "projects"):
            items = machine.get(collection, [])
            if isinstance(items, list):
                for index, item in enumerate(items):
                    add(item, f"$.machine.{collection}[{index}]")
    add(value.get("project"), "$.project")
    add_pages(value.get("pages"), "$.pages")
    for collection in ("dataSources", "actions", "jobs"):
        items = value.get(collection, [])
        if isinstance(items, list):
            for index, item in enumerate(items):
                add(item, f"$.{collection}[{index}]")
    return identifiers


def validate_unique_identifiers(value: Any) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()
    for identifier, path in contract_identifiers(value):
        if identifier in seen:
            errors.append(f"{path}: identifier is not unique")
        else:
            seen.add(identifier)
    return errors


def validate_contract_references(value: Any) -> list[str]:
    if not isinstance(value, dict):
        return []
    errors: list[str] = []

    def identifier_set(key: str) -> set[Any]:
        items = value.get(key, [])
        return {
            item["id"]
            for item in items
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        } if isinstance(items, list) else set()

    data_source_ids = identifier_set("dataSources")
    action_ids = identifier_set("actions")
    job_ids = identifier_set("jobs")

    def check(reference: Any, identifiers: set[Any], path: str) -> None:
        if isinstance(reference, str) and reference not in identifiers:
            errors.append(f"{path}: reference is not declared")

    def check_blocks(blocks: Any, path: str) -> None:
        if not isinstance(blocks, list):
            return
        for index, block in enumerate(blocks):
            block_path = f"{path}[{index}]"
            if not isinstance(block, dict):
                continue
            if "dataSourceID" in block:
                check(block["dataSourceID"], data_source_ids, f"{block_path}.dataSourceID")
            if "actionID" in block:
                check(block["actionID"], action_ids, f"{block_path}.actionID")
            if "jobID" in block:
                check(block["jobID"], job_ids, f"{block_path}.jobID")
            check_blocks(block.get("blocks"), f"{block_path}.blocks")

    def check_pages(pages: Any, path: str) -> None:
        if not isinstance(pages, list):
            return
        for index, page in enumerate(pages):
            page_path = f"{path}[{index}]"
            if isinstance(page, dict):
                check_blocks(page.get("blocks"), f"{page_path}.blocks")
                check_pages(page.get("children"), f"{page_path}.children")

    check_pages(value.get("pages"), "$.pages")
    jobs = value.get("jobs", [])
    for index, job in enumerate(jobs if isinstance(jobs, list) else []):
        if isinstance(job, dict) and "actionID" in job:
            check(job["actionID"], action_ids, f"$.jobs[{index}].actionID")

    machine = value.get("machine")
    if isinstance(machine, dict):
        machines = machine.get("machines", [])
        machine_ids = {
            item["id"]
            for item in [machine.get("homeHost"), *(machines if isinstance(machines, list) else [])]
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        projects = machine.get("projects", [])
        for index, project in enumerate(projects if isinstance(projects, list) else []):
            if isinstance(project, dict):
                check(project.get("machineID"), machine_ids, f"$.machine.projects[{index}].machineID")
        sources = value.get("dataSources", [])
        for index, source in enumerate(sources if isinstance(sources, list) else []):
            if isinstance(source, dict) and "targetMachineID" in source:
                check(source["targetMachineID"], machine_ids, f"$.dataSources[{index}].targetMachineID")
        actions = value.get("actions", [])
        for index, action in enumerate(actions if isinstance(actions, list) else []):
            if isinstance(action, dict) and isinstance(action.get("target"), dict):
                check(action["target"].get("machineID"), machine_ids, f"$.actions[{index}].target.machineID")
    return errors


PROHIBITED_KEYS = {
    "accesskeyid", "accesstoken", "apikey", "authorization", "bearer", "clientsecret", "cookie", "credential",
    "credentials", "hotp", "jwe", "jwt", "mnemonic", "otp", "passcode", "passphrase", "passwd", "password", "pin",
    "privatekey", "providerkey", "pwd", "secret", "secretaccesskey", "secretkey", "seedphrase", "sessioncookie", "token", "totp",
}
PROHIBITED_QUALIFIERS = (
    "contents", "material", "content", "encoded", "header", "base64", "string", "value", "data", "file",
    "hash", "json", "path", "pem",
)


def prohibited_qualifier_sequence(value: str) -> bool:
    if not value:
        return False
    remainder = value
    while remainder:
        if remainder in {"s", "es"} or remainder.isdigit():
            return True
        if remainder.startswith("v") and len(remainder) > 1 and remainder[1:].isdigit():
            return True
        qualifier = next((item for item in PROHIBITED_QUALIFIERS if remainder.startswith(item)), None)
        if qualifier is None:
            return False
        remainder = remainder[len(qualifier):]
    return True


def prohibited_key(value: str) -> bool:
    normalized = "".join(character for character in value.lower() if character.isalnum())
    if normalized in PROHIBITED_KEYS:
        return True
    if any(
        normalized.endswith(key) or normalized.endswith(key + "s") or normalized.endswith(key + "es")
        for key in PROHIBITED_KEYS
    ):
        return True
    return any(
        normalized.startswith(key) and prohibited_qualifier_sequence(normalized[len(key):])
        for key in PROHIBITED_KEYS
    )


def validate_no_secret_fields(value: Any, path: str = "$") -> list[str]:
    errors: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}[?]"
            if prohibited_key(key):
                errors.append(f"{child_path}: secret-bearing field is prohibited")
            else:
                errors.extend(validate_no_secret_fields(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(validate_no_secret_fields(child, f"{path}[{index}]"))
    return errors


def validate_number_kind_preservation(value: Any, path: str = "$") -> list[str]:
    errors: list[str] = []
    if isinstance(value, Decimal) and value != value.to_integral_value():
        floating = float(value)
        if math.isfinite(floating) and floating.is_integer():
            errors.append(f"{path}: nonintegral number rounds to an integer")
    elif isinstance(value, dict):
        for child in value.values():
            errors.extend(validate_number_kind_preservation(child, f"{path}[?]"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(validate_number_kind_preservation(child, f"{path}[{index}]"))
    return errors


def validate_document_depth(value: Any, path: str, depth: int, maximum: int) -> list[str]:
    if depth > maximum:
        return [f"{path}: document exceeds maximum depth"]
    errors: list[str] = []
    if isinstance(value, dict):
        for child in value.values():
            errors.extend(validate_document_depth(child, f"{path}[?]", depth + 1, maximum))
    elif isinstance(value, list):
        for child in value:
            errors.extend(validate_document_depth(child, f"{path}[]", depth + 1, maximum))
    return errors


def validate_schema_depth(value: Any, path: str, depth: int, maximum: int) -> list[str]:
    if depth > maximum:
        return [f"{path}: result schema exceeds maximum depth"]
    if not isinstance(value, dict):
        return []
    errors: list[str] = []
    if isinstance(value.get("items"), dict):
        errors.extend(validate_schema_depth(value["items"], f"{path}.items", depth + 1, maximum))
    if isinstance(value.get("properties"), dict):
        for child in value["properties"].values():
            errors.extend(validate_schema_depth(child, f"{path}.properties[?]", depth + 1, maximum))
    return errors


def validate(root: dict[str, Any], schema: Any, value: Any, path: str = "$") -> list[str]:
    if schema is True:
        return []
    if schema is False:
        return [f"{path}: schema rejected value"]
    if "$ref" in schema:
        errors = validate(root, resolve_ref(root, schema["$ref"]), value, path)
        if "x-roampi-max-schema-depth" in schema:
            errors.extend(validate_schema_depth(value, path, 0, schema["x-roampi-max-schema-depth"]))
        return errors

    errors: list[str] = []
    if "x-roampi-max-document-depth" in schema:
        depth_errors = validate_document_depth(value, path, 0, schema["x-roampi-max-document-depth"])
        if depth_errors:
            return depth_errors
    if schema.get("x-roampi-unique-identifiers"):
        errors.extend(validate_unique_identifiers(value))
    if schema.get("x-roampi-valid-references"):
        errors.extend(validate_contract_references(value))
    if schema.get("x-roampi-no-secret-fields"):
        errors.extend(validate_no_secret_fields(value))
    if schema.get("x-roampi-preserve-number-kind"):
        errors.extend(validate_number_kind_preservation(value))
    expected_type = schema.get("type")
    if expected_type is not None:
        allowed = [expected_type] if isinstance(expected_type, str) else expected_type
        if not any(type_matches(value, item) for item in allowed):
            return [f"{path}: expected {expected_type}"]
    if "const" in schema and not json_equal(value, schema["const"]):
        errors.append(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and not any(json_equal(value, item) for item in schema["enum"]):
        errors.append(f"{path}: value is not declared")

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: string is too short")
        if len(value) > schema.get("maxLength", sys.maxsize):
            errors.append(f"{path}: string is too long")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errors.append(f"{path}: string does not match pattern")
        if schema.get("x-roampi-no-control-characters") and any(
            unicodedata.category(character) in {"Cc", "Cf"} for character in value
        ):
            errors.append(f"{path}: string contains a control character")

    if is_json_number(value):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: number is below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: number is above maximum")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            errors.append(f"{path}: number is not above exclusive minimum")

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path}: array has too few items")
        if schema.get("uniqueItems"):
            if any(
                json_equal(value[left], value[right])
                for left in range(len(value))
                for right in range(left + 1, len(value))
            ):
                errors.append(f"{path}: array items are not unique")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(validate(root, schema["items"], item, f"{path}[{index}]"))

    if isinstance(value, dict):
        for required in schema.get("required", []):
            if required not in value:
                errors.append(f"{path}.{required}: required value is missing")
        properties = schema.get("properties", {})
        for key, item in value.items():
            if key in properties:
                errors.extend(validate(root, properties[key], item, f"{path}.{key}"))
            elif isinstance(schema.get("additionalProperties"), dict):
                errors.extend(validate(root, schema["additionalProperties"], item, f"{path}[?]"))
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}[?]: property is not declared")

    if "x-roampi-max-schema-depth" in schema:
        errors.extend(validate_schema_depth(value, path, 0, schema["x-roampi-max-schema-depth"]))

    if schema.get("x-roampi-required-properties") and isinstance(value, dict):
        properties = value.get("properties", {})
        required = value.get("required", [])
        if isinstance(properties, dict) and isinstance(required, list):
            for name in required:
                if isinstance(name, str) and name not in properties:
                    errors.append(f"{path}.required: required name is not declared in properties")

    if schema.get("x-roampi-width-order") and isinstance(value, dict):
        minimum = value.get("minimumWidth")
        preferred = value.get("preferredWidth")
        if is_json_number(minimum) and is_json_number(preferred):
            if preferred < minimum:
                errors.append(f"{path}.preferredWidth: preferred width is below minimum width")

    for subschema in schema.get("allOf", []):
        errors.extend(validate(root, subschema, value, path))
    if "anyOf" in schema:
        if not any(not validate(root, subschema, value, path) for subschema in schema["anyOf"]):
            errors.append(f"{path}: expected at least one matching schema")
    if "oneOf" in schema:
        matches = sum(not validate(root, subschema, value, path) for subschema in schema["oneOf"])
        if matches != 1:
            errors.append(f"{path}: expected exactly one matching schema")
    if "not" in schema and not validate(root, schema["not"], value, path):
        errors.append(f"{path}: forbidden schema matched")
    if "if" in schema and not validate(root, schema["if"], value, path):
        errors.extend(validate(root, schema.get("then", True), value, path))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("schema", type=Path)
    parser.add_argument("documents", nargs="+", type=Path)
    parser.add_argument("--expect-invalid", action="store_true")
    arguments = parser.parse_args()

    root = strict_json_loads(arguments.schema.read_text())
    failed = False
    for document_path in arguments.documents:
        try:
            document_data = document_path.read_bytes()
            maximum_bytes = root.get("x-roampi-max-document-bytes")
            if isinstance(maximum_bytes, int) and len(document_data) > maximum_bytes:
                errors = ["$: document exceeds maximum byte count"]
            else:
                value = strict_json_loads(document_data.decode("utf-8"))
                errors = validate(root, root, value)
        except (DecimalException, json.JSONDecodeError, RecursionError, UnicodeDecodeError, ValueError):
            errors = ["$: malformed JSON"]
        if arguments.expect_invalid:
            if not errors:
                print(f"unexpected-valid {document_path.name}", file=sys.stderr)
                failed = True
            else:
                print(f"schema-expected-invalid {document_path.name}")
        elif errors:
            print(f"schema-invalid {document_path.name}", file=sys.stderr)
            for error in errors[:20]:
                print(f"  {error}", file=sys.stderr)
            failed = True
        else:
            print(f"schema-valid {document_path.name}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
