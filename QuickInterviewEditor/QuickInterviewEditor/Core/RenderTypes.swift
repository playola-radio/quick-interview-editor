import Foundation

/// Input to `EngineClient.renderSlices`. Everything is in **samples** so Swift and
/// the engine share one coordinate system. `markers` carry ABSOLUTE positions taken
/// straight from the loaded `EditPlan` words — the engine never rebuilds them from
/// seconds (no rounding drift).
struct RenderRequest: Equatable, Sendable {
  var sourceURL: URL
  var sampleRate: Int
  var markers: [RenderMarker]
  var slices: [RenderSliceSpec]
}

struct RenderMarker: Equatable, Sendable {
  var position: Int
  var name: String
}

struct RenderSliceSpec: Equatable, Sendable, Identifiable {
  var id: UUID
  var startSample: Int
  var endSample: Int
}

enum RenderEvent: Equatable, Sendable {
  case progress(RenderProgress)
  case completed([RenderedSlice])
}

struct RenderProgress: Equatable, Sendable {
  var message: String
  var index: Int
  var total: Int
}

/// One rendered slice: the engine wrote `url` (an app-owned temp AIFF); Swift copies
/// it to the user's chosen folder. Keyed by the request slice `id`.
struct RenderedSlice: Equatable, Sendable, Identifiable {
  var id: UUID
  var url: URL
}
