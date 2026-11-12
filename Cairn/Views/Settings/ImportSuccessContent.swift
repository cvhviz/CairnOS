import CairnServices
import SwiftUI

/// Success and null-outcome content for the backup import sheet. Extracted
/// from `ImportPreviewSheet` so the success rendering can stay under the
/// project's ~300-line-per-file guideline and keep its own disclosure state.
struct ImportSuccessContent: View {
  @Bindable var viewModel: AppBackupViewModel
  let result: ImportResult
  @State private var isAlreadyHereExpanded = false
  @State private var isDroppedExpanded = false

  private var didAdd: Bool {
    result.totalInserted > 0
  }

  private var didMerge: Bool {
    result.totalMerged > 0
  }

  private var hasSkipped: Bool {
    result.totalSkipped > 0
  }

  private var hasDropped: Bool {
    result.totalDropped > 0
  }

  private var heroTitle: String {
    result.hasRestoredChanges
      ? L10n.Settings.Settings.Backup.Import.Success.title
      : L10n.Settings.Settings.Backup.Import.NothingToImport.title
  }

  private var heroSubtitle: String {
    if didAdd {
      return L10n.Settings.Settings.Backup.Import.Success.subtitleAdded(result.totalInserted)
    }
    if didMerge {
      return L10n.Settings.Settings.Backup.Import.Success.subtitleRefreshed(result.totalMerged)
    }
    return L10n.Settings.Settings.Backup.Import.NothingToImport.subtitle
  }

  private var heroIconName: String {
    result.hasRestoredChanges ? "checkmark.circle.fill" : "info.circle.fill"
  }

  private var heroIconColor: Color {
    result.hasRestoredChanges ? .green : .secondary
  }

  var body: some View {
    CardForm {
      BackupResultHero(systemImage: heroIconName, tint: heroIconColor, title: heroTitle, lines: [heroSubtitle])
      if didAdd {
        CardFormSection(L10n.Settings.Settings.Backup.Import.Success.addedSection) {
          BackupCountGrid { result.counts[$0]?.inserted ?? 0 }
        }
      }
      if hasSkipped {
        CardFormSection(
          L10n.Settings.Settings.Backup.Import.Success.alreadyHereSection,
          info: L10n.Settings.Settings.Backup.Import.Success.alreadyHereFooter,
          footer: refreshedFooter
        ) {
          countDisclosure(
            isExpanded: $isAlreadyHereExpanded,
            summary: L10n.Settings.Settings.Backup.Import.Success.alreadyHereSummary(result.totalSkipped)
          ) { result.counts[$0]?.skipped ?? 0 }
        }
      }
      if hasDropped {
        CardFormSection(
          L10n.Settings.Settings.Backup.Import.Success.droppedSection,
          info: Self.droppedFooterText(for: result)
        ) {
          countDisclosure(
            isExpanded: $isDroppedExpanded,
            summary: L10n.Settings.Settings.Backup.Import.Success.droppedSummary(result.totalDropped)
          ) { result.counts[$0]?.dropped ?? 0 }
        }
      }
      BackupSheetButton(
        title: L10n.Settings.Settings.Backup.Import.Success.done,
        isProminent: result.hasRestoredChanges
      ) {
        viewModel.dismissImportSheet()
      }
    }
    .onAppear {
      AccessibilityNotification.Announcement("\(heroTitle). \(heroSubtitle)").post()
    }
  }

  /// How many of the skipped items were refreshed: a result, so it stays visible under the card
  /// while the explanation of "already here" sits behind the section's "i".
  private var refreshedFooter: String? {
    guard didMerge else { return nil }
    return L10n.Settings.Settings.Backup.Import.Success.alreadyHereRefreshed(result.totalMerged)
  }

  /// Counts that didn't change anything (already here, or over a cap) stay folded on one card:
  /// a summary line, with the per-kind figures underneath when opened.
  private func countDisclosure(
    isExpanded: Binding<Bool>,
    summary: String,
    count: @escaping (BackupModelKind) -> Int
  ) -> some View {
    DisclosureGroup(isExpanded: isExpanded) {
      VStack(spacing: 8) {
        ForEach(BackupModelKind.allCases.filter { count($0) > 0 }, id: \.self) { kind in
          Divider()
          LabeledContent(kind.label, value: count(kind).formatted())
        }
      }
      .padding(.top, 8)
    } label: {
      Text(summary)
        .foregroundStyle(Color.primary)
    }
    .cardSurface(padding: 12)
  }

  /// Explanation for the dropped-items section ("i") based on which kinds were dropped.
  static func droppedFooterText(for result: ImportResult) -> String {
    let channelDropped = (result.counts[.channels]?.dropped ?? 0) > 0
    let discoverDropped = (result.counts[.discoveredNodes]?.dropped ?? 0) > 0
    let cap = PersistenceStore.maxDiscoveredNodes
    if channelDropped, discoverDropped {
      return L10n.Settings.Settings.Backup.Import.Success.droppedFooterMixed(cap)
    }
    if discoverDropped {
      return L10n.Settings.Settings.Backup.Import.Success.droppedFooterDiscoveredNodes(cap)
    }
    return L10n.Settings.Settings.Backup.Import.Success.droppedFooter
  }
}
