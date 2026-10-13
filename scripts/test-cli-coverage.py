#!/usr/bin/env python3
"""Exercise the shipping guard against real, stripped and universal Mach-O code."""
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

verifier = Path(__file__).resolve().with_name("verify-no-coverage.sh")
environment = {
    "HOME": os.environ["HOME"],
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "DEVELOPER_DIR": os.environ.get("XCODE_DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
}


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, env=environment, check=True, capture_output=True, text=True)


def check(bundle, instrumented):
    result = subprocess.run([str(verifier), str(bundle)], env=environment, capture_output=True, text=True)
    assert result.returncode == (1 if instrumented else 0), result.stderr
    if instrumented:
        assert "coverage instrumentation found" in result.stderr, result.stderr


with tempfile.TemporaryDirectory(prefix="cli-coverage-") as temporary:
    root = Path(temporary)
    source = root / "main.c"
    source.write_text("int main(void) { return 0; }\n")
    clean = root / "clean"
    covered = root / "covered"
    host_arch = platform.machine()
    other_arch = "x86_64" if host_arch == "arm64" else "arm64"
    run("/usr/bin/xcrun", "clang", "-arch", host_arch, str(source), "-o", str(clean))
    run("/usr/bin/xcrun", "clang", "-arch", host_arch, "-fprofile-instr-generate", "-fcoverage-mapping",
        str(source), "-o", str(covered))
    run(str(clean), cwd=root)
    assert not (root / "default.profraw").exists()
    run(str(covered), cwd=root)
    assert (root / "default.profraw").exists(), "Fixture must reproduce the unwanted file"

    bundle = root / "App With Spaces.app"
    helpers = bundle / "Contents/Helpers"
    helpers.mkdir(parents=True)
    helper = helpers / "cli"
    shutil.copy2(clean, helper)
    check(bundle, False)
    shutil.copy2(covered, helper)
    run("/usr/bin/strip", str(helper))
    check(bundle, True)  # Symbol stripping must not bypass section inspection.

    # One instrumented architecture is enough to make a universal CLI unsafe.
    covered_other = root / "covered-other"
    run("/usr/bin/xcrun", "clang", "-arch", other_arch, "-fprofile-instr-generate", "-fcoverage-mapping",
        str(source), "-o", str(covered_other))
    run("/usr/bin/xcrun", "lipo", "-create", str(clean), str(covered_other), "-output", str(helper))
    check(bundle, True)

    # A clean CLI can still load an instrumented shared library.
    shutil.copy2(clean, helper)
    framework = bundle / "Contents/Frameworks/Core.framework/Versions/A/Core"
    framework.parent.mkdir(parents=True)
    run("/usr/bin/xcrun", "clang", "-dynamiclib", "-fprofile-instr-generate", "-fcoverage-mapping",
        str(source), "-o", str(framework))
    check(bundle, True)
    framework.unlink()
    (helpers / "script").write_text("#!/bin/sh\nexit 0\n")
    check(bundle, False)

print("PASS: clean CLI stays clean; instrumented, stripped, universal, and linked-library builds are rejected")
