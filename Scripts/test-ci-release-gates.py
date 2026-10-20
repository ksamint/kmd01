#!/usr/bin/env python3
import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest
import sys
sys.dont_write_bytecode = True
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gates', Path(__file__).with_name('ci-release-gates.py'))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


class GateTests(unittest.TestCase):
    def test_shared_changes_run_every_check(self):
        for path in ['Scripts/install-latest-local.sh', '.github/workflows/release.yml',
                     'Build.xcconfig', 'Shared/Protocol.swift']:
            self.assertTrue(all(gates.classify([path]).values()), path)
        for path in ['MarkEditTools/Package.swift', 'VaultProtocolTS/src/index.ts',
                     'WebApp/src/main.ts', 'ConversationCaptureHelper/main.swift',
                     'ResourceModules/modules/text/manifest.json']:
            self.assertTrue(gates.classify([path])['mac'], path)
        self.assertFalse(any(gates.classify(['docs/README.md']).values()))

    def test_expected_skipped_cancelled_or_missing_jobs_fail(self):
        needs = {'changes': {'result': 'success', 'outputs': {
            key: 'true' for key in gates.CHECKS}}, 'quality': {'result': 'success'}}
        needs.update({job: {'result': 'success'} for job in gates.JOBS})
        gates.readiness(needs)
        for job in needs:
            for result in ['skipped', 'cancelled', 'failure', None]:
                broken = copy.deepcopy(needs)
                broken[job]['result'] = result
                with self.assertRaises(ValueError, msg=f'{job}: {result}'):
                    gates.readiness(broken)
        needs['changes']['outputs'] = {key: 'false' for key in gates.CHECKS}
        for job in gates.JOBS:
            needs[job]['result'] = 'skipped'
        gates.readiness(needs)

    def test_artifact_bound_completed_runtime_acceptance(self):
        commit = 'a' * 40
        hashes = {'app.dmg': 'b' * 64}
        row = {'startedAt': '2026-01-01T00:00:00Z', 'completedAt': '2026-01-02T00:00:00Z',
               'fullReboots': 2, 'lifecycleCycles': 30, 'quitRelaunchCycles': 10, 'checks': {key: 'pass' for key in gates.MATRIX},
               'evidence': 'acceptance log'}
        record = {'schema': 1, 'commit': commit, 'approved': True, 'reviewer': 'owner',
                  'artifacts': hashes, 'systems': [dict(row, macOS='15'), dict(row, macOS='26')]}
        now = dt.datetime(2026, 1, 3, tzinfo=dt.timezone.utc)
        gates.acceptance(record, commit, hashes, now)
        for field, value in [('commit', 'c' * 40), ('artifacts', {'app.dmg': 'c' * 64}),
                             ('approved', False), ('reviewer', ''), ('systems', [])]:
            with self.assertRaises(ValueError):
                gates.acceptance(dict(record, **{field: value}), commit, hashes, now)
        for field, value in [('completedAt', '2026-01-01T23:59:59Z'),
                             ('completedAt', '2026-02-01T00:00:00Z'),
                             ('fullReboots', 1), ('lifecycleCycles', 29), ('quitRelaunchCycles', 9), ('checks', {}), ('evidence', '')]:
            broken = copy.deepcopy(record)
            broken['systems'][0][field] = value
            with self.assertRaises(ValueError):
                gates.acceptance(broken, commit, hashes, now)

    def test_trusted_build_requires_protected_main_and_exact_success(self):
        commit = 'a' * 40
        run = {'id': 42, 'head_sha': commit, 'head_branch': 'main', 'event': 'push',
               'status': 'completed', 'conclusion': 'success', 'run_attempt': 1}
        replies = [{'protected': True}, {'workflow_runs': [run]},
                   {'jobs': [{'name': 'Release readiness', 'conclusion': 'success'}]}]
        with patch.dict('os.environ', GITHUB_REF='refs/heads/main', GITHUB_REPOSITORY='owner/repo'), \
                patch.object(gates.subprocess, 'run'), patch.object(gates, 'gh_api') as api:
            api.side_effect = copy.deepcopy(replies)
            gates.trusted_build(commit)
            for index, replacement in [(0, {'protected': False}),
                                       (1, {'workflow_runs': []}),
                                       (1, {'workflow_runs': [dict(run, conclusion='cancelled')]}),
                                       (2, {'jobs': [{'name': 'Release readiness', 'conclusion': 'skipped'}]})]:
                broken = copy.deepcopy(replies)
                broken[index] = replacement
                api.side_effect = broken
                with self.assertRaises(ValueError):
                    gates.trusted_build(commit)
        with patch.dict('os.environ', GITHUB_REF='refs/heads/feature'):
            with self.assertRaises(ValueError):
                gates.trusted_build(commit)


if __name__ == '__main__':
    unittest.main()
