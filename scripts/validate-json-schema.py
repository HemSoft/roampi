#!/usr/bin/env python3
"""Validate repository fixtures against the bounded JSON Schema subset used by RoamPi."""

from __future__ import annotations

import argparse
import json
import re
import sys
from decimal import Decimal
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


def validate(root: dict[str, Any], schema: Any, value: Any, path: str = "$") -> list[str]:
    if schema is True:
        return []
    if schema is False:
        return [f"{path}: schema rejected value"]
    if "$ref" in schema:
        return validate(root, resolve_ref(root, schema["$ref"]), value, path)

    errors: list[str] = []
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
            serialized = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in value]
            if len(serialized) != len(set(serialized)):
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
            value = strict_json_loads(document_path.read_text())
            errors = validate(root, root, value)
        except (json.JSONDecodeError, ValueError):
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
