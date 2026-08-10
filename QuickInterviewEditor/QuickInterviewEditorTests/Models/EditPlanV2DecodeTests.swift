import CustomDump
import Testing

@testable import QuickInterviewEditor

struct EditPlanV2DecodeTests {
  @Test func decodesSchemaV2WithConfidenceAndTranscriptSegments() {
    let plan = Fixtures.editPlanV2()
    expectNoDifference(plan.schemaVersion, 2)
    expectNoDifference(plan.words.first?.confidence, 0.99)
    // An explicit null confidence decodes to nil, not a value.
    expectNoDifference(plan.words[1].confidence, nil)
    expectNoDifference(
      plan.transcriptSegments,
      [
        EditPlan.TranscriptSegment(id: 1, wordIDs: [1, 2, 3, 4], text: "So a young Hayes."),
        EditPlan.TranscriptSegment(
          id: 2, wordIDs: [5, 6, 7, 8, 9], text: "He waits around the concert."),
        EditPlan.TranscriptSegment(id: 3, wordIDs: [10, 11, 12], text: "Then he leaves."),
      ])
  }

  @Test func v1PlanStillDecodesWithNewFieldsAbsent() {
    // The committed v1 fixture predates schema v2; every new field is optional,
    // so it decodes unchanged with `transcriptSegments` and `confidence` nil.
    let plan = Fixtures.editPlan()
    expectNoDifference(plan.schemaVersion, 1)
    expectNoDifference(plan.transcriptSegments, nil)
    expectNoDifference(plan.words.allSatisfy { $0.confidence == nil }, true)
  }
}
