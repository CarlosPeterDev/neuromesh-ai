#!/usr/bin/env bash
set -euo pipefail
run_id=${1:?Pass the successful preview run ID}
[[ "$run_id" =~ ^[0-9]+$ ]] || { echo 'Invalid run ID' >&2; exit 1; }
: "${GH_REPO:?Set owner/repository}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh api "repos/$GH_REPO/actions/runs/$run_id" > "$work/run.json"
source_sha=$(python3 - "$work/run.json" "$GH_REPO" <<'PY'
import json,sys
run=json.load(open(sys.argv[1]))
assert run['conclusion']=='success' and run['status']=='completed', 'Source run did not pass'
assert run['event']=='workflow_dispatch', 'Source must be a manual preview run'
assert run['path']=='.github/workflows/android-release.yml', 'Unexpected source workflow'
assert run['repository']['full_name']==sys.argv[2], 'Unexpected source repository'
print(run['head_sha'])
PY
)
for name in android-arm64-apk android-universal-apk android-play-aab android-checksums; do
  gh run download "$run_id" --name "$name" --dir "$work/packages"
done
cd "$work/packages"
version=$(python3 - <<'PY'
import pathlib,re
files=list(pathlib.Path('.').iterdir())
assert all(p.is_file() and not p.is_symlink() for p in files), 'Unexpected artifact contents'
arm=[p.name for p in files if p.name.endswith('-arm64-dev.apk')]
assert len(arm)==1, 'Expected one ARM64 test APK'
match=re.fullmatch(r'NeuroMesh-AI-v(\d+\.\d+\.\d+)-arm64-dev\.apk',arm[0])
assert match, 'Unexpected package version'
v=match[1]
expected={f'NeuroMesh-AI-v{v}-arm64-dev.apk',f'NeuroMesh-AI-v{v}-universal-dev.apk',f'NeuroMesh-AI-v{v}-dev.aab','SHA256SUMS.txt'}
assert {p.name for p in files}==expected, 'Unexpected asset set'
checks=pathlib.Path('SHA256SUMS.txt').read_text().splitlines()
assert len(checks)==3, 'Expected three package checksums'
for line in checks:
 assert re.fullmatch(r'[a-f0-9]{64}  NeuroMesh-AI-v'+re.escape(v)+r'(?:-arm64-dev\.apk|-universal-dev\.apk|-dev\.aab)',line), 'Invalid checksum entry'
print(v)
PY
)
sha256sum --check --strict SHA256SUMS.txt
tag="v$version-agent-preview"
cat > "$work/notes.md" <<EOF
Development/test-signed NeuroMesh AI preview. APK and AAB files are separate downloadable assets.

The standalone APK installs as NeuroMesh AI Test alongside the production app. It is not a production update. The AAB is development signed and is not a production Play upload.

Built from commit \`$source_sha\` by [successful CI run $run_id](https://github.com/$GH_REPO/actions/runs/$run_id). Package, signing, policy, size, checksum and emulator checks passed in that run. All three downloaded package checksums were verified again before uploading.

Actual Android SAF/offline TTS/playback, ARM JNI inference, real keyboards/rotation and physical clustering still need device verification. General live compound-task planning, live cloud native transports and keyed image editing remain unverified. Pollinations may return rate limits or provider errors. This is a prerelease, not a declaration of production readiness.

[Detailed repair report](https://github.com/$GH_REPO/blob/repair/model-directed-agent/docs/REBUILD_REPORT.md) · [Implementation PR](https://github.com/$GH_REPO/pull/62)
EOF
if gh release view "$tag" --json isDraft,targetCommitish > "$work/release.json" 2>/dev/null; then
  python3 - "$work/release.json" "$source_sha" <<'PY'
import json,sys
release=json.load(open(sys.argv[1]))
assert release['isDraft'], 'Refusing to replace an already published release'
assert release['targetCommitish']==sys.argv[2], 'Draft target does not match verified build'
PY
else
  gh release create "$tag" --target "$source_sha" --title "NeuroMesh AI v$version — Agent rebuild preview" --notes-file "$work/notes.md" --draft --prerelease --latest=false
fi
gh release edit "$tag" --notes-file "$work/notes.md"
gh release upload "$tag" --clobber ./*.apk ./*.aab SHA256SUMS.txt
api_url=$(gh release view "$tag" --json apiUrl --jq .apiUrl)
gh api "$api_url" > "$work/assets.json"
python3 - "$work/assets.json" <<'PY'
import hashlib,json,pathlib,sys
assets={a['name']:a for a in json.load(open(sys.argv[1]))['assets']}
files=[p for p in pathlib.Path('.').iterdir() if p.is_file()]
assert set(assets)=={p.name for p in files}, 'Uploaded asset set differs'
for p in files:
 assert assets[p.name]['size']==p.stat().st_size, 'Uploaded asset size differs'
 assert assets[p.name]['digest']=='sha256:'+hashlib.sha256(p.read_bytes()).hexdigest(), 'Uploaded asset checksum differs'
PY
gh release edit "$tag" --draft=false --prerelease --latest=false
gh release view "$tag" --json url,isDraft,isPrerelease,assets
