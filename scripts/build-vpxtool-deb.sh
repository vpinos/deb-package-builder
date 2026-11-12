#!/usr/bin/env bash
# Packages a francisdb/vpxtool release as vpxtool_<tag>-<rev>_<arch>.deb.
#
# Upstream's Linux release assets are single statically linked executables
# (vpxtool-linux-<x86_64|aarch64>-<tag>.tar.gz), so the package is just
# /usr/bin/vpxtool with no library dependencies. Upstream publishes no
# checksum sidecar.
#
# VPXTOOL_VERSION is a release tag, or "latest". CI passes the tag that
# scripts/plan.sh resolved, so plan and build always agree.
set -euo pipefail

repo="${VPXTOOL_REPO:-francisdb/vpxtool}"
version="${VPXTOOL_VERSION:-latest}"
revision="${PACKAGE_REVISION:-1}"
workdir="${WORKDIR:-$PWD/.build/vpxtool}"
outdir="${OUTDIR:-$PWD/dist}"
arch="${DEB_ARCH:-$(dpkg --print-architecture)}"
case "$arch" in
  amd64) upstream_arch="x86_64" ;;
  arm64) upstream_arch="aarch64" ;;
  *) echo "No vpxtool release asset for architecture $arch." >&2; exit 1 ;;
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

asset_name="vpxtool-linux-${upstream_arch}-${version}.tar.gz"
bin_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"
if [[ -z "$bin_url" ]]; then
  echo "Release $version of $repo has no asset $asset_name." >&2
  exit 1
fi

curl "${curl_args[@]}" -o "$workdir/$asset_name" "$bin_url"
tar -xzf "$workdir/$asset_name" -C "$workdir" vpxtool

# Make sure the binary really is for the target architecture.
case "$arch" in
  amd64) want_machine="X86-64" ;;
  arm64) want_machine="AArch64" ;;
esac
machine="$(LC_ALL=C readelf -h "$workdir/vpxtool" | awk -F: '/Machine:/{gsub(/^ +/,"",$2); print $2}')"
if [[ "$machine" != *"$want_machine"* ]]; then
  echo "$asset_name contains a $machine binary, expected $want_machine." >&2
  exit 1
fi

upstream_version="${version#v}"
upstream_version="$(printf '%s' "$upstream_version" | tr '_' '.' | sed -E 's/[^A-Za-z0-9.+:~]/./g')"
package_version="${upstream_version}-${revision}"

pkgroot="$workdir/pkgroot"
rm -rf "$pkgroot"
install -d "$pkgroot/DEBIAN" "$pkgroot/usr/bin"
install -m 0755 "$workdir/vpxtool" "$pkgroot/usr/bin/vpxtool"

installed_size="$(du -sk "$pkgroot" | awk '{print $1}')"
cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: vpxtool
Version: ${package_version}
Architecture: ${arch}
Maintainer: Superhac <superhac007@gmail.com>
Installed-Size: ${installed_size}
Section: utils
Priority: optional
Homepage: https://github.com/${repo}
Description: Terminal frontend and utilities for Visual Pinball
 vpxtool is a command-line tool for Visual Pinball X tables: it can
 extract, assemble, diff and inspect .vpx files, index a table
 collection, and act as a simple terminal-based frontend.
 This package installs the upstream statically linked release executable.
CONTROL

deb_path="$outdir/vpxtool_${package_version}_${arch}.deb"
dpkg-deb --build --root-owner-group "$pkgroot" "$deb_path"
echo "$deb_path"
