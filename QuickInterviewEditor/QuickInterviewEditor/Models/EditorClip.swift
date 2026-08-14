import Foundation

/// Where a clip sits in the suggest → approve/reject lifecycle. A `.suggested` clip is a
/// pending LLM candidate; `.approved` is a saved (exportable) clip; `.rejected` is struck
/// out and excluded from export.
enum ClipState: Equatable, Sendable { case suggested, approved, rejected }

/// What backs a clip: a cut suggestion in the persisted sidecar, or a manual slice the user
/// made in the editor. Accepted suggestions are deduped by id against their minted slice, so
/// a clip is never double-counted.
enum ClipSource: Equatable, Sendable {
  case suggestion(CutSuggestion.ID)
  case manualSlice(Slice.ID)
}

/// The unified read model the clip-cards UI walks — one entry per suggestion or manual slice,
/// with everything the card needs to render and every clip-level action to key off. Derived
/// state (never stored): `EditorModel.clips` recomputes it from the sidecar + `slices`.
struct EditorClip: Identifiable, Equatable, Sendable {
  var id: UUID
  var source: ClipSource
  var title: String
  var state: ClipState
  var wordIDs: [Word.ID]
  var range: Range<Int>?
  var snippet: String
  var order: Int
}
