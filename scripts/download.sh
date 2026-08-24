#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST=${MANIFEST:-$REPO_ROOT/datasets.tsv}
DATASETS_ROOT=${DATASETS_ROOT:-/appl/local/laifs/datasets}
STAGING_ROOT=$DATASETS_ROOT/.staging
LOCK_DIR=$STAGING_ROOT/.download.lock

dry_run=no
repo_filter=
lock_acquired=no

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [REPO_ID]

Without REPO_ID, process datasets enabled in $MANIFEST.
With REPO_ID, process that dataset regardless of its enabled value.

Environment:
  DATASETS_ROOT  Dataset destination (default: $DATASETS_ROOT)
  MANIFEST       Manifest path (default: $MANIFEST)
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

release_lock() {
    if [[ $lock_acquired == yes ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

valid_component() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

valid_datasets_root() {
    case $1 in
        /|*/.|*/..|*/./*|*/../*) return 1 ;;
        /*) return 0 ;;
        *) return 1 ;;
    esac
}

installed_revision() {
    local metadata=$1
    local key value

    [[ -f $metadata ]] || return 1
    while IFS='=' read -r key value; do
        if [[ $key == revision ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$metadata"
    return 1
}

process_dataset() {
    local repo_id=$1
    local revision=$2
    local organization=${repo_id%%/*}
    local dataset_name=${repo_id#*/}
    local staging=$STAGING_ROOT/$organization/$dataset_name/$revision
    local destination=$DATASETS_ROOT/$organization/$dataset_name
    local transfer_metadata=$staging/.cache/huggingface
    local found_revision

    if ! valid_component "$organization" || ! valid_component "$dataset_name"; then
        printf 'Error: invalid repository ID: %s\n' "$repo_id" >&2
        return 1
    fi
    if [[ ! $revision =~ ^[0-9a-fA-F]{40}$ ]]; then
        printf 'Error: %s does not have a full commit SHA\n' "$repo_id" >&2
        return 1
    fi

    if [[ $dry_run == yes ]]; then
        printf '\nDry run: %s at %s\n' "$repo_id" "$revision"
        hf download "$repo_id" \
            --repo-type dataset \
            --revision "$revision" \
            --dry-run
        return $?
    fi

    if [[ -e $destination ]]; then
        if found_revision=$(installed_revision "$destination/.lumi-mirror") && \
                [[ $found_revision == "$revision" ]]; then
            printf 'Already installed: %s at %s\n' "$repo_id" "$revision"
            return 0
        fi
        printf 'Error: destination already exists: %s\n' "$destination" >&2
        return 1
    fi

    mkdir -p "$(dirname "$staging")" || return 1
    printf '\nDownloading %s at %s\n' "$repo_id" "$revision"
    printf 'Staging directory: %s\n' "$staging"

    if ! hf download "$repo_id" \
            --repo-type dataset \
            --revision "$revision" \
            --local-dir "$staging"; then
        printf 'Error: download failed for %s; staging data was retained\n' \
            "$repo_id" >&2
        return 1
    fi

    if [[ -e $transfer_metadata || -L $transfer_metadata ]]; then
        if [[ $staging != "$STAGING_ROOT/"* || $staging == "$STAGING_ROOT" || \
                -L $transfer_metadata || ! -d $transfer_metadata ]]; then
            printf 'Error: unsafe transfer metadata path for %s: %s\n' \
                "$repo_id" "$transfer_metadata" >&2
            return 1
        fi
        if ! rm -r -- "${transfer_metadata:?}"; then
            printf 'Error: failed to remove transfer metadata for %s\n' \
                "$repo_id" >&2
            return 1
        fi
        rmdir "$staging/.cache" 2>/dev/null || true
    fi

    if ! cat > "$staging/.lumi-mirror" <<EOF
repo_id=$repo_id
revision=$revision
downloaded_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    then
        printf 'Error: failed to record mirror metadata for %s\n' \
            "$repo_id" >&2
        return 1
    fi

    chmod -R go-w,a+rX "$staging" || return 1
    mkdir -p "$(dirname "$destination")" || return 1
    chmod go-w,a+rx "$(dirname "$destination")" || return 1

    if [[ -e $destination ]]; then
        printf 'Error: destination appeared while downloading: %s\n' \
            "$destination" >&2
        return 1
    fi
    if ! mv "$staging" "$destination"; then
        printf 'Error: failed to publish %s\n' "$repo_id" >&2
        return 1
    fi

    printf 'Published: %s\n' "$destination"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            dry_run=yes
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if [[ $# -gt 0 && -z $repo_filter ]]; then
                repo_filter=$1
            elif [[ $# -gt 0 ]]; then
                die 'only one repository ID may be specified'
            fi
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            [[ -z $repo_filter ]] || die 'only one repository ID may be specified'
            repo_filter=$1
            ;;
    esac
    shift
done

[[ -f $MANIFEST ]] || die "manifest not found: $MANIFEST"
command -v hf >/dev/null 2>&1 || die "the 'hf' command is not available"
valid_datasets_root "$DATASETS_ROOT" || \
    die "DATASETS_ROOT must be a safe absolute path: $DATASETS_ROOT"

if [[ $dry_run == no ]]; then
    mkdir -p "$STAGING_ROOT" || die "cannot create staging directory: $STAGING_ROOT"
    chmod 700 "$STAGING_ROOT" || die "cannot protect staging directory: $STAGING_ROOT"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        die "another download may be running; lock exists: $LOCK_DIR"
    fi
    lock_acquired=yes
    trap release_lock EXIT
    trap 'exit 1' HUP INT TERM
fi

selected=0
failures=0
while IFS=$'\t' read -r repo_id revision stage category enabled license notes || \
        [[ -n ${repo_id:-} ]]; do
    [[ -n ${repo_id:-} && $repo_id != \#* ]] || continue

    if [[ -n $repo_filter ]]; then
        [[ $repo_id == "$repo_filter" ]] || continue
    else
        [[ $enabled == yes ]] || continue
    fi

    selected=$((selected + 1))
    if ! process_dataset "$repo_id" "$revision"; then
        failures=$((failures + 1))
    fi
done < "$MANIFEST"

if [[ $selected -eq 0 ]]; then
    if [[ -n $repo_filter ]]; then
        die "repository is not listed in the manifest: $repo_filter"
    fi
    die 'no datasets are enabled in the manifest'
fi

if [[ $failures -gt 0 ]]; then
    printf '\n%d of %d dataset operation(s) failed\n' "$failures" "$selected" >&2
    exit 1
fi

printf '\nCompleted %d dataset operation(s)\n' "$selected"
