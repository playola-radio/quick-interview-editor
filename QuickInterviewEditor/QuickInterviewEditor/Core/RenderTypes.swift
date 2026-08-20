import Foundation

struct RenderMarker: Equatable, Sendable {
  var position: Int
  var name: String
}

/// One rendered slice AIFF plus the markers Python should inject into it. Positions are
/// slice-relative EDITED samples (frames from the start of that file); names are word text.
struct MarkerInjectionFile: Equatable, Sendable {
  var url: URL
  var markers: [RenderMarker]
}
