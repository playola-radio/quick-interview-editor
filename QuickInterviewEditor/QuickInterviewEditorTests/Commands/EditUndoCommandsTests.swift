import CustomDump
import Dependencies
import Foundation
import Testing

@testable import PlayolaInterviewEditor

/// The Edit-menu Undo/Redo items route to the focused project's editor and mirror its
/// `UndoStack` state; with no focused project they are inert.
@MainActor
struct EditUndoCommandsTests {
  private func loadedProject() async throws -> ProjectModel {
    let (sink, _) = ProjectDocumentSink.recorder()
    let model = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    await withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.transcription.transcribe = { _, _, _ in
        engineEvents([.completed(Fixtures.transcriptionResult(Fixtures.editPlan()))])
      }
    } operation: {
      await model.importAudioTapped(URL(fileURLWithPath: "/clip.m4a"))
    }
    _ = try #require(model.editor)
    return model
  }

  @Test func noFocusedProjectDisablesBothWithDefaultLabels() async {
    let commands = EditUndoCommandsModel(project: nil)
    expectNoDifference(commands.undoLabel, "Undo")
    expectNoDifference(commands.redoLabel, "Redo")
    #expect(!commands.canUndo)
    #expect(!commands.canRedo)
    await commands.undoTapped()  // inert, must not trap
    await commands.redoTapped()
  }

  @Test func aProjectWithoutAnEditorIsDisabled() {
    let (sink, _) = ProjectDocumentSink.recorder()
    let project = ProjectModel(file: nil, plan: nil, audio: nil, sink: sink)
    let commands = EditUndoCommandsModel(project: project)
    #expect(!commands.canUndo)
    #expect(!commands.canRedo)
  }

  @Test func undoAndRedoRouteToTheFocusedEditor() async throws {
    let project = try await loadedProject()
    let editor = try #require(project.editor)
    let commands = EditUndoCommandsModel(project: project)
    #expect(!commands.canUndo)
    #expect(!commands.canRedo)

    editor.mutateDocument { $0.speakerCountOverride = 3 }
    #expect(commands.canUndo)
    #expect(!commands.canRedo)
    expectNoDifference(commands.undoLabel, editor.undoLabel)

    await commands.undoTapped()
    expectNoDifference(editor.speakerCountOverride, nil)
    #expect(!commands.canUndo)
    #expect(commands.canRedo)
    expectNoDifference(commands.redoLabel, editor.redoLabel)

    await commands.redoTapped()
    expectNoDifference(editor.speakerCountOverride, 3)
    #expect(commands.canUndo)
    #expect(!commands.canRedo)
  }

  @Test func reimportCommandFollowsTheFocusedProject() async throws {
    let none = TranscriptionCommandsModel(project: nil)
    #expect(!none.canReimport)
    expectNoDifference(none.reimportMenuLabel, "Re-import (Ignore Cache)")
    await none.reimportTapped()  // inert

    let project = try await loadedProject()
    let commands = TranscriptionCommandsModel(project: project)
    #expect(commands.canReimport)
    expectNoDifference(commands.reimportMenuLabel, project.reimportMenuLabel)
  }
  @Test func draftMenuUndoIsLocalEvenWithDocumentHistoryAndExport() async throws {
    let project = try await loadedProject()
    let editor = try #require(project.editor)
    editor.mutateDocument { $0.speakerCountOverride = 4 }
    let draft = EditSliceModel(
      target: .freeformDraft(UUID(1)), title: "Draft", range: 55_000..<90_000,
      editPlan: editor.editPlan)
    editor.editSlice = draft
    let commands = EditUndoCommandsModel(project: project)
    #expect(!commands.canUndo)
    await commands.undoTapped()
    expectNoDifference(editor.speakerCountOverride, 4)
    draft.cutInNudgedForward()
    #expect(commands.canUndo)
    expectNoDifference(commands.undoLabel, "Undo Cut Point Edit")
    await commands.undoTapped()
    expectNoDifference(draft.fineTune.draftRange, 55_000..<90_000)
    expectNoDifference(editor.speakerCountOverride, 4)
    #expect(commands.canRedo)
    await commands.redoTapped()
    expectNoDifference(draft.fineTune.draftRange, 55_441..<90_000)
  }

}
