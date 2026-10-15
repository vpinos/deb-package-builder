# deb-package-builder

Builds the Debian packages for the upstream software VPinOS ships, and
attaches the `.deb` files to a GitHub release here. The packages reach VPinOS
installations once [`vpinos/deb-repo`](https://github.com/vpinos/deb-repo)
publishes that release into the signed VPinOS apt repository.

| Package | From |
|---|---|
| `vpinball` | [`superhac/vpinball`](https://github.com/superhac/vpinball) release assets, repackaged |
| `vpinfe` | [`superhac/vpinfe`](https://github.com/superhac/vpinfe) release assets (slim builds), repackaged |
| `vpxconfig` | [`vpinos/vpxconfig`](https://github.com/vpinos/vpxconfig) release assets, repackaged |
| `wivrn` | [`superhac/WiVRn`](https://github.com/superhac/WiVRn) release assets: upstream's own `.deb`s, republished as-is |
| `xrizer` | [`Supreeeme/xrizer`](https://github.com/Supreeeme/xrizer), built from the tagged source |

All for amd64 and arm64. GitHub rejects git files over 100 MB but allows much
larger release assets, so the `.deb`s live in releases, not in git.

## What gets built: `packages.env`

Every package is pinned to an exact upstream release tag plus our own
packaging revision, in [`packages.env`](packages.env), the only place these
are set:

```sh
VPINFE_TAG=v2.6.6
VPINFE_REVISION=4
```

The resulting package version is the tag without the leading `v`, a `-`, and
the revision (`2.6.6-4`). vpinball also gets an epoch (`1:10.8.1-…-4`), and
WiVRn's version comes from upstream's own `.deb` (no revision).

**Only packages whose version isn't published yet are built.**
[`scripts/plan.sh`](scripts/plan.sh) compares each pinned version with the
VPinOS apt repo's index:

| Pinned version vs published | Result |
|---|---|
| Same | skipped |
| Not published, or higher | built |
| **Lower** | error: VPinOS installations only take a higher version |
| Published for one architecture only | error: fix by hand |

So a run only builds what actually changed, and an unchanged package is never
rebuilt or re-published.

## Making a change

| You want | Edit `packages.env` |
|---|---|
| A new upstream release of a package | Set `<PKG>_TAG` to the new tag, `<PKG>_REVISION=1` |
| A packaging fix (Depends, launcher, files), same upstream | Raise that package's `<PKG>_REVISION` by 1 |
| A packaging fix to a build script | Edit `scripts/build-<pkg>-deb.sh` **and** raise that package's revision |

Then commit and push to `master`:

```bash
git add packages.env scripts/
git commit -m "vpinfe 2.6.7"
git push origin master
```

The push runs **Build Debian packages**:

1. **plan:** decides what to build (the table appears in the run summary).
   Nothing to build means the run ends there.
2. **create-release:** a **draft** release `vpinos-debs-<run number>`
   listing exactly the packages and versions in it.
3. **One job per selected package**, amd64 + arm64: builds it, then
   [`scripts/finish-debs.sh`](scripts/finish-debs.sh) checks that the
   `.deb`'s version is exactly what the plan predicted, writes the
   `.sha256` sidecar, and uploads it.
4. **finalize:** makes the release public only if every build succeeded.
   If anything failed, it stays a draft and can't be published by accident:
   fix it, delete the draft, push again (or re-run).

Then publish the release to the apt repo (this step doesn't happen
automatically):

```bash
gh workflow run update-repo.yml -R vpinos/deb-repo \
  -f source_repo=vpinos/deb-package-builder -f source_release_tag=vpinos-debs-<N>
```

The finalize step prints that exact command in the run summary. In the UI:
`vpinos/deb-repo` → Actions → **Update apt repository** → source
`vpinos/deb-package-builder`, tag `vpinos-debs-<N>`. Packages not in that
release stay as they are in the apt repo.

Manual runs: **Actions → Build Debian packages → Run workflow**. Tick **dry
run** to see only the plan. Check a change before pushing:

```bash
scripts/plan.sh          # needs gh; prints the plan, exits non-zero on errors
```

For how this fits with the other VPinOS repos, see `notes/publishing.md` in
the VPinOS repo.

## vpinball

Downloads that architecture's Linux BGFX standalone player release asset of
`VPINBALL_TAG` and packages it into `/opt/vpinball` with a `vpinball`
launcher. `superhac/vpinball` doesn't publish a checksum sidecar, so the
download isn't verified against one (unlike vpinfe and vpxconfig).

## vpinfe

Downloads the slim Linux release zip for the architecture (`linux-x64-slim`,
`linux-arm64-slim`) of `VPINFE_TAG` and its `checksums.txt`, verifies the
SHA256, and packages it into `/opt/vpinfe` with a `vpinfe` launcher.

## vpxconfig

Downloads the `vpxconfig-linux-<arch>.tar.gz` asset of `VPXCONFIG_TAG` and
its `.sha256`, verifies it, and installs the executable to
`/usr/bin/vpxconfig`.

## wivrn

Downloads that architecture's `wivrn_*.deb` from `WIVRN_TAG`: already a
complete Debian package built by upstream, republished unchanged. Its version
(and revision) is upstream's. There's no checksum sidecar upstream either.
**WiVRn's `.deb`s are built for Debian trixie (13)** and depend on package
names from Debian's 64-bit time_t transition (`libqt6core6t64`, …).

## xrizer

Upstream only publishes an x86_64 build, so xrizer is built from the
`XRIZER_TAG` source for both architectures, natively on `ubuntu-24.04` and
`ubuntu-24.04-arm` (no cross-compiling):

- `cargo xbuild --release`, with the OpenXR loader statically linked like
  upstream's own builds (games run inside the Steam Linux Runtime container,
  which can't be relied on to have the host's loader);
- installs to `/opt/xrizer` (`bin/linux64/vrclient.so` /
  `bin/linuxarm64/vrclient.so`);
- the `libc6` minimum comes from the glibc symbol versions it uses.

`/opt/xrizer` is on WiVRn's default OpenVR compatibility search path, so no
per-user setup is needed: WiVRn finds it, writes
`~/.config/openvr/openvrpaths.vrpath`, and its suggested Steam launch command
sets `VR_OVERRIDE`.

## Releases

Each run that builds something creates a new release `vpinos-debs-<run
number>` containing only the packages built in that run, each with a
`.deb.sha256` sidecar:

```bash
sha256sum -c *.deb.sha256
```

## Local builds

The build scripts read the tag and revision from the environment (default:
`latest` and revision 1). To build exactly what `packages.env` pins:

```bash
. ./packages.env
sudo apt-get install curl dpkg-dev jq unzip
VPINBALL_VERSION=$VPINBALL_TAG PACKAGE_REVISION=$VPINBALL_REVISION OUTDIR=$PWD/dist scripts/build-vpinball-deb.sh
VPINFE_VERSION=$VPINFE_TAG PACKAGE_REVISION=$VPINFE_REVISION OUTDIR=$PWD/dist scripts/build-vpinfe-deb.sh
VPXCONFIG_VERSION=$VPXCONFIG_TAG PACKAGE_REVISION=$VPXCONFIG_REVISION OUTDIR=$PWD/dist scripts/build-vpxconfig-deb.sh
WIVRN_VERSION=$WIVRN_TAG OUTDIR=$PWD/dist scripts/build-wivrn-deb.sh
```

xrizer builds for the host's architecture only and needs Rust 1.85 or newer
(e.g. from [rustup](https://rustup.rs)):

```bash
sudo apt-get install binutils build-essential cmake curl dpkg-dev glslc jq \
  libclang-dev libvulkan-dev libx11-xcb-dev pkg-config
XRIZER_VERSION=$XRIZER_TAG PACKAGE_REVISION=$XRIZER_REVISION OUTDIR=$PWD/dist scripts/build-xrizer-deb.sh
```

VPinFE (`VPINFE_TRIPLET=linux-arm64-slim`) and the others (`DEB_ARCH=arm64`)
can be built for arm64 on an amd64 host; xrizer can't.
