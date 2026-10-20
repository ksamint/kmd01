#!/usr/bin/env python3
"""Fail-closed CI selection, trusted build provenance, and human release acceptance."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

CHECKS = {
    'mac': ('MarkEditMac/', 'MarkEditKit/', 'MarkEditCore/', 'MarkEditTools/',
            'MarkEdit.xcodeproj/', 'FinderExtension/', 'PreviewExtension/',
            'QuickActionExtension/', 'ConversationCaptureHelper/', 'CoreEditor/',
            'WebApp/', 'VaultProtocolTS/', 'ResourceModules/', 'Shared/'),
    'web': ('WebApp/', 'CoreEditor/', 'VaultProtocolTS/'),
    'cloud': ('Cloud/',),
    'cloud_audit': ('Cloud/Cargo.toml', 'Cloud/Cargo.lock', 'Cloud/audit.sh'),
    'resource_modules': ('ResourceModules/',),
    'agent_sdk': ('AgentSDK/',),
    'agent_contracts': ('AgentSDK/', 'MarkEditMac/'),
}
JOBS = {'mac': 'mac', 'runtime-compatibility': 'mac',
        'web': 'web', 'cloud': 'cloud', 'resource-modules': 'resource_modules',
        'agent-sdk': 'agent_sdk', 'local-agent-cli-contracts': 'agent_contracts'}
MATRIX = ('launch', 'document-open-save', 'clipboard-text', 'clipboard-rich-text',
          'clipboard-html', 'clipboard-image', 'clipboard-file', 'finder',
          'quick-action', 'preview', 'sleep-wake', 'logout-login', 'same-identity-upgrade', 'reboot')
COMPATIBILITY_MATRIX = ('launch', 'document-open-save')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def classify(paths):
    shared = any(p.startswith(('Scripts/', '.github/', 'Shared/')) or
                 '/' not in p and not p.endswith('.md') for p in paths)
    return {key: shared or any(p.startswith(prefixes) for p in paths)
            for key, prefixes in CHECKS.items()}


def readiness(needs):
    for job in ('changes', 'quality'):
        require(needs.get(job, {}).get('result') == 'success', f'{job} did not succeed')
    outputs = needs['changes'].get('outputs', {})
    for job, flag in JOBS.items():
        require(outputs.get(flag) in ('true', 'false'), f'Missing selection: {flag}')
        expected = 'success' if outputs[flag] == 'true' else 'skipped'
        require(needs.get(job, {}).get('result') == expected,
                f'{job}: expected {expected}, got {needs.get(job, {}).get("result")}')


def gh_api(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True))


def trusted_build(commit):
    require(re.fullmatch(r'[0-9a-f]{40}', commit), 'Expected a full immutable commit SHA')
    require(os.environ.get('GITHUB_REF') == 'refs/heads/main', 'Dispatch must use main')
    repo = os.environ['GITHUB_REPOSITORY']
    branch = gh_api(f'repos/{repo}/branches/main')
    require(branch.get('protected') is True, 'main must have branch protection or a ruleset')
    subprocess.run(['git', 'fetch', '--no-tags', 'origin', 'main'], check=True)
    subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'FETCH_HEAD'], check=True)
    runs = gh_api(f'repos/{repo}/actions/workflows/build-and-test.yml/runs?'
                  f'head_sha={commit}&branch=main&event=push&per_page=100')['workflow_runs']
    runs = [run for run in runs if run['head_sha'] == commit and
            run['head_branch'] == 'main' and run['event'] == 'push']
    require(runs, 'No exact-commit main CI run exists')
    run = max(runs, key=lambda item: item['id'])
    require(run['status'] == 'completed' and run['conclusion'] == 'success',
            'Latest exact-commit main CI run did not succeed')
    jobs = gh_api(f'repos/{repo}/actions/runs/{run["id"]}/attempts/'
                  f'{run["run_attempt"]}/jobs?per_page=100')['jobs']
    gate = [job for job in jobs if job['name'] == 'Release readiness']
    require(len(gate) == 1 and gate[0]['conclusion'] == 'success',
            'Exact-commit Release readiness did not succeed')
    print(f'Trusted tested commit: {commit}; CI run: {run["id"]}')


def acceptance(record, commit, artifacts, now=None):
    require(record.get('schema') == 1, 'Unsupported acceptance schema')
    require(record.get('commit') == commit and re.fullmatch(r'[0-9a-f]{40}', commit),
            'Acceptance commit mismatch')
    require(record.get('approved') is True and bool(record.get('reviewer', '').strip()),
            'Explicit human approval and reviewer required')
    require(record.get('artifacts') == artifacts, 'Acceptance artifact hashes mismatch')
    require(artifacts and all(re.fullmatch(r'[0-9a-f]{64}', h) for h in artifacts.values()),
            'Invalid artifact SHA256')
    now = now or dt.datetime.now(dt.timezone.utc)
    rows = record.get('systems', [])
    require(len(rows) == 2 and {row.get('macOS') for row in rows} == {'15', '26'},
            'Exact-artifact runtime evidence required on macOS 15 and 26')
    require(all(isinstance(row.get('acceptanceHost'), bool) for row in rows)
            and sum(row['acceptanceHost'] for row in rows) == 1,
            'Exactly one designated acceptance host required')
    for row in rows:
        start = dt.datetime.fromisoformat(row['startedAt'].replace('Z', '+00:00'))
        end = dt.datetime.fromisoformat(row['completedAt'].replace('Z', '+00:00'))
        require(start.tzinfo is not None and end.tzinfo is not None, 'UTC offsets required')
        require(start < end <= now, 'Completed runtime evidence timestamps required')
        if row['acceptanceHost']:
            require((end - start).total_seconds() >= 86400,
                    'Designated acceptance host needs at least 24 hours of completed use')
            require(row.get('fullReboots', 0) >= 2, 'Two full user-arranged reboots required')
            require(row.get('lifecycleCycles', 0) >= 30, 'Thirty lifecycle cycles required')
            require(row.get('quitRelaunchCycles', 0) >= 10, 'Ten quit/relaunch cycles required')
        checks = MATRIX if row['acceptanceHost'] else COMPATIBILITY_MATRIX
        require(all(row.get('checks', {}).get(name) == 'pass' for name in checks),
                'Runtime acceptance matrix incomplete')
        require(bool(row.get('evidence', '').strip()), 'Runtime evidence reference required')


def main():
    command = sys.argv[1]
    if command == 'classify':
        selected = classify(sys.stdin.read().splitlines())
        for name, selected in selected.items():
            print(f'{name}={str(selected).lower()}')
    elif command == 'readiness':
        readiness(json.loads(os.environ['CI_NEEDS']))
        print('Release readiness passed')
    elif command == 'trusted-build':
        trusted_build(sys.argv[2])
    elif command == 'acceptance':
        record_path, commit, *files = sys.argv[2:]
        hashes = {Path(file).name: hashlib.sha256(Path(file).read_bytes()).hexdigest()
                  for file in files}
        acceptance(json.loads(Path(record_path).read_text()), commit, hashes)
        print('Exact-artifact runtime acceptance passed')
    else:
        raise ValueError(f'Unknown command: {command}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
