import CustomDump
import Foundation
import Testing

@testable import QuickInterviewEditor

struct EditPlanDecodingTests {
  @Test func decodesRealFixture() {
    let plan = Fixtures.editPlan()
    expectNoDifference(plan.words.count, 122)
    expectNoDifference(plan.silences.count, 25)
    expectNoDifference(plan.source.sampleRate, 44100)
    expectNoDifference(plan.source.channels, 2)
    expectNoDifference(plan.words.first?.text, "So")
    expectNoDifference(plan.words.first?.startSample, 54772)
  }

  @Test func decodesSilencesAsSampleIntegers() throws {
    let jsonString = """
      {"schema_version":1,
       "source":{"path":"a","sample_rate":44100,"channels":1,"duration_samples":100},
       "words":[],"silences":[{"start":1000,"end":2000}],"segments":[]}
      """
    let plan = try JSONDecoder().decode(EditPlan.self, from: Data(jsonString.utf8))
    expectNoDifference(plan.silences, [EditPlan.Silence(startSample: 1000, endSample: 2000)])
  }

  @Test func decodesEmptySegments() throws {
    let jsonString = """
      {"schema_version":1,
       "source":{"path":"a","sample_rate":44100,"channels":1,"duration_samples":100},
       "words":[],"silences":[],"segments":[]}
      """
    let plan = try JSONDecoder().decode(EditPlan.self, from: Data(jsonString.utf8))
    expectNoDifference(plan.segments, [])
  }
}
