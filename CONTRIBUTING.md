# Contributing to dart_cast

## Development Setup

1. Clone the repository:

```bash
git clone https://github.com/abdelaziz-mahdy/dart_cast.git
cd dart_cast
```

2. Install dependencies:

```bash
dart pub get
```

3. Verify everything works:

```bash
dart test
dart analyze
```

## Running Tests

```bash
# Run all tests
dart test

# Run a specific test file
dart test test/core/media_proxy_test.dart

# Run tests with verbose output
dart test --reporter expanded
```

Tests use mock servers that simulate real device behavior for each protocol (DLNA SSDP/SOAP, Chromecast CASTV2, AirPlay HTTP). No real hardware is needed.

## Regenerating Protobuf

The Chromecast protocol uses a protobuf definition for CASTV2 messages. The generated Dart file is committed to the repository so consumers do not need the `protoc` toolchain.

If you modify `cast_channel.proto`, regenerate with:

```bash
# Install protoc and the Dart plugin
dart pub global activate protoc_plugin

# Regenerate
protoc --dart_out=lib/src/protocols/chromecast/ \
  lib/src/protocols/chromecast/cast_channel.proto
```

## Code Style

This project uses `package:lints/recommended.yaml` for analysis. Before submitting:

```bash
dart analyze   # Must pass with no issues
dart format .  # Format all files
```

## Project Structure

```
lib/
  dart_cast.dart              # Public API barrel export
  src/
    core/                     # Protocol-agnostic abstractions
    protocols/
      airplay/                # AirPlay 1 implementation
      chromecast/             # Chromecast CASTV2 implementation
      dlna/                   # DLNA/UPnP implementation
    utils/                    # Network utilities, logging
test/
  core/                       # Core unit tests
  protocols/                  # Protocol-specific tests
  integration/                # Full-flow integration tests
example/                      # Flutter example app
```

## Pull Request Guidelines

1. **Fork and branch** -- create a feature branch from `main`.
2. **Write tests** -- all new functionality must have corresponding tests.
3. **Pass CI** -- ensure `dart test` and `dart analyze` pass with no issues.
4. **Keep PRs focused** -- one feature or fix per PR.
5. **Update CHANGELOG.md** -- add a brief entry under an `## Unreleased` section.
6. **Describe your changes** -- include a clear summary in the PR description.

## Adding a New Protocol

1. Create a directory under `lib/src/protocols/<protocol_name>/`.
2. Implement `DeviceDiscoveryProvider` for device discovery.
3. Implement `CastSession` for session management and playback control.
4. Add tests under `test/protocols/<protocol_name>/` with a mock server.
5. Export new public classes from `lib/dart_cast.dart`.
