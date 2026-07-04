.PHONY: lint format format-check test generate

# Run SwiftLint (strict mode to match CI)
lint:
	swiftlint --strict

# Auto-fix formatting issues
format:
	xcrun swift-format format -i --recursive .

# Check formatting (fails on issues)
format-check:
	xcrun swift-format lint --strict --recursive .

# Run the Swift Testing suite via fastlane
test:
	bundle exec fastlane mac test

# Regenerate the Xcode project from project.yml
generate:
	xcodegen generate
