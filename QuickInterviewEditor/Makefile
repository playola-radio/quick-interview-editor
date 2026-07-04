.PHONY: lint format format-check test generate

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

# Regenerate the Xcode project from project.yml
generate:
	xcodegen generate
