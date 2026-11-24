#!/usr/bin/env bash
set -euo pipefail

repo="${VPINFE_REPO:-vpinfe/vpinfe}"
version="${VPINFE_VERSION:-latest}"
triplet="${VPINFE_TRIPLET:-linux-x64-slim}"
revision="${PACKAGE_REVISION:-1}"
workdir="${WORKDIR:-$PWD/.build/vpinfe}"
outdir="${OUTDIR:-$PWD/dist}"

case "$triplet" in
  linux-x64-slim)
    arch="amd64"
    ;;
  linux-arm64-slim)
    arch="arm64"
    ;;
  *)
    echo "Unsupported VPinFE triplet for Debian packaging: $triplet (only slim builds are supported)" >&2
    exit 1
    ;;
esac

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

if [[ "$version" == "latest" ]]; then
  release_json="$workdir/release.json"
  curl "${curl_args[@]}" "$api_base/releases/latest" > "$release_json"
  version="$(jq -r '.tag_name' "$release_json")"
else
  release_json="$workdir/release.json"
  curl "${curl_args[@]}" "$api_base/releases/tags/$version" > "$release_json"
fi

asset_name="$(jq -r --arg triplet "$triplet" '.assets[$triplet].file // empty' < <(
  curl "${curl_args[@]}" "https://github.com/$repo/releases/download/$version/manifest.json"
))"

if [[ -z "$asset_name" ]]; then
  echo "Could not find asset for $version / $triplet in manifest.json." >&2
  exit 1
fi

asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"
if [[ -z "$asset_url" ]]; then
  asset_url="https://github.com/$repo/releases/download/$version/$asset_name"
fi

curl "${curl_args[@]}" "https://github.com/$repo/releases/download/$version/checksums.txt" > "$workdir/checksums.txt"
curl "${curl_args[@]}" -o "$workdir/$asset_name" "$asset_url"
(cd "$workdir" && sha256sum --check --ignore-missing checksums.txt)

extract_dir="$workdir/extract"
mkdir -p "$extract_dir"
unzip -q "$workdir/$asset_name" -d "$extract_dir"

vpinfe_bin="$(find "$extract_dir" -type f -name vpinfe -perm /111 | sort | head -n 1)"
if [[ -z "$vpinfe_bin" ]]; then
  echo "Could not find executable vpinfe in $asset_name." >&2
  exit 1
fi
app_src="$(dirname "$vpinfe_bin")"

upstream_version="${version#v}"
# A pre-release (v3.0.0-beta.4) gets a tilde, 3.0.0~beta.4, so dpkg sorts it
# below the release it leads to (3.0.0) and above everything before it. With
# a dot (3.0.0.beta.4) it would sort ABOVE 3.0.0, and a beta tester would
# never upgrade to the release. plan.sh's norm_pre does the same.
upstream_version="$(printf '%s' "$upstream_version" | sed -E 's/-([A-Za-z])/~\1/' | tr '_' '.' | sed -E 's/[^A-Za-z0-9.+:~]/./g')"
package_version="${upstream_version}-${revision}"
# The file name carries no tilde: GitHub may rename a release asset with one,
# which would break its .sha256 sidecar and the apt index. Only the name
# changes; the package's Version keeps the tilde.
file_version="${package_version//\~/-}"

pkgroot="$workdir/pkgroot"
rm -rf "$pkgroot"
install -d "$pkgroot/DEBIAN" "$pkgroot/opt/vpinfe" "$pkgroot/usr/bin" "$pkgroot/usr/share/applications"
cp -a "$app_src/." "$pkgroot/opt/vpinfe/"
chmod 0755 "$pkgroot/opt/vpinfe/vpinfe"

cat > "$pkgroot/usr/bin/vpinfe" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/vpinfe
exec ./vpinfe "$@"
LAUNCHER
chmod 0755 "$pkgroot/usr/bin/vpinfe"

cat > "$pkgroot/usr/share/applications/vpinfe.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=VPinFE
Comment=Frontend and manager for Visual Pinball cabinets
Exec=vpinfe
Terminal=false
Categories=Game;Emulator;
DESKTOP

installed_size="$(du -sk "$pkgroot" | awk '{print $1}')"
cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: vpinfe
Version: ${package_version}
Architecture: ${arch}
Maintainer: Superhac <superhac007@gmail.com>
Installed-Size: ${installed_size}
Depends: libc6, libstdc++6, zlib1g, libglib2.0-0, libx11-6, libxcb1, libxext6, libxrender1, libgl1, libegl1, libnss3, libatk-bridge2.0-0, libgtk-3-0, libasound2, libxss1
Section: games
Priority: optional
Homepage: https://github.com/superhac/vpinfe
Description: VPinFE frontend for Visual Pinball
 VPinFE is a frontend and remote manager for Visual Pinball cabinet setups.
 This package installs the upstream Linux release bundle.
CONTROL

deb_path="$outdir/vpinfe_${file_version}_${arch}.deb"
dpkg-deb --build --root-owner-group "$pkgroot" "$deb_path"
echo "$deb_path"
