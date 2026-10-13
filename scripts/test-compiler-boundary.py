#!/usr/bin/env python3
"""Compile one allowed UI call, then prove direct configuration mutation is inaccessible.
A failed import/build is never accepted as proof of access control.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MODULE = json.loads((ROOT/'API/generation.json').read_text())['coreModule']
with tempfile.TemporaryDirectory(prefix='ui-access-probe-', dir='/tmp') as temporary:
    root = Path(temporary)
    probe = root/'Probe.swift'
    command = ['xcrun', 'swiftc', '-typecheck', '-module-cache-path', str(root/'cache'), '-I', str(ROOT/'build/Build/Products/Debug')]
    for modulemap in sorted((ROOT/'build/Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap')):
        command += ['-Xcc', '-fmodule-map-file='+str(modulemap)]
    def compile(source):
        probe.write_text('import '+MODULE+'\n'+source+'\n')
        return subprocess.run(command+[str(probe)], capture_output=True, text=True)
    allowed = compile('func read(_ store: AppConfigurationStore) throws { _ = try store.load() }')
    assert allowed.returncode == 0, 'The positive import/read probe must compile: '+allowed.stderr
    forbidden = compile('func write(_ store: AppConfigurationStore) throws { _ = try store.set(.apiPort, value: "8081") }')
    assert forbidden.returncode != 0 and "'set' is inaccessible due to 'internal' protection level" in forbidden.stderr, forbidden.stderr
    if (ROOT/'Sources/Shared/API/WorkspaceActions.swift').exists():
        allowed = compile('@MainActor func act(_ store: WorkspaceStore) throws { _ = try store.actions.createIssue(title: "Allowed") }')
        assert allowed.returncode == 0, allowed.stderr
        forbidden = compile('@MainActor func bypass(_ store: WorkspaceStore) throws { _ = try store.createIssue(title: "Forbidden") }')
        assert forbidden.returncode != 0 and "'createIssue' is inaccessible due to 'internal' protection level" in forbidden.stderr, forbidden.stderr
print('PASS: compiler accepts service calls and rejects direct UI persistence mutations.')
