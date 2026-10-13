#!/usr/bin/env python3
"""Deliberately break the declaration gate in isolated Swift fixtures."""
import importlib.util
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('boundary', Path(__file__).with_name('check-ui-boundary.py'))
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)
with tempfile.TemporaryDirectory(prefix='boundary-regression-', dir='/tmp') as temporary:
    root = Path(temporary)
    core = root/'Sources/Shared'; core.mkdir(parents=True)
    ui = root/'Sources/App'; ui.mkdir(parents=True)
    definition = core/'State.swift'
    valid = '''public protocol StateReadAccess { var value: Int { get } }
public final class State {
    public private(set) var value = 0
    func mutate() { value += 1 }
}
'''
    definition.write_text(valid)
    boundary.check(root)
    for source, diagnostic in [
        (valid.replace('func mutate', 'public func mutate'), 'outside its ReadAccess'),
        (valid.replace('public private(set)', 'public'), 'writable property'),
        (valid+'\npublic extension State { func bypass() {} }\n', 'outside its ReadAccess'),
        (valid+'\npublic class StateActions { public func newFeature() {} }\n', 'does not delegate'),
    ]:
        definition.write_text(source)
        try:
            boundary.check(root)
            raise AssertionError('Boundary gate accepted a broken fixture: '+diagnostic)
        except RuntimeError as error:
            assert diagnostic in str(error), error
    definition.write_text(valid)
    for source, diagnostic in [('import CoreData', 'persistence frameworks'), ('@testable import SomeCore', 'internal/SPI')]:
        (ui/'View.swift').write_text(source)
        try:
            boundary.check(root)
            raise AssertionError('UI bypass was accepted')
        except RuntimeError as error:
            assert diagnostic in str(error), error
print('PASS: declaration gate rejects new public mutations, writable state, extension bypasses, unbound actions, and forbidden imports.')
