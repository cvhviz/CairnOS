@testable import Cairn
@testable import CairnServices
import Testing

@Suite("RegionAddSubmission")
struct RegionAddSubmissionTests {
  /// Stands in for the radio's region list that the caller updates on add.
  private struct RegionList {
    var regions: [String] = []
    var isConnected = true

    /// Throws as `addKnownRegion` does when there is no radio to add it to.
    mutating func add(_ name: String) throws {
      guard isConnected else { throw ConnectionError.notConnected }
      if !regions.contains(name) { regions.append(name) }
    }
  }

  /// Runs one add the way the sheet does: submit, hand the name to the list, record the outcome
  /// through `RegionAddSubmission.Failure(_:)` as the sheet does.
  private static func add(
    _ name: String,
    using submission: inout RegionAddSubmission,
    to list: inout RegionList
  ) -> Bool {
    submission.name = name
    guard let submitted = submission.submit(existingRegions: list.regions) else { return false }
    do {
      try list.add(submitted)
    } catch {
      submission.markFailed(RegionAddSubmission.Failure(error))
      return false
    }
    submission.markAdded()
    return true
  }

  @Test
  func `adds two regions in a row from fresh sheets`() {
    var list = RegionList()

    for name in ["on", "gta"] {
      var submission = RegionAddSubmission()
      let added = Self.add(name, using: &submission, to: &list)
      #expect(added)
      #expect(submission.pendingName == nil)
      #expect(!submission.didFail)
    }

    #expect(list.regions == ["on", "gta"])
  }

  @Test
  func `adds a second region when the same submission is reused`() {
    var list = RegionList()
    var submission = RegionAddSubmission()

    let addedFirst = Self.add("on", using: &submission, to: &list)
    #expect(addedFirst)

    submission.name = "gta"
    #expect(submission.canSubmit(existingRegions: list.regions))
    let addedSecond = Self.add("gta", using: &submission, to: &list)
    #expect(addedSecond)

    #expect(list.regions == ["on", "gta"])
  }

  @Test
  func `trims the submitted name`() {
    var submission = RegionAddSubmission()
    submission.name = "  ottawa "
    let submitted = submission.submit(existingRegions: [])
    #expect(submitted == "ottawa")
    #expect(submission.pendingName == "ottawa")
  }

  @Test
  func `submits a hash-prefixed name without its hash`() {
    var submission = RegionAddSubmission()
    submission.name = "#socal"
    let submitted = submission.submit(existingRegions: [])
    #expect(submitted == "socal")
    #expect(submission.pendingName == "socal")
  }

  @Test(arguments: [
    ("", RegionNameValidator.ValidationError.empty),
    ("   ", .empty),
    ("#", .empty),
    ("my region", .invalidCharacters),
    ("$secret", .privateRegion),
    ("on", .duplicate),
    ("#on", .duplicate)
  ])
  func `rejects a name that cannot be added`(name: String, expected: RegionNameValidator.ValidationError) {
    var submission = RegionAddSubmission()
    submission.name = name

    #expect(submission.validationError(existingRegions: ["on"]) == expected)
    #expect(!submission.canSubmit(existingRegions: ["on"]))
    let submitted = submission.submit(existingRegions: ["on"])
    #expect(submitted == nil)
    #expect(submission.pendingName == nil)
  }

  @Test
  func `rejects a name over the firmware byte cap`() {
    var submission = RegionAddSubmission()
    submission.name = String(repeating: "a", count: ProtocolLimits.maxDefaultFloodScopeNameBytes + 1)

    #expect(
      submission.validationError(existingRegions: [])
        == .tooLong(maxBytes: ProtocolLimits.maxDefaultFloodScopeNameBytes)
    )
    let submitted = submission.submit(existingRegions: [])
    #expect(submitted == nil)
  }

  @Test
  func `a pending name is not reported as its own duplicate`() {
    var submission = RegionAddSubmission()
    submission.name = "on"
    _ = submission.submit(existingRegions: [])

    #expect(submission.validationError(existingRegions: ["on"]) == nil)
  }

  @Test
  func `cannot submit again while an add is pending`() {
    var submission = RegionAddSubmission()
    submission.name = "on"
    let first = submission.submit(existingRegions: [])
    #expect(first == "on")

    #expect(!submission.canSubmit(existingRegions: []))
    let second = submission.submit(existingRegions: [])
    #expect(second == nil)
    #expect(submission.pendingName == "on")
  }

  @Test
  func `markAdded ends the pending add`() {
    var submission = RegionAddSubmission()
    submission.name = "gta"
    _ = submission.submit(existingRegions: ["on"])
    #expect(submission.pendingName == "gta")

    submission.markAdded()
    #expect(submission.pendingName == nil)
    #expect(!submission.didFail)
  }

  @Test
  func `a dropped add is reported at once and can be retried`() {
    var list = RegionList(regions: ["on"], isConnected: false)
    var submission = RegionAddSubmission()

    let addedWhileDisconnected = Self.add("gta", using: &submission, to: &list)
    #expect(!addedWhileDisconnected)
    #expect(submission.failure == .notConnected)
    #expect(submission.didFail)
    #expect(submission.pendingName == nil)

    list.isConnected = true
    let addedOnRetry = Self.add("gta", using: &submission, to: &list)
    #expect(addedOnRetry)
    #expect(!submission.didFail)
    #expect(list.regions == ["on", "gta"])
  }

  @Test
  func `an add error maps to no radio or to a save that didn't happen`() {
    #expect(RegionAddSubmission.Failure(ConnectionError.notConnected) == .notConnected)
    #expect(RegionAddSubmission.Failure(PersistenceStoreError.deviceNotFound) == .notSaved)
    #expect(RegionAddSubmission.Failure(ConnectionError.deviceNotFound) == .notSaved)
  }

  @Test
  func `editing the name clears a reported failure`() {
    var submission = RegionAddSubmission()
    submission.name = "gta"
    _ = submission.submit(existingRegions: [])
    submission.markFailed(.notSaved)
    #expect(submission.failure == .notSaved)

    submission.name = "gta2"
    #expect(submission.failure == nil)
    #expect(!submission.didFail)
  }

  @Test
  func `markFailed without a pending add changes nothing`() {
    var submission = RegionAddSubmission()
    submission.name = "on"
    submission.markFailed(.notConnected)
    #expect(!submission.didFail)
  }
}
