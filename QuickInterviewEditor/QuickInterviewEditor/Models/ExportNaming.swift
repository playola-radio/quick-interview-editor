import Foundation

enum ExportNamePolicy: Equatable, Sendable {
  case sourcePrefixed, exactClipName
}

struct ExportNameMapping: Equatable, Identifiable, Sendable {
  var id: UUID
  var requestedName: String
  var proposedName: String
  var requiresConfirmation: Bool
}

func exportFileName(
  sourceStem: String, sliceName: String, index: Int, taken: inout Set<String>,
  policy: ExportNamePolicy = .sourcePrefixed
) -> String {
  let normalizedTaken = Set(taken.map(normalizedExportName))
  var candidate = requestedExportName(
    sourceStem: sourceStem, sliceName: sliceName, index: index, policy: policy)
  var suffix = "2"
  while normalizedTaken.contains(normalizedExportName(candidate)) {
    candidate = requestedExportName(
      sourceStem: sourceStem, sliceName: sliceName, index: index, policy: policy,
      suffix: " " + suffix)
    suffix = nextExportCollisionSuffix(suffix)
  }
  taken.insert(normalizedExportName(candidate))
  return candidate
}

func normalizedExportName(_ name: String) -> String {
  name.precomposedStringWithCanonicalMapping.lowercased()
}

func preflightExportNames(
  slices: [Slice], sourceStem: String, existing: Set<String>, originalIndexes: [UUID: Int] = [:]
) -> [ExportNameMapping] {
  var taken = existing
  var mappings = slices.enumerated().map { offset, slice in
    let index = originalIndexes[slice.id] ?? offset + 1
    let policy: ExportNamePolicy = slice.suggestionNaming == nil ? .sourcePrefixed : .exactClipName
    let requested = requestedExportName(
      sourceStem: sourceStem, sliceName: slice.name, index: index, policy: policy)
    let proposed = exportFileName(
      sourceStem: sourceStem, sliceName: slice.name, index: index, taken: &taken, policy: policy)
    return ExportNameMapping(
      id: slice.id, requestedName: requested, proposedName: proposed,
      requiresConfirmation: slice.suggestionNaming != nil && requested != proposed)
  }
  let generated = Set(slices.filter { $0.suggestionNaming != nil }.map(\.id))
  let generatedNames = Set(
    mappings.filter { generated.contains($0.id) }.flatMap {
      [normalizedExportName($0.requestedName), normalizedExportName($0.proposedName)]
    })
  let counts = Dictionary(
    mappings.map { (normalizedExportName($0.requestedName), 1) }, uniquingKeysWith: +)
  for index in mappings.indices {
    let key = normalizedExportName(mappings[index].requestedName)
    if generatedNames.contains(key),
      counts[key, default: 0] > 1 || mappings[index].requestedName != mappings[index].proposedName
    {
      mappings[index].requiresConfirmation = true
    }
  }
  return mappings
}

func nextExportCollisionSuffix(_ suffix: String) -> String {
  var digits = Array(suffix.utf8)
  for index in digits.indices.reversed() {
    if digits[index] < 57 {
      digits[index] += 1
      return String(bytes: digits, encoding: .utf8)!
    }
    digits[index] = 48
  }
  return "1" + String(bytes: digits, encoding: .utf8)!
}

private func requestedExportName(
  sourceStem: String, sliceName: String, index: Int, policy: ExportNamePolicy, suffix: String = ""
) -> String {
  let budget = 255 - ".aiff".utf8.count - suffix.utf8.count
  let name = sanitizedSliceName(sliceName, fallbackIndex: index)
  let fallback = sanitizedSliceName("", fallbackIndex: index)
  let base: String
  switch policy {
  case .exactClipName:
    base = nonemptyExportComponent(name, maxBytes: budget, fallback: fallback)
  case .sourcePrefixed:
    let stem = nonemptyExportComponent(
      sanitizedStem(sourceStem), maxBytes: max(1, budget - 3 - 8), fallback: "Export")
    base =
      stem + " - "
      + nonemptyExportComponent(
        name, maxBytes: max(1, budget - stem.utf8.count - 3), fallback: fallback)
  }
  return base + suffix + ".aiff"
}

private func nonemptyExportComponent(_ text: String, maxBytes: Int, fallback: String) -> String {
  let truncated = truncatedToUTF8Bytes(text, maxBytes: maxBytes)
  return truncated.isEmpty ? truncatedToUTF8Bytes(fallback, maxBytes: maxBytes) : truncated
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
