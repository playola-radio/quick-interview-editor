import Observation

/// The window's autosave affordance: a binary "Saving…" / "Saved" that lets the user see
/// autosave-in-place happening so File ▸ Save (⌘S) reads as an optional checkpoint rather than a
/// required step. The document drives it from the two seams it owns — `registerChange` marks an
/// edit, the save pipeline reports completion — and a monotonic generation counter keeps it honest
/// under coalesced autosaves: an edit that lands mid-save advances the edit generation, so the
/// completing save (which captured the older generation) can never clear to "Saved" over it. The
/// states are app-level, not disk-level: "Saved" means no edit is known after the last completed
/// save cycle, not a durable-write guarantee (`ReferenceFileDocument` exposes no such callback).
@MainActor
@Observable
final class SaveStatus {
  private(set) var isSaving = false
  private var latestEditGeneration = 0
  private var latestSavedGeneration = 0

  var label: String { isSaving ? "Saving…" : "Saved" }

  func markEdited(generation: Int) {
    latestEditGeneration = generation
    isSaving = true
  }

  func markSaved(upToGeneration generation: Int) {
    latestSavedGeneration = max(latestSavedGeneration, generation)
    if latestSavedGeneration >= latestEditGeneration {
      isSaving = false
    }
  }
}
