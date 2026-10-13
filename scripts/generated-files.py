#!/usr/bin/env python3
"""Verify deterministic generation; the fast build guard checks both inputs and outputs."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent
DIRECTORIES = [Path(p) for p in ("Sources/Shared/API/Generated", "Sources/CLI/Generated", "Sources/HTTP/Generated")]
STAMP = ROOT / "API/generated-manifest.json"


def hashes(root, paths):
    return {str(p): hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sorted(paths)}


def inputs():
    paths = [p.relative_to(ROOT) for directory in ("API", "Packages/AppAutomation/Sources", "scripts")
             for p in (ROOT / directory).rglob("*") if p.is_file()
             and (directory != "scripts" or p.name in ("generate-api.sh", "generated-files.py", "check-generated.sh", "prepare-xcode.sh", "check-dependencies.py"))
             and p != STAMP]
    return hashes(ROOT, paths + [Path("Packages/AppAutomation/Package.swift"), Path("Packages/AppAutomation/Package.resolved"), Path("Configuration/Package.resolved")])


def outputs(root):
    return hashes(root, [p.relative_to(root) for d in DIRECTORIES if (root / d).is_dir() for p in (root / d).rglob("*") if p.is_file()])


mode = sys.argv[1]
if mode == "--quick":
    expected = json.loads(STAMP.read_text()) if STAMP.exists() else {}
    actual = {"inputs": inputs(), "outputs": outputs(ROOT)}
    if expected != actual:
        sys.exit("Generated API sources are stale or edited. Run scripts/generate-api.sh, then commit the spec and generated files together.")
else:
    generated = Path(sys.argv[2])
    if mode == "--write":
        for directory in DIRECTORIES:
            shutil.rmtree(ROOT / directory, ignore_errors=True)
            # A CLI-only app generates no HTTP sources.
            if (generated / directory).is_dir():
                shutil.copytree(generated / directory, ROOT / directory)
        STAMP.write_text(json.dumps({"inputs": inputs(), "outputs": outputs(ROOT)}, indent=2, sort_keys=True) + "\n")
    elif mode == "--check":
        if outputs(generated) != outputs(ROOT):
            for path in sorted(set(outputs(generated)) | set(outputs(ROOT))):
                a, b = ROOT / path, generated / path
                if not a.exists() or not b.exists() or a.read_bytes() != b.read_bytes():
                    print(f"Generated output differs: {path}", file=sys.stderr)
            sys.exit(1)
        if json.loads(STAMP.read_text()) != {"inputs": inputs(), "outputs": outputs(ROOT)}:
            sys.exit("Generation manifest is stale. Run scripts/generate-api.sh.")
        print("Generated CLI, DTOs, dispatch, and catalog are current.")
    else:
        sys.exit("Unknown generation mode")
