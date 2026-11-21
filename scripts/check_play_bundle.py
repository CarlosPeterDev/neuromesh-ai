"""Measure Android artifacts and reject bundled optional Linux components."""

import argparse
from pathlib import Path
import re
import zipfile


MAX_AAB_BYTES = 200_000_000
ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
FLUTTER_ASSETS = "base/assets/flutter_assets/"
DEBUG_METADATA = "BUNDLE-METADATA/com.android.tools.build.debugsymbols/"
EXCLUDED_FILES = {
    FLUTTER_ASSETS + "packages/piper_phonemize/assets/web/piper-phonemize-wasm-main.data",
    FLUTTER_ASSETS + "packages/sherpa_onnx_web/assets/sherpa-onnx-wasm-web.wasm",
}
RUNTIME_FILES = {
    "libproot.so", "libproot_loader.so", "libtalloc.so", "libandroid-shmem.so",
    "opencode", "libopencode.so", "rootfs.tar", "rootfs.tar.gz",
}
RUNTIME_ARCHIVE = re.compile(r"(?:alpine.*rootfs|opencode-linux).+\.(?:gz|xz|zip|zst|tar)")
REQUIRED_FILES = {
    f"base/lib/{abi}/{library}"
    for abi in ABIS
    for library in ("libapp.so", "libflutter.so")
} | {
    "base/lib/arm64-v8a/libllama_jni.so",
    "base/lib/arm64-v8a/libpiper_phonemize_core.so",
    "base/lib/arm64-v8a/libsherpa-onnx-c-api.so",
    FLUTTER_ASSETS + "packages/piper_phonemize/espeak-ng-data/phondata",
    FLUTTER_ASSETS + "packages/piper_phonemize/espeak-ng-data/phontab",
}


def check_artifact(artifact, *, apk):
    errors = []
    size = artifact.stat().st_size
    label = "Standalone APK" if apk else "Play AAB"
    print(f"{label} {artifact.name}: {size:,} bytes ({size / 1_000_000:.2f} MB)")
    if not apk and size >= MAX_AAB_BYTES:
        errors.append(f"Play AAB must be smaller than {MAX_AAB_BYTES:,} bytes")

    with zipfile.ZipFile(artifact) as package:
        files = {entry.filename for entry in package.infolist() if entry.file_size}
        optional = {
            name for name in files
            if Path(name).name in RUNTIME_FILES or RUNTIME_ARCHIVE.fullmatch(Path(name).name)
        }
        errors.extend(f"Bundled optional runtime: {name}" for name in sorted(optional))
        if not apk:
            if any(name.startswith(DEBUG_METADATA) for name in files):
                errors.append(f"Unexpected contents in {DEBUG_METADATA}")
            errors.extend(f"Unexpected web asset: {name}" for name in sorted(EXCLUDED_FILES & files))
            errors.extend(f"Missing required bundle entry: {name}" for name in sorted(REQUIRED_FILES - files))

    for error in errors:
        print(f"::error::{error}")
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", action="store_true", help="Check standalone APKs instead of Play bundles")
    parser.add_argument("artifacts", type=Path, nargs="+")
    args = parser.parse_args()
    results = [check_artifact(artifact, apk=args.apk) for artifact in args.artifacts]
    return any(results)


if __name__ == "__main__":
    raise SystemExit(main())
