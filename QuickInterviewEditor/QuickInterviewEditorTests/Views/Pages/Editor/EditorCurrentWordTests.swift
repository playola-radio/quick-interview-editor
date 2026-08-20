import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
@_spi(Internals) import Sharing
import Testing

@testable import QuickInterviewEditor

@MainActor
struct EditorCurrentWordTests {
  private var plan: EditPlan {
    EditPlan(
      schemaVersion: 1,
      source: .init(path: "", sampleRate: 1000, channels: 1, durationSamples: 3000),
      words: [
        Word(id: 1, text: "one", start: 0, end: 1, startSample: 0, endSample: 1000),
        Word(id: 2, text: "two", start: 1, end: 2, startSample: 1000, endSample: 2000),
        Word(id: 3, text: "three", start: 2, end: 3, startSample: 2000, endSample: 3000),
      ], silences: [], segments: [])
  }

  private func withEditor(_ body: (EditorModel) -> Void) {
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: LockIsolated([:]))
    } operation: {
      body(
        EditorModel(
          sourceURL: URL(fileURLWithPath: "/clip.m4a"),
          canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: plan,
          sourceFingerprint: "fp-current-word"))
    }
  }

  /// The current-word highlight is driven by the persistent cursor, so it tracks the word under
  /// the playhead whether that came from playback or a manual move.
  @Test func cursorHighlightsTheWordUnderIt() {
    withEditor { editor in
      editor.playheadEditedSample = 1500
      expectNoDifference(editor.transcript.currentWordID, 2)
    }
  }

  /// Moving the cursor (a scrub, a ruler drag, a Stop back to origin) moves the highlight — it is
  /// never left stale on the last-heard word.
  @Test func movingTheCursorMovesTheHighlight() {
    withEditor { editor in
      editor.playheadEditedSample = 2500
      expectNoDifference(editor.transcript.currentWordID, 3)
      editor.playheadEditedSample = 0  // e.g. Stop returns the cursor to the origin
      expectNoDifference(editor.transcript.currentWordID, 1)
    }
  }

  /// A cursor in a gap / past the end keeps the last word, so you never lose your place.
  @Test func cursorInAGapKeepsTheLastWord() {
    withEditor { editor in
      editor.playheadEditedSample = 500
      editor.playheadEditedSample = 9999  // past the last word
      expectNoDifference(editor.transcript.currentWordID, 1)
    }
  }
}
