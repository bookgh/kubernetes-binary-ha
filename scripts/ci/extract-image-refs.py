#!/usr/bin/env python3
"""Extract deterministic image references from offline YAML/JSON artifacts."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

IMAGE_KEYS = {"image", "imageref", "image_ref", "imagename"}
IMAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$")


def normalize_image(value: str, source: Path) -> str:
    image = value.strip().strip("\"'")
    if not image or image.startswith("__") or "${" in image:
        raise ValueError(f"{source}: unresolved image placeholder: {value!r}")
    if not IMAGE_RE.fullmatch(image):
        raise ValueError(f"{source}: invalid image reference: {value!r}")

    name, separator, digest = image.partition("@")
    last = name.rsplit("/", 1)[-1]
    if ":" not in last and not separator:
        raise ValueError(f"{source}: image must be pinned by tag or digest: {image}")

    parts = name.split("/")
    if len(parts) == 1:
        name = f"docker.io/library/{name}"
    elif "." not in parts[0] and ":" not in parts[0] and parts[0] != "localhost":
        name = f"docker.io/{name}"
    elif parts[0] == "index.docker.io":
        parts[0] = "docker.io"
        name = "/".join(parts)
    if name.startswith("docker.io/") and len(name.split("/")) == 2:
        name = name.replace("docker.io/", "docker.io/library/", 1)
    return f"{name}@{digest}" if separator else name


def walk(node, source: Path, found: set[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if str(key).lower() in IMAGE_KEYS and isinstance(value, str):
                found.add(normalize_image(value, source))
            walk(value, source, found)
    elif isinstance(node, list):
        for value in node:
            walk(value, source, found)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error(f"manifest directory does not exist: {args.root}")

    found: set[str] = set()
    files = sorted(
        path for path in args.root.rglob("*")
        if path.is_file() and path.suffix.lower() in {".yaml", ".yml", ".json"}
    )
    if not files:
        raise SystemExit(f"No YAML/JSON manifests found under {args.root}")

    for path in files:
        try:
            with path.open(encoding="utf-8") as stream:
                for document in yaml.safe_load_all(stream):
                    walk(document, path, found)
        except (yaml.YAMLError, UnicodeError) as error:
            raise SystemExit(f"Failed to parse {path}: {error}") from error

    if not found:
        raise SystemExit("No image references found in offline deployment artifacts")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "".join(f"{image}\n" for image in sorted(found)),
        encoding="utf-8",
    )
    print(f"Extracted {len(found)} unique image references from {len(files)} manifests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
