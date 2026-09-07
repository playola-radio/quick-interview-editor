import Dependencies
import Foundation

actor SuggestionRecoveryStore {
  private let root: URL
  private let write: @Sendable (Data, URL) throws -> Void
  private let uuid: @Sendable () -> UUID
  private let files = FileManager.default
  private var claims: [UUID: UUID] = [:]

  init(
    root: URL,
    write: @escaping @Sendable (Data, URL) throws -> Void = {
      try $0.write(to: $1, options: .atomic)
    },
    uuid: @escaping @Sendable () -> UUID = {
      @Dependency(\.uuid) var uuid
      return uuid()
    }
  ) {
    self.root = root
    self.write = write
    self.uuid = uuid
  }

  func claimOwner(_ owner: SuggestionRecoveryOwner, instanceID: UUID) throws
    -> SuggestionRecoveryOwner
  {
    var claimed = owner
    if let previous = claims[owner.id], previous != instanceID {
      claimed.id = uuid()
      try duplicate(owner, newOwner: claimed)
    }
    claims[claimed.id] = instanceID
    return claimed
  }

  func releaseOwner(instanceID: UUID) {
    claims = claims.filter { $0.value != instanceID }
  }

  func prepare(_ owner: SuggestionRecoveryOwner, preparation: SuggestionRecoveryPreparation) throws
    -> URL
  {
    let owner = standardized(owner)
    var archive = SuggestionRecoveryArchive(
      manifest: .init(
        owner: owner, snapshot: preparation.snapshot,
        originalRequest: preparation.originalRequest, control: preparation.control), records: [:])
    _ = try archive.validatedCheckpoint()
    if let existing = try manifestIfPresent(owner.id) {
      try verify(existing, owner: owner, runID: existing.snapshot.runID)
      if existing.snapshot.runID == preparation.snapshot.runID {
        archive.manifest.retainedAppliedRunIDs = existing.retainedAppliedRunIDs
        guard existing == archive.manifest else {
          throw SuggestionRecoveryError.conflict("Preparation changed an existing run.")
        }
      } else {
        let predecessor = try collect(existing)
        guard preparation.lastAppliedRunID == existing.snapshot.runID,
          try predecessor.validatedCheckpoint().phase == .ready
        else {
          throw SuggestionRecoveryError.conflict(
            "Apply or discard the unfinished search before starting another.")
        }
        archive.manifest.retainedAppliedRunIDs =
          existing.retainedAppliedRunIDs + [existing.snapshot.runID]
        archive.retainedAppliedRuns = predecessor.retainedAppliedRuns + [predecessor.singleRun]
        try archive.validateRetainedRuns()
        try install(archive, owner: owner)
      }
    } else {
      try install(archive, owner: owner)
    }
    try index(owner)
    return runDirectory(owner.id, preparation.snapshot.runID)
  }

  func updateControl(
    _ owner: SuggestionRecoveryOwner, runID: UUID, control: SuggestionRecoveryControl,
    expectedRevision: Int
  ) throws {
    var manifest = try requireManifest(owner.id)
    try verify(manifest, owner: owner, runID: runID)
    guard manifest.control.revision == expectedRevision else {
      throw SuggestionRecoveryError.staleControl
    }
    let next = expectedRevision.addingReportingOverflow(1)
    guard !next.overflow else { throw SuggestionRecoveryError.revisionOverflow }
    manifest.control = control
    manifest.control.revision = next.partialValue
    try writeManifest(manifest)
  }

  func load(_ owner: SuggestionRecoveryOwner) throws -> SuggestionRunCheckpoint? {
    guard let manifest = try manifestIfPresent(owner.id) else { return nil }
    return try capture(owner, runID: manifest.snapshot.runID, minimumPythonRevision: nil).checkpoint
  }

  func capture(_ owner: SuggestionRecoveryOwner, runID: UUID, minimumPythonRevision: Int?) throws
    -> SuggestionRecoveryCapture
  {
    let manifest = try manifestForRun(owner.id, runID: runID)
    try verify(manifest, owner: owner, runID: runID)
    let archive = try collect(manifest)
    let checkpoint = try archive.validatedCheckpoint()
    guard checkpoint.pythonRevision >= (minimumPythonRevision ?? 0) else {
      throw SuggestionRecoveryError.invalid("Checkpoint is older than the reported event.")
    }
    return SuggestionRecoveryCapture(
      checkpoint: checkpoint, archive: try JSONEncoder().encode(archive),
      journalDirectory: runDirectory(owner.id, runID))
  }

  func restore(_ owner: SuggestionRecoveryOwner, archive data: Data) throws {
    var incoming = try SuggestionRecoveryArchive.decode(data)
    try verify(
      incoming.manifest, owner: owner, runID: incoming.manifest.snapshot.runID,
      requireOwnerID: false)
    incoming.manifest.owner = standardized(owner)
    for index in incoming.retainedAppliedRuns.indices {
      incoming.retainedAppliedRuns[index].manifest.owner = standardized(owner)
    }
    if let existing = try manifestIfPresent(owner.id) {
      try verify(existing, owner: owner, runID: existing.snapshot.runID)
      incoming = try mergeLineage(try collect(existing, requireReferencedRecords: false), incoming)
    }
    _ = try incoming.validatedCheckpoint()
    try incoming.validateRetainedRuns()
    try install(incoming, owner: standardized(owner))
    try index(standardized(owner))
  }

  func discard(_ owner: SuggestionRecoveryOwner, runID: UUID) throws {
    guard let current = try manifestIfPresent(owner.id) else { return }
    guard current.snapshot.runID == runID || current.retainedAppliedRunIDs.contains(runID) else {
      throw SuggestionRecoveryError.missingRun
    }
    try removeRuns([runID], from: current)
  }

  func duplicate(_ oldOwner: SuggestionRecoveryOwner, newOwner: SuggestionRecoveryOwner) throws {
    guard oldOwner.id != newOwner.id else {
      throw SuggestionRecoveryError.conflict("A copy requires a fresh owner.")
    }
    guard let manifest = try manifestIfPresent(oldOwner.id) else { return }
    let archive = try capture(oldOwner, runID: manifest.snapshot.runID, minimumPythonRevision: nil)
    try restore(newOwner, archive: archive.archive)
  }

  func confirmSaved(_ owner: SuggestionRecoveryOwner, runID: UUID) throws {
    guard let url = owner.documentURL,
      let data = try? Data(contentsOf: url.appending(component: "project.json")),
      let project = try? ProjectPackage.projectDecoder().decode(ProjectFile.self, from: data),
      project.content.suggestionRecoveryOwnerID == owner.id,
      project.content.lastAppliedSuggestionRunID == runID
    else { throw SuggestionRecoveryError.notSaved }
    guard let current = try manifestIfPresent(owner.id) else { return }
    let confirmed = try manifestForRun(owner.id, runID: runID)
    try removeRuns(Set(confirmed.retainedAppliedRunIDs + [runID]), from: current)
  }

  func recoverableOrphans(sourceFingerprint: String, transcriptHash: String) throws
    -> [SuggestionRecoveryOwner]
  {
    guard files.fileExists(atPath: root.path) else { return [] }
    return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .compactMap { url -> SuggestionRecoveryOwner? in
        guard let id = UUID(uuidString: url.lastPathComponent),
          let manifest = try manifestIfPresent(id),
          manifest.owner.sourceFingerprint == sourceFingerprint,
          manifest.owner.transcriptHash == transcriptHash,
          manifest.owner.documentURL.map({ !files.fileExists(atPath: $0.path) }) ?? true
        else { return nil }
        _ = try collect(manifest).validatedCheckpoint()
        return manifest.owner
      }.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  func resolveOwner(
    persistedID: UUID?, documentURL: URL?, sourceFingerprint: String, transcriptHash: String,
    archivedOwner: SuggestionRecoveryOwner? = nil, instanceID: UUID? = nil
  ) throws -> SuggestionRecoveryOwner? {
    let location = documentURL.map {
      URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: false)
    }
    let id: UUID
    if let persistedID {
      id = persistedID
    } else {
      guard let location, let indexed = try indexedOwner(location) else { return nil }
      id = indexed
    }
    guard let manifest = try manifestIfPresent(id) else {
      guard persistedID != nil else { return nil }
      let owner = try ownerWithoutManifest(
        id: id, location: location, sourceFingerprint: sourceFingerprint,
        transcriptHash: transcriptHash, archivedOwner: archivedOwner)
      return try instanceID.map { try claimOwner(owner, instanceID: $0) } ?? owner
    }
    var owner = manifest.owner
    let oldLocation = owner.documentURL.map {
      URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: false)
    }
    if oldLocation != location {
      if let oldLocation, location == nil || files.fileExists(atPath: oldLocation.path) {
        owner.id = uuid()
        owner.documentURL = location
        try duplicate(manifest.owner, newOwner: owner)
      } else {
        owner.documentURL = location
        var relocated = manifest
        relocated.owner = owner
        try writeManifest(relocated)
        try index(owner)
        if oldLocation != nil { try removeIndex(manifest.owner) }
      }
    }
    if let instanceID { owner = try claimOwner(owner, instanceID: instanceID) }
    guard owner.sourceFingerprint == sourceFingerprint, owner.transcriptHash == transcriptHash
    else {
      throw SuggestionRecoveryError.staleIdentity(owner: owner, runID: manifest.snapshot.runID)
    }
    return owner
  }

  private func ownerWithoutManifest(
    id: UUID, location: URL?, sourceFingerprint: String,
    transcriptHash: String, archivedOwner: SuggestionRecoveryOwner?
  ) throws -> SuggestionRecoveryOwner {
    var resolvedID = id
    if let archivedOwner {
      guard archivedOwner.id == id else {
        throw SuggestionRecoveryError.invalid("Archive owner differs from the document.")
      }
      if let oldURL = archivedOwner.documentURL?.standardizedFileURL,
        oldURL.path != location?.path, files.fileExists(atPath: oldURL.path)
      {
        resolvedID = uuid()
      }
    }
    return SuggestionRecoveryOwner(
      id: resolvedID, documentURL: location,
      sourceFingerprint: sourceFingerprint, transcriptHash: transcriptHash)
  }

  private func collect(
    _ manifest: SuggestionRecoveryManifest, requireReferencedRecords: Bool = true
  ) throws -> SuggestionRecoveryArchive {
    var archive = try collectRun(manifest, requireReferencedRecords: requireReferencedRecords)
    archive.retainedAppliedRuns = try manifest.retainedAppliedRunIDs.map { runID in
      try collectRun(
        manifestForRun(manifest.owner.id, runID: runID),
        requireReferencedRecords: requireReferencedRecords
      ).singleRun
    }
    if requireReferencedRecords { try archive.validateRetainedRuns() }
    return archive
  }

  private func collectRun(
    _ manifest: SuggestionRecoveryManifest, requireReferencedRecords: Bool = true
  )
    throws -> SuggestionRecoveryArchive
  {
    let directory = runDirectory(manifest.owner.id, manifest.snapshot.runID)
    let checkpoint = try optionalData(directory.appending(component: "checkpoint.json"))
    let identity = try optionalData(directory.appending(component: "identity.json"))
    let requestDirectory = directory.appending(component: "requests")
    var records = [String: Data]()
    if files.fileExists(atPath: requestDirectory.path) {
      for url in try files.contentsOfDirectory(
        at: requestDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])
      {
        if url.lastPathComponent.hasPrefix(".pending-") { continue }
        let data = try Data(contentsOf: url)
        let json = try RecoveryJSON.read(data)
        guard let key = json["key"]?.string, SuggestionRecoveryArchive.isDigest(key),
          url.lastPathComponent == SuggestionRecoveryArchive.recordFilename(key),
          records[key] == nil,
          try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else { throw SuggestionRecoveryError.invalid("Unexpected provider record path.") }
        records[key] = data
      }
    }
    let archive = SuggestionRecoveryArchive(
      manifest: manifest, identity: identity, checkpoint: checkpoint, records: records)
    if requireReferencedRecords { _ = try archive.validatedCheckpoint() }
    return archive
  }

  private func mergeLineage(_ local: SuggestionRecoveryArchive, _ saved: SuggestionRecoveryArchive)
    throws -> SuggestionRecoveryArchive
  {
    let localID = local.manifest.snapshot.runID
    let savedID = saved.manifest.snapshot.runID
    let currentID: UUID
    if localID == savedID || local.manifest.retainedAppliedRunIDs.contains(savedID) {
      currentID = localID
    } else if saved.manifest.retainedAppliedRunIDs.contains(localID) {
      currentID = savedID
    } else {
      throw SuggestionRecoveryError.conflict("Unrelated current searches share an owner.")
    }
    var runs = Dictionary(
      uniqueKeysWithValues: (local.retainedAppliedRuns + [local.singleRun]).map {
        ($0.manifest.snapshot.runID, $0.archive)
      })
    for incoming in saved.retainedAppliedRuns + [saved.singleRun] {
      let id = incoming.manifest.snapshot.runID
      if let previous = runs[id] {
        runs[id] = try merge(previous, incoming.archive)
      } else {
        runs[id] = incoming.archive
      }
    }
    guard var result = runs[currentID] else { throw SuggestionRecoveryError.missingRun }
    result.retainedAppliedRuns = try result.manifest.retainedAppliedRunIDs.enumerated().map {
      index, id in
      guard var retained = runs[id] else { throw SuggestionRecoveryError.missingRun }
      retained.manifest.retainedAppliedRunIDs = Array(
        result.manifest.retainedAppliedRunIDs.prefix(index))
      return retained.singleRun
    }
    return result
  }

  private func merge(_ local: SuggestionRecoveryArchive, _ saved: SuggestionRecoveryArchive) throws
    -> SuggestionRecoveryArchive
  {
    guard local.manifest.snapshot == saved.manifest.snapshot,
      try local.immutableRequest() == saved.immutableRequest()
    else {
      throw SuggestionRecoveryError.conflict("Immutable input changed.")
    }
    var merged = local
    merged.manifest.retainedAppliedRunIDs = try mergedLineage(
      local.manifest.retainedAppliedRunIDs, saved.manifest.retainedAppliedRunIDs)
    let left = local.manifest.control
    let right = saved.manifest.control
    if left.revision == right.revision, left != right {
      throw SuggestionRecoveryError.conflict("Equal control revisions differ.")
    }
    if right.revision > left.revision { merged.manifest.control = right }
    if let identity = local.identity, let other = saved.identity,
      try RecoveryJSON.read(identity) != RecoveryJSON.read(other)
    {
      throw SuggestionRecoveryError.conflict("Python identity changed.")
    }
    if merged.identity == nil { merged.identity = saved.identity }
    var recoverableLocal = local
    recoverableLocal.identity = recoverableLocal.identity ?? saved.identity
    let localCheckpoint = try recoverableLocal.validatedCheckpoint(requireReferencedRecords: false)
    let savedCheckpoint = try saved.validatedCheckpoint()
    if localCheckpoint.pythonRevision == savedCheckpoint.pythonRevision,
      let lhs = local.checkpoint, let rhs = saved.checkpoint,
      try RecoveryJSON.read(lhs) != RecoveryJSON.read(rhs)
    {
      throw SuggestionRecoveryError.conflict("Equal Python revisions differ.")
    }
    if savedCheckpoint.pythonRevision > localCheckpoint.pythonRevision {
      merged.checkpoint = saved.checkpoint
    }
    merged.records = try mergeRecords(local: local.records, saved: saved.records)
    return merged
  }

  private func mergedLineage(_ local: [UUID], _ saved: [UUID]) throws -> [UUID] {
    let localSet = Set(local)
    let savedSet = Set(saved)
    if local.filter(savedSet.contains) == saved { return local }
    if saved.filter(localSet.contains) == local { return saved }
    throw SuggestionRecoveryError.conflict("Applied search histories differ.")
  }

  private func mergeRecords(local: [String: Data], saved: [String: Data]) throws -> [String: Data] {
    var merged = local
    for (key, bytes) in saved {
      guard let previous = merged[key] else {
        merged[key] = bytes
        continue
      }
      let lhs = try RecoveryJSON.read(previous)
      let rhs = try RecoveryJSON.read(bytes)
      if lhs["status"] == .string("completed") {
        if rhs["status"] == .string("completed"), lhs != rhs {
          throw SuggestionRecoveryError.conflict("Completed provider response differs.")
        }
      } else if rhs["status"] == .string("completed") {
        merged[key] = bytes
      }
    }
    return merged
  }

  private func install(_ archive: SuggestionRecoveryArchive, owner: SuggestionRecoveryOwner) throws
  {
    let destination = ownerDirectory(owner.id)
    let isNew = !files.fileExists(atPath: destination.path)
    let target = isNew ? root.appending(component: ".pending-\(uuid().uuidString)") : destination
    try files.createDirectory(at: target, withIntermediateDirectories: true)
    do {
      for retained in archive.retainedAppliedRuns { try installRun(retained, in: target) }
      try installRun(archive.singleRun, in: target)
      try write(
        JSONEncoder().encode(archive.manifest), target.appending(component: "manifest.json"))
      if isNew { try files.moveItem(at: target, to: destination) }
    } catch {
      if isNew { try? files.removeItem(at: target) }
      throw error
    }
  }

  private func installRun(_ archive: SuggestionRecoveryRunArchive, in ownerDirectory: URL) throws {
    let run = ownerDirectory.appending(component: archive.manifest.snapshot.runID.uuidString)
    let requests = run.appending(component: "requests")
    try files.createDirectory(at: requests, withIntermediateDirectories: true)
    if let identity = archive.identity {
      try write(identity, run.appending(component: "identity.json"))
    }
    for (key, record) in archive.records {
      try write(
        record, requests.appending(component: SuggestionRecoveryArchive.recordFilename(key)))
    }
    if let checkpoint = archive.checkpoint {
      try write(checkpoint, run.appending(component: "checkpoint.json"))
    }
    let manifests = ownerDirectory.appending(component: "manifests")
    try files.createDirectory(at: manifests, withIntermediateDirectories: true)
    try write(
      JSONEncoder().encode(archive.manifest),
      manifests.appending(component: archive.manifest.snapshot.runID.uuidString + ".json"))
  }

  private func removeRuns(_ removed: Set<UUID>, from current: SuggestionRecoveryManifest) throws {
    let remaining = (current.retainedAppliedRunIDs + [current.snapshot.runID]).filter {
      !removed.contains($0)
    }
    guard let nextID = remaining.last else {
      try files.removeItem(at: ownerDirectory(current.owner.id))
      try removeIndex(current.owner)
      return
    }
    var next: SuggestionRecoveryManifest?
    for (index, id) in remaining.enumerated() {
      var manifest = try manifestForRun(current.owner.id, runID: id)
      manifest.retainedAppliedRunIDs = Array(remaining.prefix(index))
      try writeRunManifest(manifest)
      if id == nextID { next = manifest }
    }
    guard let next else { throw SuggestionRecoveryError.missingRun }
    try writeManifest(next)
    for id in removed {
      let run = runDirectory(current.owner.id, id)
      if files.fileExists(atPath: run.path) { try files.removeItem(at: run) }
      let manifest = runManifestURL(current.owner.id, runID: id)
      if files.fileExists(atPath: manifest.path) { try files.removeItem(at: manifest) }
    }
  }

  private func standardized(_ owner: SuggestionRecoveryOwner) -> SuggestionRecoveryOwner {
    var owner = owner
    owner.documentURL = owner.documentURL.map {
      URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: false)
    }
    return owner
  }

  private func verify(
    _ manifest: SuggestionRecoveryManifest, owner: SuggestionRecoveryOwner, runID: UUID,
    requireOwnerID: Bool = true
  ) throws {
    guard !requireOwnerID || manifest.owner.id == owner.id, manifest.snapshot.runID == runID else {
      throw SuggestionRecoveryError.missingRun
    }
    guard manifest.owner.sourceFingerprint == owner.sourceFingerprint,
      manifest.owner.transcriptHash == owner.transcriptHash
    else {
      var staleOwner = owner
      staleOwner.sourceFingerprint = manifest.owner.sourceFingerprint
      staleOwner.transcriptHash = manifest.owner.transcriptHash
      throw SuggestionRecoveryError.staleIdentity(owner: staleOwner, runID: manifest.snapshot.runID)
    }
  }

  private func ownerDirectory(_ id: UUID) -> URL { root.appending(component: id.uuidString) }
  private func runDirectory(_ ownerID: UUID, _ runID: UUID) -> URL {
    ownerDirectory(ownerID).appending(component: runID.uuidString)
  }
  private func runManifestURL(_ id: UUID, runID: UUID) -> URL {
    ownerDirectory(id).appending(component: "manifests").appending(
      component: runID.uuidString + ".json")
  }
  private func manifestForRun(_ id: UUID, runID: UUID) throws -> SuggestionRecoveryManifest {
    let current = try requireManifest(id)
    if current.snapshot.runID == runID { return current }
    guard current.retainedAppliedRunIDs.contains(runID),
      let data = try optionalData(runManifestURL(id, runID: runID))
    else {
      throw SuggestionRecoveryError.missingRun
    }
    try SuggestionRecoveryArchive.validateManifestShape(RecoveryJSON.read(data))
    var manifest = try JSONDecoder().decode(SuggestionRecoveryManifest.self, from: data)
    guard manifest.owner.id == id, manifest.snapshot.runID == runID else {
      throw SuggestionRecoveryError.missingRun
    }
    manifest.owner = current.owner
    return manifest
  }
  private func writeRunManifest(_ manifest: SuggestionRecoveryManifest) throws {
    let url = runManifestURL(manifest.owner.id, runID: manifest.snapshot.runID)
    try files.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try write(JSONEncoder().encode(manifest), url)
  }
  private func requireManifest(_ id: UUID) throws -> SuggestionRecoveryManifest {
    guard let manifest = try manifestIfPresent(id) else { throw SuggestionRecoveryError.missingRun }
    return manifest
  }
  private func manifestIfPresent(_ id: UUID) throws -> SuggestionRecoveryManifest? {
    guard let data = try optionalData(ownerDirectory(id).appending(component: "manifest.json"))
    else { return nil }
    try SuggestionRecoveryArchive.validateManifestShape(RecoveryJSON.read(data))
    let manifest = try JSONDecoder().decode(SuggestionRecoveryManifest.self, from: data)
    guard manifest.owner.id == id else {
      throw SuggestionRecoveryError.invalid("Owner identity changed.")
    }
    try SuggestionRecoveryArchive(manifest: manifest, records: [:]).validateManifest()
    return manifest
  }
  private func writeManifest(_ manifest: SuggestionRecoveryManifest) throws {
    try writeRunManifest(manifest)
    try write(
      JSONEncoder().encode(manifest),
      ownerDirectory(manifest.owner.id).appending(component: "manifest.json"))
  }
  private func optionalData(_ url: URL) throws -> Data? {
    guard files.fileExists(atPath: url.path) else { return nil }
    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw SuggestionRecoveryError.invalid("Symbolic link in recovery files.")
    }
    return try Data(contentsOf: url)
  }
  private func indexURL(_ url: URL) -> URL {
    root.appending(component: "locations").appending(
      component: SuggestionRecoveryArchive.sha256(Data(url.standardizedFileURL.path.utf8)) + ".json"
    )
  }
  private func index(_ owner: SuggestionRecoveryOwner) throws {
    guard let location = owner.documentURL else { return }
    let url = indexURL(location)
    try files.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try write(JSONEncoder().encode(owner.id), url)
  }
  private func indexedOwner(_ url: URL) throws -> UUID? {
    guard let data = try optionalData(indexURL(url)) else { return nil }
    let id = try JSONDecoder().decode(UUID.self, from: data)
    guard let manifest = try manifestIfPresent(id),
      manifest.owner.documentURL?.standardizedFileURL.path == url.standardizedFileURL.path
    else { return nil }
    return id
  }
  private func removeIndex(_ owner: SuggestionRecoveryOwner) throws {
    guard let location = owner.documentURL, let data = try optionalData(indexURL(location)),
      try JSONDecoder().decode(UUID.self, from: data) == owner.id
    else { return }
    try files.removeItem(at: indexURL(location))
  }
}
