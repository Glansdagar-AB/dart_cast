# dart_cast — guidance for Claude

## Before opening a PR: run the exact CI checks locally

CI runs two workflows — `.github/workflows/ci.yml` for the package and
`.github/workflows/build_example.yml` for the Flutter example. Replay all
of these locally before pushing, and only open the PR if every one exits
`0`:

```sh
# Package (workflow: ci.yml)
dart pub get --no-example
dart analyze lib/ test/            # exit 2 on warnings; info is OK
dart format --set-exit-if-changed lib/ test/
dart test

# Example (workflow: build_example.yml)
cd example && flutter pub get && flutter analyze   # exit 1 on *info* too
cd example && flutter build apk --debug            # optional but mirrors CI
```

Things that have actually broken CI here:

- **Pre-existing `warning`-level lints in `lib/` or `test/`.** `dart analyze`
  exits `2` on *any* warning (e.g. `unnecessary_non_null_assertion`). Info-
  level diagnostics are fine; warnings are not. Fix them before pushing — do
  not rely on the merge-base being green.
- **Formatter style changes from SDK bumps.** Bumping `environment.sdk`
  past `3.7.0` switches the default formatter to the new "tall style",
  which rewrites most files. If you touch the SDK constraint, always run
  `dart format lib/ test/` in the same commit — otherwise the format step
  fails on a huge diff unrelated to your actual change.
- **`flutter analyze` is stricter than `dart analyze`.** The example's build
  job fails on *info*-level diagnostics too (exit `1`). Running `dart analyze`
  against `lib/ test/` is not enough — you must also `cd example && flutter
  analyze` before pushing. Common trap: pre-existing `unnecessary_underscores`
  infos that the package analyze step would ignore.

`flutter pub outdated` (run in repo root *and* `example/`) is the canonical
way to decide whether a bump is needed — prefer it over pub.dev scraping.

## Versioning

Pre-1.0 semver is in force: breaking changes (SDK floor bump, major
dependency bump that's observable through transitive deps) go in a minor
release (`0.X.0`), not a patch.

## Release tags

Release tags use the `v` prefix (`v0.5.0`, not `0.5.0`). The publish workflow
triggers on `v*`; a bare-number tag will not fire it.
