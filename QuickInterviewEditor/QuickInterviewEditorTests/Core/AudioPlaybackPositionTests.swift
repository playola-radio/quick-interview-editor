import CustomDump
import Testing

@testable import PlayolaInterviewEditor

struct AudioPlaybackPositionTests {
  @Test func positionCarriesDistinctRenderAndPresentationSamples() {
    let session = PlaybackSessionID()
    let position = PlaybackPosition(
      sessionID: session,
      renderSample: .source(1_000),
      presentationSample: .source(800),
      isPlaying: true)
    expectNoDifference(position.renderSample, .source(1_000))
    expectNoDifference(position.presentationSample, .source(800))
  }
}
