# LUMI Dataset Mirror Tools

This repository contains a small set of tools for downloading selected public
Hugging Face datasets and making them available to LUMI users. The aim is to
provide useful, ready-to-use datasets close to LUMI compute resources so that
each user does not need to download a separate copy from the internet. These
datasets are also used in the examples for LUMI AI Factory Containerized
Workflows, see:

[Containerized Workflows](https://github.com/lumi-ai-factory/laifs-cwf-workflows).

The tools manage metadata and downloads. Dataset contents are not stored in
this Git repository.

## How it works

Datasets are published under:

```text
/appl/local/laifs/datasets/<organization>/<dataset-name>
```

For example:

```text
/appl/local/laifs/datasets/HuggingFaceTB/finemath
```

Each dataset is downloaded at an exact Hugging Face commit revision. Downloads
first go into a private staging directory on the same filesystem:

```text
/appl/local/laifs/datasets/.staging/
```

Users cannot access the staging directory. After a download completes, its
temporary Hugging Face metadata is removed, permissions are checked, and the
dataset is moved to its final location with a single `mv` operation. Users
therefore see either no dataset or a complete dataset, never a partially
downloaded one. A hidden `.lumi-mirror` file records the repository, revision,
and download time for `status.sh`.

Published dataset trees are read-only to ordinary LUMI users and are not
updated in place. The maintaining account retains owner write permission.
Replacing a published dataset with a newer upstream revision is a separate,
explicit maintenance operation.

## Repository contents

```text
lumi-cwf-datasets-mirror/
├── README.md
├── datasets.tsv
├── .gitignore
├── logs/
└── scripts/
    ├── download.sh
    └── status.sh
```

`README.md`:

Describes the mirror and its operation.

`datasets.tsv`:

Lists the intended datasets, their exact upstream revisions, descriptive
metadata, and whether each dataset is currently enabled for download. The
manifest is tab-separated and acts as the revision lock.

`scripts/download.sh`:

Downloads enabled datasets into the private staging directory, prepares
completed downloads for read-only use, and publishes them to the final
directory. An individual failure does not prevent attempts for other enabled
datasets, but the command exits unsuccessfully if any download failed.

`scripts/status.sh`:

Shows whether each manifest entry is absent, being staged, or installed, and
reports the expected and installed revisions.

`logs/`:

Can hold redirected operation logs. Logs are not committed to Git.

## Manifest

`datasets.tsv` has the following columns:

```text
repo_id  revision  stage  category  enabled  license  notes
```

`revision` must be a full 40-character Hugging Face commit SHA. With no
repository argument, `download.sh` processes entries whose `enabled` value is
`yes`. Naming a repository explicitly processes it even when it is disabled.

## Requirements

The download host needs:

* Bash
* the Hugging Face `hf` CLI with Xet support
* access to `huggingface.co`
* write access to `/appl/local/laifs/datasets`

The current `huggingface_hub` package installs `hf_xet`, which handles Xet-backed
downloads automatically:

```bash
python3 -m pip install --upgrade huggingface_hub
hf --version
```

Public datasets do not normally require authentication. If authentication is
needed, configure it outside this repository and do not store access tokens in
the manifest or logs.

## Usage

Run commands from the repository root.

Review the manifest and estimate the download before transferring data:

```bash
./scripts/download.sh --dry-run HuggingFaceTB/finemath
```

The dry run asks Hugging Face for the files and total download size without
creating the LUMI dataset directory.

Download and publish one dataset:

```bash
./scripts/download.sh HuggingFaceTB/finemath
```

Download all entries marked as enabled in `datasets.tsv`:

```bash
./scripts/download.sh
```

Inspect the collection:

```bash
./scripts/status.sh
```

The dataset root can be overridden for testing:

```bash
DATASETS_ROOT=/path/to/test/datasets ./scripts/download.sh
```

A different manifest can also be selected:

```bash
MANIFEST=/path/to/datasets.tsv ./scripts/status.sh
```

The download script refuses to overwrite an existing published dataset. An
already-installed dataset at the manifest revision is reported as complete. If
a download is interrupted, its staging directory and Hugging Face transfer
metadata are retained so that a later run can continue the download. The
metadata is removed after the download succeeds and before publication.
Staging paths include the pinned revision, preventing partial files from an old
revision from being included in a newer one.

Only one `download.sh` process can modify the collection at a time. The script
uses `/appl/local/laifs/datasets/.staging/.download.lock` to prevent concurrent
downloads. If a process is forcibly killed and leaves this empty directory
behind, confirm that no download is running before removing it.

## Adding or enabling a dataset

1. Add the repository and a full Hugging Face commit SHA to `datasets.tsv`.
2. Run `download.sh --dry-run` and check the required storage.
3. Confirm the dataset license and that redistribution is appropriate.
4. Mark the entry as enabled, or pass its repository ID directly to the script.
5. Run `download.sh` and inspect the result with `status.sh`.

The manifest and its pinned revisions are committed to Git, making the intended
contents of the LUMI collection explicit and reviewable.
