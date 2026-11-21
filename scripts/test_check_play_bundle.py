"""Regression checks for Android package validation."""

from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import tempfile
import unittest
import zipfile

from check_play_bundle import REQUIRED_FILES, check_artifact


class AndroidArtifactTest(unittest.TestCase):
    def check(self, name, entries, *, apk):
        with tempfile.TemporaryDirectory() as work:
            package = Path(work) / name
            with zipfile.ZipFile(package, "w") as archive:
                for entry in entries:
                    archive.writestr(entry, "fixture")
            with redirect_stdout(StringIO()):
                return check_artifact(package, apk=apk)

    def test_accepts_required_base_payload(self):
        self.assertFalse(self.check("release.aab", REQUIRED_FILES, apk=False))
        self.assertFalse(self.check("release.apk", {"lib/arm64-v8a/libapp.so"}, apk=True))

    def test_rejects_known_runtime_libraries_and_archives(self):
        for entry in (
            "lib/arm64-v8a/libproot.so",
            "assets/alpine-minirootfs-3.21.9-aarch64.tar.gz",
            "open_code/assets/opencode-linux-arm64-musl.tar.gz",
        ):
            with self.subTest(entry=entry):
                self.assertTrue(self.check("release.aab", REQUIRED_FILES | {entry}, apk=False))
                self.assertTrue(self.check("release.apk", {entry}, apk=True))

    def test_rejects_missing_android_inference(self):
        entries = REQUIRED_FILES - {"base/lib/arm64-v8a/libllama_jni.so"}
        self.assertTrue(self.check("release.aab", entries, apk=False))
