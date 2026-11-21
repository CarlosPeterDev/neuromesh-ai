#!/usr/bin/env bash
set -euo pipefail

tag="v$VERSION"
title="NeuroMesh AI $tag"
signing_label="Production-signed"
if [[ "$PRODUCTION_SIGNED" != "true" ]]; then
    signing_label="Development-signed Android packages for testing"
    title="$title (Development build)"
fi

scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT
notes="$scratch/release-notes.txt"
cat > "$notes" <<NOTES
NeuroMesh AI $tag
- Commit: $GITHUB_SHA
- Android signing: $signing_label
- GitHub APK signing channel: $STANDALONE_CHANNEL
- Android APK signer SHA-256: $APK_SIGNER
- Play AAB: $AAB_MB MB file, $SPLIT_MB MB ARM64 split download
- Download each installer separately and verify it using SHA256SUMS.txt.
NOTES
if [[ "$STANDALONE_CHANNEL" == "public-test" ]]; then
    cat >> "$notes" <<'NOTES'
- The GitHub APK installs as **NeuroMesh AI Test**. Future APKs in this test channel use the same public test certificate.
- Existing NeuroMesh installations can stay on the device. Export a backup from the old app and restore it in the Test app to bring over chats and settings.
- The public test key is intended for disposable testing. Install these APKs from this release page.
NOTES
fi

latest_route="repos/$GH_REPO/releases/latest"
if ! latest=$(gh api "$latest_route" --jq '.tag_name' 2>"$scratch/error"); then
    if ! grep -Fq 'HTTP 404' "$scratch/error"; then
        cat "$scratch/error" >&2
        exit 1
    fi
    latest=""
fi
make_latest=true
if [[ "$latest" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    newest=$(printf '%s\n' "$tag" "$latest" | sort -V | tail -n 1)
    if [[ "$newest" != "$tag" ]]; then
        make_latest=false
    fi
fi

if existing=$(gh release view "$tag" --json isDraft,targetCommitish,apiUrl \
    --jq '[.isDraft,.targetCommitish,.apiUrl]|@tsv' 2>"$scratch/error"); then
    IFS=$'\t' read -r draft target release_api <<< "$existing"
    # Published tags, and drafts created on existing tags, resolve through Git.
    if [[ "$draft" == "false" ]]; then
        target=$(gh api "repos/$GH_REPO/commits/$tag" --jq '.sha')
    fi
    if [[ "$target" != "$GITHUB_SHA" ]]; then
        echo "::error::Release $tag targets $target, expected $GITHUB_SHA"
        exit 1
    fi
else
    if ! grep -Eqi 'release not found|HTTP 404' "$scratch/error"; then
        cat "$scratch/error" >&2
        exit 1
    fi
    gh release create "$tag" --draft --target "$GITHUB_SHA" --title "$title" --notes-file "$notes"
    draft=true
    release_api=$(gh release view "$tag" --json apiUrl --jq '.apiUrl')
fi

if [[ "$draft" == "true" ]]; then
    gh release upload "$tag" dist/* --clobber
    # Compare the uploaded asset digests with the exact files from this run.
    (cd dist && sha256sum -- * | awk '{print $2 "\tsha256:" $1}' | LC_ALL=C sort) > "$scratch/expected"
    for attempt in {1..6}; do
        gh api "$release_api" --jq '.assets[] | select(.state=="uploaded") | [.name,.digest] | @tsv' |
            LC_ALL=C sort > "$scratch/uploaded"
        if cmp -s "$scratch/expected" "$scratch/uploaded"; then
            break
        fi
        if [[ "$attempt" == 6 ]]; then
            diff -u "$scratch/expected" "$scratch/uploaded" || true
            echo "::error::GitHub Release asset digests do not match the local files"
            exit 1
        fi
        sleep 5
    done
    gh release edit "$tag" --draft=false --prerelease=false --latest="$make_latest" \
        --title "$title" --notes-file "$notes"
elif [[ "$make_latest" == "true" && "$latest" != "$tag" ]]; then
    gh release edit "$tag" --prerelease=false --latest
fi

if [[ "$make_latest" == "true" ]]; then
    for attempt in {1..6}; do
        if [[ "$(gh api "$latest_route" --jq '.tag_name')" == "$tag" ]]; then
            echo "Verified GitHub Latest release: $tag"
            exit 0
        fi
        sleep 5
    done
    echo "::error::GitHub did not mark $tag as Latest"
    exit 1
fi
echo "Published $tag. GitHub Latest remains $latest."
