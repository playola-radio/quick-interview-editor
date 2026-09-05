import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct EditorDocumentMutationTests {

  private func editor() -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL,
      editPlan: Fixtures.editPlan(), sourceFingerprint: "fp-mutation")
  }

  @Test func mutateDocumentEmitsChangeOnceWithTheNewState() {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    let slice = Fixtures.slice(id: Fixtures.uuid(1))
    model.mutateDocument { $0.slices.append(slice) }

    expectNoDifference(seen.count, 1)
    expectNoDifference(seen.last?.slices.last, slice)
    #expect(model.canUndo)
  }

  @Test func noOpMutateDocumentFiresTheCallbackButRecordsNoUndo() {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.mutateDocument { _ in }

    expectNoDifference(seen.count, 1)
    #expect(!model.canUndo)
  }

  @Test func recordUndoFalseDirtiesButLeavesCanUndoUnchanged() {
    let model = editor()
    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    model.mutateDocument(recordUndo: false) {
      $0.slices.append(Fixtures.slice(id: Fixtures.uuid(1)))
    }

    expectNoDifference(seen.count, 1)
    expectNoDifference(seen.last?.slices.count, 1)
    #expect(!model.canUndo)
  }

  @Test func undoAndRedoFireTheCallbackAfterRestoring() async {
    let model = editor()
    let slice = Fixtures.slice(id: Fixtures.uuid(1))
    model.mutateDocument { $0.slices.append(slice) }

    var seen: [EditorDocumentState] = []
    model.onDocumentStateChanged = { seen.append($0) }

    await model.undoTapped()
    expectNoDifference(seen.count, 1)
    expectNoDifference(seen.last?.slices.count, 0)

    await model.redoTapped()
    expectNoDifference(seen.count, 2)
    expectNoDifference(seen.last?.slices.last, slice)
  }

  @Test func documentStateCarriesTheNewFields() {
    let model = editor()
    let suggestion = Fixtures.cutSuggestion(id: Fixtures.uuid(5))
    model.mutateDocument { doc in
      doc.cutSuggestions.append(suggestion)
      doc.speakerCountOverride = 3
      doc.speakerDisplayNames = ["0": "Host"]
    }

    expectNoDifference(model.documentState.cutSuggestions.elements, [suggestion])
    expectNoDifference(model.documentState.speakerCountOverride, 3)
    expectNoDifference(model.documentState.speakerDisplayNames, ["0": "Host"])
  }
}
