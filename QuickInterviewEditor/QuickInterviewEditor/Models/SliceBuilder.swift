import Foundation

/// The one canonical way to turn a **sample range** into a `Slice`, shared by the
/// editor's fine-tune / new-slice-from-range path (`EditorModel.makeSlice`) and the
/// cut-suggestion accept path, so word membership (by midpoint), snippet, and warnings
/// are derived exactly one way. The accept path derives its range from a suggestion's
/// word IDs and calls this; a fine-tuned cut passes its dragged range. (The plain
/// Add-from-selection path builds inline from the live transcript selection instead —
/// it owns the user's exact selected words rather than re-deriving by midpoint.)
func buildSlice(id: UUID, name: String, range: Range<Int>, plan: EditPlan) -> Slice {
  let ids = wordIDs(overlapping: range, words: plan.words)
  return Slice(
    id: id,
    name: name,
    startSample: range.lowerBound,
    endSample: range.upperBound,
    wordIDs: ids,
    snippet: displaySliceSnippet(sliceSnippet(for: ids, words: plan.words)),
    warnings: sliceWarnings(
      startSample: range.lowerBound, endSample: range.upperBound,
      durationSamples: plan.source.durationSamples, silences: plan.silences))
}

/// Wraps a plain transcript snippet the way slice rows display it: curly-quoted and
/// middle-truncated. Shared so the editor and the accept path format identically.
func displaySliceSnippet(_ text: String) -> String {
  "“\(middleTruncatedSnippet(text, maxLength: 68))”"
}

/// Middle-truncate a transcript snippet to at most `maxLength` characters, always
/// keeping the first and last words and filling in as many middle words as fit —
/// e.g. "So a young … think is great" rather than "So a young Hayes Carl…". Short
/// snippets, and those with fewer than three words, pass through unchanged.
func middleTruncatedSnippet(_ text: String, maxLength: Int) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespaces)
  guard trimmed.count > maxLength else { return trimmed }
  let words = trimmed.split(separator: " ").map(String.init)
  guard words.count >= 3 else { return trimmed }

  func rendered(head: Int, tail: Int) -> String {
    words.prefix(head).joined(separator: " ") + " … "
      + words.suffix(tail).joined(separator: " ")
  }
  // Always show the first and last word, then greedily add words toward the
  // middle from alternating ends while they still fit the budget.
  var head = 1
  var tail = 1
  var growTail = true
  // If even the minimal first-word … last-word window overflows (e.g. a single
  // run-on word or a long URL), fall back to a hard character truncation so the
  // maxLength guarantee always holds.
  guard rendered(head: head, tail: tail).count <= maxLength else {
    return String(trimmed.prefix(max(0, maxLength - 1))) + "…"
  }
  while head + tail < words.count {
    let headFits = rendered(head: head + 1, tail: tail).count <= maxLength
    let tailFits = rendered(head: head, tail: tail + 1).count <= maxLength
    if !headFits, !tailFits { break }
    if growTail, tailFits {
      tail += 1
    } else if headFits {
      head += 1
    } else {
      tail += 1
    }
    growTail.toggle()
  }
  // If the head and tail met, nothing is actually elided — show the whole thing.
  return head + tail >= words.count ? trimmed : rendered(head: head, tail: tail)
}
