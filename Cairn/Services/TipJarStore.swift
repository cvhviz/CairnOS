import CairnServices
import Foundation
import Observation
import OSLog
import StoreKit
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "TipJarStore")

/// The tip jar on Settings › About: three consumable in-app purchases that unlock nothing (App
/// Store Review Guideline 3.1.1 lets an app take tips for its developer this way). Loads the
/// tips, records a completed one for the thank-you line, and finishes every transaction,
/// including ones that complete later (Ask to Buy, an interrupted purchase), which
/// `Transaction.updates` can deliver at any time, so it starts listening at launch.
@Observable
@MainActor
final class TipJarStore {
  static let shared = TipJarStore()

  /// The tips by product ID, as set up in App Store Connect (and `Cairn.storekit` for local
  /// runs). Names and prices come from the App Store, localized for the buyer's storefront.
  enum Tip: String, CaseIterable {
    case small = "cvhvisuals.Cairn.tip.small"
    case medium = "cvhvisuals.Cairn.tip.medium"
    case large = "cvhvisuals.Cairn.tip.large"

    var systemImage: String {
      switch self {
      case .small: "cup.and.saucer.fill"
      case .medium: "mug.fill"
      case .large: "takeoutbag.and.cup.and.straw.fill"
      }
    }
  }

  enum LoadState {
    case loading
    case loaded
    /// No tips to offer: offline, or the App Store has none for this build yet.
    case unavailable
  }

  /// The tips the App Store returned, cheapest first.
  private(set) var products: [Product] = []
  private(set) var loadState = LoadState.loading
  /// The tip being bought, so its row can show progress and the others wait.
  private(set) var purchasingID: Product.ID?
  /// Why the last purchase failed, for an alert; cleared when the alert closes.
  var purchaseError: String?

  @ObservationIgnored private var updatesTask: Task<Void, Never>?

  private init() {}

  /// Finishes transactions that arrive outside a purchase (Ask to Buy approvals, purchases
  /// completed after the app quit). Once, at launch.
  func startObservingTransactions() {
    guard updatesTask == nil else { return }
    updatesTask = Task { [weak self] in
      for await result in StoreKit.Transaction.updates {
        await self?.complete(result)
      }
    }
  }

  /// Loads the tips once they're there to load; after a failure, again on the next call. A retry
  /// keeps the section hidden until it succeeds, rather than flashing a spinner.
  func loadProducts() async {
    guard products.isEmpty else { return }
    do {
      products = try await Product.products(for: Tip.allCases.map(\.rawValue)).sorted { $0.price < $1.price }
      loadState = products.isEmpty ? .unavailable : .loaded
    } catch {
      logger.error("Loading tips failed: \(error.localizedDescription, privacy: .public)")
      loadState = .unavailable
    }
  }

  /// Buys a tip through SwiftUI's `purchase` action, which presents the payment sheet over the
  /// right scene. Cancelling, or a purchase waiting for approval, ends quietly.
  func buy(_ product: Product, with purchase: PurchaseAction) async {
    guard purchasingID == nil else { return }
    purchasingID = product.id
    defer { purchasingID = nil }
    do {
      if case .success(let result) = try await purchase(product) {
        await complete(result)
      }
    } catch {
      logger.error("Tip purchase failed: \(error.localizedDescription, privacy: .public)")
      purchaseError = error.localizedDescription
    }
  }

  /// A tip grants nothing, so a verified one only counts toward the thank-you line. Every
  /// transaction is finished, or StoreKit would deliver it again on each launch.
  private func complete(_ result: VerificationResult<StoreKit.Transaction>) async {
    let transaction = result.unsafePayloadValue
    if case .verified = result, Tip(rawValue: transaction.productID) != nil {
      let key = AppStorageKey.tipJarCount.rawValue
      UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
    await transaction.finish()
  }
}
