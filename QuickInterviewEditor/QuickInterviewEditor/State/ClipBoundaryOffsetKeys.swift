import Sharing

/// Single source of truth for the default clip-boundary offsets, shared by the
/// `@Shared(.clipStartOffsetMs)` / `@Shared(.clipEndOffsetMs)` key defaults and the settings
/// model's own defaults.
let defaultClipStartOffsetMs = 0.0
let defaultClipEndOffsetMs = 0.0

extension SharedKey where Self == AppStorageKey<Double>.Default {
  static var clipStartOffsetMs: Self {
    Self[.appStorage("clipStartOffsetMs"), default: defaultClipStartOffsetMs]
  }
  static var clipEndOffsetMs: Self {
    Self[.appStorage("clipEndOffsetMs"), default: defaultClipEndOffsetMs]
  }
}
