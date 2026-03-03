# Updating the Racket PPA

Step-by-step instructions for releasing a new Racket version to the
Ubuntu PPA at https://launchpad.net/~plt/+archive/ubuntu/racket.

## Prerequisites

### System packages

```
sudo apt install cdbs debhelper dpkg-dev dput devscripts lintian \
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

As of March 2026 that is:

- jammy (22.04 LTS) — standard support ends April 2027
- noble (24.04 LTS) — standard support ends April 2029
- questing (25.10) — support ends July 2026

When a release reaches end of life, drop it from the target list.
When a new LTS or non-LTS release comes out, add it.

## Version scheme

```
<racket-version>+ppa<iteration>-<debian-revision>~<release><revision>
```

For example: `9.1+ppa1-1~noble1`

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
VERSION=9.1  # set to target Racket version
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
racket (9.1+ppa1-1~noble1) noble; urgency=medium

  * New upstream release (Racket 9.1)

 -- Your Name <your@email>  Tue, 03 Mar 2026 12:00:00 -0500
```

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
version (e.g. `<<9.1~`).

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

Generate the orig tarball (this uses `git archive` via `debian/rules`):

```
./debian/rules get-orig-source
```

This creates `../racket_${VERSION}+ppa1.orig.tar.gz`. Verify it
exists and is the right size (should be ~33MB for recent Racket
versions).

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
debuild -- clean
```

Verify the tree is clean relative to the orig tarball:

```
debuild -S -us -uc
```

If this produces errors about modified or extra files, fix them
before continuing.

## Step 7: Build signed source packages for each release

For each target release, modify the first line of `debian/changelog`
to set the release-specific version suffix and distribution, then
build a signed source package.

The changelog first line has the form:

```
racket (9.1+ppa1-1~noble1) noble; urgency=medium
```

Both the `~<release>1` version suffix and the distribution field
must match the target release.

Build for all releases using a loop:

```
PRIMARY=noble
RELEASES="noble jammy questing"
KEY=8D08AAF942E1F5C64AAE012A1ED00412299B67EB

for RELEASE in $RELEASES; do
    sed -i "1s/~${PRIMARY}1/~${RELEASE}1/" debian/changelog
    sed -i "1s/) ${PRIMARY};/) ${RELEASE};/" debian/changelog
    debuild -S -k${KEY}
    # restore to primary for next iteration
    sed -i "1s/~${RELEASE}1/~${PRIMARY}1/" debian/changelog
    sed -i "1s/) ${RELEASE};/) ${PRIMARY};/" debian/changelog
done
```

Set `PRIMARY` to whichever release the changelog currently targets.
Set `RELEASES` to the full list of target releases (including the
primary). The loop modifies the changelog, builds, then restores it,
so the working tree is clean at the end.

Each `debuild -S` produces a `.changes` file in the parent directory.

## Step 8: Upload to PPA

```
dput ppa:plt/racket ../racket_${VERSION}+ppa1-1~noble1_source.changes
dput ppa:plt/racket ../racket_${VERSION}+ppa1-1~jammy1_source.changes
dput ppa:plt/racket ../racket_${VERSION}+ppa1-1~questing1_source.changes
```

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

Builds typically take ~40 minutes per release on Launchpad builders.
After the build succeeds, it takes additional time for the Launchpad
publisher to make binaries available via apt (usually within an hour).

## Step 9: Verify installation

Test in a clean Docker container for each release:

```
docker run --rm -it ubuntu:noble bash -c '
  apt-get update &&
  apt-get install -y software-properties-common gpg &&
  add-apt-repository -y ppa:plt/racket &&
  apt-get update &&
  apt-get install -y racket &&
  racket --version
'
```

Expected output: `Welcome to Racket v9.1 [cs].`

## Step 10: Push git changes

```
git push origin main upstream
git push origin upstream/${VERSION}+ppa1
```

## Troubleshooting

### debuild fails with "unexpected upstream changes"

The source tree doesn't match the orig tarball. Common causes:
- Extra files that exist in main but not in upstream (from old merge
  history). Find and `git rm` them.
- Modified files from a bad merge. Run
  `git diff upstream -- <path>` to check.

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
