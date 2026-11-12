#!/usr/bin/env bash
# Usage: scripts/check-upstream.sh
#
# Read-only: tells you which upstream projects have a newer release than the
# tag pinned in packages.env. Compares against each upstream's "Latest"
# release (GitHub's flag, which skips pre-releases and drafts); a newer
# pre-release is shown as a note, never as an update.
#
# A package pinned to "latest" (vpxtool) has nothing pinned to compare, so it
# is compared with the version in the VPinOS apt repo instead: "update" then
# means a run of Build Debian packages would build it.
#
# To take an update: change <PKG>_TAG in packages.env, reset <PKG>_REVISION
# to 1 (if it has one), push. Needs gh. Exits 0 always; nothing is changed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../packages.env
. "${PACKAGES_ENV:-$root/packages.env}"

command -v gh >/dev/null || { echo "gh is required." >&2; exit 1; }

# package  upstream repo (same defaults as the build scripts)
packages=(
  "vpinball   ${VPINBALL_REPO:-superhac/vpinball}"
  "vpinfe     ${VPINFE_REPO:-superhac/vpinfe}"
  "vpxconfig  ${VPXCONFIG_REPO:-vpinos/vpxconfig}"
  "wivrn      ${WIVRN_REPO:-superhac/WiVRn}"
  "xrizer     ${XRIZER_REPO:-Supreeeme/xrizer}"
  "vpx-editor ${VPX_EDITOR_REPO:-jsm174/vpx-editor}"
  "vpxtool    ${VPXTOOL_REPO:-francisdb/vpxtool}"
)

packages_file=""
published_tag() { # <pkg> -> "v<upstream version>" from the apt repo (amd64)
  if [[ -z "$packages_file" ]]; then
    packages_file="$(mktemp)"
    trap 'rm -f "$packages_file"' EXIT
    gh release download apt -R vpinos/deb-repo -p Packages -O "$packages_file" --clobber
  fi
  awk -v p="$1" 'BEGIN{RS="";FS="\n"}
    { n="";v="";a=""
      for(i=1;i<=NF;i++){ if($i~/^Package: /)n=substr($i,10); if($i~/^Version: /)v=substr($i,10); if($i~/^Architecture: /)a=substr($i,15) }
      if(n==p && a=="amd64") print v }' "$packages_file" \
    | sort -V | tail -n1 | sed -E 's/^[0-9]+://; s/-[^-]+$//; s/^/v/'
}

printf '%-11s %-26s %-26s %s\n' PACKAGE PINNED UPSTREAM STATUS
updates=0
for line in "${packages[@]}"; do
  read -r pkg repo <<<"$line"
  key="${pkg//-/_}"
  tagvar="${key^^}_TAG"
  pinned="${!tagvar}"

  latest="$(gh release view -R "$repo" --json tagName -q .tagName 2>/dev/null || true)"
  if [[ -z "$latest" ]]; then
    printf '%-11s %-26s %-26s %s\n' "$pkg" "$pinned" "?" "ERROR: no latest release in $repo"
    continue
  fi

  shown="$pinned"
  if [[ "$pinned" == "latest" ]]; then
    pinned="$(published_tag "$pkg")"
    shown="latest (apt: ${pinned:-none})"
    [[ "$pinned" == "v" ]] && pinned=""
  fi

  if [[ "$pinned" == "$latest" ]]; then
    status="up to date"
  elif [[ -z "$pinned" ]]; then
    status="UPDATE (not published yet)"; updates=$((updates + 1))
  elif [[ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -n1)" == "$latest" ]]; then
    status="UPDATE"; updates=$((updates + 1))
  else
    status="pinned is newer than upstream's latest"
  fi

  # Newest pre-release, if it's newer than the latest release.
  pre="$(gh release list -R "$repo" -L 20 --json tagName,isPrerelease \
           -q '[.[] | select(.isPrerelease)][0].tagName // empty' 2>/dev/null || true)"
  if [[ -n "$pre" && "$(printf '%s\n%s\n' "$latest" "$pre" | sort -V | tail -n1)" == "$pre" ]]; then
    status="$status (pre-release $pre available)"
  fi

  printf '%-11s %-26s %-26s %s\n' "$pkg" "$shown" "$latest" "$status"
done

echo
if (( updates )); then
  echo "$updates update(s). Pin the new tag in packages.env (revision back to 1) and push;"
  echo "for vpxtool just run Build Debian packages."
else
  echo "Everything is on upstream's latest release."
fi
