#!/usr/bin/env python3
"""Exercise the installer's real rollback functions against temporary fake bundles."""
import pathlib
import shlex
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).with_name("install-latest-local.sh").read_text()
FUNCTIONS = SOURCE[SOURCE.index("rollback() {"):SOURCE.index("trap cleanup EXIT")]


class SafeInstallerTests(unittest.TestCase):
    def test_release_candidate_source_guards(self):
        start = SOURCE.index("release_state_is_allowed() {")
        guard = SOURCE[start:SOURCE.index("\n}", start) + 2]
        cases = {
            ("release", "false:false"): True,
            ("release", "true:false"): False,
            ("release", "false:true"): False,
            ("candidate", "true:false"): True,
            ("candidate", "true:true"): True,
            ("candidate", "false:false"): False,
            ("candidate", "false:true"): False,
            ("candidate", "unknown"): False,
        }
        for (mode, state), expected in cases.items():
            result = subprocess.run(["/bin/sh", "-c", guard + "\nrelease_state_is_allowed \"$1\" \"$2\"", "guard", mode, state])
            self.assertEqual(result.returncode == 0, expected, (mode, state))

    def run_case(self, *, stopped=True, replacement=True, late_failure=False):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = pathlib.Path(directory.name)
        target = root / "Applications" / "kmd.app"
        backup_directory = root / "backups" / "install"
        backup = backup_directory / "previous.app.disabled"
        target.mkdir(parents=True)
        (target / "version").write_text("new")
        backup.mkdir(parents=True)
        (backup / "version").write_text("old")
        data = root / "user-data"
        data.write_text("data written by the new app")
        scratch = root / "scratch"
        scratch.mkdir()
        variables = dict(target=target, backup_source=target, backup=backup,
                         backup_directory=backup_directory, temporary=scratch,
                         staging="", mounted="false", installation_complete="false",
                         replacement_started=str(replacement).lower(), new_install_started="true")
        script = "set -eu\n" + "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in variables.items())
        script += "\n" + FUNCTIONS
        script += f"\nstop_production() {{ return {0 if stopped else 1}; }}\n"
        script += "trap cleanup EXIT\nexit 17\n" if late_failure else "rollback\n"
        result = subprocess.run(["/bin/sh", "-c", script], capture_output=True, text=True, timeout=3)
        self.assertEqual(data.read_text(), "data written by the new app")
        return target, backup, backup_directory, result

    def test_rollback_restores_app_and_retains_failed_candidate(self):
        target, backup, directory, result = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((target / "version").read_text(), "old")
        self.assertFalse(backup.exists())
        self.assertEqual((directory / "failed-candidate.app.disabled" / "version").read_text(), "new")

    def test_late_failure_uses_exit_trap_and_preserves_original_status(self):
        target, _, _, result = self.run_case(late_failure=True)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual((target / "version").read_text(), "old")

    def test_refused_quit_does_not_replace_running_app(self):
        target, backup, _, result = self.run_case(stopped=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual((target / "version").read_text(), "new")
        self.assertEqual((backup / "version").read_text(), "old")

    def test_pre_swap_failure_never_touches_installed_app(self):
        target, backup, _, result = self.run_case(replacement=False, late_failure=True)
        self.assertEqual(result.returncode, 17)
        self.assertEqual((target / "version").read_text(), "new")
        self.assertEqual((backup / "version").read_text(), "old")


if __name__ == "__main__":
    unittest.main()
