import Dependencies
import Foundation

struct ExportCopyClient: Sendable {
  var listNames: @Sendable (URL) async throws -> Set<String>
  var copy: @Sendable (URL, URL) async throws -> Void
}

extension ExportCopyClient: DependencyKey {
  static var liveValue: Self {
    .init(
      listNames: { directory in
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
      },
      copy: { source, destination in
        try FileManager.default.copyItem(at: source, to: destination)
      })
  }
  static var testValue: Self { liveValue }
}

extension DependencyValues {
  var exportCopy: ExportCopyClient {
    get { self[ExportCopyClient.self] }
    set { self[ExportCopyClient.self] = newValue }
  }
}

struct ExportCopiedFile: Equatable, Identifiable, Sendable {
  var id: UUID
  var url: URL
}

struct ExportCopyRequest: Sendable {
  var targets: [Slice]
  var sourceStem: String
  var renderedByID: [UUID: URL]
  var destination: URL
  var approvedMappings: [ExportNameMapping]?
  var copied: [ExportCopiedFile] = []
}

struct ExportCopyOutcome: Sendable {
  var copied: [ExportCopiedFile]
  var cancelled = false
  var errorMessage: String?
  var reviewMappings: [ExportNameMapping]?
}

func copyRenderedExports(_ request: ExportCopyRequest, client: ExportCopyClient) async
  -> ExportCopyOutcome
{
  var state = ExportCopyState(request: request)
  do {
    try Task.checkCancellation()
    let initial = try await state.preflight(client: client)
    if request.approvedMappings == nil, initial.contains(where: \.requiresConfirmation) {
      return .init(copied: state.copied, reviewMappings: initial)
    }
    state.authorized = request.approvedMappings ?? initial
    while !state.remaining.isEmpty {
      try Task.checkCancellation()
      let mappings = try await state.preflight(client: client)
      if state.requiresNewApproval(mappings) {
        return .init(copied: state.copied, reviewMappings: mappings)
      }
      guard let mapping = mappings.first, let source = request.renderedByID[mapping.id] else {
        return .init(
          copied: state.copied, errorMessage: "A rendered clip is missing. Export again.")
      }
      try Task.checkCancellation()
      let destination = request.destination.appendingPathComponent(mapping.proposedName)
      do {
        try await client.copy(source, destination)
        state.copied.append(.init(id: mapping.id, url: destination))
      } catch {
        guard (error as NSError).domain == NSCocoaErrorDomain,
          (error as NSError).code == CocoaError.fileWriteFileExists.rawValue
        else { throw error }
        state.collidedNames.insert(mapping.proposedName)
      }
    }
    return .init(copied: state.copied, cancelled: Task.isCancelled)
  } catch is CancellationError {
    return .init(copied: state.copied, cancelled: true)
  } catch {
    return .init(
      copied: state.copied, cancelled: Task.isCancelled, errorMessage: error.localizedDescription)
  }
}

private struct ExportCopyState {
  var request: ExportCopyRequest
  var copied: [ExportCopiedFile]
  var authorized: [ExportNameMapping] = []
  var collidedNames: Set<String> = []

  init(request: ExportCopyRequest) {
    self.request = request
    copied = request.copied
  }

  var remaining: [Slice] {
    let copiedIDs = Set(copied.map(\.id))
    return request.targets.filter { !copiedIDs.contains($0.id) }
  }

  func preflight(client: ExportCopyClient) async throws -> [ExportNameMapping] {
    let existing = try await client.listNames(request.destination)
      .union(collidedNames).union(copied.map { $0.url.lastPathComponent })
    let indexes = Dictionary(
      uniqueKeysWithValues: request.targets.enumerated().map { ($0.element.id, $0.offset + 1) })
    return preflightExportNames(
      slices: remaining, sourceStem: request.sourceStem, existing: existing,
      originalIndexes: indexes)
  }

  func requiresNewApproval(_ mappings: [ExportNameMapping]) -> Bool {
    let generated = Set(remaining.filter { $0.suggestionNaming != nil }.map(\.id))
    return mappings.contains { mapping in
      guard let approved = authorized.first(where: { $0.id == mapping.id }) else { return true }
      return mapping.proposedName != approved.proposedName
        && (generated.contains(mapping.id) || mapping.requiresConfirmation
          || approved.requiresConfirmation)
    }
  }
}
