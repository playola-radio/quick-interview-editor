import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class ExportReviewModel: ViewModel, Identifiable {
  // MARK: - Dependencies
  @ObservationIgnored @Dependency(\.exportCopy) var copyClient

  // MARK: - Shared State

  // MARK: - Initialization
  init(request: ExportCopyRequest, scratchDirectory: URL?) {
    self.request = request
    self.scratchDirectory = scratchDirectory
    super.init()
  }

  deinit {
    if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
  }

  // MARK: - Properties
  private var request: ExportCopyRequest
  let scratchDirectory: URL?
  private(set) var mappings: [ExportNameMapping] = []
  private(set) var isCopying = false
  @ObservationIgnored var onExport: ([ExportNameMapping]) -> Void = { _ in }
  @ObservationIgnored var onReviewNames: () -> Void = {}

  // MARK: - View Helpers
  var title: String {
    request.kind == .masteredM4A ? "Review Mastered Filenames" : "Review Export Filenames"
  }
  var warning: String {
    request.kind == .masteredM4A
      ? "A file with this name already exists or is included twice. Review the suffixes before saving."
      : "A file with this name already exists or is included twice. Check your clip names or starting numbers."
  }
  let conflictingNamesLabel = "Duplicate filenames:"
  var conflictingNames: [String] {
    var seen: Set<String> = []
    return mappings.compactMap { mapping in
      guard mapping.requestedName != mapping.proposedName,
        seen.insert(mapping.requestedName).inserted
      else { return nil }
      return mapping.requestedName
    }
  }
  var showsConflictingNames: Bool { !conflictingNames.isEmpty }
  var requestedLabel: String {
    request.kind == .masteredM4A ? "Requested filename" : "Clip filename"
  }
  var proposedLabel: String {
    request.kind == .masteredM4A ? "Saved filename" : "Export filename"
  }
  var reviewNamesLabel: String {
    request.kind == .masteredM4A ? "Cancel" : "Review Names"
  }
  var exportWithSuffixesLabel: String {
    request.kind == .masteredM4A ? "Save with Suffixes" : "Export with Suffixes"
  }
  var copiedTitle: String {
    request.kind == .masteredM4A ? "Already Saved" : "Already Exported"
  }
  var helpText: String {
    request.kind == .masteredM4A
      ? "Only the saved filenames change. Embedded titles stay the same."
      : "Only these filenames will change. Your clip names and starting numbers stay the same."
  }
  var copied: [ExportCopiedFile] { request.copied }
  var copiedRows: [ExportCopiedRow] {
    copied.map { .init(id: $0.id, title: $0.url.lastPathComponent) }
  }
  var showsCopied: Bool { !copied.isEmpty }
  var total: Int { request.targets.count }
  var progressLabel: String {
    "\(copied.count) of \(total) \(request.kind == .masteredM4A ? "saved" : "exported")"
  }
  var canApprove: Bool { !isCopying && !mappings.isEmpty }

  // MARK: - User Actions
  func reviewNamesTapped() {
    onReviewNames()
  }

  func exportWithSuffixesTapped() {
    guard canApprove else { return }
    onExport(mappings)
  }

  func copy(approved: [ExportNameMapping]?) async -> ExportCopyOutcome {
    isCopying = true
    defer { isCopying = false }
    request.approvedMappings = approved
    let outcome = await copyRenderedExports(request, client: copyClient)
    request.copied = outcome.copied
    mappings = outcome.reviewMappings ?? []
    return outcome
  }

  func cleanup() async {
    await Self.removeScratch(scratchDirectory)
  }

  // MARK: - Private Helpers
  private nonisolated static func removeScratch(_ directory: URL?) async {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }
}

struct ExportCopiedRow: Identifiable {
  var id: UUID
  var title: String
}
