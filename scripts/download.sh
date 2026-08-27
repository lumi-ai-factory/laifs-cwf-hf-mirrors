#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

dry_run=no
repo_filter=
repo_type=dataset
lock_acquired=no

usage() {
    cat <<EOF
Usage: $0 [--type dataset|model] [--dry-run] [REPO_ID]

Without REPO_ID, process enabled entries in the selected manifest.
With REPO_ID, process that repository regardless of its enabled value.

Environment:
  DATASETS_ROOT  Dataset destination (default: /appl/local/laifs/datasets)
  MODELS_ROOT    Model destination (default: /appl/local/laifs/models)
  MANIFEST       Override the selected manifest path
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

installed_metadata_matches() {
    local metadata=$1
    local expected_repo_id=$2
    local expected_repo_type=$3
    local expected_revision=$4
    local key value
    local found_repo_id=
    local found_repo_type=
    local found_revision=

    [[ -f $metadata ]] || return 1
    while IFS='=' read -r key value; do
        case $key in
            repo_id) found_repo_id=$value ;;
            repo_type) found_repo_type=$value ;;
            revision) found_revision=$value ;;
        esac
    done < "$metadata"

    [[ $found_repo_id == "$expected_repo_id" && \
        $found_repo_type == "$expected_repo_type" && \
        $found_revision == "$expected_revision" ]]
}

process_repository() {
    local repo_id=$1
    local revision=$2
    local organization=${repo_id%%/*}
    local repository_name=${repo_id#*/}
    local staging=$STAGING_ROOT/$organization/$repository_name/$revision
    local destination=$PUBLISH_ROOT/$organization/$repository_name
    local transfer_metadata=$staging/.cache/huggingface

    if ! valid_component "$organization" || ! valid_component "$repository_name"; then
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
            --repo-type "$repo_type" \
            --revision "$revision" \
            --dry-run
        return $?
    fi

    if [[ -e $destination ]]; then
        if installed_metadata_matches "$destination/.lumi-mirror" \
                "$repo_id" "$repo_type" "$revision"; then
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
            --repo-type "$repo_type" \
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
repo_type=$repo_type
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
        --type)
            shift
            [[ $# -gt 0 ]] || die '--type requires dataset or model'
            repo_type=$1
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

case $repo_type in
    dataset)
        DEFAULT_MANIFEST=$REPO_ROOT/datasets.tsv
        PUBLISH_ROOT=${DATASETS_ROOT:-/appl/local/laifs/datasets}
        ;;
    model)
        DEFAULT_MANIFEST=$REPO_ROOT/models.tsv
        PUBLISH_ROOT=${MODELS_ROOT:-/appl/local/laifs/models}
        ;;
    *)
        die "unsupported repository type: $repo_type"
        ;;
esac

MANIFEST=${MANIFEST:-$DEFAULT_MANIFEST}
STAGING_ROOT=$PUBLISH_ROOT/.staging
LOCK_DIR=$STAGING_ROOT/.download.lock

[[ -f $MANIFEST ]] || die "manifest not found: $MANIFEST"
command -v hf >/dev/null 2>&1 || die "the 'hf' command is not available"
valid_datasets_root "$PUBLISH_ROOT" || \
    die "publish root must be a safe absolute path: $PUBLISH_ROOT"

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
    if ! process_repository "$repo_id" "$revision"; then
        failures=$((failures + 1))
    fi
done < "$MANIFEST"

if [[ $selected -eq 0 ]]; then
    if [[ -n $repo_filter ]]; then
        die "repository is not listed in the manifest: $repo_filter"
    fi
    die "no ${repo_type}s are enabled in the manifest"
fi

if [[ $failures -gt 0 ]]; then
    printf '\n%d of %d repository operation(s) failed\n' \
        "$failures" "$selected" >&2
    exit 1
fi

printf '\nCompleted %d repository operation(s)\n' "$selected"
