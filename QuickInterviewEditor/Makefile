.PHONY: lint format format-check test test-fast generate

# Run SwiftLint (strict mode to match CI)
lint:
	swiftlint --strict

# Swift sources only — avoids sweeping generated files under .build/DerivedData
# (swift-format has no --exclude, so we scope by directory instead).
SWIFT_SOURCES := QuickInterviewEditor QuickInterviewEditorTests

# Auto-fix formatting issues
format:
	xcrun swift-format format -i --recursive $(SWIFT_SOURCES)

# Check formatting (fails on issues)
format-check:
	xcrun swift-format lint --strict --recursive $(SWIFT_SOURCES)

# Run the Swift Testing suite via fastlane
test:
	bundle exec fastlane mac test

# Fast local dev loop: skip code signing, reuse the default (warm) DerivedData,
# no fastlane/xcbeautify wrapper. Iterate a single suite with:
#   make test-fast ONLY=PlayolaInterviewEditorTests/TranscriptSelectionTests
ONLY ?=
test-fast:
	xcodebuild test \
		-scheme PlayolaInterviewEditor \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO \
		$(if $(ONLY),-only-testing:$(ONLY),)

# Regenerate the Xcode project from project.yml
generate:
	xcodegen generate
