import Foundation

/// Pinned knobs for a cut-suggestion run. The model / prompt / product-spec versions are
/// recorded on every suggestion's provenance so a silent model or prompt upgrade is
/// attributable and stale results are detectable. The window params mirror the Python
/// two-stage cutter (`cut_suggester/config.py`); the live impl (PR 5) consumes them, and
/// they participate in its response cache key.
struct CutSuggestOptions: Equatable, Sendable {
  var model: String
  var promptVersion: String
  var productSpecVersion: String
  var stage1Window: Int
  var stage1Step: Int

  init(
    model: String = "claude-sonnet-5",
    promptVersion: String = "v2",
    productSpecVersion: String = ProductSpec.version,
    stage1Window: Int = 130,
    stage1Step: Int = 110
  ) {
    self.model = model
    self.promptVersion = promptVersion
    self.productSpecVersion = productSpecVersion
    self.stage1Window = stage1Window
    self.stage1Step = stage1Step
  }
}
