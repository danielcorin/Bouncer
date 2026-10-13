#!/usr/bin/env python3
"""Contract failures must be diagnosed before invalid Swift is emitted."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
GENERATOR = ROOT / "Packages/AppAutomation/.build/debug/app-interface"
SPEC = json.loads((ROOT / "API/openapi.yaml").read_text())


def operations(document):
    return [op for item in document["paths"].values() for op in item.values() if isinstance(op, dict) and "operationId" in op]


def reject(change, expected):
    document = copy.deepcopy(SPEC)
    change(document)
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "openapi.json"
        path.write_text(json.dumps(document))
        result = subprocess.run([str(GENERATOR), str(path), str(Path(temporary) / "generated"), "TestCore"], capture_output=True, text=True)
        assert result.returncode != 0, "Generator accepted invalid contract"
        assert expected in result.stderr, result.stderr
        assert not (Path(temporary) / "generated").exists(), "Invalid contract wrote partial output"


reject(lambda d: operations(d)[1].update(operationId=operations(d)[0]["operationId"]), "Duplicate operation IDs")
reject(lambda d: operations(d)[1]["x-cli"].update(command=operations(d)[0]["x-cli"]["command"]), "Duplicate CLI commands")
reject(lambda d: operations(d)[0]["x-cli"].update(renderer="renderStatus"), "custom behavior belongs in Swift")
reject(lambda d: operations(d)[0].update(operationId="class"), "Reserved Swift operation ID")
reject(lambda d: d["paths"]["/v1/configuration/{key}"]["put"]["x-cli"]["bindings"]["body.value"].update(option="--json"), "reserved option")
reject(lambda d: d["paths"]["/v1/configuration/{key}"]["put"]["x-cli"]["bindings"]["path.key"].update(argument=2), "positional arguments must be contiguous")
reject(lambda d: d["paths"]["/v1/configuration/{key}"]["put"]["x-cli"]["bindings"].update({"body.missing": {"option": "--missing"}}), "unknown CLI field binding")
reject(lambda d: d["components"]["schemas"]["ConfigSetBody"]["properties"]["value"].update(type="object"), "unsupported input schema")
print("Generator contract rejection tests passed.")
