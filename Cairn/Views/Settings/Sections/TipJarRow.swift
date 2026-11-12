import CairnServices
import StoreKit
import SwiftUI

/// The tip jar, as one row on Settings › About and in the support pop-up: "Support Development" and
/// the three tips as price buttons, then a line saying what tips fund and that they unlock nothing (a thank-you instead once this device has tipped). Absent until the App Store has tips to offer (offline,
/// or before they're approved), so the card never shows an empty jar. The page around it loads
/// the tips (`TipJarStore.loadProducts`), since an absent row has nothing to run a task on.
struct TipJarRow: View {
  @State private var store = TipJarStore.shared
  @Environment(\.purchase) private var purchase
  @AppStorage(AppStorageKey.tipJarCount.rawValue) private var tipCount = 0
  @Environment(\.appTheme) private var theme

  var body: some View {
    Group {
      if store.loadState == .loaded {
        VStack(alignment: .leading, spacing: 8) {
          // The title beside the tips when they fit, over them (sharing the width) when not.
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
              title(onOneLine: true)
              Spacer(minLength: 4)
              tips(fillsWidth: false)
            }
            VStack(alignment: .leading, spacing: 8) {
              // On its own line the title may wrap: translations and large text can outgrow it.
              title(onOneLine: false)
              HStack(spacing: 8) { tips(fillsWidth: true) }
            }
          }
          if tipCount > 0 {
            Label(L10n.Settings.About.TipJar.thanks, systemImage: "heart.fill")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.pink)
          } else {
            Text(L10n.Settings.About.TipJar.footer)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .animation(.default, value: tipCount)
      }
    }
    .alert(
      L10n.Settings.About.TipJar.failed,
      isPresented: Binding(get: { store.purchaseError != nil }, set: { if !$0 { store.purchaseError = nil } })
    ) {
      Button(L10n.Localizable.Common.ok) {}
    } message: {
      Text(store.purchaseError ?? "")
    }
  }

  private func title(onOneLine: Bool) -> some View {
    Label {
      Text(L10n.Settings.About.TipJar.header)
    } icon: {
      Image(systemName: "cup.and.saucer.fill")
        .foregroundStyle(theme.accentColor)
    }
    .font(.subheadline.weight(.semibold))
    .lineLimit(onOneLine ? 1 : nil)
    .fixedSize(horizontal: onOneLine, vertical: true)
    .accessibilityAddTraits(.isHeader)
  }

  private func tips(fillsWidth: Bool) -> some View {
    ForEach(store.products) { product in
      TipButton(
        product: product,
        isPurchasing: store.purchasingID == product.id,
        fillsWidth: fillsWidth
      ) {
        Task { await store.buy(product, with: purchase) }
      }
      .disabled(store.purchasingID != nil)
    }
  }
}

/// One tip: its cup and its App Store price on a capsule in the theme's accent; its name and line
/// from App Store Connect go to VoiceOver.
private struct TipButton: View {
  @Environment(\.appTheme) private var theme
  let product: Product
  let isPurchasing: Bool
  let fillsWidth: Bool
  let buy: () -> Void

  private var tip: TipJarStore.Tip? { TipJarStore.Tip(rawValue: product.id) }

  var body: some View {
    Button(action: buy) {
      HStack(spacing: 4) {
        if isPurchasing {
          ProgressView()
            .controlSize(.mini)
            .tint(.white)
        } else {
          Image(systemName: tip?.systemImage ?? "cup.and.saucer.fill")
            .imageScale(.small)
        }
        Text(product.displayPrice)
          .monospacedDigit()
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: fillsWidth ? .infinity : nil)
      .background(theme.accentColor.gradient, in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
    .accessibilityHint(product.description)
  }
}
