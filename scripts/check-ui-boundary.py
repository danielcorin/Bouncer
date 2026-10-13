#!/usr/bin/env python3
"""Inspect Swift's parsed declarations; access control is ultimately enforced by compilation.
A FooReadAccess protocol is the explicit public read surface allowed on Foo.
This gate also rejects persistence-framework imports and testing/SPI access in UI targets.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
TYPES = {'class_decl', 'struct_decl', 'enum_decl', 'protocol', 'protocol_decl', 'extension_decl'}


def declarations(path):
    result = subprocess.run(['xcrun', 'swiftc', '-frontend', '-dump-parse', str(path)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    stack, declarations, imports = [], [], []
    for line in result.stdout.splitlines():
        match = re.match(r'( *)\((\w+)\b', line)
        if not match:
            continue
        depth, kind = len(match[1]), match[2]
        while stack and stack[-1]['depth'] >= depth:
            stack.pop()
        if kind in {'unresolved_dot_expr', 'unresolved_decl_ref_expr'}:
            name = re.search(r'(?:field|name)="([^"]+)"', line)
            function = next((n for n in reversed(stack) if n['kind'] == 'func_decl'), None)
            if name and function:
                function['calls'].add(name[1])
        if kind == 'accessor_decl' and 'set' in line and stack:
            stack[-1]['hasSetter'] = True
        if kind == 'import_decl':
            imports.append(line)
        if kind in {'access_control_attr', 'setter_access_attr'}:
            if stack:
                value = re.search(r'access(?:_level)?=(\w+)', line)
                if value:
                    stack[-1]['setter' if kind == 'setter_access_attr' else 'access'] = value[1]
            continue
        if kind in TYPES or kind in {'func_decl', 'var_decl', 'constructor_decl', 'typealias'}:
            name = re.search(r'\] (?:unbound )?"([^"]+)"', line)
            if not name:
                continue
            owner = next((n for n in reversed(stack) if n['kind'] in TYPES), None)
            node = dict(depth=depth, kind=kind, name=name[1], owner=owner, access=None, setter=None, line=line, calls=set(), hasSetter=False)
            stack.append(node); declarations.append(node)
    return path, declarations, imports


def check(root=ROOT):
    paths = sorted((root/'Sources').rglob('*.swift'))
    paths = [p for p in paths if 'Generated' not in p.parts]
    with ThreadPoolExecutor(max_workers=8) as pool:
        parsed = list(pool.map(declarations, paths))
    surfaces = {}
    for _, nodes, _ in parsed:
        for node in nodes:
            owner = node['owner']
            if owner and owner['name'].endswith('ReadAccess'):
                surfaces.setdefault(owner['name'].removesuffix('ReadAccess'), set()).add(node['name'])
    generated = root/'Sources/Shared/API/Generated/AutomationOperations.swift'
    operation_ids = set()
    if generated.exists():
        match = re.search(r'public enum OperationID[^\{]*\{([^}]+)', generated.read_text())
        if match:
            operation_ids = set(re.findall(r'case (\w+)', match[1]))
    errors = []
    if not surfaces:
        errors.append('No Swift ReadAccess protocols found; the UI boundary has no protected types.')
    for path, nodes, imports in parsed:
        relative = path.relative_to(root)
        ui = len(relative.parts) > 1 and relative.parts[1] in {'App', 'UI', 'Mobile'}
        if ui:
            for declaration in imports:
                if any('module="' + name + '"' in declaration for name in ('CoreData', 'SwiftData', 'SQLite3')):
                    errors.append(f'{relative}: UI targets cannot import persistence frameworks.')
            # Compiler parsing discards comments; inspect import attributes separately.
            source = path.read_text()
            if re.search(r'@(?:testable|_spi)\b', source):
                errors.append(f'{relative}: UI targets cannot opt into internal/SPI APIs.')
        actions = {n['name'].split('(')[0]: n for n in nodes if n['owner'] and n['owner']['name'].endswith('Actions') and n['kind'] == 'func_decl'}
        def reaches_operation(name, visited=None):
            visited = set() if visited is None else visited
            if name in visited or name not in actions:
                return False
            visited.add(name)
            calls = actions[name]['calls']
            return bool(calls & operation_ids) or any(reaches_operation(c, visited) for c in calls if c in actions)
        for name, action in actions.items():
            if action['access'] in {'public', 'open'} and not reaches_operation(name):
                errors.append(f'{relative}: public action {name} does not delegate to a generated operation.')
        for node in nodes:
            owner = node['owner']
            if not owner or owner['name'] not in surfaces:
                continue
            access = node['access'] or (owner['access'] if owner['kind'] == 'extension_decl' else None)
            if access not in {'public', 'open'}:
                continue
            allowed = surfaces[owner['name']]
            if node['kind'] == 'constructor_decl' or node['name'] == 'preview()':
                continue
            if node['kind'] == 'var_decl' and node['setter'] not in {'private', 'fileprivate', 'internal'} and ' let' not in node['line']:
                # Stored vars have no accessor list in dump-parse; computed getters do.
                source_line = re.search(r'range=\[.*?:(\d+):\d+', node['line'])
                declaration_line = path.read_text().splitlines()[int(source_line[1])-1] if source_line else ''
                if '{' not in declaration_line or node['hasSetter']:
                    errors.append(f'{relative}: {owner["name"]}.{node["name"]} exposes a writable property to UI code.')
            if node['name'] not in allowed:
                errors.append(f'{relative}: public {owner["name"]}.{node["name"]} is outside its ReadAccess protocol. Expose an operation instead.')
    if errors:
        raise RuntimeError('\n'.join(errors))
    return surfaces


if __name__ == '__main__':
    try:
        surfaces = check(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT)
        print('UI access boundaries verified: ' + ', '.join(sorted(surfaces)))
    except Exception as error:
        sys.exit(str(error))
