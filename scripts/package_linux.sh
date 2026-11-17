#!/usr/bin/env bash
# Builds a .deb and an AppImage from the Flutter Linux bundle.
# usage: package_linux.sh <bundle dir> <version> <icon.png>
set -euo pipefail
B=$(realpath "$1"); V="$2"; ICON=$(realpath "$3")
OUT=$PWD

# ---- .deb (installs to /opt/neuromesh-ai, adds a menu entry and a command) ----
P=$(mktemp -d)
mkdir -p "$P/DEBIAN" "$P/opt/neuromesh-ai" "$P/usr/bin" "$P/usr/share/applications" "$P/usr/share/icons/hicolor/512x512/apps"
cp -r "$B"/. "$P/opt/neuromesh-ai/"
ln -s /opt/neuromesh-ai/neuromesh_ai "$P/usr/bin/neuromesh-ai"
cp "$ICON" "$P/usr/share/icons/hicolor/512x512/apps/neuromesh-ai.png"
cat > "$P/usr/share/applications/neuromesh-ai.desktop" <<D
[Desktop Entry]
Type=Application
Name=NeuroMesh AI
Comment=Private on-device AI assistant
Exec=/opt/neuromesh-ai/neuromesh_ai
Icon=neuromesh-ai
Categories=Utility;Development;
Terminal=false
D
SIZE=$(du -sk "$P" | cut -f1)
cat > "$P/DEBIAN/control" <<C
Package: neuromesh-ai
Version: $V
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $SIZE
Maintainer: NeuroMesh <noreply@neuromesh.local>
Depends: libgtk-3-0, libsecret-1-0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libasound2 | libasound2t64
Description: NeuroMesh AI
 Private on-device AI assistant with a bundled llama.cpp server.
C
dpkg-deb --root-owner-group -Zxz -z3 --build "$P" "$OUT/NeuroMesh-AI-v${V}-linux-x64.deb"

# ---- AppImage (runs on most distros, no install) ----
A=$(mktemp -d)/NeuroMesh.AppDir
mkdir -p "$A/usr/lib/neuromesh-ai"
cp -r "$B"/. "$A/usr/lib/neuromesh-ai/"
cp "$ICON" "$A/neuromesh-ai.png"
cat > "$A/neuromesh-ai.desktop" <<D
[Desktop Entry]
Type=Application
Name=NeuroMesh AI
Exec=neuromesh_ai
Icon=neuromesh-ai
Categories=Utility;
D
cat > "$A/AppRun" <<'R'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib/neuromesh-ai/lib:$LD_LIBRARY_PATH"
exec "$HERE/usr/lib/neuromesh-ai/neuromesh_ai" "$@"
R
chmod +x "$A/AppRun"
curl -fsSL --retry 3 -o appimagetool https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool
ARCH=x86_64 ./appimagetool --appimage-extract-and-run "$A" "$OUT/NeuroMesh-AI-v${V}-linux-x64.AppImage" || echo "AppImage step failed (the .deb and tar.gz are still published)"
ls -la "$OUT"/NeuroMesh-AI-v${V}-linux-x64.* || true
