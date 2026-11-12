import CarPlay
import Foundation
@testable import Cairn
import Testing

@Suite("CarPlayTemplates")
@MainActor
struct CarPlayTemplateBuilderTests {
  private func chatRow(_ name: String, unread: Bool = false, muted: Bool = false) -> CarPlaySnapshot.ChatRow {
    CarPlaySnapshot.ChatRow(
      id: UUID(),
      name: name,
      detail: "Bob · 2m",
      kind: .channel,
      symbol: CarPlayAvatar.channelSymbol,
      showsUnread: unread,
      isMuted: muted,
      isFavorite: false
    )
  }

  @Test
  func `Chat rows open their conversation and carry only name and detail`() {
    let row = chatRow("Public", unread: true, muted: true)
    var opened: UUID?
    let item = CarPlayTemplates.chatItem(row) { opened = $0 }
    #expect(item.text == "Public")
    #expect(item.detailText == "Bob · 2m")
    #expect(item.accessoryType == .disclosureIndicator)
    item.handler?(item) {}
    #expect(opened == row.id)
  }

  @Test
  func `Unchanged chat rows update in place`() {
    let template = CPListTemplate(title: "Chats", sections: [])
    let first = chatRow("A")
    CarPlayTemplates.applyChats([first], to: template) { _ in }
    let item = template.sections.first?.items.first as? CPListItem

    let renamed = CarPlaySnapshot.ChatRow(
      id: first.id, name: "A2", detail: "3 unread · 3m", kind: .channel, symbol: CarPlayAvatar.channelSymbol,
      showsUnread: true, isMuted: false, isFavorite: false
    )
    CarPlayTemplates.applyChats([renamed], to: template) { _ in }
    let updated = template.sections.first?.items.first as? CPListItem
    #expect(updated === item)
    #expect(updated?.text == "A2")
    #expect(updated?.detailText == "3 unread · 3m")
  }

  @Test
  func `Chat lists never exceed the car's limit`() {
    let template = CPListTemplate(title: "Chats", sections: [])
    CarPlayTemplates.applyChats((0 ..< 30).map { chatRow("\($0)") }, to: template) { _ in }
    #expect((template.sections.first?.items.count ?? 0) <= CarPlaySnapshotBuilder.maxListItems)
  }

  // MARK: - Conversation

  private func page(rows: Int, canReply: Bool = true, hasSiri: Bool = true) -> CarPlaySnapshot.ConversationPage {
    let id = UUID()
    return CarPlaySnapshot.ConversationPage(
      id: id,
      title: "Public",
      symbol: CarPlayAvatar.publicChannelSymbol,
      tint: .avatar(.channel),
      hasSiri: hasSiri,
      showsUnread: true,
      readDetail: "2 unread",
      canReply: canReply,
      rows: (0 ..< rows).map { index in
        let messageID = UUID()
        return CarPlaySnapshot.MessageRow(
          id: messageID,
          siriIdentifier: SiriMessage.identifier(conversationID: id, messageID: messageID),
          sender: "Bob \(index)",
          detail: "2 hops",
          age: "\(index)m",
          symbol: CarPlayAvatar.companionSymbol,
          tint: .avatar(.companion),
          isUnread: index == 0
        )
      },
      note: rows == 0 ? nil : "Recent messages",
      empty: .init(title: "No messages yet", subtitle: nil)
    )
  }

  @Test
  func `A conversation screen hands Siri the conversation, a reply and each message`() {
    let page = page(rows: 3)
    let template = CPListTemplate(title: page.title, sections: [])
    CarPlayTemplates.applyConversation(page, to: template)
    #expect(template.sections.count == 2)
    let actions = template.sections[0].items.compactMap { $0 as? CPMessageListItem }
    #expect(actions.count == 2)
    #expect(actions[0].conversationIdentifier == page.id.uuidString)
    #expect(actions[0].text == L10n.Localizable.CarPlay.Chats.readWithSiri)
    #expect(actions[0].leadingConfiguration.isUnread)
    #expect(actions[1].phoneOrEmailAddress == page.id.uuidString)
    #expect(actions[1].text == "Public")
    let messages = template.sections[1].items.compactMap { $0 as? CPMessageListItem }
    #expect(template.sections[1].header == "Recent messages")
    #expect(messages.map(\.conversationIdentifier) == page.rows.map(\.siriIdentifier))
    #expect(messages.map(\.text) == ["Bob 0", "Bob 1", "Bob 2"])
    #expect(messages.first?.leadingConfiguration.isUnread == true)
    #expect(messages.first?.trailingText == "0m")
  }

  @Test
  func `A room's screen has no Reply row, and no Siri means no rows`() {
    let template = CPListTemplate(title: "Room", sections: [])
    CarPlayTemplates.applyConversation(page(rows: 2, canReply: false), to: template)
    #expect(template.sections.first?.items.count == 1)

    let off = page(rows: 2, hasSiri: false)
    CarPlayTemplates.applyConversation(off, to: template)
    #expect(template.sections.isEmpty)
    #expect(template.emptyViewTitleVariants == [off.empty.title])
  }

  @Test
  func `A conversation screen stays within the car's limit and updates in place`() {
    let full = page(rows: 30)
    let template = CPListTemplate(title: full.title, sections: [])
    CarPlayTemplates.applyConversation(full, to: template)
    #expect(template.sections.reduce(0) { $0 + $1.items.count } <= CarPlayTemplates.listLimit)

    let small = page(rows: 2)
    CarPlayTemplates.applyConversation(small, to: template)
    let first = template.sections[1].items.first as? CPMessageListItem
    let aged = CarPlaySnapshot.ConversationPage(
      id: small.id, title: small.title, symbol: small.symbol, tint: small.tint, hasSiri: true, showsUnread: false,
      readDetail: "Siri reads", canReply: true,
      rows: small.rows.map {
        CarPlaySnapshot.MessageRow(
          id: $0.id, siriIdentifier: $0.siriIdentifier, sender: $0.sender, detail: "✓ Delivered", age: "9m",
          symbol: $0.symbol, tint: $0.tint, isUnread: false
        )
      },
      note: small.note, empty: small.empty
    )
    CarPlayTemplates.applyConversation(aged, to: template)
    let updated = template.sections[1].items.first as? CPMessageListItem
    #expect(updated === first)
    #expect(updated?.detailText == "✓ Delivered")
    #expect(updated?.trailingText == "9m")
    #expect(updated?.leadingConfiguration.isUnread == false)
    #expect((template.sections[0].items.first as? CPMessageListItem)?.detailText == "Siri reads")
  }

  // MARK: - Dashboard

  private func option(_ kind: CarPlaySnapshot.OptionKind, detail: String = "d", enabled: Bool = true) -> CarPlaySnapshot.Option {
    .init(kind: kind, text: "\(kind)", detail: detail, symbol: "stethoscope", tint: .feature(.health), isEnabled: enabled, pushes: kind != .advert)
  }

  private func card(_ kind: CarPlaySnapshot.CardKind, text: String = "v", opens: CarPlayTab? = nil) -> CarPlaySnapshot.Card {
    .init(kind: kind, symbol: "waveform", tint: .feature(.radio), text: text, detail: "Title · detail", opensTab: opens)
  }

  private func dashboard(cards: [CarPlaySnapshot.Card], advertDetail: String = "d") -> CarPlaySnapshot.Dashboard {
    .init(
      header: "Heltec",
      subtitle: "Ready",
      options: [option(.advert, detail: advertDetail), option(.scan), option(.health)],
      cards: cards
    )
  }

  @Test
  func `The Dashboard is one list with no headers: the cards, then the options`() {
    let sections = CarPlayTemplates.dashboardSections(
      dashboard(cards: [card(.radio), card(.nodes, opens: .nodes)]), onOption: { _ in }, onCard: { _ in }
    )
    #expect(sections.count == 1)
    #expect(sections[0].header == nil)
    #expect(sections[0].headerSubtitle == nil)
    let rows = sections[0].items.compactMap { $0 as? CPListItem }
    #expect(rows.count == 5)
    let cards = Array(rows.prefix(2))
    // Every card does something: a tab, or its own read-only screen (with the arrow).
    #expect(cards.allSatisfy { $0.handler != nil && $0.isEnabled })
    #expect(cards.map(\.accessoryType) == [.disclosureIndicator, .none])
    let options = Array(rows.dropFirst(2))
    #expect(options.allSatisfy { $0.handler != nil })
    #expect(options.map(\.accessoryType) == [.none, .disclosureIndicator, .disclosureIndicator])
  }

  @Test
  func `Scan for Nodes is the Dashboard's fourth row, the other tools after the cards`() {
    let full = dashboard(cards: [card(.radio), card(.chats, opens: .comm), card(.nodes, opens: .nodes), card(.mesh, opens: .spectrum), card(.gps, opens: .gps)])
    #expect(CarPlayTemplates.dashboardRows(full).map(\.id) == [
      "card:radio", "card:chats", "card:nodes", "opt:scan", "card:mesh", "card:gps", "opt:advert", "opt:health",
    ])
    // A short list keeps Scan in its place and cuts from the end.
    #expect(CarPlayTemplates.dashboardRows(full, limit: 4).map(\.id).last == "opt:scan")
    // Fewer rows than that: Scan after them.
    #expect(CarPlayTemplates.dashboardRows(dashboard(cards: [card(.radio)])).map(\.id) == ["card:radio", "opt:advert", "opt:health", "opt:scan"])
  }

  @Test
  func `A card opens its tab, or its own lines when its page is settings`() {
    #expect(CarPlayTemplates.action(card(.nodes, opens: .nodes)) == .openTab(.nodes))
    #expect(CarPlayTemplates.action(card(.battery)) == .showInfo(.battery))
  }

  @Test
  func `Without options the Dashboard is the cards alone`() {
    let bare = CarPlaySnapshot.Dashboard(header: "Heltec", subtitle: "Ready", options: [], cards: [card(.radio)])
    let template = CPListTemplate(title: "Dashboard", sections: [])
    CarPlayTemplates.applyDashboard(bare, to: template, onOption: { _ in }, onCard: { _ in })
    #expect(template.sections.count == 1)
    #expect(template.sections[0].header == nil)
    let radio = template.sections[0].items.first as? CPListItem
    CarPlayTemplates.applyDashboard(
      .init(header: "Heltec", subtitle: "Ready", options: [], cards: [card(.radio, text: "Hilltop")]),
      to: template, onOption: { _ in }, onCard: { _ in }
    )
    #expect(template.sections[0].items.first as? CPListItem === radio)
    #expect(radio?.text == "Hilltop")
  }

  @Test
  func `A starting Dashboard is empty and says so`() {
    let template = CPListTemplate(title: "Dashboard", sections: [])
    let starting = CarPlaySnapshot.Dashboard(header: "Cairn", subtitle: "Starting…", options: [], cards: [])
    CarPlayTemplates.applyDashboard(starting, to: template, onOption: { _ in }, onCard: { _ in })
    #expect(template.sections.isEmpty)
    #expect(template.emptyViewTitleVariants == ["Cairn"])
    #expect(template.emptyViewSubtitleVariants == ["Starting…"])
  }

  @Test
  func `Dashboard updates keep the rows, and a radio connecting rebuilds them`() {
    let template = CPListTemplate(title: "Dashboard", sections: [])
    CarPlayTemplates.applyDashboard(dashboard(cards: [card(.radio)]), to: template, onOption: { _ in }, onCard: { _ in })
    let radio = template.sections[0].items[0] as? CPListItem
    let advert = template.sections[0].items[1] as? CPListItem

    CarPlayTemplates.applyDashboard(
      dashboard(cards: [card(.radio, text: "Hilltop")], advertDetail: "Sending"),
      to: template, onOption: { _ in }, onCard: { _ in }
    )
    #expect(template.sections[0].items[0] as? CPListItem === radio)
    #expect(template.sections[0].items[1] as? CPListItem === advert)
    #expect(advert?.detailText == "Sending")
    #expect(radio?.text == "Hilltop")

    CarPlayTemplates.applyDashboard(
      dashboard(cards: [card(.radio), card(.battery)]),
      to: template, onOption: { _ in }, onCard: { _ in }
    )
    #expect(template.sections[0].items.count == 5)
    #expect(template.sections[0].items[2] as? CPListItem !== advert)
  }

  @Test
  func `The advert choice is zero-hop, flood or cancel`() {
    let sheet = CarPlayTemplates.advertSheet(onSend: { _ in }, onCancel: {})
    #expect(sheet.title == L10n.Tools.Tools.advert)
    #expect(sheet.message == L10n.Localizable.CarPlay.Advert.Sheet.message)
    #expect(sheet.actions.map(\.title) == [
      L10n.Tools.Intent.Advert.Reach.zeroHop, L10n.Tools.Tools.Advert.FloodConfirm.send, L10n.Localizable.Common.cancel,
    ])
    #expect(sheet.actions.map(\.style) == [.default, .default, .cancel])
  }

  // MARK: - Scan

  private func scan(results: [String], detail: String? = nil, header: String = "Idle") -> CarPlaySnapshot.Scan {
    CarPlaySnapshot.Scan(
      header: header,
      subtitle: "Best",
      controls: [
        .init(filter: .repeaters, title: "Repeaters", detail: detail, symbol: "dot.radiowaves.left.and.right", tint: .feature(.scan), isEnabled: true, stops: false),
        .init(filter: .sensors, title: "Sensors", detail: nil, symbol: "dot.radiowaves.left.and.right", tint: .feature(.scan), isEnabled: false, stops: false),
      ],
      sections: results.isEmpty ? [] : [.init(
        title: "Repeaters · \(results.count)",
        rows: results.enumerated().map { index, name in
          .init(publicKey: Data([UInt8(index)]), name: name, detail: "↓ 5.0 dB", barLevel: 0.75, tint: .color(.green), info: [])
        }
      )]
    )
  }

  @Test
  func `Scan shows the headline over its controls, and every result opens its detail`() {
    let sections = CarPlayTemplates.scanSections(scan(results: ["R1"]), onControl: { _, _ in }, onResult: { _ in })
    #expect(sections.count == 2)
    #expect(sections[0].header == "Idle")
    #expect(sections[0].headerSubtitle == "Best")
    #expect(sections[0].items.compactMap { $0 as? CPListItem }.map(\.isEnabled) == [true, false])
    #expect(sections[1].header == "Repeaters · 1")
    let results = sections[1].items.compactMap { $0 as? CPListItem }
    #expect(results.allSatisfy { $0.handler != nil && $0.accessoryType == .disclosureIndicator })
  }

  @Test
  func `A scan tick updates the list in place`() {
    let template = CPListTemplate(title: "Scan", sections: [])
    CarPlayTemplates.applyScan(scan(results: ["R1"]), to: template, onControl: { _, _ in }, onResult: { _ in })
    let control = template.sections[0].items.first as? CPListItem
    let result = template.sections[1].items.first as? CPListItem

    CarPlayTemplates.applyScan(scan(results: ["R1 renamed"], detail: "Scanning"), to: template, onControl: { _, _ in }, onResult: { _ in })
    #expect(template.sections[0].items.first as? CPListItem === control)
    #expect(template.sections[1].items.first as? CPListItem === result)
    #expect(control?.detailText == "Scanning")
    #expect(result?.text == "R1 renamed")

    CarPlayTemplates.applyScan(scan(results: ["R1", "R2"]), to: template, onControl: { _, _ in }, onResult: { _ in })
    #expect(template.sections[1].items.count == 2)

    CarPlayTemplates.applyScan(scan(results: ["R1", "R2"], header: "2 replied"), to: template, onControl: { _, _ in }, onResult: { _ in })
    #expect(template.sections[0].header == "2 replied")
  }

  @Test
  func `Scan never exceeds the car's list limit`() {
    let sections = CarPlayTemplates.scanSections(
      scan(results: (0 ..< 30).map { "R\($0)" }), onControl: { _, _ in }, onResult: { _ in }
    )
    #expect(sections.reduce(0) { $0 + $1.items.count } <= CarPlayTemplates.listLimit)
    #expect(sections.count <= CarPlayTemplates.sectionLimit)
  }

  @Test
  func `Scan results leave the controls their section within the car's section limit`() {
    var many = scan(results: ["R1"])
    many.sections = (0 ..< 6).map { index in
      .init(title: "S\(index)", rows: [.init(
        publicKey: Data([UInt8(index)]), name: "R\(index)", detail: "", barLevel: 0.5, tint: .color(.green), info: []
      )])
    }
    let fitted = CarPlayTemplates.fittedScan(many)
    #expect(fitted.count <= CarPlayTemplates.sectionLimit - 1)
    #expect(fitted.map(\.title) == Array(many.sections.prefix(fitted.count)).map(\.title))
  }

  // MARK: - Network Health and information tabs

  @Test
  func `Network Health heads with the fleet, and every repeater opens its detail`() {
    let health = CarPlaySnapshot.Health(
      summary: .init(title: "3 Repeaters", detail: "Need Attention · 1"),
      sections: [
        .init(title: "Needs Attention", rows: (0 ..< 20).map {
          .init(id: "\($0)", name: "R\($0)", detail: "Restarted", symbol: "arrow.counterclockwise", tint: .warning)
        }),
        .init(title: "Healthy", rows: [.init(id: "h", name: "H", detail: "", symbol: "checkmark.circle.fill", tint: .success)]),
      ],
      emptyTitle: "No Repeaters"
    )
    var selected: [String] = []
    let sections = CarPlayTemplates.healthSections(health, onSelect: { selected.append($0) })
    #expect(sections.reduce(0) { $0 + $1.items.count } <= CarPlayTemplates.listLimit)
    #expect(sections.count <= CarPlayTemplates.sectionLimit)
    // The fleet is the header, not a dimmed row.
    #expect(sections[0].header == "3 Repeaters")
    #expect(sections[0].headerSubtitle == "Need Attention · 1")
    let items = sections.flatMap(\.items).compactMap { $0 as? CPListItem }
    #expect(items.allSatisfy { $0.isEnabled && $0.handler != nil && $0.accessoryType == .disclosureIndicator })
    #expect(items.first?.text == "R0")
    items.first?.handler?(items[0]) {}
    #expect(selected == ["0"])
  }

  @Test
  func `Network Health sections fit the car's section limit`() {
    let row = { (id: String) in CarPlaySnapshot.HealthRow(id: id, name: id, detail: "", symbol: "checkmark.circle.fill", tint: .success) }
    let health = CarPlaySnapshot.Health(
      summary: nil,
      sections: (0 ..< 6).map { .init(title: "S\($0)", rows: [row("\($0)")]) },
      emptyTitle: ""
    )
    #expect(CarPlayTemplates.fittedHealth(health).count <= CarPlayTemplates.sectionLimit)
  }

  @Test
  func `Information tabs hold at most ten items and no actions`() {
    let template = CPInformationTemplate(title: "Spectrum", layout: .twoColumn, items: [], actions: [])
    CarPlayTemplates.applyInfo((0 ..< 14).map { .init(title: "T\($0)", detail: "D") }, to: template)
    #expect(template.items.count == CarPlaySnapshotBuilder.maxInfoItems)
    #expect(template.actions.isEmpty)
  }

  @Test
  func `Node groups are trimmed to the car's limits`() {
    let row = { (index: Int) in
      CarPlaySnapshot.NodeGroupRow(list: .letters("\(index)"), title: "\(index)", count: 1, symbol: "star.fill", tint: .brand)
    }
    let fitted = CarPlayTemplates.fittedGroups([
      .init(header: nil, rows: (0 ..< 10).map(row)),
      .init(header: "Groups", rows: (10 ..< 30).map(row)),
    ])
    #expect(fitted.reduce(0) { $0 + $1.rows.count } <= CarPlayTemplates.listLimit)
    #expect(fitted.count <= CarPlayTemplates.sectionLimit)
  }

  @Test
  func `Node groups update in place, and a new group replaces the sections`() {
    let template = CPListTemplate(title: "Nodes", sections: [])
    let row = { (count: Int) in
      CarPlaySnapshot.NodeGroupRow(list: .category(.contacts), title: "Contacts", count: count, symbol: CarPlayAvatar.companionSymbol, tint: .avatar(.companion))
    }
    CarPlayTemplates.applyNodeGroups([.init(header: nil, rows: [row(3)])], to: template) { _ in }
    let item = template.sections.first?.items.first as? CPListItem
    #expect(item?.detailText == "3")
    #expect(item?.accessoryType == .disclosureIndicator)
    CarPlayTemplates.applyNodeGroups([.init(header: nil, rows: [row(4)])], to: template) { _ in }
    #expect(template.sections.first?.items.first as? CPListItem === item)
    #expect(item?.detailText == "4")
    let favorites = CarPlaySnapshot.NodeGroupRow(list: .category(.favorites), title: "Favorites", count: 1, symbol: "star.fill", tint: .color(.yellow))
    CarPlayTemplates.applyNodeGroups([.init(header: nil, rows: [favorites, row(4)])], to: template) { _ in }
    #expect(template.sections.first?.items.count == 2)
  }

  @Test
  func `A node list is one section headed by its note, updated in place`() {
    let template = CPListTemplate(title: "Contacts", sections: [])
    let row = { (detail: String) in
      CarPlaySnapshot.NodeRow(publicKey: Data([1]), name: "Hilltop", detail: detail, symbol: CarPlayAvatar.repeaterSymbol, info: [])
    }
    let page = { (detail: String, note: String?) in
      CarPlaySnapshot.NodeListPage(list: .category(.repeaters), title: "Repeaters", note: note, rows: [row(detail)], emptyTitle: "None")
    }
    CarPlayTemplates.applyNodePage(page("2m", "Showing 1 of 5"), to: template) { _ in }
    #expect(template.sections.count == 1)
    #expect(template.sections.first?.header == "Showing 1 of 5")
    #expect(template.emptyViewTitleVariants == ["None"])
    let item = template.sections.first?.items.first as? CPListItem
    CarPlayTemplates.applyNodePage(page("3m", "Showing 1 of 5"), to: template) { _ in }
    #expect(template.sections.first?.items.first as? CPListItem === item)
    #expect(item?.detailText == "3m")
    CarPlayTemplates.applyNodePage(.init(list: .category(.repeaters), title: "Repeaters", rows: [], emptyTitle: "None"), to: template) { _ in }
    #expect(template.sections.isEmpty)
  }

  @Test
  func `A renamed companion's avatar is redrawn in place, in its new name's colour`() {
    let template = CPListTemplate(title: "Contacts", sections: [])
    let page = { (name: String) in
      let row = CarPlaySnapshot.NodeRow(
        publicKey: Data([7]),
        name: name,
        detail: "2m",
        symbol: CarPlayAvatar.symbol(.chat, name: name),
        info: [],
        tint: CarPlayAvatar.tint(.chat, name: name)
      )
      return CarPlaySnapshot.NodeListPage(list: .category(.contacts), title: "Contacts", rows: [row], emptyTitle: "None")
    }
    CarPlayTemplates.applyNodePage(page("Alice"), to: template) { _ in }
    let item = template.sections.first?.items.first as? CPListItem
    let before = (item?.userInfo as? CarPlayTemplates.ItemTag)?.image
    CarPlayTemplates.applyNodePage(page("🚒 Bob"), to: template) { _ in }
    #expect(template.sections.first?.items.first as? CPListItem === item)
    #expect(item?.text == "🚒 Bob")
    let after = (item?.userInfo as? CarPlayTemplates.ItemTag)?.image
    #expect(after != nil && after != before)
    #expect(after?.contains(CarPlayAvatar.emojiPrefix) == true)
  }

  @Test
  func `A Nodes group card is the phone's avatar, and switching it rebuilds the row's elements`() {
    guard #available(iOS 26.0, *) else { return }
    let template = CPListTemplate(title: "Nodes", sections: [])
    let tile = CarPlaySnapshot.Tile(id: "fav", symbol: CarPlayAvatar.favoriteSymbol, tint: .color(.yellow), title: "Favorites", subtitle: "3")
    var avatar = tile
    avatar.isAvatar = true
    CarPlayTemplates.applyCards([.init(header: nil, rows: [.init(id: "r", title: nil, tiles: [tile], style: .condensed)])], to: template) { _, _ in }
    let item = template.sections.first?.items.first as? CPListImageRowItem
    let toolImage = (item?.elements.first as? CPListImageRowItemCondensedElement)?.image
    CarPlayTemplates.applyCards([.init(header: nil, rows: [.init(id: "r", title: nil, tiles: [avatar], style: .condensed)])], to: template) { _, _ in }
    #expect(template.sections.first?.items.first as? CPListImageRowItem === item)
    let avatarImage = (item?.elements.first as? CPListImageRowItemCondensedElement)?.image
    #expect(avatarImage != nil)
    #expect(avatarImage?.pngData() != toolImage?.pngData())
  }

  @Test
  func `Row images follow the car's appearance and scale`() {
    for scale in [CGFloat(2), CGFloat(3)] {
      let traits = UITraitCollection(displayScale: scale)
      for image in [
        CarPlayTemplates.image("person.fill", traits: traits),
        CarPlayTemplates.tile(symbol: "stethoscope", tint: .feature(.health), traits: traits),
        CarPlayTemplates.image("cellularbars", tint: .color(.green), variableValue: 0.5, traits: traits),
      ] {
        let asset = image?.imageAsset
        let light = asset?.image(with: UITraitCollection { $0.displayScale = scale; $0.userInterfaceStyle = .light })
        let dark = asset?.image(with: UITraitCollection { $0.displayScale = scale; $0.userInterfaceStyle = .dark })
        #expect(light != nil && dark != nil)
        #expect(light !== dark)
        #expect(image?.scale == scale)
        let size = image?.size ?? .zero
        #expect(size.width <= CarPlayTemplates.listImageSize.width && size.height <= CarPlayTemplates.listImageSize.height)
      }
    }
  }

  @Test
  func `Message images fit their smaller slot`() {
    let image = CarPlayTemplates.image("number", tint: .feature(.comm), traits: UITraitCollection(displayScale: 2), size: CarPlayTemplates.messageImageSize)
    #expect((image?.size.width ?? 99) <= CarPlayTemplates.messageImageSize.width)
  }

  @Test
  func `Signal bars are cached in five levels`() {
    #expect([0, 0.1, 0.25, 0.4, 0.5, 0.74, 0.75, 1, 1.5].map(CarPlayTemplates.level) == [0, 0, 1, 2, 2, 3, 3, 4, 4])
    #expect(CarPlayTemplates.level(nil) == nil)
  }

  @Test
  func `A node's detail screen is read-only`() {
    let row = CarPlaySnapshot.NodeRow(
      publicKey: Data([1]), name: "Hilltop", detail: "", symbol: "antenna.radiowaves.left.and.right",
      info: [.init(title: "Type", detail: "Repeater"), .init(title: "Route", detail: "Direct")]
    )
    let template = CarPlayTemplates.nodeDetail(row)
    #expect(template.items.count == 2)
    #expect(template.actions.isEmpty)
  }

  // MARK: - Cards (iOS 26)

  private func tileRow(_ id: String, values: [String], enabled: Bool = true) -> CarPlaySnapshot.TileRow {
    .init(id: id, title: id.capitalized, tiles: values.enumerated().map { index, value in
      .init(id: "\(id).\(index)", symbol: "battery.100", tint: .success, title: "T\(index)", subtitle: value, isEnabled: enabled)
    })
  }

  @Test
  func `A card row carries one card per reading, with its name, value and tint`() throws {
    guard #available(iOS 26.0, *) else { return }
    let traits = UITraitCollection(displayScale: 2)
    let item = CarPlayTemplates.cardRowItem(tileRow("radio", values: ["87%", "Ready"]), traits: traits) { _, _ in }
    #expect(item.text == "Radio")
    #expect(item.allowsMultipleLines)
    let cards = item.elements.compactMap { $0 as? CPListImageRowItemCardElement }
    #expect(cards.map(\.title) == ["T0", "T1"])
    #expect(cards.map(\.subtitle) == ["87%", "Ready"])
    #expect(cards.allSatisfy { !$0.showsImageFullHeight && $0.tintColor != nil })
    let size = CarPlayTemplates.cardImageSize
    #expect(cards.allSatisfy { $0.image.size.width <= size.width && $0.image.size.height <= size.height })
    #expect(item.listImageRowHandler != nil)
  }

  @Test
  func `A disabled card is drawn disabled`() {
    guard #available(iOS 26.0, *) else { return }
    let item = CarPlayTemplates.cardRowItem(tileRow("tools", values: ["Sending"], enabled: false)) { _, _ in }
    #expect(item.elements.first?.isEnabled == false)
  }

  @Test
  func `Card rows update in place, and only the rows that changed`() {
    guard #available(iOS 26.0, *) else { return }
    let template = CPListTemplate(title: "Dashboard", sections: [])
    let first: [CarPlaySnapshot.TileSection] = [.init(header: nil, rows: [tileRow("radio", values: ["87%"]), tileRow("mesh", values: ["-92 dBm"])])]
    CarPlayTemplates.applyCards(first, to: template) { _, _ in }
    let items = template.sections.first?.items.compactMap { $0 as? CPListImageRowItem } ?? []
    #expect(items.count == 2)
    let untouched = items[1].elements.first

    let second: [CarPlaySnapshot.TileSection] = [.init(header: nil, rows: [tileRow("radio", values: ["86%"]), tileRow("mesh", values: ["-92 dBm"])])]
    CarPlayTemplates.applyCards(second, to: template) { _, _ in }
    let updated = template.sections.first?.items.compactMap { $0 as? CPListImageRowItem } ?? []
    #expect(updated.first === items.first)
    #expect((updated.first?.elements.first as? CPListImageRowItemCardElement)?.subtitle == "86%")
    #expect(updated[1].elements.first === untouched)
  }

  @Test
  func `A new row or header replaces the card sections`() {
    guard #available(iOS 26.0, *) else { return }
    let template = CPListTemplate(title: "Dashboard", sections: [])
    CarPlayTemplates.applyCards([.init(header: nil, rows: [tileRow("radio", values: ["87%"])])], to: template) { _, _ in }
    let item = template.sections.first?.items.first
    CarPlayTemplates.applyCards(
      [.init(header: nil, rows: [tileRow("radio", values: ["87%"])]), .init(header: "Tools", rows: [tileRow("tools", values: ["Advert"])])],
      to: template
    ) { _, _ in }
    #expect(template.sections.count == 2)
    #expect(template.sections[1].header == "Tools")
    #expect(template.sections.first?.items.first !== item)
  }

  @Test
  func `Card sections fit the car's limits`() {
    let rows = (0 ..< 30).map { tileRow("r\($0)", values: ["v"]) }
    let fitted = CarPlayTemplates.fittedCards([.init(header: nil, rows: rows)])
    #expect(fitted.flatMap(\.rows).count <= CarPlayTemplates.listLimit)
  }

  // MARK: - Rich cards

  private func panelTile(_ value: String = "-92 dBm") -> CarPlaySnapshot.Tile {
    .init(
      id: "mesh", symbol: "chart.xyaxis.line", tint: .feature(.spectrum), title: value, subtitle: "12/min",
      action: .openTab(.spectrum),
      panel: .init(symbol: "chart.xyaxis.line", tint: .feature(.spectrum), heading: "Mesh", status: .success, metrics: [
        .init(id: "signal", symbol: "dot.radiowaves.forward", label: "Last packet", value: value, caption: "7.5 dB",
              gauge: .bars(0.75, .success)),
        .init(id: "noise", symbol: "chart.xyaxis.line", label: "Noise floor", value: "-110 dBm"),
        .init(id: "battery", symbol: "battery.75", label: "Battery", value: "87%", gauge: .meter(0.87, .success)),
        .init(id: "position", symbol: "mappin.and.ellipse", label: "Position", value: "41.8823, -87.6232"),
      ])
    )
  }

  @Test
  func `A rich card is its picture at the car's scale, with the summary in the band under it, not over it`() throws {
    guard #available(iOS 26.0, *) else { return }
    let traits = UITraitCollection { $0.displayScale = 3; $0.userInterfaceStyle = .dark }
    let row = CarPlaySnapshot.TileRow(id: "overview", title: nil, tiles: [panelTile()])
    let item = CarPlayTemplates.cardRowItem(row, traits: traits) { _, _ in }
    #expect(item.text == nil)
    let card = try #require(item.elements.first as? CPListImageRowItemCardElement)
    #expect(!card.showsImageFullHeight)
    #expect(card.title == "-92 dBm")
    #expect(card.subtitle == "12/min")
    // The card element keeps the picture's pixels but re-wraps it at the host screen's scale (2 on
    // an iPad), so compare pixels: the card's size at the car's scale, on any simulator.
    let size = CarPlayTemplates.panelImageSize
    let pixels = CGSize(width: card.image.size.width * card.image.scale, height: card.image.size.height * card.image.scale)
    #expect(pixels == CGSize(width: size.width * 3, height: size.height * 3))
  }

  @Test
  func `A panel picture has a light and a dark variant`() throws {
    let size = CGSize(width: 180, height: 180)
    let panel = try #require(panelTile().panel)
    let light = try #require(CarPlayPanelImage.image(panel, size: size, traits: UITraitCollection { $0.displayScale = 2; $0.userInterfaceStyle = .light }))
    let dark = try #require(CarPlayPanelImage.image(panel, size: size, traits: UITraitCollection { $0.displayScale = 2; $0.userInterfaceStyle = .dark }))
    #expect(light.size == size)
    #expect(light.scale == 2)
    #expect(light.pngData() != dark.pngData())
  }

  @Test
  func `A panel lays its readings two to a line, a long one on a line of its own`() throws {
    let metrics = try #require(panelTile().panel?.metrics)
    let lines = CarPlayPanelImage.lines(metrics)
    #expect(lines.map { $0.map(\.id) } == [["signal", "noise"], ["battery"], ["position"]])
  }

  @Test
  func `A condensed row is small tiles beside their names, several to a line`() throws {
    guard #available(iOS 26.0, *) else { return }
    let row = CarPlaySnapshot.TileRow(id: "shortcuts", title: nil, tiles: [
      .init(id: "traffic", symbol: "waveform", tint: .feature(.health), title: "Traffic", subtitle: "12/min"),
      .init(id: "advert", symbol: "megaphone.fill", tint: .feature(.advert), title: "Send Advert", subtitle: "Sending", isEnabled: false),
    ], style: .condensed)
    let item = CarPlayTemplates.cardRowItem(row) { _, _ in }
    #expect(item.allowsMultipleLines)
    let elements = item.elements.compactMap { $0 as? CPListImageRowItemCondensedElement }
    #expect(elements.map(\.title) == ["Traffic", "Send Advert"])
    #expect(elements.map(\.subtitle) == ["12/min", "Sending"])
    #expect(elements.map(\.isEnabled) == [true, false])
    #expect(elements.allSatisfy { $0.imageShape == .roundedRectangle })
  }

  @Test
  func `A row that changes between cards and condensed is rebuilt, not updated in place`() {
    guard #available(iOS 26.0, *) else { return }
    let template = CPListTemplate(title: "Dashboard", sections: [])
    let tiles = [CarPlaySnapshot.Tile(id: "a", symbol: "waveform", tint: .success, title: "A", subtitle: "1")]
    CarPlayTemplates.applyCards([.init(header: nil, rows: [.init(id: "r", title: nil, tiles: tiles)])], to: template) { _, _ in }
    let first = template.sections.first?.items.first
    CarPlayTemplates.applyCards([.init(header: nil, rows: [.init(id: "r", title: nil, tiles: tiles, style: .condensed)])], to: template) { _, _ in }
    let second = template.sections.first?.items.first as? CPListImageRowItem
    #expect(second !== first)
    #expect(second?.elements.first is CPListImageRowItemCondensedElement)
  }

  @Test
  func `Node and conversation avatars draw the app's own symbols`() {
    let traits = UITraitCollection { $0.displayScale = 2; $0.userInterfaceStyle = .dark }
    for symbol in [
      CarPlayAvatar.repeaterSymbol, CarPlayAvatar.companionSymbol, CarPlayAvatar.roomSymbol, CarPlayAvatar.channelSymbol,
      CarPlayAvatar.publicChannelSymbol, CarPlayAvatar.privateChannelSymbol, CarPlayAvatar.emojiPrefix + "🚒",
    ] {
      #expect(CarPlayTemplates.avatar(symbol: symbol, tint: .avatar(.repeater), traits: traits) != nil, "\(symbol)")
    }
  }

  @Test
  func `A rich card's picture is the size the car asks for a card's image`() {
    guard #available(iOS 26.0, *) else { return }
    let asked = CPListImageRowItemCardElement.maximumImageSize
    #expect(CarPlayTemplates.panelImageSize == (asked.width > 0 && asked.height > 0 ? asked : CarPlayPanelImage.fallbackSize))
  }
}
