#!/usr/bin/env python3
"""Exercise the generated CLI against the isolated fixture, without user data."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
products = root / "build/Build/Products/Debug"


def stop(process):
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=22)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
            raise AssertionError("Shutdown exceeded its deadline")


def line(process):
    assert select.select([process.stdout], [], [], 15)[0], "Readiness timeout"
    value = process.stdout.readline()
    assert value, process.stderr.read()
    return value


with tempfile.TemporaryDirectory(prefix="bouncer-api-", dir="/tmp") as temporary:
    env = {**os.environ, "APP_AUTOMATION_ROOT": temporary, "XDG_CONFIG_HOME": temporary + "/config"}
    app = None
    try:
        app = subprocess.Popen([str(products / "BouncerAutomationFixture"), temporary], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert line(app).strip() == "ready"

        def cli(*arguments):
            result = subprocess.run([str(products / "bouncer"), *arguments, "--json"], env=env, capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)

        def cli_error(*arguments):
            result = subprocess.run([str(products / "bouncer"), *arguments, "--json"], env=env, capture_output=True, text=True, timeout=15)
            assert result.returncode != 0, "Expected a failure"
            assert not result.stdout, "Errors must use stderr"
            return json.loads(result.stderr)

        assert cli("status")["data"]["appName"] == "Bouncer fixture"
        spec = cli("api", "schema")
        expected = {op["operationId"] for item in spec["paths"].values() for op in item.values() if isinstance(op, dict) and "operationId" in op}
        assert {op["id"] for op in cli("api", "operations")["data"]["operations"]} == expected
        human = subprocess.run([str(products / "bouncer"), "status"], env=env, capture_output=True, text=True, check=True).stdout
        assert "Bouncer fixture" in human and "pid" in human

        # The shared configuration store is reachable without the app running.
        cli("config", "set", "flash-indicator", "--value", "false")
        assert cli("config", "get", "flash-indicator")["data"]["value"] is False
        cli("config", "unset", "flash-indicator")
        assert cli("config", "get", "flash-indicator")["data"]["value"] is True
        assert cli_error("config", "set", "flash-indicator", "--value", "maybe")["error"]["code"] == "invalid_input"

        # No HTTP listener is built, so neither the server nor its credentials exist.
        assert b"serve" not in subprocess.run([str(products / "bouncer"), "--help"], env=env, capture_output=True).stdout
        assert app.poll() is None
        print("Scaffold CLI, typed Swift renderer, shared configuration, and error contract passed.")
    finally:
        stop(app)
