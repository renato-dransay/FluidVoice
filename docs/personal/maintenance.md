# FluidVoice Personal

The personal fork starts at upstream `main` commit `3b509ea1754022d0a3825717308bf7424c8eb412`. The initial upstream commit is recorded in `tools/fork/upstream-baseline.txt` and is intentionally immutable.

## Branches and builds

`origin` is `renato-dransay/FluidVoice`; `upstream` is `altic-dev/FluidVoice`. Keep `main` as a fast-forward-only upstream mirror. The default branch is `personal`. This is a personal fork developed locally: finished work is verified locally (build, relevant tests, SwiftLint), merged into `personal` and pushed directly, then the local app is rebuilt and reinstalled. Pull requests are opened only when something requires one, such as the upstream update workflow below. `personal` has no branch protection, so a push lands without waiting for CI; `Personal fork checks` still runs on every push to `personal` and reports failures after the fact.

Build on Apple Silicon with full Xcode selected and an installed Apple Development signing identity:

```sh
tools/fork/build-personal.sh
```

The product is `DerivedData/Build/Products/Debug/FluidVoice Personal.app`, bundle identifier `com.renatobeltrao.fluidvoice.personal`. `FLUIDVOICE_DERIVED_DATA_PATH` and `FLUIDVOICE_DEVELOPMENT_TEAM` remain supported. The wrapper selects the OSS profile, so the private Fluid Intelligence runtime is absent. The upstream CTranscribe framework normalization and signing steps are retained. Unsigned CI builds cannot be installed by the local installation helper.

Run relevant checks before installation:

```sh
python3 -m unittest discover -s tools/fork -p 'test_*.py' -v
swiftlint lint --strict --config .swiftlint.yml
xcodebuild test -project Fluid.xcodeproj -scheme Fluid \
  -destination 'platform=macOS,arch=arm64' \
  -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture
```

The Tiny Whisper case retains upstream's documented CI exclusion because its hosted output is nondeterministic. Test cloud recognition with synthetic or explicitly selected audio, including multiple languages, long-file boundaries and cancellation; never infer cloud quality from a successful build.

## Installation and rollback

Quit the personal app, then install the tested signed product:

```sh
python3 tools/fork/local_install.py install
```

Installation targets `~/Applications/FluidVoice Personal.app`. It verifies bundle identity and Apple Development signing before changing the installation. Every upgrade retains the old binary, personal application-support directory and preferences under `~/Library/Application Support/FluidVoice Personal Backups/<timestamp-id>/`. Backups are private to the local user. Installation refuses to proceed while the personal app runs. The source build remains untouched.

To restore a named snapshot, quit the personal app and run:

```sh
python3 tools/fork/local_install.py rollback \
  "$HOME/Library/Application Support/FluidVoice Personal Backups/<timestamp-id>"
```

Rollback saves the current state as a new rescue snapshot before restoring the previous binary, data and preferences. Data created since the snapshot remains in that rescue backup. Keychain credentials are neither exported nor rolled back. No backup pruning runs automatically; manage retained recordings and backup disk usage explicitly.

The fork uses fresh preferences under its bundle identifier, the Keychain service `com.renatobeltrao.fluidvoice.personal.provider-api-keys`, data under `~/Library/Application Support/FluidVoice Personal`, and logs under `~/Library/Logs/FluidVoice Personal`. It does not import official preferences or credentials. Existing recordings can be imported deliberately. Model downloads may use shared caches. Official binary updater entry points refuse installation, and personal builds replace their settings controls with local build and rollback guidance. Use the same signing identity across rebuilds to retain macOS permission identity; grant microphone, accessibility and meeting capture permissions on first launch.

## Reviewed upstream updates

`Personal fork upstream updates` runs weekly on Monday at 08:23 UTC and supports manual dispatch. It fetches current upstream `main` and the latest stable GitHub release, fast-forwards the fork's `main`, skips an already included release, and prepares one update pull request per release. Beta releases are excluded. Release ancestry must descend from the initial baseline and belong to upstream `main`; divergence and merge conflicts produce a deduplicated issue requiring manual review. Existing closed update pull requests are not recreated. Existing open update pull requests have checks re-dispatched to recover from a failed dispatch.

The bot never force-pushes, merges a pull request, publishes a binary or installs an application. It explicitly dispatches `Personal fork checks` on the candidate branch because pull requests opened with `GITHUB_TOKEN` do not trigger ordinary pull-request workflows. The checks are `Fork tooling tests`, `Personal SwiftLint`, and `Personal build and tests`; nothing enforces them, so review the diff and CI before merging. Then rebuild locally, run app smoke checks, and install through the snapshot helper.

Enable Actions and "Allow GitHub Actions to create and approve pull requests" in the fork settings; the workflow only creates pull requests and never approves them. Keep default workflow token permissions read-only. Workflow-level permissions grant only the update job its necessary writes. Inherited upstream bots are restricted by repository guards to `altic-dev/FluidVoice`. Keep the two personal workflows enabled; other upstream maintenance workflows can stay disabled. `personal` has no branch protection, so nothing on GitHub blocks force-pushes or deletion; avoid both. Repository auto-merge is disabled. Merge commits remain allowed for upstream integration.

GitHub scheduled workflows in inactive public repositories may stop after 60 days. Upstream **Watch > Custom > Releases** notifications were enabled and verified in GitHub during the initial setup. Check that the scheduled workflow stays active. For another account, configure the same releases-only option in GitHub; its REST subscription API does not provide that selector.

If an update branch conflicts or falls behind `personal`, resolve it manually in a clean checkout, push the reviewed resolution, and re-dispatch `fork-ci.yml` for that branch. Do not discard personal work or reset `personal` to upstream.
