#!/usr/bin/env python3
"""Keep archive, installed profiles, and manual export mappings consistent."""
from pathlib import Path
import re
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
