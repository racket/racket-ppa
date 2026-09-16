# Updating the Racket PPA

Step-by-step instructions for releasing a new Racket version to the
Ubuntu PPA at https://launchpad.net/~plt/+archive/ubuntu/racket.

## Prerequisites

### System packages

```
sudo apt install debhelper dpkg-dev dput devscripts lintian \
  libfreetype-dev libjpeg-dev libpango1.0-dev libpng-dev libssl-dev \
  libxaw7-dev xbitmaps libxft-dev libgl-dev libglu1-mesa-dev \
  libx11-dev libxrender-dev libcairo2-dev sqlite3 zlib1g-dev \
  liblz4-dev libncurses-dev libffi-dev patchutils
```

### GPG signing key

The PPA signing key is stored age-encrypted in the `plt-admin` repo
as `ppa-signing-key`. Decrypt it and import:

```
age -d -i ~/.ssh/YOUR_PRIVATE_KEY /path/to/plt-admin/ppa-signing-key | gpg --import
```

The key identity is `Racket PPA <adm@racket-lang.org>`, fingerprint
`8D08AAF942E1F5C64AAE012A1ED00412299B67EB`. This key must be
registered with the Launchpad account used for uploads.

### Clone the repo

```
git clone git@github.com:racket/racket-ppa.git
cd racket-ppa
```

## Release policy

Target all current Ubuntu LTS releases plus the current non-LTS
release.

To determine which releases to target, check
https://wiki.ubuntu.com/Releases. An LTS release is "current" if its
standard support end date (not ESM) has not passed. The current
non-LTS release is the most recent `.10` or `.04` (non-LTS) release
that is still within its 9-month support window.

As of September 2026 that is:

- jammy (22.04 LTS) — standard support ends April 2027
- noble (24.04 LTS) — standard support ends April 2029
- resolute (26.04 LTS) — current stable release

There is no current non-LTS release to target right now: questing
(25.10) went end of life in July 2026 and stonking (26.10) is still in
development.  `update-ppa.sh` works this list out from the Launchpad
API, so it picks up such changes on its own.

When a release reaches end of life, drop it from the target list.
When a new LTS or non-LTS release comes out, add it.

## Version scheme

```
<racket-version>+ppa<iteration>-<debian-revision>~<release><revision>
```

For example: `9.3+ppa1-1~noble1`

- `+ppa1`: PPA-specific upstream version suffix (increment if
  repackaging the same Racket version)
- `-1`: Debian revision (increment for packaging-only changes)
- `~noble1`: Release-specific suffix. The `~` ensures PPA versions
  sort lower than an equivalent version without the suffix, so an
  official Ubuntu package would take precedence.

## Step 1: Download the source tarball

Find the latest Racket version at https://racket-lang.org/ (the
version number is on the front page) or at
https://download.racket-lang.org/ (lists all available versions).

```
VERSION=9.3  # set to target Racket version
wget https://download.racket-lang.org/installers/${VERSION}/racket-${VERSION}-src.tgz
```

## Step 2: Import source onto the upstream branch

```
git checkout upstream
```

Clear the working tree completely (preserving `.git`):

```
git ls-files -z | xargs -0 rm -f
git clean -fxd
```

Extract the tarball, stripping the top-level directory:

```
tar --strip-components=1 -zxf /path/to/racket-${VERSION}-src.tgz
```

Verify there are no nested `.git` directories (remove any if found):

```
find . -name .git -type d
```

Commit:

```
git add -A
git commit -m "Importing racket-${VERSION}-src.tgz"
```

## Step 3: Update the main branch with new source

Do **not** use `git merge` — with large version gaps the merge
conflicts are unmanageable. Instead, replace all source files while
preserving `debian/`:

```
git checkout main
```

Save the debian directory, replace everything with upstream, restore
debian:

```
cp -a debian /tmp/debian-save
git checkout upstream -- .
rm -rf debian
mv /tmp/debian-save debian
```

Remove any files that exist in the working tree but not in upstream
(leftover from previous versions):

```
# Compare working tree (minus debian/) to upstream
diff <(git ls-tree -r --name-only upstream | sort) \
     <(git ls-files | grep -v '^debian/' | sort) \
     | grep '^>' | sed 's/^> //'
```

If that produces any file paths, `git rm` them.

Commit:

```
git add -A
git commit -m "Update source to Racket ${VERSION}"
```

## Step 3b: Pick up packaging changes from Debian

`debian/` in this repository is a fork of Debian's racket packaging at
https://salsa.debian.org/bremner/racket.  Check on every update, so that
Debian's packaging work — which tracks debhelper and library changes
across Debian and Ubuntu — arrives here instead of being reinvented.

Take **only `debian/`**.  Debian's branch also carries their own copy of
the Racket source tree, always an older release than the tarball just
imported, and their `debian/changelog` records their uploads, not ours.
That is why these are cherry-picks and not a merge: merging would drag
their source tree and their entire history in with the packaging.

`update-ppa.sh` records how far we have got in `DEBIAN_SYNC_COMMIT`.  To
do it by hand:

```
git remote add debian https://salsa.debian.org/bremner/racket.git   # once
git fetch --no-tags debian master

# commits touching debian/, excluding changelog-only ones, oldest first
git log --format='%h %s' --reverse \
    "$DEBIAN_SYNC_COMMIT..debian/master" -- debian/ ':(exclude)debian/changelog'
```

For each, in order:

```
git cherry-pick -n <sha>
git checkout HEAD -- debian/changelog     # keep our changelog
git checkout HEAD -- <any path outside debian/>
git commit -C <sha>
```

Then set `DEBIAN_SYNC_COMMIT` in `update-ppa.sh` to the last commit
picked, and commit that.

A conflict means Debian changed something this repository adapts.  Keep
the local adaptation and take Debian's change around it.  Keeping the
list short is what keeps this step cheap; it is currently six things,
and `git diff debian/master main -- debian/ ':(exclude)debian/changelog'`
prints all of them:

In `debian/control`:

1. `Maintainer` and `Vcs-*` point at the PPA rather than at Debian.
2. `libfreetype-dev` and `libgl-dev | libgl1-mesa-dev`, rather than
   Debian's transitional `libfreetype6-dev` and `libgl1-mesa-dev`
   first.  Debian's names still resolve on every target release today,
   but lintian flags them and Ubuntu retires transitional packages
   sooner than Debian does.
3. `libjpeg-turbo8 | libjpeg62-turbo` in `Recommends`, because
   `libjpeg62-turbo` does not exist on Ubuntu 26.04.
4. `Breaks`/`Replaces: racket-common (<< <version>~)` names the version
   packaged here, which `update-ppa.sh` bumps each release.  This one
   diverges from Debian permanently by design.

Elsewhere:

5. `debian/racket-common.manpages` points at
   `share/pkgs/drracket-core-lib/drracket/drracket.1`, where drracket.1
   lives in Racket 9.x.  Debian packages 8.18, where it is under
   `share/pkgs/drracket`.  Expect this to stop being a difference when
   Debian moves to 9.x — at which point take theirs.
6. No `debian/patches`.  Debian's two patches are an upstream
   cherry-pick and its own revert, so the series is a no-op, and neither
   applies to 9.x source.

`debian/source/local-options` is ours alone rather than a divergence:
it tells dpkg-source to ignore NOTES, UPDATING.md and update-ppa.sh,
which this repository owns and the upstream tarball does not contain.
Debian has no equivalent because their repository does not carry them.

Item 4 is the only one guaranteed to keep diverging, so a conflicting
pick will almost certainly land in `debian/control`.

## Step 4: Update debian packaging

### debian/changelog

Add a new entry at the top. Use the primary target release (e.g.
noble) as the initial distribution. The release-specific suffix will
be adjusted per-release in Step 7.

```
dch -v "${VERSION}+ppa1-1~noble1" -D noble "New upstream release (Racket ${VERSION})"
```

Or edit manually. The format must be:

```
racket (9.3+ppa1-1~noble1) noble; urgency=medium

  * New upstream release (Racket 9.3)

 -- Your Name <your@email>  Tue, 03 Mar 2026 12:00:00 -0500
```

`debian/rules` is dh-based (`dh $@ --builddir=build`), inherited from
Debian.  It was cdbs-based until September 2026; cdbs 0.4.182, which
Ubuntu 26.04 ships, deleted the autotools class that the old rules
included, so cdbs packaging cannot build on 26.04 at all.  Do not
reintroduce cdbs.

### debian/control

Check for obsolete package names in `Build-Depends` and
`Recommends`. Common renames across Ubuntu releases:

| Old | New |
|-----|-----|
| libfreetype6-dev | libfreetype-dev |
| libgl1-mesa-dev | libgl-dev |
| libncurses5-dev, libncursesw5-dev | libncurses-dev |
| libssl1.1 | libssl3 |

Update `Breaks`/`Replaces` version numbers to match the new Racket
version (e.g. `<< 9.3~`).

**Cross-release compatibility:** The same `debian/control` is used for
all target releases. When updating package names, verify that the new
names exist on every target release. You can check with Docker:

```
docker run --rm ubuntu:jammy apt-cache show libfreetype-dev > /dev/null 2>&1 && echo "exists" || echo "missing"
```

In practice, Ubuntu provides transitional packages for renamed
libraries, so the newer name usually works on older releases too. If a
package genuinely doesn't exist on an older release, use alternatives
syntax: `libgl1-mesa-dev | libgl-dev` (dpkg tries left to right).

### debian/racket-common.manpages

Verify the paths to man pages still exist in the source tree. The
drracket.1 man page moved between versions:

```
find . -name 'drracket.1' -not -path './debian/*'
find . -name 'racket.1' -not -path './debian/*'
find . -name 'raco.1' -not -path './debian/*'
```

Update paths in `debian/racket-common.manpages` if they changed.

### Other files to review

- `debian/racket.install`, `debian/racket-common.install`,
  `debian/racket-doc.install` — verify install paths still match the
  build output
- `debian/compat` — debhelper compatibility level
- `debian/rules` — usually does not need changes

## Step 5: Tag upstream and generate the orig tarball

Tag the upstream branch:

```
git tag upstream/${VERSION}+ppa1 upstream
```

Generate the orig tarball from that tag.  (The old cdbs `debian/rules`
had a `get-orig-source` target for this; Debian's dh rules do not, so
call `git archive` directly.)

```
git archive --format=tar --prefix=racket-${VERSION}+ppa1/ \
    upstream/${VERSION}+ppa1 | gzip -9 > ../racket_${VERSION}+ppa1.orig.tar.gz
```

Verify it exists and is the right size (should be ~33MB for recent
Racket versions).

## Step 6: Test build locally

### Source package (quick check)

```
debuild -S -us -uc
```

This validates that the source tree matches the orig tarball and that
`debian/` is well-formed. Fix any errors before proceeding.

Check lintian output. The only expected error is a prebuilt .chm file
in zlib contrib, which is harmless for PPA uploads.

### Binary package (full build, optional but recommended)

```
debuild -us -uc -j$(nproc)
```

This takes 30-40 minutes. Verify the resulting `.deb` files install
and work:

```
dpkg -c racket_*.deb | head
```

### Clean up after test build

If you ran the binary build above, clean the build artifacts before
proceeding. The build creates a `build/` directory and other files
that will cause `debuild -S` to fail with "unexpected upstream
changes":

```
fakeroot debian/rules clean
```

Verify the tree is clean relative to the orig tarball:

```
debuild -S -us -uc
```

If this produces errors about modified or extra files, fix them
before continuing.

## Step 7: Build signed source packages for each release

One source package per target release, each with the release-specific
version suffix and distribution in the first changelog line:

```
racket (9.3+ppa1-1~noble1) noble; urgency=medium
```

Rewrite that line for each release rather than substituting the previous
release name into it.  Substituting silently does nothing when the line
names a release you did not expect, which produces the same source
package under one release name and leaves the other uploads with no
`.changes` file to send:

```
VERSION=9.3
RELEASES="jammy noble resolute"
KEY=8D08AAF942E1F5C64AAE012A1ED00412299B67EB

for RELEASE in $RELEASES; do
    sed -i "1s|^racket (.*) [^;]*;|racket (${VERSION}+ppa1-1~${RELEASE}1) ${RELEASE};|" \
        debian/changelog
    debuild -S -d -k${KEY}
done

git checkout -- debian/changelog     # back to the committed entry
```

`-d` skips the build-dependency check: a source-only build compiles
nothing, and the dependencies that matter are the ones on Launchpad's
builders, which Step 4 already checked against each target release.

Restoring the changelog from git rather than rewriting it once more
leaves the working tree clean whichever release was built last.

Each `debuild -S` produces a `.changes` file in the parent directory.

## Step 8: Upload to PPA

One per target release:

```
dput ppa:plt/racket ../racket_${VERSION}+ppa1-1~jammy1_source.changes
dput ppa:plt/racket ../racket_${VERSION}+ppa1-1~noble1_source.changes
dput ppa:plt/racket ../racket_${VERSION}+ppa1-1~resolute1_source.changes
```

This is the irreversible step.  Launchpad will not accept a version
string twice, so any fix after this needs a new one — `+ppa2`, or `-2`
for a packaging-only change.

After each upload, Launchpad sends email to the uploader's address:

- **Accepted**: the source package passed initial validation and is
  queued for building. This usually arrives within a few minutes.
- **Rejected**: the upload was invalid (bad signature, duplicate
  version, etc.). The email contains the specific error.
- **Build failure**: if the build fails on Launchpad, a separate
  notification is sent with a link to the build log.

If you don't receive an Accepted email within ~10 minutes, check
that `dput` reported success and that the GPG key is correctly
registered with Launchpad.

Monitor build progress at:
https://launchpad.net/~plt/+archive/ubuntu/racket/+packages

Or via the API:

```
curl -s "https://api.launchpad.net/1.0/~plt/+archive/ubuntu/racket?ws.op=getPublishedSources&source_name=racket&status=Published" | python3 -m json.tool
```

Each series is built for amd64 and arm64, so there are six builds.
Watch the binaries rather than the source publications: the sources go
`Published` as soon as they are accepted, while the binaries stay
`Pending` until the publisher runs, and only then does apt see them.

```
curl -s "https://api.launchpad.net/1.0/~plt/+archive/ubuntu/racket?ws.op=getBuildRecords&source_name=racket" \
  | jq -r '.entries[] | "\(.source_package_version)\t\(.arch_tag)\t\(.buildstate)"'

curl -s "https://api.launchpad.net/1.0/~plt/+archive/ubuntu/racket?ws.op=getPublishedBinaries&binary_name=racket" \
  | jq -r '.entries[] | "\(.binary_package_version)\t\(.distro_arch_series_link|split("/")|.[-2:]|join("/"))\t\(.status)"'
```

For 9.3 the whole thing took about two hours: uploaded 23:25, all six
builds finished by 00:31, binaries published 01:36.

## Step 9: Verify installation

Install from the PPA in a clean container for each release.  Note the
`|| true`: on jammy, `add-apt-repository` fails while importing the
signing key — its software-properties-common predates the current
keyserver output — but it still adds the repository, and apt resolves
the PPA fine afterwards.  Without it the check reports a failure that
is not there.

```
for REL in jammy noble resolute; do
  docker run --rm ubuntu:$REL bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends software-properties-common gpg ca-certificates
    add-apt-repository -y ppa:plt/racket || true
    apt-get update -qq
    apt-get install -y racket
    racket --version
    apt-cache policy racket | grep -A1 "\*\*\*" | tail -1
  '
done
```

Expected output: `Welcome to Racket v${VERSION} [cs].`, and an origin
line pointing at `ppa.launchpadcontent.net`.  Check that origin line:
Ubuntu ships its own racket package, so an install can succeed while
silently coming from the distribution rather than from the PPA.

## Step 10: Push git changes

```
git push origin main upstream
git push origin $(git tag -l 'upstream/*')
```

Push every upstream tag origin is missing, not just this release's: a
version may have been packaged here without being uploaded, and its tag
still belongs on origin.

## Troubleshooting

### debuild fails with "unexpected upstream changes"

The source tree doesn't match the orig tarball. Common causes:
- Extra files that exist in main but not in upstream (from old merge
  history). Find and `git rm` them.
- Modified files from a bad merge. Run
  `git diff upstream -- <path>` to check.

### `No rule to make target '/usr/share/cdbs/1/class/autotools.mk'`

`debian/rules` is including cdbs' autotools class, which cdbs 0.4.182
(Ubuntu 26.04 and later) no longer ships.  The packaging was migrated to
dh in September 2026 precisely to avoid this; check that `debian/rules`
starts with `include /usr/share/dpkg/architecture.mk` and uses
`dh $@ --builddir=build`, and that nothing picked up from Debian has
reintroduced the cdbs version.

### A cherry-pick from Debian touches files outside debian/

Expected for some of their commits: Debian's branch contains their own,
older copy of the Racket source tree.  Restore every such path from
`HEAD` before committing — see Step 3b.

### Lintian warnings about obsolete Build-Depends

Update package names in `debian/control`. Run `apt-cache show
<package>` to check if a package exists or has been renamed.

### Binary .deb from one release doesn't install on another

This is expected. Launchpad builds packages per-release with
release-appropriate library versions. The per-release source uploads
in Step 7 handle this.

### GPG key not found by debuild

Make sure the key is imported into your local GPG keyring:

```
gpg --list-keys adm@racket-lang.org
```

If missing, decrypt from plt-admin and import (see Prerequisites).

### Launchpad build fails

Click the build link on the PPA packages page to view the build log.
Common causes:

- **Missing Build-Depends**: a package name doesn't exist on that
  Ubuntu release. Fix `debian/control` (see cross-release
  compatibility note in Step 4), increment the version, and
  re-upload.
- **Build timeout**: Racket's build (including doc rendering) can be
  slow. Launchpad has a build timeout of several hours, which should
  be sufficient, but if it times out, check whether the doc build is
  hanging.
- **Architecture-specific failure**: the build may succeed on amd64
  but fail on arm64. Check the per-architecture build logs.

After fixing the issue, you must increment the version (e.g.
`+ppa1` to `+ppa2`, or `-1` to `-2`) because Launchpad will not
accept a re-upload of the same version string.

### dput rejects the upload

If you get "Already uploaded", either the version was already
uploaded, or you need to increment the version. Launchpad does not
allow re-uploading the same version string. Increment the ppa
iteration (`+ppa2`) or the debian revision (`-2`).
