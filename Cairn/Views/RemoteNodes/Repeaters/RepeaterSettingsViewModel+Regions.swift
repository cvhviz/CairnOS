import CairnServices

extension RepeaterSettingsViewModel {
  /// CLI argument when default scope is unset (`region default <null>`).
  private static let firmwareNullToken = "<null>"
  /// `RegionMap.exportTo(reply, 160)` yields at most 159 UTF-8 bytes plus a trailing NUL.
  static let firmwareRegionDumpMaxPayloadBytes = 159
  /// `MAX_REGION_ENTRIES`: the regions a repeater holds, not counting Unscoped.
  static let firmwareRegionTableCapacity = 32
  /// `RegionEntry.name[31]`: a repeater's region names are at most 30 bytes.
  static let firmwareRegionNameMaxBytes = 30
  /// `RegionMap.exportNamesTo(reply, 160, ...)` appends a name only while `used + length + 2 < 160`
  /// and silently skips one that doesn't fit. A reply shorter than this (plus the trailing comma
  /// the firmware drops) still had room for the longest name, so it skipped none.
  static let firmwareRegionNameListCompleteBelowBytes = 160 - 2 - firmwareRegionNameMaxBytes - 1
  /// Substring on a `region default` reply. Set replies use `defaultScopeSetReplyMarker`, which also matches this.
  private static let defaultScopeReplyMarker = "default scope is"
  private static let defaultScopeSetReplyMarker = "default scope is now"

  func fetchRegions() async {
    isLoadingRegions = true
    regionsError = false
    defer { isLoadingRegions = false }

    do {
      let treeResponse = try await helper.sendAndWait("region", timeout: .seconds(10), rawMatching: true)
      guard let dump = Self.parseRegionDump(treeResponse) else {
        originalRegions = nil
        regionsError = true
        return
      }
      let table: RegionTable
      if dump.isTruncated {
        // Reading the rest takes a remote round trip per list and per missing region, so the
        // dumped part shows as a partial table meanwhile. Edits stay off while isLoadingRegions.
        regions = dump.entries
        originalRegions = dump.entries
        unplacedRegionNames = []
        regionsListPartial = true
        table = await fetchRegionsPastDump(dump.entries)
      } else {
        table = RegionTable(entries: dump.entries, unplacedNames: [], isComplete: true)
      }
      regions = table.entries
      originalRegions = table.entries
      unplacedRegionNames = table.unplacedNames
      regionsListPartial = !table.isComplete
    } catch {
      if case RemoteNodeError.timeout = error {
        regionsError = true
      }
      logger.warning("Failed to fetch regions: \(error)")
    }
  }

  func fetchDefaultScope() async {
    guard supportsRegionDefaultScope, !isLoadingDefaultScope else { return }
    isLoadingDefaultScope = true
    defer { isLoadingDefaultScope = false }

    do {
      let defaultReply = try await helper.sendAndWait(
        "region default",
        timeout: .seconds(10),
        rawMatching: true
      )
      if let parsed = Self.parseDefaultScopeReply(defaultReply) {
        applyParsedDefaultScope(parsed)
      } else {
        logger.warning("Unparsed region default reply: \(defaultReply)")
      }
    } catch {
      logger.warning("Failed to fetch default scope: \(error)")
    }
  }

  /// A `region` reply. Firmware writes the tree depth first with `exportTo(reply, 160)`, which
  /// stops mid-line at 159 bytes once a tree is longer (about a dozen regions of the 32 a repeater
  /// holds), so `entries` is then the tree up to its last whole line.
  struct RegionDump: Equatable {
    var entries: [RepeaterRegionEntry]
    /// The reply hit the firmware's cap or lost its end: regions after `entries` may be missing.
    var isTruncated: Bool
  }

  /// Nil for a reply that isn't a region tree (a skipped indent, a space in a name, no root line).
  static func parseRegionDump(_ response: String) -> RegionDump? {
    // Firmware ends each region with LF; a truncated dump's last Unicode scalar is not LF.
    // CRLF is one Swift Character, so the terminator is unicodeScalars.last, not a Character suffix.
    // A whole tree of exactly 159 bytes can't be told from a cut one, so it counts as cut.
    let endsWithLineBreak = response.unicodeScalars.last == "\n"
    let isTruncated = response.utf8.count >= firmwareRegionDumpMaxPayloadBytes || !endsWithLineBreak

    let wholeLines: String
    if endsWithLineBreak {
      wholeLines = response
    } else if let lastLineBreak = response.utf8.lastIndex(of: UInt8(ascii: "\n")) {
      // The cut can split a UTF-8 sequence, but only after the last LF, which is dropped here.
      wholeLines = String(decoding: response.utf8[...lastLineBreak], as: UTF8.self)
    } else {
      return nil
    }

    guard let entries = parseRegionLines(wholeLines), !entries.isEmpty else { return nil }
    return RegionDump(entries: entries, isTruncated: isTruncated)
  }

  private static func parseRegionLines(_ text: String) -> [RepeaterRegionEntry]? {
    var entries: [RepeaterRegionEntry] = []
    var stack: [String] = []
    let lines = text.split(
      omittingEmptySubsequences: true,
      whereSeparator: { $0 == "\n" || $0 == "\r\n" }
    )

    for line in lines {
      let depth = line.prefix(while: { $0 == " " }).count
      var text = String(line.dropFirst(depth))
      guard !text.isEmpty else { return nil }

      let floodAllowed: Bool
      if text.hasSuffix(" F") {
        floodAllowed = true
        text = String(text.dropLast(2))
      } else {
        floodAllowed = false
      }

      let isHome: Bool
      if text.hasSuffix("^") {
        isHome = true
        text = String(text.dropLast(1))
      } else {
        isHome = false
      }

      guard !text.isEmpty, !text.contains(" ") else { return nil }

      guard depth <= stack.count else { return nil }
      stack.removeSubrange(depth...)
      stack.append(text)
      let parentName: String? = depth == 0 ? nil : stack[depth - 1]

      entries.append(RepeaterRegionEntry(
        name: text,
        parentName: parentName,
        depth: depth,
        floodAllowed: floodAllowed,
        isHome: isHome
      ))
    }

    return entries
  }

  /// A `region list allowed|denied` reply: comma-separated names without their '#', or `-none-`.
  struct RegionNameList: Equatable {
    /// The named regions; Unscoped (`*`), which the lists include, is left out.
    var names: [String]
    /// False when the reply was long enough that the firmware may have skipped a name.
    var isComplete: Bool
  }

  /// Nil for a reply that isn't a name list (an error, or a firmware without `region list`).
  static func parseRegionNameList(_ response: String) -> RegionNameList? {
    let text = strippingCLIPrompt(response)
    if text == "-none-" { return RegionNameList(names: [], isComplete: true) }
    guard !text.isEmpty, !text.hasPrefix("Err"), !text.contains(" ") else { return nil }

    let names = text.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
    return RegionNameList(
      names: names.filter { $0 != RepeaterRegionEntry.unscopedName },
      isComplete: text.utf8.count < firmwareRegionNameListCompleteBelowBytes
    )
  }

  /// What `region get <name>` says about a name.
  enum RegionLookup: Equatable {
    /// ` name (parent) F`, without ` (parent)` under Unscoped; a trailing `F` is flood allowed.
    case found(name: String, parentName: String, floodAllowed: Bool)
    /// `Err - unknown region`: no region has the name, or starts with it.
    case notFound
  }

  /// Nil for a reply that isn't a `region get` answer.
  static func parseRegionGetReply(_ response: String) -> RegionLookup? {
    let text = strippingCLIPrompt(response)
    if text.contains("unknown region") { return .notFound }
    guard !text.hasPrefix("Err") else { return nil }

    var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)[...]
    guard let name = tokens.popFirst().map(withoutLeadingHash), !name.isEmpty else { return nil }

    var parentName = RepeaterRegionEntry.unscopedName
    // A name can't hold '(', ')' or a space (`RegionMap::is_name_char`), so this is the parent.
    if let first = tokens.first, first.count > 2, first.hasPrefix("("), first.hasSuffix(")") {
      parentName = withoutLeadingHash(String(first.dropFirst().dropLast()))
      tokens = tokens.dropFirst()
    }

    switch Array(tokens) {
    case []:
      return .found(name: name, parentName: parentName, floodAllowed: false)
    case ["F"]:
      return .found(name: name, parentName: parentName, floodAllowed: true)
    default:
      return nil
    }
  }

  /// Firmware shows names without a leading '#' and matches them that way (`skip_hash`), but
  /// `region get` prints them as stored.
  private static func withoutLeadingHash(_ name: String) -> String {
    name.hasPrefix("#") ? String(name.dropFirst()) : name
  }

  private static func strippingCLIPrompt(_ response: String) -> String {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(">") else { return trimmed }
    return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
  }

  /// A repeater's region table as read: `entries` is the tree, `unplacedNames` the regions it
  /// listed whose place in the tree couldn't be read.
  struct RegionTable: Equatable {
    var entries: [RepeaterRegionEntry]
    var unplacedNames: [String]
    /// Every region on the repeater is in `entries`.
    var isComplete: Bool
  }

  /// Reads the regions a truncated `region` dump left out. `region list allowed` and `region list
  /// denied` together name every region (each is capped at 160 bytes too, but a name costs less
  /// there than in the tree, and the length shows whether one was skipped), and `region get`
  /// gives each missing one's parent. The table is complete only when every name was listed and
  /// placed; a timeout stops the reads, since the rest would wait out the same silence.
  private func fetchRegionsPastDump(_ dumped: [RepeaterRegionEntry]) async -> RegionTable {
    var listed: [String] = []
    var listsComplete = true

    for list in ["allowed", "denied"] {
      do {
        let reply = try await helper.sendAndWait("region list \(list)", rawMatching: true)
        if let parsed = Self.parseRegionNameList(reply) {
          listed += parsed.names
          listsComplete = listsComplete && parsed.isComplete
        } else {
          logger.warning("Unparsed region list \(list) reply: \(reply)")
          listsComplete = false
        }
      } catch {
        logger.warning("Failed to list \(list) regions: \(error)")
        return RegionTable(entries: dumped, unplacedNames: [], isComplete: false)
      }
    }

    let dumpedNames = Set(dumped.map(\.name))
    var missing: [String] = []
    for name in listed where !dumpedNames.contains(name) && !missing.contains(name) {
      missing.append(name)
    }

    var found: [(name: String, parentName: String, floodAllowed: Bool)] = []
    for name in missing {
      do {
        let reply = try await helper.sendAndWait("region get \(name)", rawMatching: true)
        // A name with no exact match answers with a region it starts, so only an exact one counts.
        if case let .found(foundName, parentName, floodAllowed) = Self.parseRegionGetReply(reply),
           foundName == name {
          found.append((name, parentName, floodAllowed))
        } else {
          logger.warning("Unexpected region get \(name) reply: \(reply)")
        }
      } catch {
        logger.warning("Failed to get region \(name): \(error)")
        break
      }
    }

    let merged = Self.mergeRegionTree(dumped: dumped, found: found)
    let placedNames = Set(merged.map(\.name))
    let unplaced = missing.filter { !placedNames.contains($0) }
    return RegionTable(
      entries: merged,
      unplacedNames: unplaced,
      isComplete: listsComplete && unplaced.isEmpty
    )
  }

  /// The dumped tree with the regions read past it added under their parents, depth first in the
  /// firmware's order: each parent's dumped children first, then the others as listed. A region
  /// whose parent isn't in the tree is left out.
  static func mergeRegionTree(
    dumped: [RepeaterRegionEntry],
    found: [(name: String, parentName: String, floodAllowed: Bool)]
  ) -> [RepeaterRegionEntry] {
    var children: [String: [(name: String, floodAllowed: Bool, isHome: Bool)]] = [:]
    for entry in dumped {
      guard let parentName = entry.parentName else { continue }
      children[parentName, default: []].append((entry.name, entry.floodAllowed, entry.isHome))
    }
    let dumpedNames = Set(dumped.map(\.name))
    for region in found where !dumpedNames.contains(region.name) {
      children[region.parentName, default: []].append((region.name, region.floodAllowed, false))
    }

    var merged: [RepeaterRegionEntry] = []
    var placed: Set<String> = []
    func place(_ name: String, parentName: String?, depth: Int, floodAllowed: Bool, isHome: Bool) {
      // A loop in what the repeater reported can't recurse forever.
      guard placed.insert(name).inserted else { return }
      merged.append(RepeaterRegionEntry(
        name: name,
        parentName: parentName,
        depth: depth,
        floodAllowed: floodAllowed,
        isHome: isHome
      ))
      for child in children[name] ?? [] {
        place(child.name, parentName: name, depth: depth + 1, floodAllowed: child.floodAllowed, isHome: child.isHome)
      }
    }
    for root in dumped where root.parentName == nil {
      place(root.name, parentName: nil, depth: 0, floodAllowed: root.floodAllowed, isHome: root.isHome)
    }
    return merged
  }

  /// Unset (`<null>` or `*`) versus a named region.
  enum ParsedDefaultScope: Equatable {
    case cleared
    case named(String)
  }

  /// Nil is an unparsed reply, not an unset scope.
  static func parseDefaultScopeReply(_ response: String) -> ParsedDefaultScope? {
    let lines = response.split(separator: "\n", omittingEmptySubsequences: true)
    guard let last = lines.last else { return nil }
    var line = last.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix(">") {
      line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    guard line.localizedCaseInsensitiveContains(defaultScopeReplyMarker) else { return nil }

    let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let lastToken = tokens.last else { return nil }
    // Firmware treats a default of `*` as unset, same as `<null>`.
    if lastToken == firmwareNullToken || lastToken == RepeaterRegionEntry.unscopedName { return .cleared }
    return .named(lastToken)
  }

  private func applyParsedDefaultScope(_ parsed: ParsedDefaultScope) {
    switch parsed {
    case .cleared:
      defaultScopeName = nil
    case let .named(name):
      defaultScopeName = name
    }
    defaultScopeLoaded = true
  }

  func toggleRegionFlood(name: String) async {
    guard regionsLoaded, !helper.isApplying else { return }
    guard let index = regions.firstIndex(where: { $0.name == name }) else { return }
    let currentlyAllowed = regions[index].floodAllowed
    let command = currentlyAllowed ? "region denyf \(name)" : "region allowf \(name)"

    helper.isApplying = true
    helper.errorMessage = nil

    do {
      let response = try await helper.sendAndWait(command)
      if case .ok = CLIResponse.parse(response) {
        if let liveIndex = regions.firstIndex(where: { $0.name == name }) {
          regions[liveIndex].floodAllowed = !currentlyAllowed
          hasUnsavedRegionChanges = true
        }
        await autoSaveRegions()
      } else {
        helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.Regions.unknownRegion
      }
    } catch {
      helper.errorMessage = error.userFacingMessage
    }

    helper.isApplying = false
  }

  /// `region save` straight after a change the repeater took, so a toggle doesn't live only in RAM
  /// until someone remembers Save: the firmware applies region commands at once but keeps them
  /// across a reboot only once saved. A save that fails leaves the card's Save to Device active.
  func autoSaveRegions() async {
    guard hasUnsavedRegionChanges else { return }
    do {
      let response = try await helper.sendAndWait("region save")
      if case .ok = CLIResponse.parse(response) {
        hasUnsavedRegionChanges = false
      } else {
        logger.warning("Automatic region save refused: \(response)")
      }
    } catch {
      logger.warning("Automatic region save failed: \(error)")
    }
  }

  func setDefaultScope(name: String?) async {
    guard supportsRegionDefaultScope, regionsLoaded, !helper.isApplying else { return }
    if name == RepeaterRegionEntry.unscopedName { return }
    if name == defaultScopeName { return }

    let argument = name ?? Self.firmwareNullToken
    let command = "region default \(argument)"

    helper.isApplying = true
    helper.errorMessage = nil

    do {
      let response = try await helper.sendAndWait(command, rawMatching: true)
      if response.contains(Self.defaultScopeSetReplyMarker) {
        defaultScopeName = name
        defaultScopeLoaded = true
        if let name, let index = regions.firstIndex(where: { $0.name == name }) {
          regions[index].floodAllowed = true
        }
        hasUnsavedRegionChanges = true
        await autoSaveRegions()
      } else {
        helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.Regions.unknownRegion
      }
    } catch {
      helper.errorMessage = error.userFacingMessage
    }

    helper.isApplying = false
  }

  enum AddRegionError: Error, Equatable {
    /// Not sent, or refused by the repeater. `reason` is what to tell the user; nil when the
    /// region list isn't ready or the name is empty, and nothing more needs saying.
    case rejected(reason: String?)
  }

  func addRegion(name: String, parent: RepeaterRegionEntry.Parent) async throws {
    guard regionsLoaded, !helper.isApplying else { throw AddRegionError.rejected(reason: nil) }

    // Sent as firmware would store it (`RegionNameValidator.cleanedName`); a repeater matches
    // names without their '#' anyway.
    let cleaned = RegionNameValidator.cleanedName(name)
    let knownNames = regions.map(\.name) + unplacedRegionNames
    if let validationError = RegionNameValidator.validateForRepeater(cleaned, existingRegions: knownNames) {
      let reason: String
      switch validationError {
      case .empty:
        throw AddRegionError.rejected(reason: nil)
      case .invalidCharacters:
        reason = L10n.RemoteNodes.RemoteNodes.Settings.Regions.invalidName
      case .privateRegion:
        reason = L10n.RemoteNodes.RemoteNodes.Settings.Regions.privateName
      case let .tooLong(maxBytes):
        reason = L10n.RemoteNodes.RemoteNodes.Settings.Regions.nameTooLong(maxBytes)
      case .duplicate:
        reason = L10n.RemoteNodes.RemoteNodes.Settings.Regions.duplicate
      }
      helper.errorMessage = reason
      throw AddRegionError.rejected(reason: reason)
    }

    let command: String
    let parentName: String

    switch parent {
    case .unscoped:
      command = "region put \(cleaned)"
      parentName = RepeaterRegionEntry.unscopedName
    case let .named(namedParent):
      guard regions.contains(where: { $0.name == namedParent }) else {
        let reason = L10n.RemoteNodes.RemoteNodes.Settings.Regions.parentMissing
        helper.errorMessage = reason
        throw AddRegionError.rejected(reason: reason)
      }
      command = "region put \(cleaned) \(namedParent)"
      parentName = namedParent
    }

    helper.isApplying = true
    helper.errorMessage = nil

    // `region put` on a name the repeater already has moves that region under the new parent and
    // turns its flood on. With part of the table unread, the duplicate check above can't rule that
    // out, so the repeater is asked first, and a name it can't vouch for isn't sent.
    if regionsListPartial {
      if let refusal = await partialTableRefusal(for: cleaned) {
        helper.errorMessage = refusal
        helper.isApplying = false
        throw AddRegionError.rejected(reason: refusal)
      }
    }

    let reason: String
    do {
      let response = try await helper.sendAndWait(command)
      if case .ok = CLIResponse.parse(response) {
        let liveParentIndex = regions.firstIndex(where: { $0.name == parentName })
        let depth = liveParentIndex.map { regions[$0].depth + 1 } ?? 1
        let newEntry = RepeaterRegionEntry(
          name: cleaned,
          parentName: parentName,
          depth: depth,
          floodAllowed: true,
          isHome: false
        )
        if let liveParentIndex {
          let parentDepth = regions[liveParentIndex].depth
          var insertIndex = liveParentIndex + 1
          while insertIndex < regions.count, regions[insertIndex].depth > parentDepth {
            insertIndex += 1
          }
          regions.insert(newEntry, at: insertIndex)
        } else {
          regions.append(newEntry)
        }
        hasUnsavedRegionChanges = true
        await autoSaveRegions()
        helper.isApplying = false
        return
      }
      reason = Self.putRefusalReason(response)
    } catch {
      helper.errorMessage = error.userFacingMessage
      helper.isApplying = false
      throw error
    }

    helper.errorMessage = reason
    helper.isApplying = false
    throw AddRegionError.rejected(reason: reason)
  }

  /// Why a repeater refused `region put` (CommonCLI `region put`).
  static func putRefusalReason(_ response: String) -> String {
    if response.contains("unknown parent") {
      // The parent was in the list when the add began, so it went since (another admin, a reload).
      return L10n.RemoteNodes.RemoteNodes.Settings.Regions.parentMissing
    }
    if response.contains("unable to put") {
      // `putRegion` fails on a full table, a refused character or a region put under itself. The
      // name check rules out the other two, so the table is full.
      return L10n.RemoteNodes.RemoteNodes.Settings.Regions.tableFull(RepeaterSettingsViewModel.firmwareRegionTableCapacity)
    }
    return L10n.RemoteNodes.RemoteNodes.Settings.Regions.addFailed
  }

  /// Asks the repeater whether `name` is free, for a table read only in part. Nil when it is; the
  /// reason to refuse the add otherwise.
  private func partialTableRefusal(for name: String) async -> String? {
    do {
      let reply = try await helper.sendAndWait("region get \(name)", rawMatching: true)
      switch Self.parseRegionGetReply(reply) {
      case .notFound:
        return nil
      case let .found(foundName, _, _):
        // Without an exact match, firmware answers with a region the name starts.
        guard foundName == name else { return nil }
        if !unplacedRegionNames.contains(name) {
          unplacedRegionNames.append(name)
        }
        return L10n.RemoteNodes.RemoteNodes.Settings.Regions.existsOnRepeater
      case nil:
        logger.warning("Unexpected region get \(name) reply: \(reply)")
      }
    } catch {
      logger.warning("Failed to check region \(name) before put: \(error)")
    }
    return L10n.RemoteNodes.RemoteNodes.Settings.Regions.unconfirmedName
  }

  func removeRegion(name: String) async {
    guard regionsLoaded, !helper.isApplying else { return }
    helper.isApplying = true
    helper.errorMessage = nil
    let wasDefault = defaultScopeName == name

    do {
      let response = try await helper.sendAndWait("region remove \(name)")
      if case .ok = CLIResponse.parse(response) {
        regions.removeAll { $0.name == name }
        hasUnsavedRegionChanges = true
        if wasDefault, supportsRegionDefaultScope {
          let clearReply = try await helper.sendAndWait(
            "region default \(Self.firmwareNullToken)",
            rawMatching: true
          )
          if clearReply.contains(Self.defaultScopeSetReplyMarker) {
            defaultScopeName = nil
          } else {
            helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.Regions.unknownRegion
          }
        }
        await autoSaveRegions()
      } else if response.contains("not empty") {
        helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.Regions.notEmpty
      } else {
        helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.Regions.removeFailed
      }
    } catch {
      helper.errorMessage = error.userFacingMessage
    }

    helper.isApplying = false
  }

  func saveRegions() async {
    guard !helper.isApplying else { return }
    helper.isApplying = true
    helper.errorMessage = nil

    do {
      let response = try await helper.sendAndWait("region save")
      if case .ok = CLIResponse.parse(response) {
        hasUnsavedRegionChanges = false
        await helper.flashSuccess(
          setApplying: { helper.isApplying = $0 },
          setSuccess: { regionsSaveSuccess = $0 }
        )
        return
      } else {
        helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.Regions.saveFailed
      }
    } catch {
      helper.errorMessage = error.userFacingMessage
    }

    helper.isApplying = false
  }
}
