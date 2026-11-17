#!/usr/bin/env bash
# Packages a superhac/vpx-ssf-test-table release as
# vpx-ssf-test-table_<tag>-<rev>_all.deb.
#
# Upstream's release asset is a zip of one ordinary table folder
# (SSF_Speaker_Test-<tag>.zip -> SSF_Speaker_Test/ with the .vpx, its
# .directb2s and music/). The package installs that folder unchanged as
# /usr/share/vpx-ssf-test-table/SSF_Speaker_Test/. It's data only, so it's
# Architecture: all and has no dependencies. VPinOS's menu (Testing > SSF
# Speaker Test) runs it from a per-user copy, since VPX writes its cache next
# to the table. Upstream publishes no checksum sidecar.
#
# VPX_SSF_TEST_TABLE_VERSION is a release tag, or "latest". CI passes the tag
# that scripts/plan.sh resolved, so plan and build always agree.
set -euo pipefail

repo="${VPX_SSF_TEST_TABLE_REPO:-superhac/vpx-ssf-test-table}"
version="${VPX_SSF_TEST_TABLE_VERSION:-latest}"
revision="${PACKAGE_REVISION:-1}"
workdir="${WORKDIR:-$PWD/.build/vpx-ssf-test-table}"
outdir="${OUTDIR:-$PWD/dist}"
table="SSF_Speaker_Test"

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
command -v unzip >/dev/null || { echo "unzip is required." >&2; exit 1; }

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

asset_name="${table}-${version}.zip"
zip_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"
if [[ -z "$zip_url" ]]; then
  echo "Release $version of $repo has no asset $asset_name." >&2
  exit 1
fi

curl "${curl_args[@]}" -o "$workdir/$asset_name" "$zip_url"
mkdir "$workdir/unpacked"
unzip -q "$workdir/$asset_name" -d "$workdir/unpacked"

# The zip must be exactly one table folder with the .vpx in it.
src="$workdir/unpacked/$table"
if [[ ! -f "$src/$table.vpx" ]]; then
  echo "$asset_name has no $table/$table.vpx." >&2
  exit 1
fi
extra="$(find "$workdir/unpacked" -mindepth 1 -maxdepth 1 ! -name "$table")"
if [[ -n "$extra" ]]; then
  echo "$asset_name has files outside $table/:" >&2
  echo "$extra" >&2
  exit 1
fi

upstream_version="${version#v}"
upstream_version="$(printf '%s' "$upstream_version" | tr '_' '.' | sed -E 's/[^A-Za-z0-9.+:~]/./g')"
package_version="${upstream_version}-${revision}"

pkgroot="$workdir/pkgroot"
dest="$pkgroot/usr/share/vpx-ssf-test-table"
rm -rf "$pkgroot"
install -d "$pkgroot/DEBIAN" "$dest"
cp -R "$src" "$dest/"
find "$dest" -type d -exec chmod 0755 {} +
find "$dest" -type f -exec chmod 0644 {} +

installed_size="$(du -sk "$pkgroot" | awk '{print $1}')"
cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: vpx-ssf-test-table
Version: ${package_version}
Architecture: all
Maintainer: Superhac <superhac007@gmail.com>
Installed-Size: ${installed_size}
Section: games
Priority: optional
Enhances: vpinball
Homepage: https://github.com/${repo}
Description: Visual Pinball table for testing a 7.1 SSF speaker setup
 SSF Speaker Test is a Visual Pinball X utility table that checks a 7.1
 Surround Sound Feedback (SSF) cabinet is wired and configured correctly.
 It plays a test sound on one speaker at a time and shows the active
 speaker on the backglass.
 This package installs the upstream release's table folder, unchanged, in
 /usr/share/vpx-ssf-test-table.
CONTROL

deb_path="$outdir/vpx-ssf-test-table_${package_version}_all.deb"
dpkg-deb --build --root-owner-group "$pkgroot" "$deb_path"
echo "$deb_path"
