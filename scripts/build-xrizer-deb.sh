#!/usr/bin/env bash
set -euo pipefail

repo="${XRIZER_REPO:-Supreeeme/xrizer}"
version="${XRIZER_VERSION:-latest}"
revision="${PACKAGE_REVISION:-1}"
workdir="${WORKDIR:-$PWD/.build/xrizer}"
outdir="${OUTDIR:-$PWD/dist}"
arch="${DEB_ARCH:-$(dpkg --print-architecture)}"
# Upstream only publishes an x86_64 build, so build from source for every
# architecture. This builds natively; there's no cross-compiling, so DEB_ARCH
# has to match the host. The platform directory is where OpenVR looks for
# vrclient.so on each architecture.
case "$arch" in
  amd64) platform_dir="bin/linux64" ;;
  arm64) platform_dir="bin/linuxarm64" ;;
  *) echo "xrizer doesn't support architecture $arch." >&2; exit 1 ;;
esac
if [[ "$arch" != "$(dpkg --print-architecture)" ]]; then
  echo "Building xrizer for $arch needs an $arch host (no cross-compiling)." >&2
  exit 1
fi

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
command -v cargo >/dev/null || { echo "cargo (Rust 1.85 or newer) is required." >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake is required." >&2; exit 1; }
command -v glslc >/dev/null || { echo "glslc is required." >&2; exit 1; }
command -v objdump >/dev/null || { echo "objdump is required." >&2; exit 1; }

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

srcdir="$workdir/src"
mkdir -p "$srcdir"
curl "${curl_args[@]}" "$api_base/tarball/$version" | tar -xz -C "$srcdir" --strip-components=1

# A source tarball has no git checkout, so drop the default git-version feature
# and hand the version over in XRIZER_VERSION, as upstream's README describes.
# static-openxr matches upstream's release builds: games run inside the Steam
# Linux Runtime container, which can't be relied on to have the host's OpenXR
# loader.
(
  cd "$srcdir"
  XRIZER_VERSION="$version" CARGO_TARGET_DIR="$workdir/target" \
    cargo xbuild --release --locked --no-default-features --features monado,static-openxr
)

# xbuild lays the OpenVR runtime out under target/release/bin, with vrclient.so
# symlinked to the built library.
lib="$workdir/target/release/$platform_dir/vrclient.so"
if [[ ! -e "$lib" ]]; then
  echo "Build didn't produce $platform_dir/vrclient.so." >&2
  exit 1
fi

upstream_version="${version#v}"
upstream_version="$(printf '%s' "$upstream_version" | tr '_' '.' | sed -E 's/[^A-Za-z0-9.+:~]/./g')"
package_version="${upstream_version}-${revision}"

# The OpenVR runtime directory is the one containing bin/; it goes under /usr
# so Steam's container still sees it at /run/host/usr.
pkgroot="$workdir/pkgroot"
rm -rf "$pkgroot"
install -d "$pkgroot/DEBIAN" "$pkgroot/usr/lib/xrizer/$platform_dir"
install -m 0644 "$lib" "$pkgroot/usr/lib/xrizer/$platform_dir/vrclient.so"

# Take the glibc floor from the library itself, since it depends on whichever
# host it was built on.
glibc_min="$(objdump -T "$lib" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -Vu | tail -n1)"

installed_size="$(du -sk "$pkgroot" | awk '{print $1}')"
cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: xrizer
Version: ${package_version}
Architecture: ${arch}
Maintainer: Superhac <superhac007@gmail.com>
Installed-Size: ${installed_size}
Depends: libc6 (>= ${glibc_min}), libgcc-s1, libstdc++6
Section: games
Priority: optional
Homepage: https://github.com/Supreeeme/xrizer
Description: OpenVR implementation on top of OpenXR
 xrizer reimplements OpenVR on top of OpenXR, so OpenVR games can run
 through any OpenXR runtime (such as WiVRn or Monado) without SteamVR.
 This package installs a build of the upstream release to /usr/lib/xrizer.
 Point OpenVR at it by adding that path to the "runtime" list in
 ~/.config/openvr/openvrpaths.vrpath, or with VR_OVERRIDE=/usr/lib/xrizer
 (/run/host/usr/lib/xrizer inside the Steam Linux Runtime).
CONTROL

deb_path="$outdir/xrizer_${package_version}_${arch}.deb"
dpkg-deb --build --root-owner-group "$pkgroot" "$deb_path"
echo "$deb_path"
