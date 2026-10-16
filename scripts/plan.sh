#!/usr/bin/env bash
# Usage: scripts/plan.sh
#
# Works out which packages from packages.env need building: the Debian
# version each pinned tag + revision produces, compared with what the VPinOS
# apt repo (vpinos/deb-repo, release "apt") already publishes. Nothing is
# downloaded except the apt index and the WiVRn release metadata.
#
# Packages are built for amd64 and arm64, except vpx-editor (amd64 only:
# upstream has no arm64 build). A package name's "-" becomes "_" in its
# packages.env variables and $GITHUB_OUTPUT keys (vpx-editor ->
# VPX_EDITOR_TAG, build_vpx_editor).
#
#   same version published (all archs)  -> skip
#   not published / pinned is newer     -> build
#   pinned is OLDER than published      -> error: installations would never
#                                          take it (raise the revision)
#   published for some archs only       -> error: fix by hand
#
# Prints a table (also to $GITHUB_STEP_SUMMARY), and in GitHub Actions writes
# build_<pkg>=true|false, version_<pkg>=<version> and any=true|false to
# $GITHUB_OUTPUT. Exits non-zero on any error. Runs locally too (needs gh).
#
# The version formulas must match scripts/build-*-deb.sh; the workflow checks
# every built .deb against the version planned here.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../packages.env
. "${PACKAGES_ENV:-$root/packages.env}"

apt_repo="${APT_REPO:-vpinos/deb-repo}"
apt_tag="${APT_TAG:-apt}"
archs_for() { # <pkg>
  case "$1" in
    vpx-editor) echo "amd64" ;;
    *) echo "amd64 arm64" ;;
  esac
}

command -v gh >/dev/null || { echo "gh is required." >&2; exit 1; }
command -v dpkg >/dev/null || { echo "dpkg is required." >&2; exit 1; }

# Same normalisation as the build scripts.
norm() { printf '%s' "$1" | tr '_' '.' | sed -E 's/[^A-Za-z0-9.+:~]/./g'; }
norm_dash() { printf '%s' "$1" | tr '_' '.' | sed -E 's/[^A-Za-z0-9.+:~-]/./g'; }

expected_version() { # <pkg> <arch>
  case "$1" in
    vpinball)  echo "1:$(norm_dash "${VPINBALL_TAG#v}")-${VPINBALL_REVISION}" ;;
    vpinfe)    echo "$(norm "${VPINFE_TAG#v}")-${VPINFE_REVISION}" ;;
    vpxconfig) echo "$(norm "${VPXCONFIG_TAG#v}")-${VPXCONFIG_REVISION}" ;;
    xrizer)    echo "$(norm "${XRIZER_TAG#v}")-${XRIZER_REVISION}" ;;
    wivrn)
      # Upstream's own .deb: wivrn_<version>_<arch>.deb
      gh release view "$WIVRN_TAG" -R superhac/WiVRn --json assets -q '.assets[].name' \
        | sed -n "s/^wivrn_\(.*\)_$2\.deb\$/\1/p" | head -n1
      ;;
    vpx-editor)
      # Upstream's own .deb, whose Version is the tag without the "v" (its
      # asset name adds a build number and commit, which the Version
      # doesn't). Not downloaded here (~500 MB); finish-debs.sh checks it.
      echo "$(norm "${VPX_EDITOR_TAG#v}")"
      ;;
  esac
}

packages_file="$(mktemp)"
trap 'rm -f "$packages_file"' EXIT
gh release download "$apt_tag" -R "$apt_repo" -p Packages -O "$packages_file" --clobber

published_version() { # <pkg> <arch>  -> newest published version, or empty
  awk -v p="$1" -v a="$2" 'BEGIN{RS="";FS="\n"}
    { n="";v="";ar=""
      for(i=1;i<=NF;i++){ if($i~/^Package: /)n=substr($i,10); if($i~/^Version: /)v=substr($i,10); if($i~/^Architecture: /)ar=substr($i,15) }
      if(n==p && ar==a) print v }' "$packages_file" \
    | while read -r v; do echo "$v"; done | sort -V | tail -n1
}

out() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }
summary() { echo "$1"; [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }

summary "| Package | Pinned | Version | Published | Action |"
summary "|---|---|---|---|---|"
errors=0
any=false
for pkg in vpinball vpinfe vpxconfig wivrn xrizer vpx-editor; do
  key="${pkg//-/_}"
  tagvar="${key^^}_TAG"
  tag="${!tagvar}"
  present=0; build=0; bad=""
  version=""
  pubs=""
  for arch in $(archs_for "$pkg"); do
    want="$(expected_version "$pkg" "$arch")"
    if [[ -z "$want" ]]; then
      bad="no $arch .deb in $tag"; break
    fi
    if [[ -n "$version" && "$want" != "$version" ]]; then
      bad="architecture versions differ ($version vs $want)"; break
    fi
    version="$want"
    have="$(published_version "$pkg" "$arch")"
    pubs="${pubs:+$pubs, }$arch ${have:-none}"
    if [[ -z "$have" ]] || dpkg --compare-versions "$want" gt "$have"; then
      build=$((build + 1))
    elif [[ "$want" == "$have" ]]; then
      present=$((present + 1))
    else
      bad="pinned $want is older than published $have: raise the revision"
    fi
  done
  if [[ -z "$bad" && $present -gt 0 && $build -gt 0 ]]; then
    bad="published for some architectures only; check the apt repo by hand"
  fi
  if [[ -n "$bad" ]]; then
    action="**ERROR:** $bad"; errors=$((errors + 1)); out "build_$key=false"
  elif [[ $build -gt 0 ]]; then
    action="**build**"; any=true; out "build_$key=true"
  else
    action="skip (already published)"; out "build_$key=false"
  fi
  out "version_$key=$version"
  summary "| $pkg | \`$tag\` | \`${version:-?}\` | $pubs | $action |"
done
out "any=$any"

if (( errors )); then
  echo "plan: $errors error(s); nothing will be built." >&2
  exit 1
fi
$any || summary "Nothing to build: every pinned version is already published."
