#!/usr/bin/env python3
"""Run the Swift-authored scenario suite against three real execution paths.
The fixture runs typed direct calls and all assertions; Python only drives transports.
All state, files, credentials and processes are isolated from the installed app.
"""
import base64
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
PRODUCTS = ROOT/'build/Build/Products/Debug'
CONFIG = json.loads((ROOT/'API/generation.json').read_text())
APP = CONFIG['coreModule'].removesuffix('Core')
CLI_NAME = CONFIG.get('cliName', APP.lower())
CLI = PRODUCTS/CLI_NAME
FIXTURE = PRODUCTS/(APP + 'AutomationFixture')


def wait_line(process):
    assert select.select([process.stdout], [], [], 20)[0], 'Readiness timed out'
    line = process.stdout.readline()
    assert line, 'Fixture exited before readiness: ' + process.stderr.read()
    return line


def stop(process):
    if process and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=22)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
            raise AssertionError('Shutdown exceeded deadline')


def receive(connection, count):
    data = b''
    while len(data) < count:
        chunk = connection.recv(count-len(data))
        assert chunk, 'Truncated fixture control response'
        data += chunk
    return data


reports = {}
for transport in ('direct', 'cli'):
    with tempfile.TemporaryDirectory(prefix='operation-scenarios-', dir='/tmp') as temporary:
        root = Path(temporary)
        env = {**os.environ, 'TASKS_AUTOMATION_ROOT': str(root), 'APP_AUTOMATION_ROOT': str(root), 'XDG_CONFIG_HOME': str(root/'config')}
        fixture = None
        try:
            fixture = subprocess.Popen([str(FIXTURE), str(root), '--scenarios'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            assert wait_line(fixture).strip() == 'ready'

            def control(operation, value=None):
                request_id = str(uuid.uuid4())
                frame = json.dumps(dict(protocolVersion=1, requestId=request_id, operation=operation, input=value or {})).encode()
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(20)
                    connection.connect(str(root/'automation.sock'))
                    connection.sendall(struct.pack('>I', len(frame)) + frame)
                    length, = struct.unpack('>I', receive(connection, 4))
                    assert length <= 1_048_576
                    response = json.loads(receive(connection, length))
                assert response['requestId'].lower() == request_id.lower()
                assert 'error' not in response, response.get('error')
                return response['data']

            def run_cli(arguments):
                result = subprocess.run([str(CLI), *arguments, '--json'], capture_output=True, text=True, timeout=20, env=env)
                if result.returncode:
                    assert not result.stdout, 'Errors must use stderr'
                    return json.loads(result.stderr)
                assert not result.stderr, result.stderr
                return json.loads(result.stdout)

            operations = run_cli(['api', 'operations'])['data']['operations']
            required = {op['id'] for op in operations}
            while True:
                scenario = control('$scenarioNext')
                if scenario.get('done'):
                    assert set(scenario['verified']) == required, 'Coverage is incomplete'
                    reports[transport] = scenario
                    break
                op, values = scenario['definition'], scenario['input']
                assert op in operations, 'Scenario operation differs from generated discovery'
                if transport == 'direct':
                    result = control('$scenarioDirect')
                else:
                    args = list(op['command'])
                    values = dict(values)
                    if op['upload']:
                        args += ['--file', str(root/'Transfers'/values.pop('transfer'))]
                    output = root/'exported.bin'
                    if op['download']:
                        args += ['--output', str(output), '--force']
                    payload = root/'input.json'
                    payload.write_text(json.dumps(values))
                    args += ['--input-file', str(payload)]
                    result = run_cli(args)
                    if op['download'] and 'error' not in result:
                        result = {'data': {'download': base64.b64encode(output.read_bytes()).decode()}}
                try:
                    control('$scenarioAssert', result)
                except AssertionError as error:
                    raise AssertionError(f'{transport}/{op["id"]}: {error}') from error
            print(f'{transport}: {len(required)} operations verified in {scenario["steps"]} executed Swift scenarios')
        finally:
            stop(fixture)
output = ROOT/'build/verification/scenarios.json'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(reports, indent=2, sort_keys=True)+'\n')
print('PASS: identical Swift scenario assertions across direct service and CLI.')
