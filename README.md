# vpinos-deb-repo

This repository builds Debian packages for VPINOS-related projects and publishes
the `.deb` files as GitHub Release assets.

The current packages are:

- `vpinball`, repackaged from [`superhac/vpinball`](https://github.com/superhac/vpinball)
  release assets
- `vpinfe`, repackaged from [`superhac/vpinfe`](https://github.com/superhac/vpinfe)
  release assets
- `vpxconfig`, repackaged from [`vpinos/vpxconfig`](https://github.com/vpinos/vpxconfig)
  release assets
- `wivrn`, fetched from [`superhac/WiVRn`](https://github.com/superhac/WiVRn)
  release assets (already-built `.deb`s, republished as-is)

GitHub rejects normal git files larger than 100 MB, while GitHub Release assets
can be much larger. The workflow therefore uploads `.deb` files to a release
instead of committing them to `pool/`.

## Installing with apt

End users should install through the signed apt repository published from these
builds, not by downloading `.deb` files from releases. See
[`superhac/vpinos-repo`](https://github.com/superhac/vpinos-repo) for the
instructions.

## Build Packages

Run the `Build Debian packages` workflow from the GitHub Actions tab. Each run
builds `vpinball`, `vpinfe`, `vpxconfig` and `wivrn`.

## vpinball

The `vpinball` job runs once per architecture (amd64, arm64). For each:

1. reads the selected release from `https://github.com/superhac/vpinball`
   (`vpinball_version`, default `latest`),
2. downloads that architecture's Linux BGFX standalone player release asset,
3. creates a `vpinball` Debian package,
4. writes it to `dist/`,
5. generates a `.sha256` checksum sidecar, and
6. uploads the `.deb` and checksum sidecar to the selected GitHub Release.

`superhac/vpinball` doesn't publish a checksum sidecar for its release assets,
so the download isn't verified against one (unlike vpinfe and vpxconfig).

The package version is the upstream release tag, e.g. `10.8.1-5958-bb02f4439-1`.
Bump `package_revision` to repackage the same upstream release.

## vpinfe

The `vpinfe` job:

1. reads the selected release from `https://github.com/superhac/vpinfe`,
2. downloads the selected slim Linux release zip and `checksums.txt`,
3. verifies the zip SHA256,
4. creates a `vpinfe` Debian package,
5. writes it to `dist/`,
6. generates a `.sha256` checksum sidecar, and
7. uploads the `.deb` and checksum sidecar to the selected GitHub Release.

Only the slim VPinFE release assets are packaged. The default is
`linux-x64-slim`; `linux-arm64-slim` is available as a workflow input.

## vpxconfig

The `vpxconfig` job:

1. reads the selected release from `https://github.com/vpinos/vpxconfig`
   (`vpxconfig_version`, default `latest`),
2. downloads the single-file `vpxconfig` release asset and its `.sha256`,
3. verifies the checksum,
4. creates an amd64 `vpxconfig` Debian package that installs the executable
   to `/usr/bin/vpxconfig`,
5. writes it to `dist/`,
6. generates a `.sha256` checksum sidecar, and
7. uploads the `.deb` and checksum sidecar to the selected GitHub Release.

The package version is the upstream release tag, e.g. `0.5.2-1`.

## wivrn

The `wivrn` job runs once per architecture (amd64, arm64). For each:

1. reads the selected release from `https://github.com/superhac/WiVRn`
   (`wivrn_version`, default `latest`),
2. downloads that architecture's `wivrn_*.deb` release asset — already a
   complete Debian package built by upstream, not a binary or tarball we
   repackage ourselves,
3. writes it to `dist/`,
4. generates a `.sha256` checksum sidecar, and
5. uploads the `.deb` and checksum sidecar to the selected GitHub Release.

`superhac/WiVRn` doesn't publish a checksum sidecar for its release assets
either, so the download isn't verified against one. `package_revision` doesn't
apply to this package, since its Debian revision comes from upstream.

**WiVRn's `.deb`s are built for Debian trixie (13)** and depend on package
names (`libqt6core6t64`, `libarchive13t64`, …) from Debian's 64-bit time_t
transition, so it needs Debian 13 or newer.

## Releases

Each workflow run creates a brand-new GitHub Release, tagged
`<release_tag>-<run number>` (e.g. `vpinos-debs-42`), instead of reusing or
adding to a previous release. Override `release_tag` to change the base
name used for that run's release.

The uploaded checksum sidecars can be used to verify downloads:

```bash
sha256sum -c vpinball_*.deb.sha256
sha256sum -c vpinfe_*.deb.sha256
sha256sum -c vpxconfig_*.deb.sha256
sha256sum -c wivrn_*.deb.sha256
```

## Local Builds

Build VPinball locally:

```bash
sudo apt-get install curl dpkg-dev jq
OUTDIR="$PWD/dist" scripts/build-vpinball-deb.sh
```

Build VPinFE locally:

```bash
sudo apt-get install curl dpkg-dev jq unzip
OUTDIR="$PWD/dist" scripts/build-vpinfe-deb.sh
```

Build VPXConfig locally:

```bash
sudo apt-get install curl dpkg-dev jq
OUTDIR="$PWD/dist" scripts/build-vpxconfig-deb.sh
```

Fetch WiVRn locally:

```bash
sudo apt-get install curl dpkg-dev jq
OUTDIR="$PWD/dist" scripts/build-wivrn-deb.sh
```
