import CustomDump
import Testing

@testable import PlayolaInterviewEditor

@MainActor
struct SaveStatusTests {

  @Test func freshStatusReadsSaved() {
    let status = SaveStatus()
    #expect(!status.isSaving)
    expectNoDifference(status.label, "Saved")
  }

  @Test func editingFlipsToSaving() {
    let status = SaveStatus()
    status.markEdited(generation: 1)
    #expect(status.isSaving)
    expectNoDifference(status.label, "Saving…")
  }

  @Test func completingTheOnlyEditReturnsToSaved() {
    let status = SaveStatus()
    status.markEdited(generation: 1)
    status.markSaved(upToGeneration: 1)
    #expect(!status.isSaving)
    expectNoDifference(status.label, "Saved")
  }

  @Test func anEditLandingMidSaveKeepsSaving() {
    let status = SaveStatus()
    status.markEdited(generation: 1)
    status.markEdited(generation: 2)
    status.markSaved(upToGeneration: 1)
    #expect(status.isSaving)
    expectNoDifference(status.label, "Saving…")
  }

  @Test func theLaterSaveThenClearsTheMidSaveEdit() {
    let status = SaveStatus()
    status.markEdited(generation: 1)
    status.markEdited(generation: 2)
    status.markSaved(upToGeneration: 1)
    status.markSaved(upToGeneration: 2)
    #expect(!status.isSaving)
    expectNoDifference(status.label, "Saved")
  }
}
