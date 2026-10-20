#!/usr/bin/env python3
"""Keep archive, installed profiles, and manual export mappings consistent."""
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
PROFILES = {
    "MarkEditMac": ("art.apuch.ksamint.markedit", "ksamint MarkEdit Developer ID 2.5.6"),
    "ConversationCaptureHelper": ("art.apuch.ksamint.markedit.conversation-capture-helper", "ksamint Capture Helper Developer ID 2.5.6"),
    "FinderExtension": ("art.apuch.ksamint.markedit.finder-extension", "ksamint Finder Extension Developer ID 2.5.6"),
    "PreviewExtension": ("art.apuch.ksamint.markedit.preview-extension", "ksamint Preview Extension Developer ID"),
    "QuickActionExtension": ("art.apuch.ksamint.markedit.quick-actions", "ksamint Quick Actions Developer ID 2.5.6"),
}


class SigningTests(unittest.TestCase):
    def run_submission(self, fail_cli):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Submit each byte sequence once", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            binary = work / "bin"
            binary.mkdir()
            (binary / "xcrun").write_text(
                '#!/bin/sh\ncase "$3" in\n'
                '  *.dmg) printf \'{"id":"dmg-submission"}\\n\' ;;\n'
                '  *.zip) [ "$FAIL_CLI" = 0 ] || exit 1; printf \'{"id":"cli-submission"}\\n\' ;;\n'
                '  *) exit 2 ;;\nesac\n')
            (binary / "gh").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RUNNER_TEMP/gh-args"\n')
            for executable in binary.iterdir():
                executable.chmod(0o755)
            for name in ("ksamint-MarkEdit-2.5.6.dmg", "ksamint-vault-macos-arm64.zip"):
                (work / name).write_bytes(b"exact signed fixture bytes")
            environment = dict(os.environ, RUNNER_TEMP=directory, RELEASE_TAG="v2.5.6",
                               APPLE_NOTARY_KEY_P8_BASE64="", APPLE_NOTARY_KEY_ID="fixture",
                               APPLE_NOTARY_ISSUER_ID="fixture", APPLE_TEAM_ID="fixture",
                               GITHUB_REPOSITORY="fixture/repo", FAIL_CLI=str(int(fail_cli)))
            environment["PATH"] = f"{binary}{os.pathsep}{environment['PATH']}"
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", script],
                                    cwd=ROOT, env=environment, capture_output=True, text=True)
            self.assertEqual(json.loads((work / "NotaryDMG.json").read_text())["id"], "dmg-submission")
            if fail_cli:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((work / "gh-args").exists())
                self.assertFalse((work / "NotarySubmission.json").exists())
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                metadata = json.loads((work / "NotarySubmission.json").read_text())
                self.assertEqual(metadata["dmg"]["submissionID"], "dmg-submission")
                self.assertEqual(metadata["cli"]["submissionID"], "cli-submission")
                self.assertIn("--draft\n", (work / "gh-args").read_text())

    def test_first_submission_survives_second_submission_failure(self):
        self.run_submission(fail_cli=True)

    def test_successful_submissions_create_only_a_draft(self):
        self.run_submission(fail_cli=False)

    def test_archive_profiles_match_both_workflow_export_and_install_maps(self):
        config = (ROOT / "ReleaseSigning.xcconfig").read_text()
        project = (ROOT / "MarkEdit.xcodeproj/project.pbxproj").read_text()
        self.assertIn("CODE_SIGN_STYLE = Manual", config)
        for target, (bundle_id, profile) in PROFILES.items():
            self.assertIn(f"KSAMINT_PROFILE_{target} = {profile}\n", config)
            self.assertEqual(project.count(
                f'PROVISIONING_PROFILE_SPECIFIER = "$(KSAMINT_PROFILE_{target})";'), 2)
            for name in ("release.yml", "signed-local-install.yml"):
                workflow = (ROOT / ".github/workflows" / name).read_text()
                self.assertEqual(workflow.count(f"{bundle_id}|{profile}\n"), 2)

    def test_archive_has_no_automatic_provisioning_or_new_signing_identity(self):
        for name in ("release.yml", "signed-local-install.yml"):
            workflow = (ROOT / ".github/workflows" / name).read_text()
            archive = re.search(r"xcodebuild archive \\\n(.*?)\n          plutil",
                                workflow, re.S).group(1)
            self.assertIn("-xcconfig ReleaseSigning.xcconfig", archive)
            self.assertIn('CODE_SIGN_IDENTITY="$APPLE_DEVELOPER_ID_SHA1"', archive)
            self.assertNotIn("-allowProvisioningUpdates", workflow)
            self.assertNotIn("-authenticationKey", archive)
            self.assertIn("signingStyle -string manual", workflow)
            self.assertIn('signingCertificate -string "$APPLE_DEVELOPER_ID_SHA1"', workflow)


if __name__ == "__main__":
    unittest.main()
