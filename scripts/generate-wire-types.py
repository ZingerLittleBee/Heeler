#!/usr/bin/env python3
"""Generate Swift Codable wire types from herdr's JSON API schema (#7).

Usage:
    scripts/generate-wire-types.py            # runs `herdr api schema --json`
    scripts/generate-wire-types.py --schema herdr-schema.json
    scripts/generate-wire-types.py --check    # fail if the committed output is stale

Output: Sources/Heeler/Transport/Generated/HerdrAPITypes.swift

Scope and shape are deliberate (see issue #7 and spec #20):

- Only the stable data types for the methods this app uses are generated.
  The request/response/event envelopes and the method/event enums stay
  hand-written in HerdrWire.swift / HerdrEvents.swift, as do the
  `events.subscribe` params (they are the event-kind enum in disguise).
- The schema's `$ref`s use non-standard nested paths
  (`#/schemas/<schema>/$defs/X`) and type names repeat across the five
  top-level schemas. Preprocessing flattens all `$defs` into one namespace
  and fails loudly if two same-named defs ever stop being structurally
  identical (verified against herdr 0.7.5).
- String enums are emitted as raw-string `RawRepresentable` structs, not
  Swift enums: herdr's API has no stability guarantee, so unknown values
  must decode intact instead of failing.
- `result` payloads are the tagged variants of the success_response schema;
  each wanted variant becomes a `<Tag>Response` struct with the redundant
  `type` tag dropped (the envelope already establishes success).

The output is deterministic (sorted types and fields, no timestamps), so
regenerating against an unchanged schema is a no-op diff.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPO_ROOT / "Sources/Heeler/Transport/Generated/HerdrAPITypes.swift"

# The v1 method surface (#7). Params types are derived from the schema's
# request oneOf; empty params objects are skipped (the hand-written envelope
# sends `"params": {}` for those).
METHODS = [
    "ping",
    "agent.explain",
    "agent.focus",
    "agent.get",
    "agent.list",
    "agent.prompt",
    "agent.read",
    "agent.rename",
    "agent.send_keys",
    "agent.start",
    "events.subscribe",
    "tab.create",
    "pane.read",
    "pane.close",
    "session.snapshot",
    "workspace.rename",
    "worktree.create",
    "worktree.list",
    "worktree.remove",
]

# Params defs excluded from generation even when a wanted method uses them.
EXCLUDED_PARAMS_DEFS = {
    # Empty objects; requests without params go through the hand-written
    # envelope's empty-params path.
    "EmptyParams",
    "PingParams",
    # The subscription union restates the event-kind enums, which are
    # hand-written (HerdrEvents.swift); HerdrWire builds these params.
    "EventsSubscribeParams",
}

# success_response ResponseResult variants (by `type` tag) the app consumes.
# The schema does not link methods to result variants, so this list is
# curated: it covers every result our METHODS can produce.
RESULT_TAGS = [
    "pong",  # ping
    "agent_explain",  # agent.explain
    "agent_info",  # agent.get, agent.focus, agent.rename
    "agent_prompted",  # agent.prompt
    "agent_started",  # agent.start
    "agent_list",  # agent.list
    "pane_read",  # pane.read, agent.read
    "session_snapshot",  # session.snapshot
    "subscription_started",  # events.subscribe ack
    "tab_created",  # tab.create
    "ok",  # pane.close
    "workspace_info",  # workspace.rename
    "worktree_created",  # worktree.create
    "worktree_list",  # worktree.list
    "worktree_removed",  # worktree.remove
]

# Wire-name overrides for members whose mechanical camelCase would be a Swift
# keyword or collide with established naming.
MEMBER_NAME_OVERRIDES = {
    "protocol": "protocolVersion",
}

# snake_case segments spelled as acronyms in Swift member names.
ACRONYMS = {"id": "ID", "ansi": "ANSI", "url": "URL"}

REF_PATTERN = re.compile(r"^#/schemas/(?P<schema>[a-z_]+)/\$defs/(?P<name>\w+)$")


def fail(message: str) -> "sys.NoReturn":
    print(f"generate-wire-types: {message}", file=sys.stderr)
    sys.exit(1)


def load_schema(path: str | None) -> dict:
    if path is not None:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    try:
        completed = subprocess.run(
            ["herdr", "api", "schema", "--json"], capture_output=True, text=True, check=True
        )
    except FileNotFoundError:
        fail("herdr not found on PATH; pass --schema <file> instead")
    except subprocess.CalledProcessError as error:
        fail(f"`herdr api schema --json` failed: {error.stderr.strip()}")
    return json.loads(completed.stdout)


def normalized(definition: object) -> str:
    """Structural fingerprint with `$ref` schema prefixes stripped, so
    same-named defs from different top-level schemas compare equal."""
    text = json.dumps(definition, sort_keys=True)
    return re.sub(r'"#/schemas/[a-z_]+/\$defs/(\w+)"', r'"#/\1"', text)


def flatten_defs(schemas: dict) -> dict:
    """One namespace for every `$defs` entry across the five top-level
    schemas. Collisions must be structurally identical."""
    flat: dict = {}
    origin: dict = {}
    for schema_name in sorted(schemas):
        for def_name, definition in schemas[schema_name].get("$defs", {}).items():
            if def_name in flat and normalized(flat[def_name]) != normalized(definition):
                fail(
                    f"$defs/{def_name} differs between schemas "
                    f"'{origin[def_name]}' and '{schema_name}'; the flat namespace "
                    "assumption broke — disambiguate before regenerating"
                )
            flat.setdefault(def_name, definition)
            origin.setdefault(def_name, schema_name)
    return flat


def ref_name(ref: str) -> str:
    match = REF_PATTERN.match(ref)
    if match is None:
        fail(f"unrecognized $ref shape: {ref}")
    return match.group("name")


def pascal_case(snake: str) -> str:
    return "".join(part.capitalize() for part in snake.split("_"))


def member_name(wire_name: str) -> str:
    if wire_name in MEMBER_NAME_OVERRIDES:
        return MEMBER_NAME_OVERRIDES[wire_name]
    head, *rest = wire_name.split("_")
    return head + "".join(ACRONYMS.get(part, part.capitalize()) for part in rest)


class SwiftType:
    """A resolved Swift type for one schema node: its spelling plus whether
    the node itself allows null."""

    def __init__(self, spelling: str, nullable: bool = False):
        self.spelling = spelling
        self.nullable = nullable


def resolve_type(node: object, context: str, needed: set[str]) -> SwiftType:
    if node is True:
        return SwiftType("JSONValue")
    if not isinstance(node, dict):
        fail(f"{context}: unhandled schema node {node!r}")

    if "$ref" in node:
        name = ref_name(node["$ref"])
        needed.add(name)
        return SwiftType(name)

    if "anyOf" in node:
        variants = node["anyOf"]
        non_null = [v for v in variants if v != {"type": "null"}]
        if len(non_null) != 1 or len(variants) != 2:
            fail(f"{context}: unhandled anyOf shape {variants!r}")
        inner = resolve_type(non_null[0], context, needed)
        return SwiftType(inner.spelling, nullable=True)

    kind = node.get("type")
    nullable = False
    if isinstance(kind, list):
        non_null = [k for k in kind if k != "null"]
        if len(non_null) != 1:
            fail(f"{context}: unhandled type union {kind!r}")
        kind = non_null[0]
        nullable = True

    if "enum" in node:
        fail(f"{context}: inline enum; name it as a $def before generating")

    if kind == "string":
        return SwiftType("String", nullable)
    if kind == "integer":
        return SwiftType("Int", nullable)
    if kind == "number":
        return SwiftType("Double", nullable)
    if kind == "boolean":
        return SwiftType("Bool", nullable)
    if kind == "array":
        item = resolve_type(node.get("items", True), f"{context}[]", needed)
        if item.nullable:
            fail(f"{context}: arrays of nullable items are unhandled")
        return SwiftType(f"[{item.spelling}]", nullable)
    if kind == "object":
        if "properties" in node:
            fail(f"{context}: anonymous nested object; name it as a $def")
        extra = node.get("additionalProperties")
        if extra is not None:
            value = resolve_type(extra, f"{context}{{}}", needed)
            if value.nullable:
                fail(f"{context}: maps with nullable values are unhandled")
            return SwiftType(f"[String: {value.spelling}]", nullable)
        return SwiftType("JSONValue", nullable)
    fail(f"{context}: unhandled schema node {node!r}")


class Field:
    def __init__(self, wire_name: str, node: object, required: bool, context: str, needed: set[str]):
        resolved = resolve_type(node, f"{context}.{wire_name}", needed)
        self.wire_name = wire_name
        self.name = member_name(wire_name)
        self.optional = resolved.nullable or not required
        self.swift_type = resolved.spelling + ("?" if self.optional else "")


def emit_struct(name: str, doc: str, fields: list[Field]) -> str:
    lines = [f"/// {doc}"]
    if not fields:
        lines.append(f"struct {name}: Codable, Equatable, Sendable {{}}")
        return "\n".join(lines)

    lines.append(f"struct {name}: Codable, Equatable, Sendable {{")
    for field in fields:
        lines.append(f"    let {field.name}: {field.swift_type}")

    # Required members first so call sites read `Type(key: ..., options...)`.
    ordered = [f for f in fields if not f.optional] + [f for f in fields if f.optional]
    parameters = ", ".join(
        f"{f.name}: {f.swift_type}" + (" = nil" if f.optional else "") for f in ordered
    )
    signature = f"    init({parameters}) {{"
    if len(signature) > 96:
        wrapped = ",\n        ".join(
            f"{f.name}: {f.swift_type}" + (" = nil" if f.optional else "") for f in ordered
        )
        lines.append("")
        lines.append("    init(")
        lines.append(f"        {wrapped}")
        lines.append("    ) {")
    else:
        lines.append("")
        lines.append(signature)
    for field in ordered:
        lines.append(f"        self.{field.name} = {field.name}")
    lines.append("    }")

    if any(field.name != field.wire_name for field in fields):
        lines.append("")
        lines.append("    private enum CodingKeys: String, CodingKey {")
        for field in fields:
            if field.name == field.wire_name:
                lines.append(f"        case {field.name}")
            else:
                lines.append(f'        case {field.name} = "{field.wire_name}"')
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines)


def emit_string_wrapper(name: str, doc: str, values: list[str]) -> str:
    lines = [
        f"/// {doc}",
        "///",
        "/// Closed set in the source schema, but herdr's API has no stability",
        "/// guarantee — unknown raw values decode intact instead of failing.",
        f"struct {name}: RawRepresentable, Codable, Hashable, Sendable {{",
        "    let rawValue: String",
        "",
        "    init(rawValue: String) {",
        "        self.rawValue = rawValue",
        "    }",
        "",
    ]
    for value in values:
        lines.append(f'    static let {member_name(value)} = {name}(rawValue: "{value}")')
    lines.append("}")
    return "\n".join(lines)


def object_fields(definition: dict, context: str, needed: set[str], skip: set[str] = frozenset()) -> list[Field]:
    required = set(definition.get("required", []))
    fields = [
        Field(wire_name, node, wire_name in required, context, needed)
        for wire_name, node in definition.get("properties", {}).items()
        if wire_name not in skip
    ]
    return sorted(fields, key=lambda f: f.name)


def generate(schema: dict) -> str:
    schemas = schema["schemas"]
    defs = flatten_defs(schemas)

    method_params: dict[str, str] = {}
    for variant in schemas["request"]["oneOf"]:
        method_params[variant["properties"]["method"]["const"]] = ref_name(
            variant["properties"]["params"]["$ref"]
        )
    missing = [m for m in METHODS if m not in method_params]
    if missing:
        fail(f"methods not in schema: {missing}")

    result_variants: dict[str, dict] = {}
    for variant in schemas["success_response"]["$defs"]["ResponseResult"]["oneOf"]:
        result_variants[variant["properties"]["type"]["const"]] = variant
    missing = [t for t in RESULT_TAGS if t not in result_variants]
    if missing:
        fail(f"result tags not in schema: {missing}")

    needed: set[str] = set()
    emitted: dict[str, str] = {}

    # Result payload wrappers, named from their tag.
    for tag in RESULT_TAGS:
        name = pascal_case(tag) + "Response"
        doc = f'The `"type":"{tag}"` result payload of herdr\'s success_response schema.'
        fields = object_fields(result_variants[tag], name, needed, skip={"type"})
        emitted[name] = emit_struct(name, doc, fields)

    # Params for the wanted methods.
    for method in METHODS:
        def_name = method_params[method]
        if def_name not in EXCLUDED_PARAMS_DEFS:
            needed.add(def_name)

    # Transitive closure over $defs.
    pending = set(needed)
    while pending:
        name = pending.pop()
        if name in emitted:
            continue
        if name not in defs:
            fail(f"$defs/{name} not found in any schema")
        definition = defs[name]
        doc = f"herdr schema `$defs/{name}`."
        if definition.get("enum") is not None:
            if definition.get("type") != "string":
                fail(f"$defs/{name}: only string enums are handled")
            emitted[name] = emit_string_wrapper(name, doc, definition["enum"])
            continue
        if definition.get("type") != "object":
            fail(f"$defs/{name}: unhandled top-level shape")
        before = set(needed)
        fields = object_fields(definition, name, needed)
        emitted[name] = emit_struct(name, doc, fields)
        pending |= needed - before

    header = "\n".join(
        [
            "// Generated by scripts/generate-wire-types.py — DO NOT EDIT.",
            f"// Source: `herdr api schema --json` "
            f"(protocol {schema['protocol']}, schema_version {schema['schema_version']}).",
            "//",
            "// Stable data types only: the request/response/event envelopes, the",
            "// method/event enums, and the events.subscribe params stay hand-written",
            "// (HerdrWire.swift, HerdrEvents.swift). `<Tag>Response` structs are the",
            "// tagged `result` variants of the success_response schema with the",
            "// redundant `type` tag dropped. Decoding is lenient by construction:",
            "// unknown fields are ignored and closed string sets are raw-string",
            "// wrappers, because herdr's API has no stability guarantee.",
            "",
            "import Foundation",
        ]
    )
    body = "\n\n".join(emitted[name] for name in sorted(emitted))
    return f"{header}\n\n{body}\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema", help="read the schema from a file instead of running herdr")
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed output is up to date; write nothing",
    )
    arguments = parser.parse_args()

    output = generate(load_schema(arguments.schema))
    if arguments.check:
        current = OUTPUT_PATH.read_text(encoding="utf-8") if OUTPUT_PATH.exists() else ""
        if current != output:
            fail(f"{OUTPUT_PATH.relative_to(REPO_ROOT)} is stale; rerun scripts/generate-wire-types.py")
        print("up to date")
        return
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(output, encoding="utf-8")
    print(f"wrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
