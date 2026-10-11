#!/usr/bin/env bash
set -euo pipefail

repo="${WIVRN_REPO:-superhac/WiVRn}"
version="${WIVRN_VERSION:-latest}"
workdir="${WORKDIR:-$PWD/.build/wivrn}"
outdir="${OUTDIR:-$PWD/dist}"
arch="${DEB_ARCH:-$(dpkg --print-architecture)}"

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb is required." >&2; exit 1; }

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

# WiVRn publishes complete, ready-to-install .deb packages, not a tarball or
# bare binary we repackage ourselves. Its own Version (e.g. 26.9-1) doesn't
# follow the release tag's scheme (e.g. v26.9-trixie), so match the asset by
# architecture instead of deriving a filename from the tag.
asset_name="$(jq -r --arg suffix "_${arch}.deb" \
  '[.assets[] | select(.name | startswith("wivrn_") and endswith($suffix))][0].name // empty' \
  "$release_json")"
if [[ -z "$asset_name" ]]; then
  echo "Release $version of $repo has no wivrn_*_${arch}.deb asset." >&2
  exit 1
fi
asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"

curl "${curl_args[@]}" -o "$workdir/$asset_name" "$asset_url"
# WiVRn doesn't publish a checksum sidecar for its release assets, so the
# download isn't verified against one (unlike vpinfe and vpxconfig).

pkg_arch="$(dpkg-deb -f "$workdir/$asset_name" Architecture)"
if [[ "$pkg_arch" != "$arch" ]]; then
  echo "$asset_name is built for $pkg_arch, not the requested $arch." >&2
  exit 1
fi

# Re-derive the output filename from the deb's own control data rather than
# trusting the upstream asset name stays in that shape.
pkg_name="$(dpkg-deb -f "$workdir/$asset_name" Package)"
pkg_version="$(dpkg-deb -f "$workdir/$asset_name" Version)"
deb_path="$outdir/${pkg_name}_${pkg_version}_${arch}.deb"
cp "$workdir/$asset_name" "$deb_path"
echo "$deb_path"
