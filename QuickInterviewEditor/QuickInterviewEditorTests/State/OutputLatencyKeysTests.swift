import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
// `FileStorage.inMemory(fileSystem:)` is `@_spi(Internals)`; isolate this test's fileStorage
// key from the shared default in-memory filesystem the same way `ProjectStorePersistenceTests`
// does, so nothing bleeds across tests.
@_spi(Internals) import Sharing
import Testing

@testable import PlayolaInterviewEditor

struct OutputLatencyKeysTests {

  @Test func offsetLookupReturnsZeroForMissingOrNilDevice() {
    let map = ["uid-a": 0.12]
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: nil, in: map), 0.0)
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-b", in: map), 0.0)
  }

  @Test func offsetLookupReturnsStoredValue() {
    let map = ["uid-a": 0.12, "uid-b": -0.03]
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-a", in: map), 0.12)
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-b", in: map), -0.03)
  }

  @Test func offsetLookupTreatsNonFiniteStoredValueAsZero() {
    let map = ["uid-a": Double.nan]
    expectNoDifference(OutputLatencyOffsets.offsetSeconds(for: "uid-a", in: map), 0.0)
  }

  @Test func offsetsKeyRoundTripsPerDevice() {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    withDependencies {
      $0.defaultFileStorage = FileStorage.inMemory(fileSystem: fileSystem)
    } operation: {
      @Shared(.outputLatencyOffsets) var offsets = [:]
      $offsets.withLock { $0["uid-a"] = 0.2 }
      expectNoDifference(offsets["uid-a"], 0.2)
    }
  }

  @Test func estimatesKeyDefaultsToEmpty() {
    @Shared(.outputLatencyEstimates) var estimates = [:]
    expectNoDifference(estimates, [String: Double]())
  }
}
