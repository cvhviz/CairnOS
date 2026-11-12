import Foundation
@testable import CairnServices
import MeshCore

/// Mock implementation of ChannelServiceProtocol for testing.
///
/// Configure the mock by setting the stub properties before calling methods.
/// Track method calls by examining the recorded invocations.
public actor MockChannelService: ChannelServiceProtocol {
  // MARK: - Stubs

  /// Result to return from syncChannels
  public var stubbedSyncChannelsResult: Result<ChannelSyncResult, Error> = .success(
    ChannelSyncResult(channelsSynced: 0, errors: [])
  )

  /// Result to return from retryFailedChannels
  public var stubbedRetryResult: Result<ChannelSyncResult, Error> = .success(
    ChannelSyncResult(channelsSynced: 0, errors: [])
  )

  /// Result to return from verifyChannels. Defaults to a change, so a caller that verifies
  /// still reads every slot unless a test opts in to a match.
  public var stubbedVerifyResult: Result<ChannelVerification, Error> = .success(.changed(reason: "mock default"))

  // MARK: - Recorded Invocations

  public struct SyncChannelsInvocation: Sendable, Equatable {
    public let radioID: UUID
    public let maxChannels: UInt8
    public let usePipelinedRead: Bool
  }

  public struct RetryInvocation: Sendable, Equatable {
    public let radioID: UUID
    public let indices: [UInt8]
  }

  public private(set) var syncChannelsInvocations: [SyncChannelsInvocation] = []
  public private(set) var retryInvocations: [RetryInvocation] = []
  public private(set) var verifyInvocations: [SyncChannelsInvocation] = []

  // MARK: - Initialization

  public init() {}

  // MARK: - Protocol Methods

  public func syncChannels(radioID: UUID, maxChannels: UInt8, usePipelinedRead: Bool) async throws -> ChannelSyncResult {
    syncChannelsInvocations.append(
      SyncChannelsInvocation(radioID: radioID, maxChannels: maxChannels, usePipelinedRead: usePipelinedRead)
    )
    switch stubbedSyncChannelsResult {
    case let .success(result):
      return result
    case let .failure(error):
      throw error
    }
  }

  public func retryFailedChannels(radioID: UUID, indices: [UInt8]) async throws -> ChannelSyncResult {
    retryInvocations.append(RetryInvocation(radioID: radioID, indices: indices))
    switch stubbedRetryResult {
    case let .success(result):
      return result
    case let .failure(error):
      throw error
    }
  }

  public func verifyChannels(radioID: UUID, maxChannels: UInt8) async throws -> ChannelVerification {
    verifyInvocations.append(
      SyncChannelsInvocation(radioID: radioID, maxChannels: maxChannels, usePipelinedRead: false)
    )
    return try stubbedVerifyResult.get()
  }

  func setStubbedVerifyResult(_ result: Result<ChannelVerification, Error>) {
    stubbedVerifyResult = result
  }

  // MARK: - Test Helpers

  /// Resets all recorded invocations
  public func reset() {
    syncChannelsInvocations = []
    retryInvocations = []
    verifyInvocations = []
  }
}
