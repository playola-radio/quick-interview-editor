import Foundation

/// Builds the on-disk filename for an exported slice: `<source stem> - <name>.aiff`.
///
/// The slice name is **sanitized** (path separators / illegal chars stripped) so a
/// user-typed name can never escape the destination folder, and falls back to a
/// zero-padded `Slice NNN` when it sanitizes to nothing. Collisions — against files
/// already in the folder and against names assigned earlier in the same export — are
/// resolved with ` 2`, ` 3`, … suffixes, compared case-insensitively (the macOS
/// filesystem is case-insensitive by default). `taken` is updated with the chosen
/// name (lowercased) so a batch export never assigns the same name twice.
func exportFileName(
  sourceStem: String, sliceName: String, index: Int, taken: inout Set<String>
) -> String {
  // macOS caps a filename at 255 UTF-8 bytes. Both the stem and the slice name are
  // user-controlled, so clamp them (reserving room for " - ", ".aiff", and a " NN"
  // collision suffix) rather than letting `copyItem` throw a cryptic OS error.
  let reserved = " - ".utf8.count + ".aiff".utf8.count + 4  // " 999"
  let maxStemBytes = max(1, 255 - reserved - 8)  // leave ≥8 bytes for the name
  let stem = truncatedToUTF8Bytes(sanitizedStem(sourceStem), maxBytes: maxStemBytes)
  let nameBudget = max(1, 255 - stem.utf8.count - reserved)
  let name = truncatedToUTF8Bytes(
    sanitizedSliceName(sliceName, fallbackIndex: index), maxBytes: nameBudget)

  let base = "\(stem) - \(name)"
  var candidate = "\(base).aiff"
  var suffix = 2
  while taken.contains(candidate.lowercased()) {
    candidate = "\(base) \(suffix).aiff"
    suffix += 1
  }
  taken.insert(candidate.lowercased())
  return candidate
}

/// Trim `s` to at most `maxBytes` UTF-8 bytes, dropping whole characters so the
/// result stays valid (never splits a multi-byte scalar or grapheme).
private func truncatedToUTF8Bytes(_ text: String, maxBytes: Int) -> String {
  guard text.utf8.count > maxBytes else { return text }
  var result = text
  while result.utf8.count > maxBytes, !result.isEmpty { result.removeLast() }
  return result
}

private let illegalFilenameCharacters = CharacterSet(charactersIn: "/\\:\u{0}")

/// Sanitize a slice name into a safe path component. Illegal characters become `-`,
/// whitespace is collapsed, and leading dots are stripped (no dotfiles / `..`). An
/// empty result falls back to `Slice NNN`.
private func sanitizedSliceName(_ name: String, fallbackIndex: Int) -> String {
  var cleaned = name.components(separatedBy: illegalFilenameCharacters).joined(separator: "-")
  cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }.joined(separator: " ")
  while cleaned.hasPrefix(".") { cleaned.removeFirst() }
  cleaned = cleaned.trimmingCharacters(in: .whitespaces)
  guard !cleaned.isEmpty else { return "Slice \(String(format: "%03d", fallbackIndex))" }
  return cleaned
}

/// Sanitize the source stem the same way, so a pathological source name can't break
/// out either. Falls back to `Export` if it sanitizes to nothing.
private func sanitizedStem(_ stem: String) -> String {
  var cleaned = stem.components(separatedBy: illegalFilenameCharacters).joined(separator: "-")
  cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }.joined(separator: " ")
  while cleaned.hasPrefix(".") { cleaned.removeFirst() }
  cleaned = cleaned.trimmingCharacters(in: .whitespaces)
  return cleaned.isEmpty ? "Export" : cleaned
}
