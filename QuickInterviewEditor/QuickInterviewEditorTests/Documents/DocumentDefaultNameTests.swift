import CustomDump
import Testing

@testable import PlayolaInterviewEditor

/// The decision behind the untitled-document default-name bridge (`DocumentDefaultName`): what name,
/// if any, gets written to the backing `NSDocument.displayName`. Covers the guards Greptile/Codex
/// flagged as untested — apply the suggestion to an unsaved doc, never touch a saved one, and no-op
/// when there's nothing to change — without a live `NSWindow`/`NSDocument` hierarchy.
@MainActor
struct DocumentDefaultNameTests {

  private typealias View = DocumentDefaultName.NameApplyingView

  @Test func appliesSuggestionToUnsavedUntitledDocument() {
    expectNoDifference(
      View.nameToApply(suggested: "my interview", currentDisplayName: "Untitled", isSaved: false),
      "my interview")
  }

  @Test func doesNotTouchSavedDocument() {
    expectNoDifference(
      View.nameToApply(suggested: "my interview", currentDisplayName: "Untitled", isSaved: true),
      nil)
  }

  @Test func noOpWhenNameAlreadyApplied() {
    expectNoDifference(
      View.nameToApply(
        suggested: "my interview", currentDisplayName: "my interview", isSaved: false),
      nil)
  }

  @Test func noOpWhenSuggestionIsNilOrEmpty() {
    expectNoDifference(
      View.nameToApply(suggested: nil, currentDisplayName: "Untitled", isSaved: false), nil)
    expectNoDifference(
      View.nameToApply(suggested: "", currentDisplayName: "Untitled", isSaved: false), nil)
  }
}
