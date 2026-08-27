# LUMI AI Factory Dataset and Model Mirroring Tools for CWF

This repository contains a small set of tools for downloading selected public
Hugging Face datasets and models and making them available to LUMI users. The
aim is to provide useful, ready-to-use artifacts close to LUMI compute resources
so that each user does not need to download a separate copy from the internet.
These datasets and models are also used in the examples for LUMI AI Factory
Containerized Workflows, see:

[Containerized Workflows](https://github.com/lumi-ai-factory/laifs-cwf-workflows).

The tools manage metadata and downloads. Dataset and model contents are not
stored in this Git repository.

## How it works

Datasets and models are published under:

```text
/appl/local/laifs/datasets/<organization>/<dataset-name>
/appl/local/laifs/models/<organization>/<model-name>
```

For example:

```text
/appl/local/laifs/datasets/HuggingFaceTB/finemath
/appl/local/laifs/models/unsloth/Llama-3.2-3B
```

Each repository is downloaded at an exact Hugging Face commit revision.
Downloads first go into a private staging directory under the selected root on
the same filesystem:

```text
/appl/local/laifs/datasets/.staging/
/appl/local/laifs/models/.staging/
```

Ordinary users cannot access the staging directory. Members of the mirror group
can read and update staged downloads. After a download completes, its temporary
Hugging Face metadata is removed, permissions are checked, and the repository is
moved to its final location with a single `mv` operation. Users therefore see
either no artifact or a complete artifact, never a partially downloaded one. A
hidden `.lumi-mirror` file records the repository type, repository ID, revision,
and download time for `status.sh`.

Published dataset and model trees are read-only to ordinary LUMI users and are
not updated in place. Their group owner is `appl_laifs` by default. Group members
can update files and directories, and setgid directories preserve the group on
new content. Replacing a published repository with a newer upstream revision is
a separate, explicit maintenance operation.

## Repository contents

```text
lumi-cwf-datasets-mirror/
├── README.md
├── datasets.tsv
├── models.tsv
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

`models.tsv`:

Lists the intended models, their exact upstream revisions, descriptive
metadata, and whether each model is currently enabled for download. The
manifest is tab-separated and acts as the model revision lock.

`scripts/download.sh`:

Downloads enabled datasets or models into the corresponding private staging
directory, prepares completed downloads for shared use, and publishes them
to the final directory. An individual failure does not prevent attempts for
other enabled repositories, but the command exits unsuccessfully if any
download failed.

`scripts/status.sh`:

Shows whether each entry in the selected manifest is absent, being staged, or
installed, and reports the expected and installed revisions.

`logs/`:

Can hold redirected operation logs. Logs are not committed to Git.

## Manifest

`datasets.tsv` has the following columns:

```text
repo_id  revision  stage  category  enabled  license  notes
```

`models.tsv` has corresponding model-oriented columns:

```text
repo_id  revision  task  category  enabled  license  notes
```

`revision` must be a full 40-character Hugging Face commit SHA. With no
repository argument, `download.sh` processes entries whose `enabled` value is
`yes`. Naming a repository explicitly processes it even when it is disabled.
Datasets are selected by default; pass `--type model` to use `models.tsv`.

## Requirements

The download host needs:

* Bash
* the Hugging Face `hf` CLI with Xet support
* access to `huggingface.co`
* write access to the selected dataset or model root
* membership in the group used to own mirrored content (`appl_laifs` by default)

The current `huggingface_hub` package installs `hf_xet`, which handles Xet-backed
downloads automatically:

```bash
python3 -m pip install --upgrade huggingface_hub
hf --version
```

Public datasets and models do not normally require authentication. If
authentication is needed, configure it outside this repository and do not store
access tokens in the manifests or logs.

## Usage

Run commands from the repository root.

Review the dataset manifest and estimate the download before transferring data:

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

Estimate, download, or inspect models with `--type model`:

```bash
./scripts/download.sh --type model --dry-run unsloth/Llama-3.2-3B
./scripts/download.sh --type model unsloth/Llama-3.2-3B
./scripts/download.sh --type model
./scripts/status.sh --type model
```

Inspect the collection:

```bash
./scripts/status.sh
```

The dataset root can be overridden for testing:

```bash
DATASETS_ROOT=/path/to/test/datasets ./scripts/download.sh
```

The model root has a separate override:

```bash
MODELS_ROOT=/path/to/test/models ./scripts/download.sh --type model
```

A different manifest can also be selected:

```bash
MANIFEST=/path/to/datasets.tsv ./scripts/status.sh
```

The group that owns staging and published content defaults to `appl_laifs` and
can be overridden for testing:

```bash
MIRROR_GROUP=$(id -gn) DATASETS_ROOT=/path/to/test/datasets \
    ./scripts/download.sh HuggingFaceTB/finemath
```

Staging directories are private to the owner and mirror group. Staged files are
group-readable and group-writable, and staged directories are group-accessible,
group-writable, and setgid. Before publication, the script recursively assigns
the mirror group, gives that group read and write access, and gives ordinary
users read access to files and read and traversal access to directories.

The download script refuses to overwrite an existing published repository. An
already-installed repository at the manifest revision is reported as complete.
If a download is interrupted, its staging directory and Hugging Face transfer
metadata are retained so that a later run can continue the download. The
metadata is removed after the download succeeds and before publication.
Staging paths include the pinned revision, preventing partial files from an old
revision from being included in a newer one. After publication, the script
removes empty repository and organization directories from staging. Failure to
remove them produces a warning but does not fail the completed operation. Do
not remove a retained staging directory manually without first confirming that
no other download is running.

Only one `download.sh` process can modify each artifact root at a time. The
script uses `.staging/.download.lock` under the selected dataset or model root
to prevent concurrent downloads. Dataset and model downloads can run at the
same time because they use separate roots. If a process is forcibly killed and
leaves an empty lock directory behind, confirm that no download is running
before removing it.

## Adding or enabling a dataset or model

1. Add the repository and a full Hugging Face commit SHA to the appropriate
   manifest.
2. Run `download.sh --dry-run` with the appropriate `--type` and check the
   required storage.
3. Confirm the artifact license and that redistribution is appropriate.
4. Mark the entry as enabled, or pass its repository ID directly to the script.
5. Run `download.sh` and inspect the result with the matching `status.sh` type.

The manifests and their pinned revisions are committed to Git, making the
intended contents of the LUMI collection explicit and reviewable.
