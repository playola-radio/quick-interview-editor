import CustomDump
import Foundation
import Testing

@testable import PlayolaInterviewEditor

// swiftlint:disable:next inclusive_language
struct MasteringInputsDigestTests {
  @Test func snapshotFreezesEditedWordsAndIgnoresSpotlightOnlyChanges() throws {
    var intro = Fixtures.slice(id: Fixtures.uuid(101), start: 0, end: 500)
    intro.name = "Opening"
    intro.suggestionTypeID = "intro"
    var spotlight = Fixtures.slice(id: Fixtures.uuid(102), start: 500, end: 1_000)
    spotlight.suggestionTypeID = "spotlight"
    let removal = TimelineRemoval(
      id: Fixtures.uuid(103), removedRange: 100..<200,
      crossfade: Crossfade(lengthSamples: 0))
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(
        path: "fixture", sampleRate: 48_000, channels: 1, durationSamples: 1_000),
      words: [50, 150, 250].enumerated().map { index, frame in
        EditPlan.Word(
          id: index, text: "word\(index)", start: 0, end: nil,
          startSample: frame, endSample: nil)
      }, silences: [], segments: [])
    let source = Fixtures.projectSource(sampleRate: 48_000, durationSamples: 1_000)
    let document = EditorDocumentState(
      slices: [intro, spotlight], timelineRemovals: [removal],
      interviewArtist: "Artist")
    let snapshot = try MasteringSnapshotBuilder.build(
      document: document, plan: plan, source: source,
      canonicalAudioURL: URL(fileURLWithPath: "/tmp/canonical.aiff")
    ).get()
    expectNoDifference(snapshot.pieces.map(\.title), ["Opening"])
    expectNoDifference(snapshot.pieces[0].editedDurationSamples, 400)
    expectNoDifference(snapshot.pieces[0].wordStarts.map(\.position), [50, 150])
    var spotlightChanged = document
    spotlightChanged.slices[id: spotlight.id]?.name = "New spotlight title"
    let afterSpotlight = try MasteringSnapshotBuilder.build(
      document: spotlightChanged, plan: plan, source: source,
      canonicalAudioURL: snapshot.canonicalAudioURL
    ).get()
    expectNoDifference(snapshot.inputsDigest, afterSpotlight.inputsDigest)
    var introChanged = document
    introChanged.slices[id: intro.id]?.name = "New intro title"
    let afterIntro = try MasteringSnapshotBuilder.build(
      document: introChanged, plan: plan, source: source,
      canonicalAudioURL: snapshot.canonicalAudioURL
    ).get()
    #expect(snapshot.inputsDigest != afterIntro.inputsDigest)
  }

  @Test func malformedWordTimeReturnsInvalidTimelineInsteadOfTrapping() {
    var intro = Fixtures.slice(id: Fixtures.uuid(111), start: 0, end: 100)
    intro.suggestionTypeID = "intro"
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(
        path: "fixture", sampleRate: 48_000, channels: 1, durationSamples: 100),
      words: [
        EditPlan.Word(
          id: 1, text: "bad", start: .nan, end: nil,
          startSample: nil, endSample: nil)
      ], silences: [], segments: [])
    let document = EditorDocumentState(slices: [intro], interviewArtist: "Artist")
    let result = MasteringSnapshotBuilder.build(
      document: document, plan: plan,
      source: Fixtures.projectSource(sampleRate: 48_000, durationSamples: 100),
      canonicalAudioURL: URL(fileURLWithPath: "/tmp/canonical.aiff"))
    expectNoDifference(result, .failure(.invalidTimeline))
  }

  @Test func nonfiniteIntroCrossfadeCannotCrashDigestSerialization() {
    var intro = Fixtures.slice(id: Fixtures.uuid(121), start: 0, end: 100)
    intro.suggestionTypeID = "intro"
    let removal = TimelineRemoval(
      id: UUID(), removedRange: 20..<30,
      crossfade: Crossfade(lengthSamples: 2, curveAmount: .nan))
    let plan = EditPlan(
      schemaVersion: 1,
      source: EditPlan.Source(
        path: "fixture", sampleRate: 48_000, channels: 1, durationSamples: 100),
      words: [], silences: [], segments: [])
    let document = EditorDocumentState(
      slices: [intro], timelineRemovals: [removal], interviewArtist: "Artist")
    let result = MasteringSnapshotBuilder.build(
      document: document, plan: plan,
      source: Fixtures.projectSource(sampleRate: 48_000, durationSamples: 100),
      canonicalAudioURL: URL(fileURLWithPath: "/tmp/canonical.aiff"))
    expectNoDifference(result, .failure(.invalidTimeline))
  }

  @Test func digestIsStableAndTracksFrozenIntroInputs() throws {
    let source = ProjectSource(
      originalFileName: "source.aiff", originalPath: nil, originalFingerprint: "old",
      canonicalFingerprint: "canonical", canonicalByteCount: 1, importedAt: .distantPast,
      sampleRate: 48_000, channels: 1, durationSamples: 48_000)
    let id = UUID()
    let piece = MasteringPieceInput(
      sliceID: id, title: "Intro",
      render: AudioEditRenderPlan(
        timeline: EditedTimeline(sourceDurationSamples: 100, removals: [])),
      editedDurationSamples: 100, sourceRange: 0..<100, localRemovals: [],
      wordStarts: [RenderMarker(position: 2, name: "Hello")], typeProvenance: "explicit")
    let first = MasteringInputsDigest.make(
      source: source, artist: "Artist", pieces: [piece], typeIDs: [id: "intro"])
    expectNoDifference(
      first,
      MasteringInputsDigest.make(
        source: source, artist: "Artist", pieces: [piece], typeIDs: [id: "intro"]))
    #expect(first.hasPrefix("v1:"))
    #expect(
      first
        != MasteringInputsDigest.make(
          source: source, artist: "Changed", pieces: [piece], typeIDs: [id: "intro"]))
    var renamed = piece
    renamed.title = "Changed"
    #expect(
      first
        != MasteringInputsDigest.make(
          source: source, artist: "Artist", pieces: [renamed], typeIDs: [id: "intro"]))
  }
}
