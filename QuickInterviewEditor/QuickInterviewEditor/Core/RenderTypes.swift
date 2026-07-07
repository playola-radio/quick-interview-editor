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
  case completed(RenderResult)
}

/// The finished render. `workDir` is the app-owned scratch directory the engine
/// wrote into — vouched for by `LiveEngine` (not inferred from engine output), so
/// the caller can copy the slices out and then delete exactly this directory.
struct RenderResult: Equatable, Sendable {
  var slices: [RenderedSlice]
  var workDir: URL
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
