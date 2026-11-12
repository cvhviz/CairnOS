import Foundation

/// Drives the Select Text sheet opened from the message actions sheet.
struct SelectTextContext: Identifiable {
  let id = UUID()
  let text: String
}

/// Drives the Forward picker opened from the message actions sheet. `text` is what lands in the
/// target's draft: the message named after who wrote it (`ForwardedDraft.attributed`).
struct ForwardContext: Identifiable {
  let id = UUID()
  let text: String
}
