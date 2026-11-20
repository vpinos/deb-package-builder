#!/usr/bin/env bash
set -euo pipefail

repo="${VPINBALL_REPO:-superhac/vpinball}"
version="${VPINBALL_VERSION:-latest}"
revision="${PACKAGE_REVISION:-1}"
workdir="${WORKDIR:-$PWD/.build/vpinball}"
outdir="${OUTDIR:-$PWD/dist}"
arch="${DEB_ARCH:-$(dpkg --print-architecture)}"

depends="libc6, libstdc++6, zlib1g, libdrm2, libgbm1, libglu1-mesa | libglu1, libegl1, libgl1, libwayland-client0, libwayland-egl1, libudev1, libx11-6, libxcursor1, libxi6, libxss1, libxtst6, libxkbcommon0, libxrandr2, libasound2, libpipewire-0.3-0"
case "$arch" in
  amd64) platform="linux-x64" ;;
  # ZeDMD support links libgpiod on aarch64 only.
  arm64) platform="linux-aarch64"; depends="$depends, libgpiod3" ;;
  *) echo "No vpinball release asset for architecture $arch." >&2; exit 1 ;;
esac

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

rm -rf "$workdir"
mkdir -p "$workdir" "$outdir"

api_base="https://api.github.com/repos/$repo"
curl_args=(-fsSL)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

release_json="$workdir/release.json"
if [[ "$version" == "latest" ]]; then
  curl "${curl_args[@]}" "$api_base/releases/latest" > "$release_json"
  version="$(jq -r '.tag_name' "$release_json")"
else
  curl "${curl_args[@]}" "$api_base/releases/tags/$version" > "$release_json"
fi

upstream_tag="${version#v}"
asset_name="VPinballX_BGFX-${upstream_tag}-${platform}-Release.tar.gz"
asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"
if [[ -z "$asset_url" ]]; then
  echo "Release $version of $repo has no asset named $asset_name." >&2
  exit 1
fi

curl "${curl_args[@]}" -o "$workdir/$asset_name" "$asset_url"
# superhac/vpinball releases don't publish a checksum sidecar to verify
# the download against, unlike the vpinfe/vpxconfig release assets.

upstream_version="$(printf '%s' "$upstream_tag" | tr '_' '.' | sed -E 's/[^A-Za-z0-9.+:~-]/./g')"
# Epoch 1: upstream switched from a fake, always-increasing timestamp version
# (10.9.<buildtime>) to its real tag (<semver>-<height>-<sha>), which sorts
# lower to dpkg (e.g. 10.8.1 < 10.9.*). The epoch keeps every future build
# ordered above every version already published under the old scheme.
package_version="1:${upstream_version}-${revision}"

extract_dir="$workdir/extract"
mkdir -p "$extract_dir"
tar -xzf "$workdir/$asset_name" -C "$extract_dir"

if [[ ! -f "$extract_dir/VPinballX_BGFX" ]]; then
  echo "VPinballX_BGFX not found in $asset_name." >&2
  exit 1
fi

pkgroot="$workdir/pkgroot"
rm -rf "$pkgroot"
install -d "$pkgroot/DEBIAN" "$pkgroot/opt/vpinball" "$pkgroot/usr/bin" "$pkgroot/usr/share/applications"

# The release tarball is the same flat, vendored-library layout vpinball's own
# build produces (CMAKE_INSTALL_RPATH=$ORIGIN): the binary, its shared libs,
# assets/scripts/docs and every plugin all sit flat next to each other. Ship
# the whole tree, not just the binary.
cp -a "$extract_dir/." "$pkgroot/opt/vpinball/"
chmod 0755 "$pkgroot/opt/vpinball/VPinballX_BGFX"

cat > "$pkgroot/usr/bin/vpinball" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/vpinball
exec ./VPinballX_BGFX "$@"
LAUNCHER
chmod 0755 "$pkgroot/usr/bin/vpinball"

cat > "$pkgroot/usr/share/applications/vpinball.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Visual Pinball X
Comment=Standalone Visual Pinball player
Exec=vpinball
Terminal=false
Categories=Game;Emulator;
DESKTOP

installed_size="$(du -sk "$pkgroot" | awk '{print $1}')"
# Breaks: VPX 10.9 keeps its settings in ~/.local/share/VPinballX/10.9
# instead of 10.8. vpinos-core before 1.1.30 has 10.8 hard-coded, so its
# VPinOS Configuration and VR switch would edit a file VPX no longer reads.
# This makes apt upgrade vpinos-core along with vpinball. It has no effect
# on systems without vpinos-core.
cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: vpinball
Version: ${package_version}
Architecture: ${arch}
Maintainer: Superhac <superhac007@gmail.com>
Installed-Size: ${installed_size}
Depends: ${depends}
Breaks: vpinos-core (<< 1.1.30)
Section: games
Priority: optional
Homepage: https://github.com/vpinball/vpinball
Description: Visual Pinball X standalone player
 Visual Pinball X is an open source pinball table editor and simulator.
 This package installs the standalone Linux BGFX player release build.
CONTROL

# The filename just needs to be unique per package/arch; apt-ftparchive reads
# the real Version (with epoch) from the control file above, not from the
# filename. Drop the epoch here instead of percent-encoding it: GitHub's
# release-asset upload strips '%' from filenames, which previously left the
# downloaded .deb unable to match the name recorded in its .sha256 sidecar.
file_version="${package_version#*:}"
deb_path="$outdir/vpinball_${file_version}_${arch}.deb"
dpkg-deb --build --root-owner-group "$pkgroot" "$deb_path"
echo "$deb_path"
