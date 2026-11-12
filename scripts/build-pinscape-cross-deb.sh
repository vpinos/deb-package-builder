#!/usr/bin/env bash
set -euo pipefail

repo="${PINSCAPE_CROSS_REPO:-superhac/pinscape-cross}"
version="${PINSCAPE_CROSS_VERSION:-latest}"
workdir="${WORKDIR:-$PWD/.build/pinscape-cross}"
outdir="${OUTDIR:-$PWD/dist}"
arch="${DEB_ARCH:-$(dpkg --print-architecture)}"

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb is required." >&2; exit 1; }

# Upstream only publishes a Linux amd64 .deb.
case "$arch" in
  amd64) ;;
  *) echo "pinscape-cross is only published for amd64, not $arch." >&2; exit 1 ;;
esac

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

# Pinscape-Cross publishes a complete, ready-to-install .deb of its GUI
# (a Tauri app: /usr/bin/pinscape-cross plus a udev rule for the Pinscape
# Pico's USB interfaces), republished unchanged. The release also carries
# an .rpm, an AppImage and the separate pinscape-cli tarballs, none of
# which are wanted: only Pinscape-Cross_<version>_amd64.deb is taken.
asset_name="$(jq -r \
  '[.assets[] | select(.name | test("^Pinscape-Cross_[^_]+_amd64\\.deb$"))][0].name // empty' \
  "$release_json")"
if [[ -z "$asset_name" ]]; then
  echo "Release $version of $repo has no Pinscape-Cross_<version>_amd64.deb asset." >&2
  exit 1
fi
asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"

curl "${curl_args[@]}" -o "$workdir/$asset_name" "$asset_url"
# Pinscape-Cross doesn't publish a checksum sidecar for its release assets,
# so the download isn't verified against one (unlike vpinfe and vpxconfig).

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
