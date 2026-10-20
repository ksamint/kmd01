#!/usr/bin/env python3
import copy
import datetime
import importlib.util
from pathlib import Path
import unittest
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("profile_check", Path(__file__).with_name("verify-release-profile.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.source = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.bookmarks.app-scope": True,
            "com.apple.security.application-groups": ["group.existing"],
            "keychain-access-groups": ["$(AppIdentifierPrefix)group.existing"],
        }
        self.signed = dict(self.source, **{
            "keychain-access-groups": ["TEAM.group.existing"],
            "com.apple.application-identifier": "TEAM.app.production",
            "com.apple.developer.team-identifier": "TEAM",
        })
        self.profile = {
            "ExpirationDate": datetime.datetime(2099, 1, 1),
            "TeamIdentifier": ["TEAM"],
            "ProvisionsAllDevices": True,
            "Entitlements": copy.deepcopy(self.signed),
        }

    def check(self):
        module.validate(self.profile, self.signed, self.source, "app.production", "TEAM")

    def test_valid(self):
        self.check()

    def test_missing_group(self):
        del self.profile["Entitlements"]["com.apple.security.application-groups"]
        with self.assertRaisesRegex(ValueError, "app group"):
            self.check()

    def test_expired(self):
        self.profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
        with self.assertRaisesRegex(ValueError, "expired"):
            self.check()

    def test_wrong_bundle(self):
        self.profile["Entitlements"]["com.apple.application-identifier"] = "TEAM.app.dev"
        with self.assertRaisesRegex(ValueError, "identity"):
            self.check()

    def test_missing_bookmark(self):
        del self.signed["com.apple.security.files.bookmarks.app-scope"]
        with self.assertRaisesRegex(ValueError, "bookmarks"):
            self.check()

    def test_changed_keychain(self):
        self.signed["keychain-access-groups"] = ["TEAM.new"]
        with self.assertRaisesRegex(ValueError, "keychain"):
            self.check()

    def test_unexpected_privilege(self):
        self.signed["com.apple.security.cs.disable-library-validation"] = True
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            self.check()

    def test_profile_team_entitlement_mismatch(self):
        self.profile["Entitlements"]["com.apple.developer.team-identifier"] = "OTHER"
        with self.assertRaisesRegex(ValueError, "Team ID"):
            self.check()

    def test_rejects_debug_profile_and_signature(self):
        for entitlements in [self.profile["Entitlements"], self.signed]:
            entitlements["com.apple.security.get-task-allow"] = True
            with self.assertRaises(ValueError):
                self.check()
            del entitlements["com.apple.security.get-task-allow"]


if __name__ == "__main__":
    unittest.main()
