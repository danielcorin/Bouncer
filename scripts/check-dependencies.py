#!/usr/bin/env python3
"""Keep generation and Xcode on one reviewed set of dependency revisions."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
package = json.loads((root / "Packages/AppAutomation/Package.resolved").read_text())
xcode = json.loads((root / "Configuration/Package.resolved").read_text())
locked = {p["identity"]: p["state"] for p in xcode["pins"]}
for pin in package["pins"]:
    if locked.get(pin["identity"]) != pin["state"]:
        raise SystemExit(f"Xcode/generator locks differ for {pin['identity']}. Resolve and commit both locks together.")
