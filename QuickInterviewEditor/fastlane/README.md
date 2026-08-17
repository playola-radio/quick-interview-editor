fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac test

```sh
[bundle exec] fastlane mac test
```

Runs the Swift Testing suite (QuickInterviewEditorTests)

### mac lint_code

```sh
[bundle exec] fastlane mac lint_code
```

Run SwiftLint (strict — fails on warnings)

### mac format_check

```sh
[bundle exec] fastlane mac format_check
```

Check swift-format formatting (fails on issues)

### mac bump

```sh
[bundle exec] fastlane mac bump
```

Bump MARKETING_VERSION / integer CURRENT_PROJECT_VERSION, regenerate, commit

### mac release

```sh
[bundle exec] fastlane mac release
```

Build, sign, notarize, DMG, sign appcast, upload to S3 (LOCAL release)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
