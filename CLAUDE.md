# dart_cast — guidance for Claude

## Before opening a PR: run the exact CI checks locally

CI (`.github/workflows/ci.yml`) runs these three commands. Run the same ones
before pushing any branch that will open a PR, and only open the PR if all
three exit `0`:

```sh
dart pub get --no-example
dart analyze lib/ test/            # must exit 0 — warnings are fatal, info is not
dart format --set-exit-if-changed lib/ test/
dart test
```

Things that have actually broken CI here:

- **Pre-existing `warning`-level lints.** `dart analyze` exits with code `2`
  when it finds *any* warning (e.g. `unnecessary_non_null_assertion`). Info-
  level diagnostics are fine; warnings are not. Fix them before pushing — do
  not rely on the merge-base being green.
- **Formatter style changes from SDK bumps.** Bumping the `environment.sdk`
  floor past `3.7.0` switches the default formatter to the new "tall style",
  which rewrites most files. If you touch the SDK constraint, always run
  `dart format lib/ test/` in the same commit — otherwise the format step
  fails on a huge diff unrelated to your actual change.

`flutter pub outdated` (run in repo root *and* `example/`) is the canonical
way to decide whether a bump is needed — prefer it over pub.dev scraping.

## Versioning

Pre-1.0 semver is in force: breaking changes (SDK floor bump, major
dependency bump that's observable through transitive deps) go in a minor
release (`0.X.0`), not a patch.

## Release tags

Release tags use the `v` prefix (`v0.5.0`, not `0.5.0`). The publish workflow
triggers on `v*`; a bare-number tag will not fire it.
