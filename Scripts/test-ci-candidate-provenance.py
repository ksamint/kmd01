#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("candidate", Path(__file__).with_name("ci-candidate-provenance.py"))
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.dmg = Path(self.directory.name) / "ksamint-MarkEdit-2.5.6.dmg"
        self.dmg.write_bytes(b"fixture for immutable candidate validation")
        self.digest = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        self.release = {"isDraft": True, "tagName": "v2.5.6"}
        self.metadata = {"schema": 1, "tag": "v2.5.6", "commit": "a" * 40,
                         "teamID": candidate.TEAM_ID,
                         "dmg": {"asset": self.dmg.name, "stapledSHA256": self.digest}}
        self.sums = f"{self.digest}  {self.dmg.name}\n"

    def check(self, **changes):
        inputs = dict(tag="v2.5.6", release=self.release, metadata=self.metadata,
                      checksums=self.sums, dmg=self.dmg)
        inputs.update(changes)
        return candidate.validate(**inputs)

    def test_exact_stapled_draft(self):
        result = self.check()
        self.assertEqual(result["commit"], "a" * 40)
        self.assertEqual(result["sha256"], self.digest)

    def test_rejects_invalid_tag_release_identity_or_provenance(self):
        for tag in ("../../other", "v2.5.6\n", "main"):
            with self.assertRaises(ValueError):
                self.check(tag=tag)
        for release in ({"isDraft": False, "tagName": "v2.5.6"},
                        {"isDraft": True, "tagName": "v2.5.5"}):
            with self.assertRaises(ValueError):
                self.check(release=release)
        for field, value in (("tag", "v2.5.5"), ("schema", 0),
                             ("commit", "main"), ("teamID", "OTHERTEAM")):
            with self.assertRaises(ValueError):
                self.check(metadata=dict(self.metadata, **{field: value}))

    def test_rejects_unstapled_changed_or_ambiguous_bytes(self):
        for field, value in (("asset", "../other.dmg"), ("stapledSHA256", ""),
                             ("stapledSHA256", "b" * 64)):
            metadata = copy.deepcopy(self.metadata)
            metadata["dmg"][field] = value
            with self.assertRaises(ValueError):
                self.check(metadata=metadata)
        for sums in ("", self.sums * 2, "malformed\n", f"{'b' * 64}  {self.dmg.name}\n"):
            with self.assertRaises(ValueError):
                self.check(checksums=sums)
        self.dmg.write_bytes(b"changed after preflight")
        with self.assertRaises(ValueError):
            self.check()


if __name__ == "__main__":
    unittest.main()
