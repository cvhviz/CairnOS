import SwiftUI

struct TracePathHopRow: View {
  let hop: PathHop
  let hopNumber: Int
  /// The last run timed out but was overheard getting past this hop.
  var isReached = false

  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        if let name = hop.resolvedName {
          Text(name)
          Text(hop.hashHex)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        } else {
          Text(hop.hashHex)
            .font(.body.monospaced())
        }
      }
      if isReached {
        Spacer(minLength: 8)
        Label(L10n.Contacts.Contacts.Trace.List.reached, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.Contacts.Contacts.Trace.List.hopLabel(hopNumber, hop.resolvedName ?? hop.hashHex))
    .accessibilityHint(L10n.Contacts.Contacts.Trace.List.hopHint)
  }
}
