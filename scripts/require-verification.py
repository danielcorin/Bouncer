#!/usr/bin/env python3
"""Inspect or install the repository's required deterministic GitHub check.
Defaults to read-only verification. --apply creates/updates only the named ruleset.
GitHub plan/permission failures exit nonzero; they never masquerade as enforcement.
"""
import argparse
import json
import subprocess
import sys

NAME = 'Required app verification'
CONTEXT = 'App verification'


def api(path, method='GET', body=None):
    result = subprocess.run(['gh', 'api', path, '--method', method] + (['--input', '-'] if body is not None else []),
                            input=json.dumps(body) if body is not None else None, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--repo', help='owner/repository; defaults to the current Git repository')
    args = parser.parse_args()
    repo = args.repo or subprocess.check_output(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], text=True).strip()
    base = 'repos/' + repo + '/rulesets'
    rules = api(base)
    existing = next((rule for rule in rules if rule['name'] == NAME), None)
    body = dict(name=NAME, target='branch', enforcement='active', bypass_actors=[],
                conditions={'ref_name': {'include': ['~DEFAULT_BRANCH'], 'exclude': []}},
                rules=[{'type': 'required_status_checks', 'parameters': {
                    'required_status_checks': [{'context': CONTEXT}],
                    'strict_required_status_checks_policy': True}}])
    if args.apply:
        api(base + ('/' + str(existing['id']) if existing else ''), 'PUT' if existing else 'POST', body)
        rules = api(base)
        existing = next(rule for rule in rules if rule['name'] == NAME)
    if not existing:
        raise RuntimeError('Required merge check is not configured. Run scripts/require-verification.py --apply with repository administrator access.')
    detail = api(base + '/' + str(existing['id']))
    required = next((r for r in detail['rules'] if r['type'] == 'required_status_checks'), {}).get('parameters', {})
    contexts = {c['context'] for c in required.get('required_status_checks', [])}
    if detail['enforcement'] != 'active' or CONTEXT not in contexts or not required.get('strict_required_status_checks_policy') or detail.get('bypass_actors'):
        raise RuntimeError('The required verification ruleset is inactive, bypassable, or incomplete.')
    if detail['conditions']['ref_name'] != body['conditions']['ref_name']:
        raise RuntimeError('The required verification rule does not protect the default branch exactly.')
    print('PASS: GitHub requires App verification against the current default branch before merging.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        sys.exit('Required merge-check enforcement is unavailable: ' + str(error))
