// Cairn/Views/Chats/Components/PathHopRowView.swift
import CairnServices
import SwiftUI

/// Type of hop in the message path.
enum PathHopType {
  case sender
  case intermediate(Int)
  case receiver
}

/// Row displaying a single hop in the message path.
struct PathHopRowView: View {
  let hopType: PathHopType
  let nodeName: String
  let nodeID: String?
  let snr: Double?
  let matchKind: NodeNameMatchKind
  /// For an unknown hop, the node that shares its hash but wasn't taken for it, and why.
  let hint: String?
  /// Opens the stored contact the hop resolved to. Nil when the hop resolved to a
  /// discovered node or to nothing, which leaves the row non-interactive.
  let onOpenContact: (() -> Void)?

  init(
    hopType: PathHopType,
    nodeName: String,
    nodeID: String?,
    snr: Double?,
    matchKind: NodeNameMatchKind = .exact,
    hint: String? = nil,
    onOpenContact: (() -> Void)? = nil
  ) {
    self.hopType = hopType
    self.nodeName = nodeName
    self.nodeID = nodeID
    self.snr = snr
    self.matchKind = matchKind
    self.hint = hint
    self.onOpenContact = onOpenContact
  }

  var body: some View {
    if let onOpenContact {
      HStack(spacing: 8) {
        rowContent

        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.vertical, 1)
      .contentShape(.rect)
      .onTapGesture(perform: onOpenContact)
      // Not `.combine`: it would fold the possible-match button's action into the row's own.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(hopLabel): \(nodeName)")
      .accessibilityValue(accessibilityValueText)
      .accessibilityHint(openContactHint)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, onOpenContact)
    } else {
      rowContent
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hopLabel): \(nodeName)")
        .accessibilityValue(accessibilityValueText)
    }
  }

  private var rowContent: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          if let nodeID {
            Text(nodeID)
              .font(.body)
              .foregroundStyle(.secondary)
              .monospaced()
          }

          Text(nodeName)
            .font(.body)

          if matchKind == .fallback {
            FallbackMatchIndicatorView()
          }
        }

        Text(hopLabel)
          .font(.caption)
          .foregroundStyle(.secondary)

        if let hint {
          Label(hint, systemImage: "questionmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer()

      // Show signal info only on receiver (where we have SNR)
      if case .receiver = hopType, let snr {
        VStack(alignment: .trailing, spacing: 2) {
          Image(systemName: "cellularbars", variableValue: snrQuality.barLevel)
            .foregroundStyle(snrQuality.color)

          Text("SNR \(snr, format: .number.precision(.fractionLength(1))) dB")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var openContactHint: String {
    matchKind == .fallback
      ? L10n.Chats.Chats.Path.Hop.openPossibleContactHint
      : L10n.Chats.Chats.Path.Hop.openContactHint
  }

  private var hopLabel: String {
    switch hopType {
    case .sender:
      L10n.Chats.Chats.Path.Hop.sender
    case let .intermediate(index):
      L10n.Chats.Chats.Path.Hop.number(index)
    case .receiver:
      L10n.Chats.Chats.Path.Receiver.label
    }
  }

  private var accessibilityValueText: String {
    var values: [String] = []
    if case .receiver = hopType, let snr {
      let snrText = snr.formatted(.number.precision(.fractionLength(1)))
      values.append(L10n.Chats.Chats.Path.Hop.signalQuality(signalQualityText, snrText))
    }
    if let hint {
      values.append(hint)
    }
    if let nodeID {
      values.append(L10n.Chats.Chats.Path.Hop.nodeId(nodeID))
    }
    // A tappable row hides its children from VoiceOver, so the possible-match
    // indicator has to be spoken here.
    if onOpenContact != nil, matchKind == .fallback {
      values.append(L10n.Chats.Chats.Path.Hop.possibleMatch)
    }
    return values.joined(separator: ", ")
  }

  private var snrQuality: SNRQuality {
    SNRQuality(snr: snr)
  }

  private var signalQualityText: String {
    snrQuality.localizedLabel
  }
}

#Preview {
  List {
    PathHopRowView(hopType: .sender, nodeName: "AlphaNode", nodeID: "A3", snr: nil)
    PathHopRowView(hopType: .intermediate(1), nodeName: "RelayNode", nodeID: "7F", snr: nil)
    PathHopRowView(
      hopType: .intermediate(2),
      nodeName: "HilltopRepeater",
      nodeID: "C4",
      snr: nil,
      matchKind: .fallback,
      onOpenContact: {}
    )
    PathHopRowView(hopType: .receiver, nodeName: "MyDevice", nodeID: nil, snr: 6.2)
  }
}
