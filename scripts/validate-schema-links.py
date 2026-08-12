#!/usr/bin/env python3
"""Validate JSON syntax and local JSON Schema references without dependencies."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
SCHEMA_ROOT = ROOT / "schemas"


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def resolve_pointer(document, fragment: str):
    current = document
    if not fragment:
        return current
    if not fragment.startswith("/"):
        raise ValueError(f"unsupported JSON pointer fragment: #{fragment}")
    for raw in fragment[1:].split("/"):
        token = unquote(raw).replace("~1", "/").replace("~0", "~")
        if isinstance(current, list):
            current = current[int(token)]
        else:
            current = current[token]
    return current


def main() -> int:
    errors: list[str] = []
    documents: dict[Path, object] = {}
    for path in sorted(ROOT.rglob("*.json")):
        if ".git" in path.parts:
            continue
        try:
            documents[path.resolve()] = json.loads(path.read_text(encoding="utf-8-sig"))
        except Exception as exc:  # noqa: BLE001
            errors.append(f"invalid JSON {path.relative_to(ROOT)}: {exc}")

    for path in sorted(SCHEMA_ROOT.glob("*.json")):
        document = documents.get(path.resolve())
        if document is None:
            continue
        for node in walk(document):
            reference = node.get("$ref")
            if not isinstance(reference, str) or reference.startswith(("http://", "https://")):
                continue
            file_part, _, fragment = reference.partition("#")
            target_path = (path.parent / file_part).resolve() if file_part else path.resolve()
            target = documents.get(target_path)
            if target is None:
                errors.append(f"missing schema target {reference} in {path.name}")
                continue
            try:
                resolve_pointer(target, fragment)
            except Exception as exc:  # noqa: BLE001
                errors.append(f"broken schema reference {reference} in {path.name}: {exc}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print(f"RESULT: failed ({len(errors)} error(s))")
        return 1
    print(f"RESULT: passed ({len(documents)} JSON file(s), local schema references resolved)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

