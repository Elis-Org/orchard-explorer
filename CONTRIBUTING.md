# Contributing to Orchard Explorer

Build and test on an Apple Silicon Mac running macOS 26.7.1 or later. Install the Xcode Command Line Tools and run the commands below from the repository root. The first Swift package build fetches ZIPFoundation 0.9.20.

## Run the full test suite

The ZIP tests exercise archives produced by Windows Explorer and the Mac’s `ditto` and `zip` tools. Use Python 3 and the bundled synthetic Windows archive to generate the fixtures in a fresh temporary directory. Set `MAXPLORER_ZIP_PRODUCER_CORPUS` as shown to include all five archive cases in the test run.

```sh
(
  set -e
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/orchard-explorer-tests.XXXXXX")"
  python3 -B validation/preview-zip-operations/make-producer-corpus.py \
    --output "$run_dir/producer-corpus" \
    --windows-input validation/preview-zip-operations/producer-inputs/windows-explorer-updated.zip
  MAXPLORER_ZIP_PRODUCER_CORPUS="$run_dir/producer-corpus" bash app/test.sh --no-parallel
)
```

The script also accepts Swift Testing filters. For example, `bash app/test.sh --filter OneDriveRetentionTests` runs a focused set of OneDrive tests. Build the release app with `bash app/build.sh release`.

## Open a pull request

1. Fork the repository and make your change on a branch in your fork. The filesystem and archive code lives in `app/Sources/ExplorerCore`, and the native interface lives in `app/Sources/ExplorerApp`. Each has a matching test target. See the [source map](docs/ARCHITECTURE.md) for individual components.
2. Run the tests affected by your change. Use disposable files for tests that rename, overwrite, or remove data.
3. Open a pull request against `main` for review by the project’s code owner, `@EliPulsifer`. Describe the behavior change, the checks you ran, and anything you could not verify.

For a bug report, include the macOS version, the steps that reproduce the problem, and the expected and actual result. For file operations, identify whether the location is a regular folder, a ZIP, or a cloud provider. Use synthetic filenames in examples and screenshots.
