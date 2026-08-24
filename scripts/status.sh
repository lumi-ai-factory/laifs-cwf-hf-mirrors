#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST=${MANIFEST:-$REPO_ROOT/datasets.tsv}
DATASETS_ROOT=${DATASETS_ROOT:-/appl/local/laifs/datasets}
STAGING_ROOT=$DATASETS_ROOT/.staging

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

[[ -f $MANIFEST ]] || {
    printf 'Error: manifest not found: %s\n' "$MANIFEST" >&2
    exit 1
}
valid_datasets_root "$DATASETS_ROOT" || {
    printf 'Error: DATASETS_ROOT must be a safe absolute path: %s\n' \
        "$DATASETS_ROOT" >&2
    exit 1
}

printf '%-52s %-7s %-12s %-12s %s\n' \
    'DATASET' 'ENABLED' 'EXPECTED' 'INSTALLED' 'STATE'

while IFS=$'\t' read -r repo_id revision stage category enabled license notes || \
        [[ -n ${repo_id:-} ]]; do
    [[ -n ${repo_id:-} && $repo_id != \#* ]] || continue

    organization=${repo_id%%/*}
    dataset_name=${repo_id#*/}
    destination=$DATASETS_ROOT/$organization/$dataset_name
    staging=$STAGING_ROOT/$organization/$dataset_name/$revision
    expected_short=${revision:0:12}
    installed_short=-

    if [[ -e $destination ]]; then
        if found_revision=$(installed_revision "$destination/.lumi-mirror"); then
            installed_short=${found_revision:0:12}
            if [[ $found_revision == "$revision" ]]; then
                state=installed
            else
                state=revision-mismatch
            fi
        else
            state=installed-unknown
        fi
    elif [[ -e $staging ]]; then
        state=staging
    else
        state=absent
    fi

    printf '%-52s %-7s %-12s %-12s %s\n' \
        "$repo_id" "$enabled" "$expected_short" "$installed_short" "$state"
done < "$MANIFEST"
