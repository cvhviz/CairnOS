#if canImport(CarPlay)
  import CarPlay
  import UIKit

  /// Turns `CarPlaySnapshot` parts into CarPlay template content, and applies a new snapshot to
  /// existing templates with as little redrawing as possible: rows whose identity is unchanged are
  /// updated in place, and sections are replaced only when membership, order or headers change.
  /// Nothing here reads app state; the controller hands in the snapshot, the car's traits and the
  /// tap handlers.
  @MainActor
  enum CarPlayTemplates {
    typealias Tint = CarPlayTint

    // MARK: - Tabs

    static let addedSymbol = "checkmark.circle.fill"
    static let signalSymbol = "cellularbars"

    /// A tab image. The tab bar tints template images itself, so these stay plain symbols. An SF
    /// Symbol, or the app's own (Home's walkie-talkie, `AppTab.isCustomSymbol`) from the asset catalog.
    static func symbol(_ name: String) -> UIImage? {
      (UIImage(systemName: name) ?? UIImage(named: name))?.withRenderingMode(.alwaysTemplate)
    }

    /// The rows a list may show: the snapshot already caps at 12, and some cars allow fewer.
    static var listLimit: Int {
      min(CarPlaySnapshotBuilder.maxListItems, max(1, Int(CPListTemplate.maximumItemCount)))
    }

    /// The sections a list may show; a limited car can allow fewer.
    static var sectionLimit: Int {
      max(1, Int(CPListTemplate.maximumSectionCount))
    }

    // MARK: - Images

    /// What a row is and which image it shows, kept on the item so an update in place only
    /// redraws the image when it really changed.
    struct ItemTag: Equatable {
      let id: String
      let image: String
    }

    private enum ImageKind: Hashable {
      /// A tinted glyph, as on the app's status cards.
      case glyph
      /// A white glyph on a rounded square of the tint, as the app's tool tiles (`IconTile`).
      case tile
      /// The app's avatar: the glyph on a pebble of the tint (`AvatarPebble`), for nodes and
      /// conversations (`CarPlayAvatar`).
      case avatar
    }

    private struct ImageKey: Hashable {
      let kind: ImageKind
      let name: String
      let tint: Tint
      /// `variableValue` in quarters, so the cache holds five fill levels per glyph at most.
      let level: Int?
      let scale: CGFloat
      let width: CGFloat
      let height: CGFloat
    }

    private static var imageCache: [ImageKey: UIImageAsset] = [:]

    /// The default list-row image size, for a car that has not reported one.
    private static let fallbackImageSize = CGSize(width: 44, height: 44)
    /// A tile's corner radius against its side, the app's icon tiles' proportion.
    static let tileCornerRatio: CGFloat = 0.28

    static var listImageSize: CGSize {
      let size = CPListItem.maximumImageSize
      return size.width > 0 && size.height > 0 ? size : fallbackImageSize
    }

    static var messageImageSize: CGSize {
      let size = CPMaximumMessageItemImageSize
      return size.width > 0 && size.height > 0 ? size : fallbackImageSize
    }

    /// A fill level rounded to quarters, the steps `cellularbars` draws.
    static func level(_ variableValue: Double?) -> Int? {
      variableValue.map { Int((min(1, max(0, $0)) * 4).rounded()) }
    }

    /// A display-ready symbol for a CarPlay row: drawn at the car's scale (not the phone's) and
    /// sized to the template's image slot, with a light and a dark variant in one `UIImageAsset`
    /// so it follows the car's appearance. List rows do not reliably tint template images, which
    /// is how a dark glyph ends up on a dark screen at night.
    static func image(
      _ name: String,
      tint: Tint = .brand,
      variableValue: Double? = nil,
      traits: UITraitCollection,
      size: CGSize = listImageSize
    ) -> UIImage? {
      render(.glyph, name: name, tint: tint, level: level(variableValue), traits: traits, size: size)
    }

    /// The app's icon tile for an option row: a white glyph on a rounded square filled with the
    /// tool's colour, the dark variant filled with the colour the phone uses at night.
    static func tile(
      symbol name: String,
      tint: Tint,
      variableValue: Double? = nil,
      traits: UITraitCollection,
      size: CGSize = listImageSize
    ) -> UIImage? {
      render(.tile, name: name, tint: tint, level: level(variableValue), traits: traits, size: size)
    }

    /// A node's or conversation's avatar as the phone draws it: its glyph (an SF Symbol or one of
    /// the app's own, such as the walkie-talkie and the repeater mast) on a pebble of its colour.
    static func avatar(
      symbol name: String,
      tint: Tint,
      traits: UITraitCollection,
      size: CGSize = listImageSize
    ) -> UIImage? {
      render(.avatar, name: name, tint: tint, level: nil, traits: traits, size: size)
    }

    /// A glyph by name: an SF Symbol, or the app's own symbol from the asset catalog.
    private static func symbolImage(_ name: String, level: Int?, configuration: UIImage.SymbolConfiguration) -> UIImage? {
      if let level, let image = UIImage(systemName: name, variableValue: Double(level) / 4, configuration: configuration) {
        return image
      }
      return UIImage(systemName: name, withConfiguration: configuration)
        ?? UIImage(named: name, in: .main, with: configuration)
    }

    /// How large an avatar's glyph is against its side, as the phone's avatars size theirs: the
    /// slender mast larger, so it fills the pebble as the door does.
    private static func avatarGlyphShare(_ name: String) -> CGFloat {
      switch name {
      case CarPlayAvatar.repeaterSymbol: 0.56
      case CarPlayAvatar.roomSymbol: 0.45
      default: 0.42
      }
    }

    private static func render(
      _ kind: ImageKind,
      name: String,
      tint: Tint,
      level: Int?,
      traits: UITraitCollection,
      size: CGSize
    ) -> UIImage? {
      let scale = traits.displayScale > 0 ? traits.displayScale : 2
      let key = ImageKey(kind: kind, name: name, tint: tint, level: level, scale: scale, width: size.width, height: size.height)
      if let asset = imageCache[key] {
        return asset.image(with: traits)
      }
      let side = min(size.width, size.height)
      let asset = UIImageAsset()
      for style in [UIUserInterfaceStyle.light, .dark] {
        let color = tint.color(for: style)
        let pointSize = switch kind {
        case .glyph: side * 0.5
        case .tile: side * 0.42
        case .avatar: side * avatarGlyphShare(name)
        }
        let glyphColor = switch kind {
        case .glyph: color
        case .tile: UIColor.white
        case .avatar: CarPlayAvatar.glyphColor(on: tint, fill: color)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let glyphImage: UIImage? = if let emoji = CarPlayAvatar.emoji(name) {
          emojiImage(emoji, pointSize: side * 0.4, format: format)
        } else {
          symbolImage(name, level: level, configuration: config)?.withTintColor(glyphColor, renderingMode: .alwaysOriginal)
        }
        guard let symbol = glyphImage else { return nil }
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
          let box: CGSize
          if kind == .glyph {
            box = size
          } else {
            let square = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            let radius = side * (kind == .avatar ? AvatarPebble.cornerFraction : tileCornerRatio)
            color.setFill()
            UIBezierPath(roundedRect: square, cornerRadius: radius).fill()
            let share: CGFloat = kind == .avatar ? 0.7 : 0.62
            box = CGSize(width: side * share, height: side * share)
          }
          let glyph = symbol.size
          let fit = min(1, box.width / max(glyph.width, 1), box.height / max(glyph.height, 1))
          let drawn = CGSize(width: glyph.width * fit, height: glyph.height * fit)
          symbol.draw(in: CGRect(
            origin: CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2),
            size: drawn
          ))
        }
        asset.register(rendered, with: UITraitCollection {
          $0.displayScale = scale
          $0.userInterfaceStyle = style
        })
      }
      imageCache[key] = asset
      return asset.image(with: traits)
    }

    /// An emoji drawn as the glyph, the size `ContactAvatar` draws a name's emoji.
    private static func emojiImage(_ emoji: String, pointSize: CGFloat, format: UIGraphicsImageRendererFormat) -> UIImage? {
      let text = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: pointSize)])
      let size = text.size()
      guard size.width > 0, size.height > 0 else { return nil }
      return UIGraphicsImageRenderer(size: size, format: format).image { _ in text.draw(at: .zero) }
    }

    private static func imageID(_ kind: String, _ name: String, _ tint: Tint, _ level: Int? = nil) -> String {
      "\(kind)|\(name)|\(tint)|\(level.map(String.init) ?? "-")"
    }

    /// Updates a row's text, detail, image and enabled state, each only when it changed.
    private static func update(
      _ item: CPListItem,
      text: String,
      detail: String?,
      tag: ItemTag,
      isEnabled: Bool = true,
      image: () -> UIImage?
    ) {
      if item.text != text { item.setText(text) }
      if item.detailText != detail { item.setDetailText(detail) }
      if (item.userInfo as? ItemTag)?.image != tag.image {
        item.setImage(image())
        item.userInfo = tag
      }
      if item.isEnabled != isEnabled { item.isEnabled = isEnabled }
    }

    private static func tags(_ section: CPListSection) -> [String] {
      section.items.compactMap { (($0 as? CPListItem)?.userInfo as? ItemTag)?.id }
    }

    /// Sets the list's empty-state text only when it changed.
    static func applyEmpty(_ empty: CarPlaySnapshot.EmptyState, to template: CPListTemplate) {
      let titles = [empty.title]
      let subtitles = empty.subtitle.map { [$0] } ?? []
      if template.emptyViewTitleVariants != titles { template.emptyViewTitleVariants = titles }
      if template.emptyViewSubtitleVariants != subtitles { template.emptyViewSubtitleVariants = subtitles }
    }

    // MARK: - Dashboard

    nonisolated static func identity(_ kind: CarPlaySnapshot.OptionKind) -> String {
      "opt:\(kind.rawValue)"
    }

    nonisolated static func identity(_ kind: CarPlaySnapshot.CardKind) -> String {
      "card:\(kind.rawValue)"
    }

    private static func tag(_ option: CarPlaySnapshot.Option) -> ItemTag {
      ItemTag(id: identity(option.kind), image: imageID("tile", option.symbol, option.tint))
    }

    private static func tag(_ card: CarPlaySnapshot.Card) -> ItemTag {
      ItemTag(id: identity(card.kind), image: imageID("glyph", card.symbol, card.tint))
    }

    static func optionItem(
      _ option: CarPlaySnapshot.Option,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (CarPlaySnapshot.OptionKind) -> Void
    ) -> CPListItem {
      let item = CPListItem(
        text: option.text,
        detailText: option.detail,
        image: tile(symbol: option.symbol, tint: option.tint, traits: traits),
        accessoryImage: nil,
        accessoryType: option.pushes ? .disclosureIndicator : .none
      )
      item.userInfo = tag(option)
      item.isEnabled = option.isEnabled
      let kind = option.kind
      item.handler = { _, completion in
        onSelect(kind)
        completion()
      }
      return item
    }

    /// What a status card does when tapped: open its tab, as the app's card does, or, for a card
    /// whose app page is settings, show its lines on a read-only screen.
    enum CardAction: Equatable {
      case openTab(CarPlayTab)
      case showInfo(CarPlaySnapshot.CardKind)
    }

    static func action(_ card: CarPlaySnapshot.Card) -> CardAction {
      card.opensTab.map(CardAction.openTab) ?? .showInfo(card.kind)
    }

    /// A status card as a row: its value as the text, its title and detail lines below, its
    /// glyph in the card's colour. Every card does something when tapped (`CardAction`); one that
    /// opens a screen of its own shows the disclosure arrow.
    static func cardItem(
      _ card: CarPlaySnapshot.Card,
      traits: UITraitCollection = .current,
      onCard: @escaping @MainActor (CardAction) -> Void
    ) -> CPListItem {
      let cardAction = Self.action(card)
      let item = CPListItem(
        text: card.text,
        detailText: card.detail,
        image: image(card.symbol, tint: card.tint, traits: traits),
        accessoryImage: nil,
        accessoryType: card.opensTab == nil ? .disclosureIndicator : .none
      )
      item.userInfo = tag(card)
      item.handler = { _, completion in
        onCard(cardAction)
        completion()
      }
      return item
    }

    /// One Dashboard row: a status card or a tool.
    enum DashboardRow {
      case card(CarPlaySnapshot.Card)
      case option(CarPlaySnapshot.Option)

      var id: String {
        switch self {
        case let .card(card): identity(card.kind)
        case let .option(option): identity(option.kind)
        }
      }
    }

    /// Scan for Nodes is the Dashboard's fourth row, within reach without scrolling.
    static let scanRowIndex = 3

    /// The rows the car shows, in order: the cards as on the app's Home with Scan for Nodes
    /// fourth, then the other tools, cut to the car's list limit.
    static func dashboardRows(_ dashboard: CarPlaySnapshot.Dashboard, limit: Int = listLimit) -> [DashboardRow] {
      var rows = dashboard.cards.map(DashboardRow.card)
        + dashboard.options.filter { $0.kind != .scan }.map(DashboardRow.option)
      if let scan = dashboard.options.first(where: { $0.kind == .scan }) {
        rows.insert(.option(scan), at: min(scanRowIndex, rows.count))
      }
      return Array(rows.prefix(limit))
    }

    /// The Dashboard as one list: the status cards, then the tools. Empty while the app starts,
    /// when the list's empty view says so instead.
    static func dashboardSections(
      _ dashboard: CarPlaySnapshot.Dashboard,
      traits: UITraitCollection = .current,
      onOption: @escaping @MainActor (CarPlaySnapshot.OptionKind) -> Void,
      onCard: @escaping @MainActor (CardAction) -> Void
    ) -> [CPListSection] {
      let items: [CPListItem] = dashboardRows(dashboard).map { row in
        switch row {
        case let .card(card): cardItem(card, traits: traits, onCard: onCard)
        case let .option(option): optionItem(option, traits: traits, onSelect: onOption)
        }
      }
      // One section, no headers: the Radio card leads with the radio's name and link, and the
      // tools' tiles set them apart from the cards, so every row of the screen is a row to read.
      return items.isEmpty ? [] : [CPListSection(items: items)]
    }

    /// Updates the Dashboard in place while its rows and header are the same; a radio connecting
    /// (which adds the Battery and GPS cards) or a reordering replaces the sections.
    static func applyDashboard(
      _ dashboard: CarPlaySnapshot.Dashboard,
      to template: CPListTemplate,
      traits: UITraitCollection = .current,
      onOption: @escaping @MainActor (CarPlaySnapshot.OptionKind) -> Void,
      onCard: @escaping @MainActor (CardAction) -> Void
    ) {
      let rows = dashboardRows(dashboard)
      applyEmpty(.init(title: dashboard.header, subtitle: dashboard.subtitle), to: template)

      let ids = rows.map(\.id)
      let wanted = ids.isEmpty ? [] : [ids]
      let current = template.sections
      let sameShape = !wanted.isEmpty && current.map(tags) == wanted
      guard sameShape else {
        template.updateSections(dashboardSections(dashboard, traits: traits, onOption: onOption, onCard: onCard))
        return
      }
      let cards = rows.compactMap { row -> CarPlaySnapshot.Card? in if case let .card(card) = row { card } else { nil } }
      let options = rows.compactMap { row -> CarPlaySnapshot.Option? in if case let .option(option) = row { option } else { nil } }
      let cardByID = Dictionary(uniqueKeysWithValues: cards.map { (identity($0.kind), $0) })
      let optionByID = Dictionary(uniqueKeysWithValues: options.map { (identity($0.kind), $0) })
      for item in current.flatMap(\.items).compactMap({ $0 as? CPListItem }) {
        guard let id = (item.userInfo as? ItemTag)?.id else { continue }
        if let card = cardByID[id] {
          update(item, text: card.text, detail: card.detail, tag: tag(card)) {
            image(card.symbol, tint: card.tint, traits: traits)
          }
        } else if let option = optionByID[id] {
          update(item, text: option.text, detail: option.detail, tag: tag(option), isEnabled: option.isEnabled) {
            tile(symbol: option.symbol, tint: option.tint, traits: traits)
          }
        }
      }
    }

    /// The Send Advert choice, the app's confirmation dialog for the car: zero-hop to the nodes
    /// in range or flooded across the mesh, so a flood is always a deliberate choice.
    static func advertSheet(
      onSend: @escaping @MainActor (_ flood: Bool) -> Void,
      onCancel: @escaping @MainActor () -> Void
    ) -> CPActionSheetTemplate {
      CPActionSheetTemplate(
        title: L10n.Tools.Tools.advert,
        message: L10n.Localizable.CarPlay.Advert.Sheet.message,
        actions: [
          CPAlertAction(title: L10n.Tools.Intent.Advert.Reach.zeroHop, style: .default) { _ in
            onSend(false)
          },
          CPAlertAction(title: L10n.Tools.Tools.Advert.FloodConfirm.send, style: .default) { _ in
            onSend(true)
          },
          CPAlertAction(title: L10n.Localizable.Common.cancel, style: .cancel) { _ in
            onCancel()
          },
        ]
      )
    }

    // MARK: - Comm

    /// The Read with Siri row's glyph and the Reply row's.
    static let readSymbol = "speaker.wave.2.fill"
    static let replySymbol = "mic.fill"

    static func identity(_ row: CarPlaySnapshot.ChatRow) -> String {
      "chat:\(row.id.uuidString)"
    }

    /// What a conversation row is and which avatar it shows: a direct chat's colour and emoji
    /// follow its name, so a rename redraws the avatar in place.
    private static func tag(_ row: CarPlaySnapshot.ChatRow) -> ItemTag {
      ItemTag(id: identity(row), image: imageID("avatar", row.symbol, CarPlayAvatar.tint(row.kind, name: row.name)))
    }

    /// A conversation: its avatar as the Chats list draws it, its name, and who wrote last and
    /// when (`CarPlayChatsSource.chatDetail`). A tap opens its screen; there is no field for
    /// message text, so none can reach the car.
    static func chatItem(
      _ row: CarPlaySnapshot.ChatRow,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (UUID) -> Void
    ) -> CPListItem {
      let item = CPListItem(
        text: row.name,
        detailText: row.detail,
        image: avatar(symbol: row.symbol, tint: CarPlayAvatar.tint(row.kind, name: row.name), traits: traits),
        accessoryImage: nil,
        accessoryType: .disclosureIndicator
      )
      item.userInfo = tag(row)
      let id = row.id
      item.handler = { _, completion in
        onSelect(id)
        completion()
      }
      return item
    }

    /// The Comm list, updated in place while the same conversations are listed in the same order.
    static func applyChats(
      _ rows: [CarPlaySnapshot.ChatRow],
      to template: CPListTemplate,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (UUID) -> Void
    ) {
      let rows = Array(rows.prefix(listLimit))
      let current = template.sections
      let sameShape = current.count == (rows.isEmpty ? 0 : 1)
        && (current.first.map { tags($0) == rows.map(identity) } ?? true)
      guard sameShape else {
        template.updateSections(rows.isEmpty ? [] : [CPListSection(items: rows.map { chatItem($0, traits: traits, onSelect: onSelect) })])
        return
      }
      for (item, row) in zip(current.first?.items.compactMap { $0 as? CPListItem } ?? [], rows) {
        update(item, text: row.name, detail: row.detail, tag: tag(row)) {
          avatar(symbol: row.symbol, tint: CarPlayAvatar.tint(row.kind, name: row.name), traits: traits)
        }
      }
    }

    // MARK: - Conversation

    static func readIdentity(_ page: CarPlaySnapshot.ConversationPage) -> String {
      "read:\(page.id.uuidString)"
    }

    static func replyIdentity(_ page: CarPlaySnapshot.ConversationPage) -> String {
      "reply:\(page.id.uuidString)"
    }

    static func identity(_ row: CarPlaySnapshot.MessageRow) -> String {
      "msg:\(row.id.uuidString)"
    }

    private static func leading(image: UIImage?, unread: Bool) -> CPMessageListItemLeadingConfiguration {
      CPMessageListItemLeadingConfiguration(leadingItem: .none, leadingImage: image, unread: unread)
    }

    /// Read with Siri: the conversation handed to Siri, which reads its messages (the unread ones
    /// first) and offers a reply, as the Comm rows did before they opened a screen.
    static func readItem(_ page: CarPlaySnapshot.ConversationPage, traits: UITraitCollection = .current) -> CPMessageListItem {
      let item = CPMessageListItem(
        conversationIdentifier: page.id.uuidString,
        text: L10n.Localizable.CarPlay.Chats.readWithSiri,
        leadingConfiguration: leading(image: tile(symbol: readSymbol, tint: .feature(.comm), traits: traits, size: messageImageSize), unread: page.showsUnread),
        trailingConfiguration: nil,
        detailText: page.readDetail,
        trailingText: nil
      )
      item.userInfo = ItemTag(id: readIdentity(page), image: imageID("tile", readSymbol, .feature(.comm)))
      return item
    }

    /// Reply: Siri's compose for this conversation (`INSendMessageIntent`, the conversation's
    /// identifier as the recipient's handle), dictated and sent by voice. The row's text is the
    /// recipient's name, which Siri says back; "Reply with Siri" is its detail.
    static func replyItem(_ page: CarPlaySnapshot.ConversationPage, traits: UITraitCollection = .current) -> CPMessageListItem {
      let item = CPMessageListItem(
        fullName: page.title,
        phoneOrEmailAddress: page.id.uuidString,
        leadingConfiguration: leading(image: tile(symbol: replySymbol, tint: .feature(.comm), traits: traits, size: messageImageSize), unread: false),
        trailingConfiguration: nil,
        detailText: L10n.Localizable.CarPlay.Chats.reply,
        trailingText: nil
      )
      item.userInfo = ItemTag(id: replyIdentity(page), image: imageID("tile", replySymbol, .feature(.comm)))
      return item
    }

    private static func tag(_ row: CarPlaySnapshot.MessageRow) -> ItemTag {
      ItemTag(id: identity(row), image: imageID("avatar", row.symbol, row.tint))
    }

    /// A message: who wrote it, how it came or how the user's went, and when. A tap has Siri read
    /// this one message (`SiriMessage.identifier` as the conversation identifier), never the screen.
    static func messageItem(_ row: CarPlaySnapshot.MessageRow, traits: UITraitCollection = .current) -> CPMessageListItem {
      let item = CPMessageListItem(
        conversationIdentifier: row.siriIdentifier,
        text: row.sender,
        leadingConfiguration: leading(image: avatar(symbol: row.symbol, tint: row.tint, traits: traits, size: messageImageSize), unread: row.isUnread),
        trailingConfiguration: nil,
        detailText: row.detail,
        trailingText: row.age
      )
      item.userInfo = tag(row)
      return item
    }

    /// The rows the car can show: the Siri rows, then the messages in the room left. None
    /// without Siri.
    static func fittedConversation(_ page: CarPlaySnapshot.ConversationPage) -> (actions: [String], rows: [CarPlaySnapshot.MessageRow]) {
      guard page.hasSiri else { return ([], []) }
      let actions = [readIdentity(page)] + (page.canReply ? [replyIdentity(page)] : [])
      return (actions, Array(page.rows.prefix(max(0, listLimit - actions.count))))
    }

    private static func messageTags(_ section: CPListSection) -> [String] {
      section.items.compactMap { (($0 as? CPMessageListItem)?.userInfo as? ItemTag)?.id }
    }

    /// A conversation's screen: the Siri rows, then the messages under their header. Rows are
    /// updated in place while the same messages are listed; a new message replaces the sections.
    static func applyConversation(
      _ page: CarPlaySnapshot.ConversationPage,
      to template: CPListTemplate,
      traits: UITraitCollection = .current
    ) {
      applyEmpty(page.empty, to: template)
      let (actions, rows) = fittedConversation(page)
      let current = template.sections
      let wanted: [(header: String?, ids: [String])] = actions.isEmpty ? [] : [(nil, actions)]
        + (rows.isEmpty ? [] : [(page.note, rows.map(identity))])
      let sameShape = current.count == wanted.count
        && zip(current, wanted).allSatisfy { $0.header == $1.header && messageTags($0) == $1.ids }
      guard sameShape else {
        var sections: [CPListSection] = []
        if !actions.isEmpty {
          sections.append(CPListSection(items: [readItem(page, traits: traits)] + (page.canReply ? [replyItem(page, traits: traits)] : [])))
        }
        if !rows.isEmpty {
          sections.append(CPListSection(items: rows.map { messageItem($0, traits: traits) }, header: page.note, sectionIndexTitle: nil))
        }
        template.updateSections(sections)
        return
      }
      if let read = current.first?.items.first as? CPMessageListItem {
        if read.detailText != page.readDetail { read.detailText = page.readDetail }
        if read.leadingConfiguration.isUnread != page.showsUnread {
          read.leadingConfiguration = leading(image: tile(symbol: readSymbol, tint: .feature(.comm), traits: traits, size: messageImageSize), unread: page.showsUnread)
        }
      }
      guard current.count > 1 else { return }
      for (item, row) in zip(current[1].items.compactMap { $0 as? CPMessageListItem }, rows) {
        if item.text != row.sender { item.text = row.sender }
        if item.detailText != row.detail { item.detailText = row.detail }
        if item.trailingText != row.age { item.trailingText = row.age }
        let tag = tag(row)
        if (item.userInfo as? ItemTag)?.image != tag.image || item.leadingConfiguration.isUnread != row.isUnread {
          item.leadingConfiguration = leading(image: avatar(symbol: row.symbol, tint: row.tint, traits: traits, size: messageImageSize), unread: row.isUnread)
          item.userInfo = tag
        }
      }
    }

    // MARK: - Nodes

    static func nodeItem(
      _ row: CarPlaySnapshot.NodeRow,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (Data) -> Void
    ) -> CPListItem {
      let item = CPListItem(
        text: row.name,
        detailText: row.detail,
        image: avatar(symbol: row.symbol, tint: row.tint, traits: traits),
        accessoryImage: nil,
        accessoryType: .disclosureIndicator
      )
      item.userInfo = tag(row)
      let key = row.publicKey
      item.handler = { _, completion in
        onSelect(key)
        completion()
      }
      return item
    }

    /// What a node row is and which avatar it shows: a companion's colour and emoji follow its
    /// name, so a rename redraws the avatar in place.
    private static func tag(_ row: CarPlaySnapshot.NodeRow) -> ItemTag {
      ItemTag(id: identity(row), image: imageID("avatar", row.symbol, row.tint))
    }

    static func identity(_ row: CarPlaySnapshot.NodeRow) -> String {
      "node:\(row.publicKey.base64EncodedString())"
    }

    /// A pushed list of nodes: one section, headed by its note when it was cut ("Showing 12 of
    /// 40"). Rows are updated in place while the same nodes are listed in the same order.
    static func applyNodePage(
      _ page: CarPlaySnapshot.NodeListPage,
      to template: CPListTemplate,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (Data) -> Void
    ) {
      applyEmpty(.init(title: page.emptyTitle, subtitle: nil), to: template)
      let rows = Array(page.rows.prefix(listLimit))
      let current = template.sections
      let sameShape = current.count == (rows.isEmpty ? 0 : 1)
        && (current.first.map { section in
          section.header == page.note
            && tags(section) == rows.map(identity)
        } ?? true)
      guard sameShape else {
        template.updateSections(rows.isEmpty ? [] : [CPListSection(
          items: rows.map { nodeItem($0, traits: traits, onSelect: onSelect) },
          header: page.note,
          sectionIndexTitle: nil
        )])
        return
      }
      for (item, row) in zip(current.first?.items.compactMap { $0 as? CPListItem } ?? [], rows) {
        update(item, text: row.name, detail: row.detail, tag: tag(row)) {
          avatar(symbol: row.symbol, tint: row.tint, traits: traits)
        }
      }
    }

    // MARK: - Node groups

    /// Collapsed groups under one heading (none for the first).
    struct NodeGroupSection: Equatable {
      let header: String?
      let rows: [CarPlaySnapshot.NodeGroupRow]
    }

    private static func tag(_ row: CarPlaySnapshot.NodeGroupRow) -> ItemTag {
      ItemTag(id: row.id, image: imageID("avatar", row.symbol, row.tint))
    }

    /// A collapsed group as a row: its glyph on the phone's avatar pebble in its colour, its
    /// name, and its count with the node heard most recently. A tap opens its list.
    static func nodeGroupItem(
      _ row: CarPlaySnapshot.NodeGroupRow,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (CarPlaySnapshot.NodeList) -> Void
    ) -> CPListItem {
      let item = CPListItem(
        text: row.title,
        detailText: row.detail,
        image: avatar(symbol: row.symbol, tint: row.tint, traits: traits),
        accessoryImage: nil,
        accessoryType: .disclosureIndicator
      )
      item.userInfo = tag(row)
      let list = row.list
      item.handler = { _, completion in
        onSelect(list)
        completion()
      }
      return item
    }

    /// The groups trimmed to what the car allows now: `listLimit` rows across at most
    /// `sectionLimit` sections. Both can shrink while driving.
    static func fittedGroups(_ sections: [NodeGroupSection]) -> [NodeGroupSection] {
      var remaining = listLimit
      var result: [NodeGroupSection] = []
      for section in sections.prefix(sectionLimit) where remaining > 0 && !section.rows.isEmpty {
        let rows = Array(section.rows.prefix(remaining))
        remaining -= rows.count
        result.append(.init(header: section.header, rows: rows))
      }
      return result
    }

    /// The Nodes tab's root (or Find's letter groups) as rows, before iOS 26. Counts and ages
    /// update in place while the same groups are listed under the same headings.
    static func applyNodeGroups(
      _ sections: [NodeGroupSection],
      to template: CPListTemplate,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (CarPlaySnapshot.NodeList) -> Void
    ) {
      let sections = fittedGroups(sections)
      let current = template.sections
      let sameShape = current.count == sections.count
        && zip(current, sections).allSatisfy { section, wanted in
          section.header == wanted.header && tags(section) == wanted.rows.map(\.id)
        }
      guard sameShape else {
        template.updateSections(sections.map { section in
          let items = section.rows.map { nodeGroupItem($0, traits: traits, onSelect: onSelect) }
          guard let header = section.header else { return CPListSection(items: items) }
          return CPListSection(items: items, header: header, sectionIndexTitle: nil)
        })
        return
      }
      for (section, wanted) in zip(current, sections) {
        for (item, row) in zip(section.items.compactMap { $0 as? CPListItem }, wanted.rows) {
          update(item, text: row.title, detail: row.detail, tag: tag(row)) {
            avatar(symbol: row.symbol, tint: row.tint, traits: traits)
          }
        }
      }
    }

    /// The screen a node or scan row opens. No edit actions: changing the node list is setup,
    /// which stays on the phone. A node's screen adds a Ping button (`pingButton`).
    /// A read-only screen of lines, two to a row (the first on the left, the next on the right),
    /// so the car shows half as many rows. Builders order their lines in pairs that belong together.
    static func infoDetail(
      title: String,
      rows: [CarPlaySnapshot.InfoRow],
      layout: CPInformationTemplateLayout = .twoColumn
    ) -> CPInformationTemplate {
      CPInformationTemplate(title: title, layout: layout, items: infoItems(rows), actions: [])
    }

    /// The Zero-Hop Ping button under a node's details; "Zero-Hop Ping…" while one is out.
    static func pingButton(handler: @escaping @MainActor (CPTextButton) -> Void) -> CPTextButton {
      CPTextButton(title: L10n.Contacts.Contacts.Detail.ping, textStyle: .confirm, handler: handler)
    }

    static func setPinging(_ button: CPTextButton, _ isPinging: Bool) {
      button.title = L10n.Contacts.Contacts.Detail.ping + (isPinging ? "…" : "")
    }

    /// A node's details in two columns, so all ten lines fit on the car's screen at once.
    static func nodeDetail(_ row: CarPlaySnapshot.NodeRow) -> CPInformationTemplate {
      infoDetail(title: row.name, rows: row.info, layout: .twoColumn)
    }

    /// Title/detail rows for an information template, at most the ten it holds.
    static func infoItems(_ rows: [CarPlaySnapshot.InfoRow]) -> [CPInformationItem] {
      rows.prefix(CarPlaySnapshotBuilder.maxInfoItems).map { CPInformationItem(title: $0.title, detail: $0.detail) }
    }

    /// Replaces an information template's items only when they changed.
    static func applyInfo(_ rows: [CarPlaySnapshot.InfoRow], to template: CPInformationTemplate) {
      let current = template.items.map { CarPlaySnapshot.InfoRow(title: $0.title ?? "", detail: $0.detail ?? "") }
      let wanted = Array(rows.prefix(CarPlaySnapshotBuilder.maxInfoItems))
      if current != wanted {
        template.items = infoItems(wanted)
      }
    }

    // MARK: - Scan

    /// What each row is, so an unchanged list is updated in place rather than rebuilt (which
    /// would reset the driver's focus and scroll position on every scan tick).
    static func identity(_ filter: NodeDiscoveryFilter) -> String {
      "control:\(filter.rawValue)"
    }

    static func identity(_ row: CarPlaySnapshot.ScanResultRow) -> String {
      "result:\(row.publicKey.base64EncodedString())"
    }

    private static func tag(_ control: CarPlaySnapshot.ScanControl) -> ItemTag {
      ItemTag(id: identity(control.filter), image: imageID("tile", control.symbol, control.tint))
    }

    private static func tag(_ row: CarPlaySnapshot.ScanResultRow) -> ItemTag {
      ItemTag(id: identity(row), image: imageID("glyph", signalSymbol, row.tint, level(row.barLevel)))
    }

    /// The Scan list as the car may show it: the sections (header, subtitle, row ids), already
    /// within `listLimit`.
    private struct ScanShape: Equatable {
      struct Section: Equatable {
        let header: String?
        let subtitle: String?
        let ids: [String]
      }

      let sections: [Section]
    }

    /// The result sections trimmed to what the car allows now: the rows left beside the controls,
    /// in the sections left after the controls' own.
    static func fittedScan(_ scan: CarPlaySnapshot.Scan) -> [CarPlaySnapshot.ScanSection] {
      var remaining = max(0, listLimit - scan.controls.count)
      var sections: [CarPlaySnapshot.ScanSection] = []
      for section in scan.sections.prefix(max(0, sectionLimit - 1)) where remaining > 0 && !section.rows.isEmpty {
        let rows = Array(section.rows.prefix(remaining))
        remaining -= rows.count
        sections.append(.init(title: section.title, rows: rows))
      }
      return sections
    }

    private static func scanShape(_ scan: CarPlaySnapshot.Scan) -> ScanShape {
      let controls = ScanShape.Section(header: scan.header, subtitle: scan.subtitle, ids: scan.controls.map { identity($0.filter) })
      return ScanShape(sections: [controls] + fittedScan(scan).map { .init(header: $0.title, subtitle: nil, ids: $0.rows.map(identity)) })
    }

    private static func currentShape(_ template: CPListTemplate) -> ScanShape {
      ScanShape(sections: template.sections.map { section in
        ScanShape.Section(header: section.header, subtitle: section.headerSubtitle, ids: tags(section))
      })
    }

    static func scanSections(
      _ scan: CarPlaySnapshot.Scan,
      traits: UITraitCollection = .current,
      onControl: @escaping @MainActor (NodeDiscoveryFilter, _ stops: Bool) -> Void,
      onResult: @escaping @MainActor (Data) -> Void
    ) -> [CPListSection] {
      let controls = scan.controls.map { control in
        let item = CPListItem(
          text: control.title,
          detailText: control.detail,
          image: tile(symbol: control.symbol, tint: control.tint, traits: traits)
        )
        item.userInfo = tag(control)
        item.isEnabled = control.isEnabled
        let filter = control.filter
        let stops = control.stops
        item.handler = { _, completion in
          onControl(filter, stops)
          completion()
        }
        return item
      }
      var sections = [CPListSection(
        items: controls,
        header: scan.header,
        headerSubtitle: scan.subtitle,
        headerImage: nil,
        headerButton: nil,
        sectionIndexTitle: nil
      )]

      // What the scan heard; a tap shows both directions, place, type and status. Adding one to
      // the radio's node list is setup, so it stays on the phone.
      for section in fittedScan(scan) {
        let items = section.rows.map { row in
          let item = CPListItem(
            text: row.name,
            detailText: row.detail,
            image: image(signalSymbol, tint: row.tint, variableValue: row.barLevel, traits: traits),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
          )
          item.userInfo = tag(row)
          let key = row.publicKey
          item.handler = { _, completion in
            onResult(key)
            completion()
          }
          return item
        }
        sections.append(CPListSection(items: items, header: section.title, sectionIndexTitle: nil))
      }
      return sections
    }

    /// Updates the Scan list in place while its rows and headers are the same ones in the same
    /// order; a change in membership, order or headers replaces the sections.
    static func applyScan(
      _ scan: CarPlaySnapshot.Scan,
      to template: CPListTemplate,
      traits: UITraitCollection = .current,
      onControl: @escaping @MainActor (NodeDiscoveryFilter, _ stops: Bool) -> Void,
      onResult: @escaping @MainActor (Data) -> Void
    ) {
      guard currentShape(template) == scanShape(scan) else {
        template.updateSections(scanSections(scan, traits: traits, onControl: onControl, onResult: onResult))
        return
      }
      let sections = template.sections
      for (item, control) in zip(sections[0].items.compactMap { $0 as? CPListItem }, scan.controls) {
        // A control's tap action can change (start ↔ stop) with the same identity.
        let filter = control.filter
        let stops = control.stops
        item.handler = { _, completion in
          onControl(filter, stops)
          completion()
        }
        update(item, text: control.title, detail: control.detail, tag: tag(control), isEnabled: control.isEnabled) {
          tile(symbol: control.symbol, tint: control.tint, traits: traits)
        }
      }
      let rowByID = Dictionary(scan.results.map { (identity($0), $0) }, uniquingKeysWith: { first, _ in first })
      for item in sections.dropFirst().flatMap(\.items).compactMap({ $0 as? CPListItem }) {
        guard let id = (item.userInfo as? ItemTag)?.id, let row = rowByID[id] else { continue }
        update(item, text: row.name, detail: row.detail, tag: tag(row)) {
          image(signalSymbol, tint: row.tint, variableValue: row.barLevel, traits: traits)
        }
      }
    }

    // MARK: - Network Health

    /// The health sections trimmed to what the car allows now.
    static func fittedHealth(_ health: CarPlaySnapshot.Health) -> [CarPlaySnapshot.HealthSection] {
      var remaining = listLimit
      var sections: [CarPlaySnapshot.HealthSection] = []
      for section in health.sections.prefix(sectionLimit) where remaining > 0 && !section.rows.isEmpty {
        let rows = Array(section.rows.prefix(remaining))
        remaining -= rows.count
        sections.append(.init(title: section.title, rows: rows))
      }
      return sections
    }

    /// The Network Health page for the car: Needs Attention and Healthy, with the fleet ("8
    /// Repeaters · Need Attention 2") as the first section's header, as the app's summary card
    /// heads its page. Each row opens its repeater's status, issues and last advert, read-only.
    static func healthSections(
      _ health: CarPlaySnapshot.Health,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (String) -> Void
    ) -> [CPListSection] {
      fittedHealth(health).enumerated().map { index, section in
        let items = section.rows.map { row in
          let item = CPListItem(
            text: row.name,
            detailText: row.detail,
            image: image(row.symbol, tint: row.tint, traits: traits),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
          )
          item.userInfo = ItemTag(id: row.id, image: imageID("glyph", row.symbol, row.tint))
          let id = row.id
          item.handler = { _, completion in
            onSelect(id)
            completion()
          }
          return item
        }
        let summary = index == 0 ? health.summary : nil
        return CPListSection(
          items: items,
          header: summary?.title ?? section.title,
          headerSubtitle: summary?.detail,
          headerImage: nil,
          headerButton: nil,
          sectionIndexTitle: nil
        )
      }
    }

    // MARK: - Cards (iOS 26)

    /// Whether the Dashboard, Nodes, Spectrum and GPS draw iOS 26's card rows. Off: those cards are
    /// small squares, too much to read at a glance while driving, so every car gets full-width
    /// rows and two-column information screens. The card builders stay for a later, larger card.
    static var usesCards: Bool {
      false
    }

    /// A card row's identity, the cards it shows and the appearance their tints were resolved
    /// for, kept on the item so an update in place only rebuilds a row whose cards changed or
    /// whose car switched between light and dark.
    struct CardRowTag: Equatable {
      let id: String
      let tiles: [CarPlaySnapshot.Tile]
      let style: UIUserInterfaceStyle
      /// Cards or condensed: a row can't change its kind of element in place.
      var rowStyle: CarPlaySnapshot.TileRowStyle = .cards
    }

    @available(iOS 26.0, *)
    static var cardImageSize: CGSize {
      let size = CPListImageRowItemCardElement.maximumImageSize
      return size.width > 0 && size.height > 0 ? size : fallbackImageSize
    }

    /// A rich card's picture fills the card's image slot, at the size the car asks for. Not full
    /// height: a full-height card lays its title and subtitle over the picture on a blur, while
    /// this one sets them in the tinted band under it.
    @available(iOS 26.0, *)
    static var panelImageSize: CGSize {
      let size = CPListImageRowItemCardElement.maximumImageSize
      return size.width > 0 && size.height > 0 ? size : CarPlayPanelImage.fallbackSize
    }

    @available(iOS 26.0, *)
    static var condensedImageSize: CGSize {
      let size = CPListImageRowItemCondensedElement.maximumImageSize
      return size.width > 0 && size.height > 0 ? size : fallbackImageSize
    }

    /// A card: the app's icon tile for its glyph (white on the tint, drawn at the car's scale and
    /// sized to the card's image slot), its name and value, and the tint under its labels,
    /// resolved for the car's appearance. A card with a panel, or a picture of the phone's own
    /// view (`CarPlayPictureImage`), is that picture instead, filling the card, with its name and
    /// value in the tinted band under it, never over it.
    @available(iOS 26.0, *)
    static func cardElement(_ tile: CarPlaySnapshot.Tile, traits: UITraitCollection = .current) -> CPListImageRowItemCardElement {
      let image: UIImage? = if let picture = tile.picture {
        CarPlayPictureImage.image(picture, size: panelImageSize, traits: traits)
      } else if let panel = tile.panel {
        CarPlayPanelImage.image(panel, size: panelImageSize, traits: traits)
      } else {
        Self.tile(symbol: tile.symbol, tint: tile.tint, variableValue: tile.level, traits: traits, size: cardImageSize)
      }
      let element = CPListImageRowItemCardElement(
        image: image ?? UIImage(),
        showsImageFullHeight: false,
        title: tile.title,
        subtitle: tile.subtitle,
        tintColor: tile.tint.color(for: traits.userInterfaceStyle)
      )
      element.isEnabled = tile.isEnabled
      return element
    }

    /// A condensed card: the glyph on its tile (or, for a Nodes group, the phone's avatar), the
    /// name and the value beside it, several to a line.
    @available(iOS 26.0, *)
    static func condensedElement(_ tile: CarPlaySnapshot.Tile, traits: UITraitCollection = .current) -> CPListImageRowItemCondensedElement {
      let image = if tile.isAvatar {
        avatar(symbol: tile.symbol, tint: tile.tint, traits: traits, size: condensedImageSize)
      } else {
        Self.tile(symbol: tile.symbol, tint: tile.tint, variableValue: tile.level, traits: traits, size: condensedImageSize)
      }
      let element = CPListImageRowItemCondensedElement(
        image: image ?? UIImage(),
        imageShape: .roundedRectangle,
        title: tile.title,
        subtitle: tile.subtitle,
        accessorySymbolName: nil
      )
      element.isEnabled = tile.isEnabled
      return element
    }

    /// The row's cards as the elements its style draws.
    @available(iOS 26.0, *)
    static func elements(_ row: CarPlaySnapshot.TileRow, traits: UITraitCollection) -> [CPListImageRowItemElement] {
      switch row.style {
      case .cards: row.tiles.map { cardElement($0, traits: traits) }
      case .condensed: row.tiles.map { condensedElement($0, traits: traits) }
      }
    }

    /// One row of cards. A tap on a card reports the row and the card's index; the controller
    /// looks the card up in the snapshot applied last, so a row updated in place never runs a
    /// stale action.
    @available(iOS 26.0, *)
    static func cardRowItem(
      _ row: CarPlaySnapshot.TileRow,
      traits: UITraitCollection = .current,
      onTile: @escaping @MainActor (_ rowID: String, _ index: Int) -> Void
    ) -> CPListImageRowItem {
      // Every card stays on screen, wrapping to a second line, rather than scrolling sideways.
      let item = switch row.style {
      case .cards:
        CPListImageRowItem(text: row.title, cardElements: row.tiles.map { cardElement($0, traits: traits) }, allowsMultipleLines: true)
      case .condensed:
        CPListImageRowItem(text: row.title, condensedElements: row.tiles.map { condensedElement($0, traits: traits) }, allowsMultipleLines: true)
      }
      item.userInfo = CardRowTag(id: row.id, tiles: row.tiles, style: traits.userInterfaceStyle, rowStyle: row.style)
      let id = row.id
      item.listImageRowHandler = { _, index, completion in
        onTile(id, index)
        completion()
      }
      return item
    }

    @available(iOS 26.0, *)
    static func cardSections(
      _ sections: [CarPlaySnapshot.TileSection],
      traits: UITraitCollection = .current,
      onTile: @escaping @MainActor (_ rowID: String, _ index: Int) -> Void
    ) -> [CPListSection] {
      fittedCards(sections).map { section in
        let items = section.rows.map { cardRowItem($0, traits: traits, onTile: onTile) }
        guard let header = section.header else { return CPListSection(items: items) }
        return CPListSection(items: items, header: header, sectionIndexTitle: nil)
      }
    }

    /// The card sections trimmed to what the car allows now: `listLimit` rows across at most
    /// `sectionLimit` sections.
    static func fittedCards(_ sections: [CarPlaySnapshot.TileSection]) -> [CarPlaySnapshot.TileSection] {
      var remaining = listLimit
      var result: [CarPlaySnapshot.TileSection] = []
      for section in sections.prefix(sectionLimit) where remaining > 0 && !section.rows.isEmpty {
        let rows = Array(section.rows.prefix(remaining))
        remaining -= rows.count
        result.append(.init(header: section.header, rows: rows))
      }
      return result
    }

    /// Updates card rows in place while the sections and rows are the same ones in the same
    /// order: a row whose cards (or the car's appearance) changed gets new elements (the item, and the driver's place in
    /// the list, stay); an unchanged row is left alone. A change in rows or headers replaces the
    /// sections.
    @available(iOS 26.0, *)
    static func applyCards(
      _ sections: [CarPlaySnapshot.TileSection],
      to template: CPListTemplate,
      traits: UITraitCollection = .current,
      onTile: @escaping @MainActor (_ rowID: String, _ index: Int) -> Void
    ) {
      let sections = fittedCards(sections)
      let current = template.sections
      let sameShape = current.count == sections.count
        && zip(current, sections).allSatisfy { section, wanted in
          section.header == wanted.header
            && section.items.map { (($0 as? CPListImageRowItem)?.userInfo as? CardRowTag).map { "\($0.id)|\($0.rowStyle)" } }
            == wanted.rows.map { "\($0.id)|\($0.style)" }
        }
      guard sameShape else {
        template.updateSections(cardSections(sections, traits: traits, onTile: onTile))
        return
      }
      for (section, wanted) in zip(current, sections) {
        for (item, row) in zip(section.items.compactMap { $0 as? CPListImageRowItem }, wanted.rows) {
          let tag = CardRowTag(id: row.id, tiles: row.tiles, style: traits.userInterfaceStyle, rowStyle: row.style)
          guard item.userInfo as? CardRowTag != tag else { continue }
          if item.text != row.title { item.text = row.title }
          item.elements = elements(row, traits: traits)
          item.userInfo = tag
        }
      }
    }

    static func applyHealth(
      _ health: CarPlaySnapshot.Health,
      to template: CPListTemplate,
      traits: UITraitCollection = .current,
      onSelect: @escaping @MainActor (String) -> Void
    ) {
      applyEmpty(.init(title: health.emptyTitle, subtitle: nil), to: template)
      template.updateSections(healthSections(health, traits: traits, onSelect: onSelect))
    }
  }
#endif
