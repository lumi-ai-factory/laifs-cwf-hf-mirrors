#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
repo_type=dataset

usage() {
    cat <<EOF
Usage: $0 [--type dataset|model]

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

valid_datasets_root() {
    case $1 in
        /|*/.|*/..|*/./*|*/../*) return 1 ;;
        /*) return 0 ;;
        *) return 1 ;;
    esac
}

read_installed_metadata() {
    local metadata=$1
    local key value

    installed_repo_id=
    installed_repo_type=
    installed_revision=
    [[ -f $metadata ]] || return 1
    while IFS='=' read -r key value; do
        case $key in
            repo_id) installed_repo_id=$value ;;
            repo_type) installed_repo_type=$value ;;
            revision) installed_revision=$value ;;
        esac
    done < "$metadata"
    [[ -n $installed_repo_id && -n $installed_repo_type && \
        -n $installed_revision ]]
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            shift
            [[ $# -gt 0 ]] || die '--type requires dataset or model'
            repo_type=$1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
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

[[ -f $MANIFEST ]] || {
    printf 'Error: manifest not found: %s\n' "$MANIFEST" >&2
    exit 1
}
valid_datasets_root "$PUBLISH_ROOT" || {
    printf 'Error: publish root must be a safe absolute path: %s\n' \
        "$PUBLISH_ROOT" >&2
    exit 1
}

printf '%-52s %-7s %-12s %-12s %s\n' \
    'REPOSITORY' 'ENABLED' 'EXPECTED' 'INSTALLED' 'STATE'

while IFS=$'\t' read -r repo_id revision stage category enabled license notes || \
        [[ -n ${repo_id:-} ]]; do
    [[ -n ${repo_id:-} && $repo_id != \#* ]] || continue

    organization=${repo_id%%/*}
    repository_name=${repo_id#*/}
    destination=$PUBLISH_ROOT/$organization/$repository_name
    staging=$STAGING_ROOT/$organization/$repository_name/$revision
    expected_short=${revision:0:12}
    installed_short=-

    if [[ -e $destination ]]; then
        if read_installed_metadata "$destination/.lumi-mirror"; then
            installed_short=${installed_revision:0:12}
            if [[ $installed_repo_id != "$repo_id" || \
                    $installed_repo_type != "$repo_type" ]]; then
                state=metadata-mismatch
            elif [[ $installed_revision == "$revision" ]]; then
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
