#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# jailbr0ke Repo index generator
# Usage: ./update-repo.sh [repository-directory]

REPO_DIR="$(realpath "${1:-.}")"
DEBS_DIR="$REPO_DIR/debs"

for cmd in dpkg-deb bzip2 sha256sum md5sum find sort stat realpath; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ ! -d "$DEBS_DIR" ]]; then
    echo "ERROR: Package directory not found: $DEBS_DIR" >&2
    exit 1
fi

# Build everything in a temporary directory first.
WORK_DIR="$(mktemp -d "$REPO_DIR/.repo-index.XXXXXX")"

cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

PACKAGES_TMP="$WORK_DIR/Packages"
: > "$PACKAGES_TMP"

count=0
failed=0

while IFS= read -r -d '' deb; do
    relative="${deb#"$REPO_DIR"/}"
    echo "Processing: $relative"

    if ! metadata="$(dpkg-deb --field "$deb" 2>&1)"; then
        echo "ERROR: Cannot read package metadata:" >&2
        echo "$metadata" >&2
        ((failed += 1))
        continue
    fi

    for field in Package Version Architecture; do
        if ! grep -q "^${field}: .\\+" <<< "$metadata"; then
            echo "ERROR: $relative has no valid $field field" >&2
            ((failed += 1))
            continue 2
        fi
    done

    size="$(stat -c '%s' "$deb")"
    md5="$(md5sum "$deb" | cut -d ' ' -f 1)"
    sha256="$(sha256sum "$deb" | cut -d ' ' -f 1)"

    {
        printf '%s\n' "$metadata"
        printf 'Filename: %s\n' "$relative"
        printf 'Size: %s\n' "$size"
        printf 'MD5sum: %s\n' "$md5"
        printf 'SHA256: %s\n' "$sha256"
        printf '\n'
    } >> "$PACKAGES_TMP"

    ((count += 1))
done < <(find "$DEBS_DIR" -type f -name '*.deb' -print0 | sort -z)

if (( failed > 0 )); then
    echo "ERROR: $failed package(s) failed validation." >&2
    echo "Existing index files have not been changed." >&2
    exit 1
fi

if (( count == 0 )); then
    echo "WARNING: No .deb packages found in $DEBS_DIR" >&2
fi

# Compress both indexes before publishing anything.
if ! bzip2 -9 -c "$PACKAGES_TMP" > "$WORK_DIR/Packages.bz2"; then
    echo "ERROR: Failed to create Packages.bz2" >&2
    exit 1
fi

if ! bzip2 -9 -c "$PACKAGES_TMP" > "$WORK_DIR/Packages.bz"; then
    echo "ERROR: Failed to create Packages.bz" >&2
    exit 1
fi

# Publish the completed files.
for file in Packages Packages.bz2 Packages.bz; do
    if ! mv -f -- "$WORK_DIR/$file" "$REPO_DIR/$file"; then
        echo "ERROR: Could not publish $file" >&2
        exit 1
    fi
done

echo
echo "Successfully indexed $count package(s)."
echo "Repository: $REPO_DIR"
echo "Generated: Packages, Packages.bz2, Packages.bz"
