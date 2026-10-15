import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import Sharing
import Testing

@testable import PlayolaInterviewEditor

@MainActor
final class ClipNamingGate {
  private(set) var requests: [ClipNamingRequest] = []
  private(set) var apiKeys: [String] = []
  private var pending: [CheckedContinuation<ClipNamingResult?, any Error>] = []

  func nameClip(_ request: ClipNamingRequest, _ apiKey: String) async throws -> ClipNamingResult? {
    requests.append(request)
    apiKeys.append(apiKey)
    return try await withCheckedThrowingContinuation { pending.append($0) }
  }

  func resolveNext(_ result: ClipNamingResult?) {
    pending.removeFirst().resume(returning: result)
  }

  func failNext() {
    pending.removeFirst().resume(throwing: CutSuggestClientError.unimplemented("nameClip"))
  }

  func waitForRequests(_ count: Int) async {
    var attempts = 0
    while requests.count < count, attempts < 2_000 {
      attempts += 1
      await Task.yield()
    }
  }
}

extension ClipNamingResult {
  static let songIntro = ClipNamingResult(
    typeID: "intro", fields: ["song-title": "Whiskey Rain", "artist-name": "Hayes Carll"])
  static let spotlight = ClipNamingResult(typeID: "spotlight", fields: [:])
}

@MainActor
struct EditorManualClipNamingTests {
  private func run(
    gate: ClipNamingGate, key: String? = "sk-test",
    configuration: SuggestionConfiguration = SuggestionDefaults.configuration,
    _ operation: () async throws -> Void
  ) async rethrows {
    try await withMainSerialExecutor {
      try await withDependencies {
        $0.uuid = .incrementing
        $0.defaultAppStorage = UserDefaults(suiteName: "manual-clip-naming-\(UUID())")!
        $0.keychain = .inMemory(key)
        $0.suggestionConfiguration = .inMemory(configuration)
        $0.cutSuggest = CutSuggestClient(
          suggestCuts: { _, _ in AsyncThrowingStream { $0.finish() } },
          nameClip: { try await gate.nameClip($0, $1) })
      } operation: {
        try await operation()
      }
    }
  }

  private func editor(initialDocument: EditorDocumentState = EditorDocumentState()) -> EditorModel {
    EditorModel(
      sourceURL: URL(fileURLWithPath: "/clip.m4a"),
      canonicalAudioURL: Fixtures.canonicalAudioURL, editPlan: Fixtures.editPlan(),
      initialDocument: initialDocument)
  }

  private func selectWords(_ model: EditorModel, _ first: Int, _ last: Int) {
    let transcript = model.transcript
    transcript.transcriptDragBegan(
      atUTF16Offset: transcript.document.wordRanges[first].range.location)
    transcript.transcriptDragged(
      toUTF16Offset: transcript.document.wordRanges[last].range.location)
  }

  private func markClip(_ model: EditorModel, _ first: Int, _ last: Int) -> Slice {
    selectWords(model, first, last)
    model.addSliceTapped()
    return model.slices.last!
  }

  private func reservation(
    for typeID: String, number: Int, candidateID: UUID = UUID(99)
  ) -> SequenceReservation {
    let type = SuggestionDefaults.configuration.types.first { $0.id == typeID }!
    return SequenceReservation(
      candidateID: candidateID,
      key: suggestionSequenceKey(type: type, values: [:], candidateID: candidateID),
      number: number, canonicalValues: [:])
  }

  // MARK: - Renaming

  @Test func songIntroClipIsRenamedFromItsTemplate() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      gate.resolveNext(.songIntro)
      await model.awaitClipNaming()

      let named = model.slices[id: clip.id]
      expectNoDifference(named?.name, "Whiskey Rain 1, Hayes Carll")
      expectNoDifference(named?.suggestionTypeID, "intro")
      expectNoDifference(named?.suggestionNaming?.typeName, "Song Intro")
      expectNoDifference(
        named?.suggestionNaming?.extractedValues,
        ["song-title": "Whiskey Rain", "artist-name": "Hayes Carll"])
      expectNoDifference(named?.suggestionNaming?.discoveryLabel, "Slice 1")
      expectNoDifference(model.issuedSuggestionNumbers.map(\.candidateID), [clip.id])
    }
  }

  @Test func requestCarriesTheClipTheKeyAndTheTranscriptContext() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      model.mutateDocument(recordUndo: false) { $0.interviewArtist = "Hayes Carll" }
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)

      let request = gate.requests[0]
      expectNoDifference(gate.apiKeys, ["sk-test"])
      expectNoDifference(
        request.clipText, sliceSnippet(for: clip.wordIDs, words: model.editPlan.words))
      expectNoDifference(request.clipStartSample, clip.startSample)
      expectNoDifference(request.clipEndSample, clip.endSample)
      expectNoDifference(request.model, "claude-sonnet-5")
      expectNoDifference(request.configuration, SuggestionDefaults.configuration)
      expectNoDifference(request.transcriptUnits, model.editPlan.transcriptUnits)
      expectNoDifference(request.interviewArtist, "Hayes Carll")
      gate.resolveNext(nil)
      await model.awaitClipNaming()
    }
  }

  @Test func numberingContinuesAfterAnAlreadyIssuedNumber() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let earlier = reservation(for: "spotlight", number: 4)
      let model = editor(initialDocument: EditorDocumentState(issuedSuggestionNumbers: [earlier]))
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id]?.name, "Spotlight 5")
      expectNoDifference(model.issuedSuggestionNumbers.map(\.candidateID), [UUID(99), clip.id])
      expectNoDifference(model.issuedSuggestionNumbers.map(\.number), [4, 5])
    }
  }

  @Test func rapidClipsAreNamedInCreationOrder() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let first = markClip(model, 0, 3)
      let second = markClip(model, 10, 13)
      await gate.waitForRequests(1)
      expectNoDifference(gate.requests.count, 1)
      expectNoDifference(gate.requests[0].clipStartSample, first.startSample)
      gate.resolveNext(.spotlight)
      await gate.waitForRequests(2)
      expectNoDifference(gate.requests[1].clipStartSample, second.startSample)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: first.id]?.name, "Spotlight 1")
      expectNoDifference(model.slices[id: second.id]?.name, "Spotlight 2")
    }
  }

  @Test func commitFromFineTunePaneIsNamed() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      selectWords(model, 0, 3)
      model.syncEditSession()
      model.commitEditTapped()
      let clip = model.slices[0]
      await gate.waitForRequests(1)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id]?.name, "Spotlight 1")
    }
  }

  @Test func freeformDraftSaveIsNamed() async throws {
    let gate = ClipNamingGate()
    try await run(gate: gate) {
      let model = editor()
      model.selection = .range(55_000..<90_000, anchor: 55_000)
      model.openSelectionTapped()
      let child = try #require(model.editSlice)
      let id = child.target.resultingClipID
      child.saveTapped()
      await gate.waitForRequests(1)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: id]?.name, "Spotlight 1")
    }
  }

  // swiftlint:disable:next inclusive_language
  @Test func handMarkedIntroBecomesMasteringEligible() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      expectNoDifference(MasteringEligibilityRule.evaluate(model.documentState).intros, [])
      await gate.waitForRequests(1)
      gate.resolveNext(.songIntro)
      await model.awaitClipNaming()

      expectNoDifference(
        MasteringEligibilityRule.evaluate(model.documentState).intros.map(\.id), [clip.id])
    }
  }

  // MARK: - Nothing happens

  @Test func missingKeyNeverCallsTheHelper() async {
    let gate = ClipNamingGate()
    await run(gate: gate, key: nil) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await model.awaitClipNaming()

      expectNoDifference(gate.requests, [])
      expectNoDifference(model.slices[id: clip.id]?.name, "Slice 1")
    }
  }

  @Test func noMatchLeavesTheClipUnchanged() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      gate.resolveNext(nil)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id], clip)
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func helperFailureLeavesTheClipUnchanged() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      gate.failNext()
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id], clip)
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func unknownTypeLeavesTheClipUnchanged() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      gate.resolveNext(ClipNamingResult(typeID: "not-a-type", fields: [:]))
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id], clip)
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func invalidConfigurationNeverCallsTheHelper() async {
    let gate = ClipNamingGate()
    await run(gate: gate, configuration: SuggestionConfiguration(types: [], fields: [])) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await model.awaitClipNaming()

      expectNoDifference(gate.requests, [])
      expectNoDifference(model.slices[id: clip.id]?.name, "Slice 1")
    }
  }

  @Test func deletedClipIsNotResurrectedOrNumbered() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      await model.deleteSlice(clip.id)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      #expect(model.slices.isEmpty)
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func renamedClipKeepsItsName() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      model.renameSlice(clip.id, to: "My name")
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id]?.name, "My name")
      expectNoDifference(model.slices[id: clip.id]?.suggestionNaming, nil)
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func clipWhoseNameIsBeingEditedKeepsItsName() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      model.sliceNameFocusChanged(clip.id, isFocused: true)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id]?.name, "Slice 1")
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  private func removal(coveringWord index: Int, of model: EditorModel) -> TimelineRemoval {
    let word = model.editPlan.words[index]
    return TimelineRemoval(
      id: UUID(77), removedRange: word.startSample!..<word.endSample!,
      crossfade: Crossfade(lengthSamples: 200, curve: .equalPower))
  }

  @Test func removedWordsAreLeftOutOfTheClipText() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let removed = removal(coveringWord: 1, of: model)
      model.mutateDocument(recordUndo: false) { $0.timelineRemovals.append(removed) }
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)

      expectNoDifference(
        gate.requests[0].clipText,
        sliceSnippet(
          for: clip.wordIDs.filter { $0 != model.editPlan.words[1].id },
          words: model.editPlan.words))
      gate.resolveNext(nil)
      await model.awaitClipNaming()
    }
  }

  @Test func clipWhoseRemovalsChangedKeepsItsName() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      let removed = removal(coveringWord: 1, of: model)
      model.mutateDocument(recordUndo: false) { $0.timelineRemovals.append(removed) }
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id]?.name, "Slice 1")
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func changedInterviewArtistKeepsTheClipName() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      model.mutateDocument(recordUndo: false) { $0.interviewArtist = "Alice" }
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      model.mutateDocument(recordUndo: false) { $0.interviewArtist = "Bob" }
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id]?.name, "Slice 1")
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func resultArrivingDuringExportIsAppliedWhenExportCloses() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      model.exportPhase = .reviewing(current: 0, total: 1)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()
      expectNoDifference(model.slices[id: clip.id]?.name, "Slice 1")

      model.exportPhase = .idle

      expectNoDifference(model.slices[id: clip.id]?.name, "Spotlight 1")
    }
  }

  @Test func rangeEditedClipKeepsItsName() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      model.commitSliceEdit(id: clip.id, range: clip.startSample..<(clip.endSample + 20_000))
      let edited = model.slices[id: clip.id]
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: clip.id], edited)
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  // MARK: - Undo

  @Test func undoAfterNamingRemovesTheClipInOneStepAndRedoRestoresTheNamedClip() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let clip = markClip(model, 0, 3)
      let undoDepth = model.history.undo.count
      await gate.waitForRequests(1)
      gate.resolveNext(.songIntro)
      await model.awaitClipNaming()
      expectNoDifference(model.history.undo.count, undoDepth)

      await model.undoTapped()
      #expect(model.slices.isEmpty)

      await model.redoTapped()
      expectNoDifference(model.slices[id: clip.id]?.name, "Whiskey Rain 1, Hayes Carll")
      expectNoDifference(model.slices[id: clip.id]?.suggestionTypeID, "intro")
    }
  }

  @Test func undoneClipIsNotRenamedByALateResult() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      _ = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      await model.undoTapped()
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      #expect(model.slices.isEmpty)
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  // MARK: - Teardown

  @Test func cancellingClipNamingDropsRunningAndQueuedJobs() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      let first = markClip(model, 0, 3)
      let second = markClip(model, 10, 13)
      await gate.waitForRequests(1)
      model.cancelClipNaming()
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(gate.requests.count, 1)
      expectNoDifference(model.slices[id: first.id]?.name, "Slice 1")
      expectNoDifference(model.slices[id: second.id]?.name, "Slice 2")
      expectNoDifference(model.issuedSuggestionNumbers, [])
    }
  }

  @Test func namingStillWorksAfterACancellation() async {
    let gate = ClipNamingGate()
    await run(gate: gate) {
      let model = editor()
      _ = markClip(model, 0, 3)
      await gate.waitForRequests(1)
      model.cancelClipNaming()
      let next = markClip(model, 10, 13)
      await gate.waitForRequests(2)
      gate.resolveNext(.spotlight)
      gate.resolveNext(.spotlight)
      await model.awaitClipNaming()

      expectNoDifference(model.slices[id: next.id]?.name, "Spotlight 1")
    }
  }
}

@MainActor
struct ProjectManualClipNamingTests {
  @Test func closingTheProjectCancelsPendingClipNaming() async throws {
    let gate = ClipNamingGate()
    try await withMainSerialExecutor {
      try await withDependencies {
        $0.uuid = .incrementing
        $0.defaultAppStorage = UserDefaults(suiteName: "project-clip-naming-\(UUID())")!
        $0.keychain = .inMemory("sk-test")
        $0.suggestionConfiguration = .inMemory()
        $0.canonicalAudioStore.remove = { _ in }
        $0.cutSuggest = CutSuggestClient(
          suggestCuts: { _, _ in AsyncThrowingStream { $0.finish() } },
          nameClip: { try await gate.nameClip($0, $1) })
      } operation: {
        let (sink, _) = ProjectDocumentSink.recorder()
        let model = ProjectModel(
          file: Fixtures.projectFile(), plan: Fixtures.editPlan(),
          audio: .sessionFile(URL(fileURLWithPath: "/session/audio.aiff")), sink: sink)
        await model.viewAppeared()
        let editor = try #require(model.editor)
        let transcript = editor.transcript
        transcript.transcriptDragBegan(
          atUTF16Offset: transcript.document.wordRanges[0].range.location)
        transcript.transcriptDragged(
          toUTF16Offset: transcript.document.wordRanges[3].range.location)
        editor.addSliceTapped()
        let clip = try #require(editor.slices.last)
        await gate.waitForRequests(1)

        await model.viewDisappeared()
        gate.resolveNext(.spotlight)
        await editor.awaitClipNaming()

        expectNoDifference(editor.slices[id: clip.id]?.name, clip.name)
        expectNoDifference(editor.issuedSuggestionNumbers, [])
      }
    }
  }
}
