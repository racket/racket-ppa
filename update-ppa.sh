#!/bin/bash
#
# update-ppa.sh — Build and upload a new Racket release to the Ubuntu PPA.
#
# Usage:
#   ./update-ppa.sh VERSION [OPTIONS]
#
# Required:
#   VERSION              Racket version to package (e.g. 9.2)
#
# Options:
#   --releases LIST      Space-separated Ubuntu release codenames
#                        (default: auto-detect from Launchpad API)
#   --primary RELEASE    Primary release for debian/changelog
#                        (default: newest LTS from target list)
#   --ppa-iteration N    PPA iteration number (default: 1)
#   --ssh-key PATH       SSH private key for decrypting plt-admin secrets
#                        (default: first key found in ~/.ssh/)
#   --skip-binary-build  Skip the local binary test build
#   --no-debian-sync     Skip picking up packaging changes from Debian
#   --no-upload          Skip uploading to PPA
#   --no-push            Skip pushing git changes
#   --no-docker          Skip Docker-based checks (Build-Depends validation)
#   --yes                Auto-confirm all prompts
#   --work-dir DIR       Working directory (default: temporary directory)
#
# Prerequisites:
#   apt packages: cdbs debhelper dpkg-dev dput devscripts lintian
#                 age jq curl docker.io wget
#   Build-Depends from debian/control (see UPDATING.md)

set -euo pipefail

###############################################################################
# Argument parsing
###############################################################################

VERSION=""
RELEASES=""
PRIMARY=""
PPA_ITERATION=1
SSH_KEY=""
SKIP_BINARY_BUILD=false
NO_DEBIAN_SYNC=false
NO_UPLOAD=false
NO_PUSH=false
NO_DOCKER=false
YES=false
WORK_DIR=""

usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --releases)    RELEASES="$2"; shift 2 ;;
        --primary)     PRIMARY="$2"; shift 2 ;;
        --ppa-iteration) PPA_ITERATION="$2"; shift 2 ;;
        --ssh-key)     SSH_KEY="$2"; shift 2 ;;
        --skip-binary-build) SKIP_BINARY_BUILD=true; shift ;;
        --no-debian-sync) NO_DEBIAN_SYNC=true; shift ;;
        --no-upload)   NO_UPLOAD=true; shift ;;
        --no-push)     NO_PUSH=true; shift ;;
        --no-docker)   NO_DOCKER=true; shift ;;
        --yes)         YES=true; shift ;;
        --work-dir)    WORK_DIR="$2"; shift 2 ;;
        --help|-h)     usage ;;
        -*)            echo "Unknown option: $1" >&2; usage ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"; shift
            else
                echo "Unexpected argument: $1" >&2; usage
            fi
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "Error: VERSION is required" >&2
    usage
fi

GPG_KEY="8D08AAF942E1F5C64AAE012A1ED00412299B67EB"

# Debian's packaging is upstream for ours; see UPDATING.md.
DEBIAN_REMOTE_URL="https://salsa.debian.org/bremner/racket.git"
DEBIAN_BRANCH="debian/master"

# Last Debian commit whose debian/ changes have been picked into this
# repository.  This script rewrites the line when it picks up new ones.
DEBIAN_SYNC_COMMIT="639242c9b486a26e62ecdc14ca84b7f44b2af228"

###############################################################################
# Helpers
###############################################################################

log()   { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# Point the top changelog entry at one target release.  This rewrites the
# line rather than substituting the previous release name into it, so it
# does not matter which release the entry currently names.
set_changelog_release() {
    local rel="$1"
    sed -i "1s|^racket (.*) [^;]*;|racket (${VERSION}+ppa${PPA_ITERATION}-1~${rel}1) ${rel};|" \
        debian/changelog
}

confirm() {
    if $YES; then return 0; fi
    local prompt="$1"
    local answer
    read -r -p "$prompt [y/N] " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# Preflight: validate everything before doing any work
###############################################################################

log "Running preflight checks"
PREFLIGHT_OK=true

# --- Required commands ---
REQUIRED_CMDS=(git wget debuild dput dch dpkg-parsechangelog lintian age jq curl)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        warn "Required command not found: $cmd"
        PREFLIGHT_OK=false
    fi
done

# --- SSH key ---
if [[ -z "$SSH_KEY" ]]; then
    for keyfile in ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$keyfile" ]]; then
            SSH_KEY="$keyfile"
            break
        fi
    done
fi
if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
    warn "No SSH key found. Specify --ssh-key PATH."
    PREFLIGHT_OK=false
fi

# --- Source tarball URL exists ---
TARBALL="racket-${VERSION}-src.tgz"
TARBALL_URL="https://download.racket-lang.org/installers/${VERSION}/${TARBALL}"
HTTP_CODE=$(curl -sL -o /dev/null -w '%{http_code}' --head "$TARBALL_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "200" ]]; then
    warn "Source tarball not found at $TARBALL_URL (HTTP $HTTP_CODE)"
    PREFLIGHT_OK=false
fi

# --- Docker is functional ---
if ! $NO_DOCKER; then
    if ! command -v docker &>/dev/null; then
        warn "Docker not found (needed for Build-Depends validation; use --no-docker to skip)"
        PREFLIGHT_OK=false
    elif ! docker info &>/dev/null; then
        warn "Docker is installed but not running or not accessible"
        PREFLIGHT_OK=false
    fi
fi

# --- Git SSH access ---
if ! git ls-remote git@github.com:racket/racket-ppa.git HEAD &>/dev/null; then
    warn "Cannot authenticate to GitHub via SSH (git ls-remote failed)"
    PREFLIGHT_OK=false
fi

# --- GPG key ---
if ! gpg --list-keys "$GPG_KEY" &>/dev/null; then
    # Will need to import from plt-admin — verify we can clone it
    if ! git ls-remote git@github.com:racket/plt-admin.git HEAD &>/dev/null; then
        warn "GPG key not in keyring and cannot access plt-admin repo"
        PREFLIGHT_OK=false
    fi
fi

# --- Determine target Ubuntu releases ---
SERIES_JSON=""
if [[ -z "$RELEASES" ]]; then
    log "Auto-detecting target Ubuntu releases from Launchpad API"

    SERIES_JSON=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series")
    if [[ -z "$SERIES_JSON" ]] || ! echo "$SERIES_JSON" | jq -e '.entries' &>/dev/null; then
        warn "Failed to fetch Ubuntu series from Launchpad API"
        PREFLIGHT_OK=false
    else
        CURRENT_YEAR=$(date +%Y)
        CURRENT_MONTH=$(date +%m)

        # Current stable release
        CURRENT_STABLE=$(echo "$SERIES_JSON" | jq -r \
            '.entries[] | select(.status == "Current Stable Release") | .name')

        # Supported LTS releases still within standard (non-ESM) support.
        # LTS standard support = 5 years from release date.
        LTS_RELEASES=$(echo "$SERIES_JSON" | jq -r \
            --argjson cy "$CURRENT_YEAR" --argjson cm "$CURRENT_MONTH" '
            .entries[]
            | select(.status == "Supported")
            | select(.version | test("^[0-9]+\\.04$"))
            | .datereleased as $dr
            | ($dr | split("-") | .[0] | tonumber) as $ry
            | ($dr | split("-") | .[1] | tonumber) as $rm
            | (($ry + 5) * 12 + $rm) as $eol_month
            | ($cy * 12 + $cm) as $now_month
            | select($now_month < $eol_month)
            | .name
        ')

        # Combine, deduplicate
        RELEASES=$(echo -e "${LTS_RELEASES}\n${CURRENT_STABLE}" | grep -v '^$' | sort -u | tr '\n' ' ')
        RELEASES="${RELEASES% }"
    fi
fi

if [[ -z "$RELEASES" ]]; then
    warn "No target releases determined. Specify --releases."
    PREFLIGHT_OK=false
fi

# --- Determine primary release ---
if [[ -n "$RELEASES" && -z "$PRIMARY" ]]; then
    if [[ -z "$SERIES_JSON" ]]; then
        SERIES_JSON=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series")
    fi
    for rel in $RELEASES; do
        rel_version=$(echo "$SERIES_JSON" | jq -r \
            --arg name "$rel" '.entries[] | select(.name == $name) | .version')
        if echo "$rel_version" | grep -qE '^[0-9]+\.04$'; then
            PRIMARY="$rel"
        fi
    done
    if [[ -z "$PRIMARY" ]]; then
        PRIMARY=$(echo "$RELEASES" | awk '{print $1}')
    fi
fi

# --- Verify Docker images exist for all target releases ---
if [[ -n "$RELEASES" ]] && ! $NO_DOCKER; then
    for release in $RELEASES; do
        if ! docker manifest inspect "ubuntu:${release}" &>/dev/null; then
            warn "Docker image ubuntu:${release} not found"
            PREFLIGHT_OK=false
        fi
    done
fi

# (racket-ppa accessibility already verified in Git SSH access check above)

# --- Report preflight results ---
if ! $PREFLIGHT_OK; then
    die "Preflight checks failed. Fix the issues above before continuing."
fi

log "Preflight checks passed"
log "  Version:  $VERSION"
log "  Releases: $RELEASES"
log "  Primary:  $PRIMARY"
log "  SSH key:  $SSH_KEY"

###############################################################################
# Set up working directory
###############################################################################

if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR=$(mktemp -d -t racket-ppa-XXXXXX)
fi
mkdir -p "$WORK_DIR"
log "Working directory: $WORK_DIR"
cd "$WORK_DIR"

###############################################################################
# Import GPG signing key from plt-admin
###############################################################################

if gpg --list-keys "$GPG_KEY" &>/dev/null; then
    log "GPG signing key already in keyring"
else
    log "Cloning plt-admin to import GPG signing key"
    git clone --depth 1 git@github.com:racket/plt-admin.git "$WORK_DIR/plt-admin"
    age -d -i "$SSH_KEY" "$WORK_DIR/plt-admin/ppa-signing-key" | gpg --import
    rm -rf "$WORK_DIR/plt-admin"
    log "GPG key imported"
fi

###############################################################################
# Step 1: Download source tarball
###############################################################################

if [[ -f "$WORK_DIR/$TARBALL" ]]; then
    log "Source tarball already downloaded: $TARBALL"
else
    log "Downloading $TARBALL_URL"
    wget -q --show-progress -O "$WORK_DIR/$TARBALL" "$TARBALL_URL"
fi

log "Tarball size: $(du -h "$WORK_DIR/$TARBALL" | cut -f1)"

###############################################################################
# Clone racket-ppa
###############################################################################

REPO_DIR="$WORK_DIR/racket-ppa"

if [[ -d "$REPO_DIR/.git" ]]; then
    log "racket-ppa already cloned"
else
    log "Cloning racket-ppa"
    git clone git@github.com:racket/racket-ppa.git "$REPO_DIR"
fi
cd "$REPO_DIR"

# Make sure we have the upstream branch locally
if ! git rev-parse --verify upstream &>/dev/null; then
    git checkout -b upstream origin/upstream
    git checkout main
fi

###############################################################################
# Step 2: Import source onto upstream branch
###############################################################################

log "Importing source onto upstream branch"
cd "$REPO_DIR"
git checkout upstream

# Remember what the previous import contained, so that step 3 can tell
# files left over from it apart from files this repo owns.
PREV_UPSTREAM=$(git rev-parse upstream)

# Clear working tree (preserve .git) using filesystem ops
find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

# Extract tarball
tar --strip-components=1 -zxf "$WORK_DIR/$TARBALL"

# Remove any nested .git directories (skip the repo's own .git)
find . -mindepth 2 -name .git -type d -exec rm -rf {} + 2>/dev/null || true

git add -A
if git diff --cached --quiet; then
    log "Upstream branch already matches tarball, no changes"
else
    git commit -m "Importing racket-${VERSION}-src.tgz"
fi

###############################################################################
# Step 3: Update main branch with new source
###############################################################################

log "Updating main branch with upstream source"
git checkout main

# Save debian/, replace everything with upstream, restore debian/
DEBIAN_SAVE=$(mktemp -d)
cp -a debian "$DEBIAN_SAVE/"
git checkout upstream -- .
rm -rf debian
mv "$DEBIAN_SAVE/debian" debian
rmdir "$DEBIAN_SAVE"

# Remove files left over from the *previous* upstream import: tracked
# files that the old tarball had and the new one does not.  Anything this
# repo owns (debian/, NOTES, UPDATING.md, update-ppa.sh, ...) never
# appeared in an upstream tarball, so it is untouched.
STALE_FILES=$(comm -23 \
    <(git ls-tree -r --name-only "$PREV_UPSTREAM" | sort) \
    <(git ls-tree -r --name-only upstream | sort) \
    | while IFS= read -r f; do
          git ls-files --error-unmatch -- "$f" &>/dev/null && echo "$f"
      done || true)

if [[ -n "$STALE_FILES" ]]; then
    log "Removing stale files not in upstream:"
    echo "$STALE_FILES"
    echo "$STALE_FILES" | xargs git rm -f
fi

git add -A
if git diff --cached --quiet; then
    log "Main branch source already matches upstream, no changes"
else
    git commit -m "Update source to Racket ${VERSION}"
fi

###############################################################################
# Step 3b: Pick up packaging changes from Debian
###############################################################################
#
# debian/ here is a fork of Debian's racket packaging, so each update
# cherry-picks whatever Debian has changed in debian/ since last time.
# Only debian/ is taken: Debian's branch also carries their own, older
# copy of the Racket source tree, and their changelog is theirs, not
# ours.  DEBIAN_SYNC_COMMIT above records how far we have got.

if $NO_DEBIAN_SYNC; then
    log "Skipping Debian packaging sync (--no-debian-sync)"
else
    log "Checking Debian for packaging changes"

    if ! git remote get-url debian &>/dev/null; then
        git remote add debian "$DEBIAN_REMOTE_URL"
    fi
    git fetch --no-tags debian master

    if ! git cat-file -e "$DEBIAN_SYNC_COMMIT" 2>/dev/null; then
        die "DEBIAN_SYNC_COMMIT $DEBIAN_SYNC_COMMIT is not in the repository"
    fi

    # Commits touching debian/, oldest first.  Changelog-only commits are
    # skipped: Debian's changelog entries are not ours.
    NEW_DEBIAN_COMMITS=$(git log --format=%H --reverse \
        "${DEBIAN_SYNC_COMMIT}..${DEBIAN_BRANCH}" \
        -- debian/ ':(exclude)debian/changelog')

    if [[ -z "$NEW_DEBIAN_COMMITS" ]]; then
        log "No new Debian packaging commits"
    else
        echo ""
        log "New Debian packaging commits:"
        while IFS= read -r sha; do
            [[ -z "$sha" ]] && continue
            echo "  $(git log -1 --format='%h %s' "$sha")"
        done <<< "$NEW_DEBIAN_COMMITS"
        echo ""

        if ! confirm "Cherry-pick these into debian/?"; then
            die "Aborted. Re-run with --no-debian-sync to skip this step."
        fi

        while IFS= read -r sha; do
            [[ -z "$sha" ]] && continue
            log "  $(git log -1 --format='%h %s' "$sha")"

            git cherry-pick -n "$sha" >/dev/null 2>&1 || true

            # Keep everything outside debian/, and keep our changelog.
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if [[ "$f" == debian/* && "$f" != debian/changelog ]]; then
                    continue
                fi
                if git cat-file -e "HEAD:$f" 2>/dev/null; then
                    git checkout HEAD -- "$f" 2>/dev/null || true
                else
                    git rm -q --force --ignore-unmatch -- "$f" >/dev/null 2>&1 || true
                fi
            done < <(git show --name-only --format= "$sha")

            # A conflict means Debian changed something this repo adapted;
            # that needs a human, not a rule.
            if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
                echo ""
                warn "Conflict picking $(git log -1 --format='%h %s' "$sha"):"
                git diff --name-only --diff-filter=U
                echo ""
                warn "Resolve in $REPO_DIR keeping the local adaptation, 'git add'"
                warn "each file, commit, set DEBIAN_SYNC_COMMIT in update-ppa.sh to"
                warn "$sha, then re-run this script."
                die "Debian sync needs manual resolution"
            fi

            if git diff --cached --quiet; then
                log "    (nothing for us in that commit)"
                git cherry-pick --quit 2>/dev/null || true
                continue
            fi

            git commit -q \
                --author="$(git log -1 --format='%an <%ae>' "$sha")" \
                -m "$(git log -1 --format=%B "$sha")" \
                -m "(cherry picked from commit $sha)"
            git cherry-pick --quit 2>/dev/null || true
        done <<< "$NEW_DEBIAN_COMMITS"

        # Record how far we have got.  sed -i replaces the file rather
        # than writing in place, so this is safe while the script runs.
        NEW_SYNC=$(git rev-parse "$DEBIAN_BRANCH")
        sed -i "s/^DEBIAN_SYNC_COMMIT=.*/DEBIAN_SYNC_COMMIT=\"${NEW_SYNC}\"/" update-ppa.sh
        git commit -q -m "Track Debian packaging up to ${NEW_SYNC:0:12}" update-ppa.sh
        log "Picked up Debian packaging through ${NEW_SYNC:0:12}"
    fi
fi

###############################################################################
# Step 4: Update debian packaging
###############################################################################

log "Updating debian packaging"

# 4a: debian/changelog
FULL_VERSION="${VERSION}+ppa${PPA_ITERATION}-1~${PRIMARY}1"
CURRENT_VERSION=$(dpkg-parsechangelog -S Version)
# Compare without the ~release suffix: the same upload is built once per
# target release, each with a different suffix, so the suffix currently
# in the changelog says nothing about whether the entry is up to date.
if [[ "${CURRENT_VERSION%%\~*}" == "${FULL_VERSION%%\~*}" ]]; then
    # Re-run after an earlier failure: dch refuses to add an entry that
    # is not newer than the current one.
    log "Changelog already at $CURRENT_VERSION"
else
    dch -v "$FULL_VERSION" -D "$PRIMARY" "New upstream release (Racket ${VERSION})"
fi

# 4b: debian/control — update the Breaks/Replaces that cover files moved
# from racket-common into racket.  racket-common's own Breaks/Replaces on
# racket records an old file move and is deliberately left alone.
sed -i "s/Breaks: racket-common (<<[^)]*)/Breaks: racket-common (<< ${VERSION}~)/" debian/control
sed -i "s/Replaces: racket-common (<<[^)]*)/Replaces: racket-common (<< ${VERSION}~)/" debian/control

# 4c: debian/racket-common.manpages — verify and fix paths
log "Checking man page paths"
MANPAGES_UPDATED=false
while IFS= read -r manpath; do
    manpath=$(echo "$manpath" | xargs)  # trim whitespace
    [[ -z "$manpath" ]] && continue
    if [[ ! -f "$manpath" ]]; then
        warn "Man page path not found: $manpath"
        basename_mp=$(basename "$manpath")
        found=$(find . -name "$basename_mp" -not -path './debian/*' -not -path './.git/*' | head -1)
        if [[ -n "$found" ]]; then
            found="${found#./}"
            log "  Found at: $found"
            sed -i "s|^${manpath}\$|${found}|" debian/racket-common.manpages
            MANPAGES_UPDATED=true
        else
            warn "  Could not find $basename_mp anywhere in source tree"
        fi
    fi
done < debian/racket-common.manpages
if $MANPAGES_UPDATED; then
    log "Updated debian/racket-common.manpages"
fi

# 4d: Validate Build-Depends exist on all target releases
if $NO_DOCKER; then
    log "Skipping Build-Depends validation (--no-docker)"
else
    log "Validating Build-Depends across target releases"

    # One line per Build-Depends entry, alternatives kept together, so
    # that "a | b" counts as satisfied when either exists.
    BUILD_DEP_GROUPS=$(sed -n '/^Build-Depends:/,/^[A-Z][A-Za-z-]*:/p' debian/control \
        | sed '$d' \
        | sed 's/^Build-Depends://' \
        | tr ',' '\n' \
        | sed 's/([^)]*)//g; s/|/ /g; s/^[ \t]*//; s/[ \t]*$//; s/[ \t][ \t]*/ /g' \
        | grep -v '^$')

    DEPS_PROBLEMS=false
    for release in $RELEASES; do
        log "  Checking packages on $release..."
        # One container per release, not one per package.
        MISSING=$(docker run --rm -e GROUPS="$BUILD_DEP_GROUPS" "ubuntu:${release}" \
            bash -c '
                apt-get update -qq >/dev/null 2>&1
                printf "%s\n" "$GROUPS" | while read -r group; do
                    [ -z "$group" ] && continue
                    found=no
                    for pkg in $group; do
                        if apt-cache show "$pkg" >/dev/null 2>&1; then
                            found=yes
                            break
                        fi
                    done
                    [ "$found" = no ] && echo "$group"
                done
                # The loop ends non-zero when the last group was found,
                # which would abort this script under set -e.
                exit 0
            ' 2>/dev/null || true)

        if [[ -n "$MISSING" ]]; then
            warn "Missing on $release: $(echo "$MISSING" | tr '\n' ',' | sed 's/,$//')"
            DEPS_PROBLEMS=true
        fi
    done

    if $DEPS_PROBLEMS; then
        warn "Some Build-Depends are missing on target releases."
        warn "Fix debian/control before continuing (see UPDATING.md Step 4)."
    fi
fi

# Show what changed in debian/ for review
echo ""
log "Changes to debian/:"
git diff debian/
echo ""

if ! confirm "Review the debian/ changes above. Continue?"; then
    die "Aborted. Fix debian/ and re-run."
fi

git add -A
if git diff --cached --quiet; then
    log "No debian packaging changes needed"
else
    git commit -m "Update debian packaging for Racket ${VERSION}"
fi

###############################################################################
# Step 5: Tag upstream and generate orig tarball
###############################################################################

TAG_NAME="upstream/${VERSION}+ppa${PPA_ITERATION}"
if git rev-parse "$TAG_NAME" &>/dev/null; then
    log "Tag $TAG_NAME already exists"
else
    log "Tagging upstream: $TAG_NAME"
    git tag "$TAG_NAME" upstream
fi

log "Generating orig tarball"
# Debian's dh-based debian/rules has no get-orig-source target, so build
# the tarball straight from the tag.
ORIG_TARBALL="../racket_${VERSION}+ppa${PPA_ITERATION}.orig.tar.gz"
git archive --format=tar \
    --prefix="racket-${VERSION}+ppa${PPA_ITERATION}/" "$TAG_NAME" \
    | gzip -9 > "$ORIG_TARBALL"

if [[ ! -s "$ORIG_TARBALL" ]]; then
    die "Orig tarball not created: $ORIG_TARBALL"
fi
log "Orig tarball: $ORIG_TARBALL ($(du -h "$ORIG_TARBALL" | cut -f1))"

###############################################################################
# Step 6: Test build
###############################################################################

log "Building unsigned source package (validation)"
debuild -S -d -us -uc

if ! $SKIP_BINARY_BUILD; then
    if confirm "Run full binary test build? (30-40 minutes)"; then
        log "Building binary packages"
        debuild -us -uc -j"$(nproc)"
        log "Binary build succeeded"

        log "Cleaning build artifacts"
        fakeroot debian/rules clean
    fi
fi

###############################################################################
# Step 7: Build signed source packages for each release
###############################################################################

log "Building signed source packages"

for release in $RELEASES; do
    log "  Building for $release"
    set_changelog_release "$release"
    debuild -S -d -k"$GPG_KEY"
done

# Restore the committed changelog, so the working tree is clean whichever
# release happened to be built last.
git checkout -- debian/changelog

# dpkg-genchanges leaves this behind after a source-only build, which
# makes the working tree look dirty on the next run.
rm -f debian/files

log "Source packages built:"
ls -1 ../racket_"${VERSION}"+ppa"${PPA_ITERATION}"-1~*_source.changes

###############################################################################
# Step 8: Upload to PPA
###############################################################################

if $NO_UPLOAD; then
    log "Skipping upload (--no-upload)"
    log "To upload manually:"
    for release in $RELEASES; do
        echo "  dput ppa:plt/racket ../racket_${VERSION}+ppa${PPA_ITERATION}-1~${release}1_source.changes"
    done
else
    log "Ready to upload to PPA"

    for release in $RELEASES; do
        CHANGES="../racket_${VERSION}+ppa${PPA_ITERATION}-1~${release}1_source.changes"
        if [[ ! -f "$CHANGES" ]]; then
            warn "Changes file not found: $CHANGES"
            continue
        fi

        echo ""
        echo "Upload: $CHANGES"
        if confirm "Upload to ppa:plt/racket?"; then
            dput ppa:plt/racket "$CHANGES"
        else
            log "Skipped. To upload manually:"
            echo "  dput ppa:plt/racket $CHANGES"
        fi
    done
fi

###############################################################################
# Step 9: Push git changes
###############################################################################

if $NO_PUSH; then
    log "Skipping push (--no-push)"
    log "To push manually:"
    echo "  cd $REPO_DIR"
    echo "  git push origin main upstream"
    echo "  git push origin \$(git tag -l 'upstream/*')"
else
    echo ""
    if confirm "Push main, upstream, and tags to origin?"; then
        git push origin main upstream

        # Push every upstream tag origin is missing, not just this run's:
        # an earlier version may have been packaged but not uploaded.
        MISSING_TAGS=$(comm -23 \
            <(git tag -l 'upstream/*' | sort) \
            <(git ls-remote --tags origin 'refs/tags/upstream/*' \
                | sed 's|.*refs/tags/||; s|\^{}||' | sort -u))
        if [[ -n "$MISSING_TAGS" ]]; then
            log "Pushing tags: $(echo "$MISSING_TAGS" | tr '\n' ' ')"
            # shellcheck disable=SC2086
            git push origin $MISSING_TAGS
        fi
        log "Pushed to origin"
    else
        log "Skipped push. To push manually:"
        echo "  git push origin main upstream"
        echo "  git push origin \$(git tag -l 'upstream/*')"
    fi
fi

###############################################################################
# Done
###############################################################################

echo ""
log "PPA update for Racket ${VERSION} complete."
log "Monitor builds at: https://launchpad.net/~plt/+archive/ubuntu/racket/+packages"
log "Working directory: $WORK_DIR"
