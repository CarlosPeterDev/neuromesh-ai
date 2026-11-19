import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from report_build_config import write_config


class ReportBuildConfigTests(unittest.TestCase):
    def test_private_credentials_and_derived_compiler_values_are_masked(self):
        token = "12345678:" + "x" * 35
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "defines.json"
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                write_config(path, {"NEUROMESH_REPORT_BOT_TOKEN": token,
                                    "NEUROMESH_REPORT_CHAT_ID": "-1234"})
            values = json.loads(path.read_text())
            self.assertEqual(values["NEUROMESH_REPORT_BOT_TOKEN"], token)
            self.assertEqual(values["NEUROMESH_REPORT_CHAT_ID"], "-1234")
            self.assertEqual(output.getvalue().count("::add-mask::"), 4)
            for line in output.getvalue().splitlines():
                if not line.startswith("::add-mask::"):
                    self.assertNotIn(token, line)
            if os.name != "nt":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_partial_or_missing_release_credentials_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "defines.json"
            for environment in [
                {"NEUROMESH_REPORT_CHAT_ID": "-1234"},
                {"REQUIRE_DEVELOPER_REPORT_DELIVERY": "true"},
                {"NEUROMESH_REPORT_ENDPOINT": "http://example.test/report"},
            ]:
                with self.assertRaises(ValueError):
                    write_config(path, environment)
                self.assertFalse(path.exists())

    def test_pull_request_builds_can_be_tested_without_secrets(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            path = Path(folder) / "defines.json"
            write_config(path, {})
            self.assertTrue(path.exists())
