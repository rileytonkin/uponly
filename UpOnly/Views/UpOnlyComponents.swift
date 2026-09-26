import SwiftUI
import os

// Small views, styles and dashboard arithmetic shared across pages.

struct UpOnlyAmount: View {
    @Environment(UpOnlySession.self) private var session
    var value: Decimal
    var signed = false
    var tint: Color = .primary
    /// Shows cents, in secondary colour so the dollars still read first: "$13,710.42".
    var cents = false
    var body: some View {
        // Privacy mode shows the stand-in figure in the same style, and tells VoiceOver it's hidden.
        if let shown = session.privacyMode ? session.standInFactor.map({ value * $0 }) : value {
            let parts = Self.parts(shown, signed: signed, cents: cents)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(parts.sign + "$").fixedSize(horizontal: false, vertical: true)
                        .font(.system(size: 24, weight: .bold))
                    Text(parts.whole).fixedSize(horizontal: false, vertical: true)
                        .font(.system(size: 40, weight: .bold).monospacedDigit()).tracking(-1.3)
                    if !parts.fraction.isEmpty {
                        Text(parts.fraction).font(.system(size: 40, weight: .bold).monospacedDigit()).tracking(-1.3).foregroundStyle(.secondary)
                    }
                }.fixedSize()
                    // The digits roll to a new figure as prices update or the page changes, as the system's do.
                    .contentTransition(.numericText(value: NSDecimalNumber(decimal: shown).doubleValue))
                    .animation(.snappy(duration: 0.4), value: shown)
                Text(parts.sign + "$" + parts.whole + parts.fraction).fixedSize(horizontal: false, vertical: true).font(.system(size: 24, weight: .bold).monospacedDigit())
            }.foregroundStyle(tint)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(session.privacyMode ? "Hidden value" : parts.sign + "$" + parts.whole + parts.fraction)
        } else {
            Text("••••").font(.system(size: 40, weight: .bold)).foregroundStyle(.primary)
                .accessibilityLabel("Hidden value")
        }
    }
    /// "−", "13,710" and ".42" (or "" without cents).
    static func parts(_ value: Decimal, signed: Bool, cents: Bool) -> (sign: String, whole: String, fraction: String) {
        let sign = value < 0 ? "−" : signed && value > 0 ? "+" : ""
        // A million or more is short ("1.25M"), all in the figure's own colour.
        if let short = UpOnlyFormat.compact(value) { return (sign, short, "") }
        let text = (cents ? UpOnlyFormat.exactMoney(abs(value)) : UpOnlyFormat.money(abs(value))).replacingOccurrences(of: "$", with: "")
        guard cents, let dot = text.lastIndex(of: ".") else { return (sign, text, "") }
        return (sign, String(text[..<dot]), String(text[dot...]))
    }
}

/// Privacy mode's stand-in figures: every amount scaled by one factor, fixed per vault and unknown to anyone looking,
/// so the figures look real and small, agree with each other, and keep their percentages.
nonisolated enum UpOnlyStandIn {
    /// A vault-random base (6,000 to 12,000) over the power of ten just above the real total: the stand-in total lands
    /// between about 600 and 12,000 and moves as the real one does, without saying what that is.
    static func factor(total: Decimal?, vaultID: UUID) -> Decimal {
        let seed = vaultID.uuidString.unicodeScalars.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1.value)) &* 1_099_511_628_211 }
        let base = Decimal(6000 + Int(seed % 6000))
        let magnitude = max(abs(NSDecimalNumber(decimal: total ?? 100_000).doubleValue), 1)
        return base / Decimal(pow(10, ceil(log10(magnitude))))
    }
    // Symbols with a country prefix count too ("CA$", "A$", "R$", "HK$", "CN¥"), as do codes before the number ("CHF 1,234").
    // Either may be short, with a suffix: "$1.25M", "3.71B PEPE".
    private static let money = try! NSRegularExpression(pattern: #"(?<![\w.,])((?:[A-Z]{1,3})?[$£€¥₹₩₫₱₪₦₴₺₽฿]|[A-Z]{3}[\s\u00A0])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)([MBT](?![A-Za-z]))?"#)
    // A number before any ticker (one letter, or starting with a digit: "S", "1INCH"), a coin's name ("Arbitrum") or a unit.
    private static let quantity = try! NSRegularExpression(pattern: #"(?<![\w.,$£€¥₹])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)([MBT])?(?=[\s\u00A0](?:[A-Z0-9][A-Za-z0-9]{0,15}|ozt|kg|g)\b)"#)
    // A bare number on its own ("25,000,000"), as a form reads back what was typed.
    private static let bare = try! NSRegularExpression(pattern: #"^[\s\u00A0]*[−-]?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)[\s\u00A0]*$"#)
    /// The same text with each amount and quantity scaled: "$1,234.56", "£20.00", "CHF 1,234.00", "0.1 BTC", "2 ozt".
    /// Percentages, dates and counts are left alone.
    static func scale(_ text: String, by factor: Decimal) -> String {
        var result = text
        // A form reading back what was typed keeps it written out; amounts and quantities are shortened like any others.
        for (expression, group, isQuantity, shortens) in [(money, 2, false, true), (quantity, 1, true, true), (bare, 1, true, false)] {
            let source = result as NSString
            for match in expression.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed() {
                var range = match.range(at: group)
                let original = source.substring(with: range)
                guard var value = Decimal(string: original.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) else { continue }
                // A short figure is scaled whole ("1.25M" is 1,250,000) and written the way any figure that size is.
                let suffixRange = group + 1 < match.numberOfRanges ? match.range(at: group + 1) : NSRange(location: NSNotFound, length: 0)
                let suffix = suffixRange.location == NSNotFound ? "" : source.substring(with: suffixRange)
                if !suffix.isEmpty {
                    value *= suffix == "T" ? 1_000_000_000_000 : suffix == "B" ? 1_000_000_000 : 1_000_000
                    range = NSUnionRange(range, suffixRange)
                }
                let decimals = suffix.isEmpty ? original.split(separator: ".").dropFirst().first?.count ?? 0 : 2
                let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = decimals; formatter.maximumFractionDigits = isQuantity ? max(decimals, 4) : decimals
                let scaled = value * factor
                let text = (shortens ? UpOnlyFormat.compact(scaled) : nil) ?? formatter.string(from: NSDecimalNumber(decimal: scaled)) ?? original
                result = (result as NSString).replacingCharacters(in: range, with: text)
            }
        }
        return result
    }
}

/// Plain labels with the chosen one in a soft pill that slides to the next choice, as market apps do: the chart's
/// range and any other small choice of period.
struct UpOnlySegments<Value: Hashable>: View {
    let options: [(value: Value, title: String, spoken: String)]
    @Binding var selection: Value
    var label: String
    @Namespace private var pill
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let chosen = selection == option.value
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: 11, weight: chosen ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background { if chosen { Capsule().fill(Color.white.opacity(0.12)).matchedGeometryEffect(id: "pill", in: pill) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityLabel(option.spoken).accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }.animation(.snappy(duration: 0.25), value: selection)
            .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// Every search: a filled pill with the magnifier, and a clear button once there's text.
struct UpOnlySearchField: View {
    var placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }.font(UpOnlyType.row).padding(.horizontal, 12).padding(.vertical, 8)
            .background(UpOnlyContentSurface.fill, in: Capsule())
    }
}

/// A figure in its own tile, as market apps lay out a holding's numbers: a quiet title, the figure large, and an
/// optional line under it (a move, a note). Tiles sit two to a row.
struct UpOnlyStatTile: View {
    var title: String
    var value: String
    var isPrivate = false
    var detail: String? = nil
    var detailTint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(UpOnlyType.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Group { if isPrivate { UpOnlyPrivateText(value) } else { Text(value) } }
                .font(.system(size: 16, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText()).animation(.snappy(duration: 0.35), value: value)
            if let detail {
                Text(detail).font(UpOnlyType.caption.weight(.medium).monospacedDigit()).foregroundStyle(detailTint ?? .secondary).lineLimit(1)
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(UpOnlyContentSurface())
            .accessibilityElement(children: .combine)
    }
}

/// A change as an outlined pill, "↑ 21.0%", green up and red down, as on the admin dashboard.
struct UpOnlyChangeBadge: View {
    var fraction: Decimal
    var body: some View {
        let rounded = UpOnlyFormat.roundedPercent(fraction)
        let tint = UpOnlyTint.signed(rounded)
        HStack(spacing: 2) {
            if rounded != 0 { Image(systemName: rounded > 0 ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .bold)) }
            Text(UpOnlyFormat.magnitude(fraction)).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }.foregroundStyle(tint).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.75), lineWidth: 1))
            .accessibilityElement(children: .ignore).accessibilityLabel(UpOnlyFormat.percent(fraction))
    }
}

/// A coin or metal at a glance. The top coins' logos ship with the app, so none is ever fetched (that would tell a
/// server what you hold); any other coin shows its ticker's first letter on a colour fixed by its id, and metals use
/// the bar icon in their own colour.
struct UpOnlyAssetBadge: View {
    var assetID: String
    var symbol: String
    var size: CGFloat = 24
    static let palette: [Color] = [
        Color(red: 0.95, green: 0.58, blue: 0.10), Color(red: 0.38, green: 0.49, blue: 0.92), Color(red: 0.16, green: 0.66, blue: 0.56),
        Color(red: 0.86, green: 0.30, blue: 0.36), Color(red: 0.55, green: 0.36, blue: 0.86), Color(red: 0.13, green: 0.60, blue: 0.84),
        Color(red: 0.84, green: 0.44, blue: 0.70), Color(red: 0.40, green: 0.62, blue: 0.24), Color(red: 0.62, green: 0.48, blue: 0.30),
        Color(red: 0.36, green: 0.44, blue: 0.54)]
    /// Coins people recognise by colour keep it; others get a stable index from the id's characters (Swift's
    /// `hashValue` changes between launches).
    static let known: [String: Int] = ["bitcoin": 0, "ethereum": 1, "tether": 2, "usd-coin": 5, "solana": 4, "ripple": 9, "cardano": 5, "dogecoin": 8]
    static func colourIndex(_ id: String) -> Int { known[id] ?? id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count }
    static func metalColour(_ metal: PreciousMetal) -> Color {
        switch metal {
        case .gold: Color(red: 0.83, green: 0.66, blue: 0.22)
        case .silver: Color(red: 0.55, green: 0.58, blue: 0.62)
        case .platinum: Color(red: 0.45, green: 0.52, blue: 0.58)
        case .palladium: Color(red: 0.58, green: 0.50, blue: 0.44)
        }
    }
    var body: some View {
        if let metal = PreciousMetal.asset(CanonicalAssetID(rawValue: assetID)) {
            UpOnlySymbolBadge(symbol: TrackedKind.metals.symbol, tint: Self.metalColour(metal), size: size)
        } else if let logo = NSImage(named: "CoinLogos/" + assetID) {
            Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size).clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            let tint = Self.palette[Self.colourIndex(assetID)]
            Text(assetID == "bitcoin" ? "₿" : String(symbol.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(tint)
                .frame(width: size, height: size).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// A label and a value on one line, or stacked when they don't fit. VoiceOver reads "<label>, <value>".
struct UpOnlyValueRow: View {
    @Environment(UpOnlySession.self) private var session
    var label: String
    var value: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).fixedSize().foregroundStyle(Color.secondary)
            Spacer(minLength: 8)
            UpOnlyPrivateText(value).fixedSize().monospacedDigit().foregroundStyle(.primary)
        }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).fixedSize(horizontal: false, vertical: true).foregroundStyle(Color.secondary)
                UpOnlyPrivateText(value).fixedSize(horizontal: false, vertical: true).monospacedDigit().foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.font(UpOnlyType.row).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityValue(session.privacyMode ? "Hidden value" : value)
    }
}


struct UpOnlyPrivacyButton: View {
    var inMenu = false
    var size: CGFloat = 32
    /// A round glass button of its own, beside the page's + and "…", rather than a small icon by the title.
    var glass = false
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        if inMenu { button }
        else if glass { button.buttonStyle(.plain).glassEffect(.regular, in: .circle) }
        else { button.buttonStyle(UpOnlyToolbarButtonStyle(size: size)) }
    }
    // Never disabled while a save runs: hiding values has to work at once, even during a history rebuild.
    private var button: some View {
        Button {
            Task {
                let token = session.sessionToken
                do { try await session.togglePrivacyMode() }
                catch {
                    if session.sessionToken == token, session.state == .unlocked {
                        session.message = "Couldn’t save privacy mode. Please try again."
                    }
                }
            }
        } label: {
            if inMenu { Label(session.privacyMode ? "Show values" : "Hide values", systemImage: session.privacyMode ? "eye.slash" : "eye") }
            else {
                // The eye closes and opens as the system draws it.
                Image(systemName: session.privacyMode ? "eye.slash" : "eye").font(.system(size: glass ? 14 : 13, weight: glass ? .semibold : .medium))
                    .contentTransition(.symbolEffect(.replace)).animation(.snappy, value: session.privacyMode)
                    .frame(width: glass ? 32 : 16, height: glass ? 32 : 16).contentShape(Circle())
            }
        }.foregroundStyle(session.privacyMode ? UpOnlyTint.brand : inMenu ? Color.primary : Color.secondary)
            .accessibilityLabel(session.privacyMode ? "Show values" : "Hide values")
            .accessibilityValue(session.privacyMode ? "Privacy mode on" : "Privacy mode off")
            .accessibilityIdentifier("PrivacyMode")
            .help(session.privacyMode ? "Show values (⇧⌘P)" : "Hide values (⇧⌘P)")
            // One shortcut: the eye by the title is on every dashboard page, so the menu item doesn't register another.
            .keyboardShortcut(inMenu ? nil : KeyboardShortcut("p", modifiers: [.command, .shift]))
    }
}

/// One bank the app knows, from the small bundled catalog of well-known banks, neobanks and brokers, each with its own
/// app icon. Nothing is fetched; the list ships with the app.
nonisolated struct BankCatalogEntry: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let aliases: [String]
    /// ISO country codes, or "GLOBAL".
    let countries: [String]
    let kind: String
    let logo: Bool
    /// "United Kingdom", "Neobank · Brazil", "Worldwide": where it is, for telling same-named banks apart.
    var caption: String {
        let places = countries.contains("GLOBAL") ? ["Worldwide"] : countries.prefix(2).compactMap { Locale.current.localizedString(forRegionCode: $0) }
        let place = places.joined(separator: ", ") + (countries.count > 2 && !countries.contains("GLOBAL") ? " and more" : "")
        let kinds = ["neobank": "Neobank", "broker": "Broker", "wallet": "Wallet", "crypto": "Crypto exchange", "credit-union": "Credit union",
                     "building-society": "Building society", "card": "Cards", "mobile-money": "Mobile money", "cooperative": "Cooperative"]
        return [kinds[kind], place.isEmpty ? nil : place].compactMap { $0 }.joined(separator: " · ")
    }
    /// The currency an account here most likely holds: this Mac's region's if the bank is there, else its first country's.
    var currency: String? {
        let region = Locale.current.region?.identifier
        guard let country = countries.first(where: { $0 == region }) ?? countries.first(where: { $0 != "GLOBAL" }) else { return nil }
        return Locale(identifier: "en_" + country).currency?.identifier
    }
}
nonisolated enum BankCatalog {
    static let all: [BankCatalogEntry] = {
        guard let data = NSDataAsset(name: "BankCatalog")?.data else { return [] }
        return (try? JSONDecoder().decode([BankCatalogEntry].self, from: data)) ?? []
    }()
    /// Lower-case words without accents, so "Itaú" and "itau" match.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    /// Words too common to name a bank on their own ("Joint", "Savings", "First").
    private static let common: Set<String> = ["bank", "banco", "banca", "banque", "banks", "savings", "saving", "cash", "card", "cards", "wallet",
        "pay", "money", "credit", "debit", "first", "national", "capital", "personal", "business", "joint", "account", "accounts", "current",
        "checking", "main", "everyday", "international", "global", "trust", "union", "federal", "mutual", "digital", "direct", "online", "mobile",
        "one", "plus", "prime", "united", "community", "citizens", "peoples", "state", "city", "commerce", "investment", "invest", "finance",
        "financial", "group", "home", "usd", "eur", "gbp", "the", "de", "do", "da", "del", "la", "le", "of", "and", "y", "e"]
    /// Each bank's name and aliases as word sequences, longest first so "Bank of America" wins over "America".
    private static let phrases: [(words: [String], index: Int)] = {
        var list: [(words: [String], index: Int)] = []
        for (index, bank) in all.enumerated() {
            for text in [bank.name] + bank.aliases {
                let phrase = words(text)
                // A lone short or everyday word would match far too much.
                if phrase.isEmpty || (phrase.count == 1 && (phrase[0].count < 3 || common.contains(phrase[0]))) { continue }
                list.append((phrase, index))
            }
        }
        return list.sorted { $0.words.count != $1.words.count ? $0.words.count > $1.words.count : $0.index < $1.index }
    }()
    /// Each bank's name and aliases as words, worked out once for typing suggestions.
    private static let searchable: [(name: [String], aliases: [[String]])] = all.map { (words($0.name), $0.aliases.map(words)) }
    private static let cache = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
    /// The bank an account called `name` is at: a bank's name or alias as whole words in it ("Monzo Joint" is Monzo).
    static func bank(named name: String) -> BankCatalogEntry? {
        if let hit = cache.withLock({ $0[name] }) { return hit < 0 ? nil : all[hit] }
        let account = words(name)
        let exact = all.firstIndex { words($0.name) == account }
        let found = exact ?? phrases.first { phrase in
            account.count >= phrase.words.count && (0...(account.count - phrase.words.count)).contains { Array(account[$0..<($0 + phrase.words.count)]) == phrase.words }
        }?.index
        cache.withLock { $0[name] = found ?? -1 }
        return found.map { all[$0] }
    }
    /// Banks for what's being typed: names (then aliases) whose words start with it, banks in this Mac's region
    /// first, then the biggest.
    static func suggestions(_ query: String, limit: Int = 5) -> [BankCatalogEntry] {
        let typed = words(query)
        guard !typed.isEmpty else { return [] }
        let region = Locale.current.region?.identifier, prefix = typed.joined(separator: " ")
        func score(_ target: [String]) -> Int {
            if target.joined(separator: " ").hasPrefix(prefix) { return 3 }
            // Every typed word starts some word of the name, in order: "bank am" finds "Bank of America".
            var position = 0
            for word in typed {
                guard let next = target[position...].firstIndex(where: { $0.hasPrefix(word) }) else { return 0 }
                position = next + 1
                if position > target.count { return 0 }
            }
            return 2
        }
        let ranked = all.enumerated().compactMap { index, bank -> (bank: BankCatalogEntry, score: Int, index: Int)? in
            let best = max(score(searchable[index].name), searchable[index].aliases.contains { score($0) > 0 } ? 1 : 0)
            guard best > 0 else { return nil }
            return (bank, best * 2 + (region.map { bank.countries.contains($0) } == true ? 1 : 0), index)
        }
        return ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(limit).map(\.bank)
    }
}
/// The logo for an account, matched from its name; a synced account comes from Wise.
nonisolated enum BankLogos {
    static func logo(for name: String, synced: Bool = false) -> String? {
        if synced { return "wise" }
        return BankCatalog.bank(named: name).flatMap { $0.logo ? $0.id : nil }
    }
}
/// A bank at a glance: its logo when it's one the app knows, else a picture (a Wise profile's), else the bank symbol.
struct UpOnlyBankBadge: View {
    var name: String
    var synced = false
    var image: Data? = nil
    var size: CGFloat = 24
    var body: some View {
        if let logo = BankLogos.logo(for: name, synced: synced), let picture = NSImage(named: "BankLogos/" + logo) {
            Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        } else if let image { UpOnlyProfileImage(data: image, name: name, size: size) }
        else { UpOnlySymbolBadge(symbol: TrackedKind.banks.symbol, size: size) }
    }
}

/// Replace the text, not merely its pixels, so hidden values are absent from accessibility.
struct UpOnlyPrivateText: View {
    @Environment(UpOnlySession.self) private var session
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View {
        if session.privacyMode {
            // The stand-in figures, or dots before a vault is open.
            Text(session.standInFactor.map { UpOnlyStandIn.scale(value, by: $0) } ?? "••••").accessibilityLabel("Hidden value")
        } else { Text(value) }
    }
}

/// Native secure entry retains editing and paste without exposing a financial amount.
struct UpOnlyValueField: View {
    @Environment(UpOnlySession.self) private var session
    let placeholder: String
    @Binding var text: String
    init(_ placeholder: String, text: Binding<String>) { self.placeholder = placeholder; _text = text }
    var body: some View {
        if session.privacyMode { SecureField(placeholder, text: $text) }
        else { TextField(placeholder, text: $text, axis: .vertical) }
    }
}

// Equal hit regions and one shared glass surface keep toolbar actions aligned.
struct UpOnlyToolbarButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: size, height: size)
            .contentShape(Rectangle())
            .background(.primary.opacity(configuration.isPressed ? 0.14 : 0), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// macOS substitutes a native menu label, so padding inside its label closure is
// discarded. Size the menu itself before applying its glass surface.
struct UpOnlyPillMenu: ViewModifier {
    /// 26 pt for menus that act; 22 pt for the quieter pill that names what a page's figure covers.
    var height: CGFloat = 26
    func body(content: Content) -> some View {
        content.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, height < 26 ? 9 : 10).frame(minHeight: height)
            .glassEffect(.regular, in: .capsule)
    }
}
/// A flat list row: a soft highlight under the pointer, darker while pressed, lightly shaded while selected.
struct UpOnlyRowButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration, selected: selected) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label.background {
                // Inset inside the card: clear of its edges and of the lines between rows.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.08) : selected ? Color.primary.opacity(0.08) : hovering && isEnabled ? Color.primary.opacity(0.05) : .clear)
                    .padding(.horizontal, -7).padding(.vertical, 3)
            }.onHover { hovering = $0 }
        }
    }
}
/// Every list row, on the dashboard and in Manage alike: a badge, the name over a caption, a value over its change or a
/// second amount, and a chevron or a quiet "…". The row itself does the obvious thing; anything else is in the menu or
/// a right-click.
struct UpOnlyRow<Badge: View, Options: View>: View {
    var title: String
    var caption: String? = nil
    /// The caption is an amount (a balance, a quantity), hidden in privacy mode.
    var captionIsPrivate = false
    var value: String? = nil
    /// The row's own move over the chart's range, as a fraction, under the value.
    var change: Decimal? = nil
    /// A second amount under the value, such as a foreign balance under its dollar value. Hidden in privacy mode.
    var valueDetail: String? = nil
    var chevron = false
    /// Lightly shaded: the page showing, or the account a company page is focused on.
    var selected = false
    /// Right-click options, such as updating a balance.
    var options: [(title: String, action: () -> Void)] = []
    var action: (() -> Void)? = nil
    @ViewBuilder var badge: () -> Badge
    @ViewBuilder var menu: () -> Options
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { action?() } label: {
                    HStack(spacing: 10) {
                        badge()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(UpOnlyType.row.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                            if let caption {
                                Group { if captionIsPrivate { UpOnlyPrivateText(caption) } else { Text(caption) } }
                                    .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(minWidth: 100, alignment: .leading)  // a huge amount shrinks before the name disappears
                        Spacer(minLength: 8)
                        if let value {
                            // Value over its change, as in Delta, so the name keeps the width.
                            VStack(alignment: .trailing, spacing: 1) {
                                // Only a very long amount may shrink; SwiftUI otherwise sometimes shrinks short ones for no reason.
                                // A figure is bold; words in its place ("Balance needed", "Not reported") stay quiet.
                                let figure = value.contains(where: \.isNumber)
                                UpOnlyPrivateText(value).font(figure ? UpOnlyType.row.weight(.semibold).monospacedDigit() : UpOnlyType.body)
                                    .foregroundStyle(figure ? .primary : .secondary).lineLimit(1)
                                    .contentTransition(.numericText()).animation(.snappy(duration: 0.35), value: value)
                                    .minimumScaleFactor(value.count > 13 ? 0.7 : 1)
                                // Moves stay visible in privacy mode: a percentage doesn't say how much you hold.
                                if let change {
                                    Text(UpOnlyFormat.arrowPercent(change)).font(UpOnlyType.caption.weight(.medium).monospacedDigit())
                                        .foregroundStyle(UpOnlyTint.signed(change)).lineLimit(1)
                                } else if let valueDetail {
                                    UpOnlyPrivateText(valueDetail).font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.layoutPriority(1)
                        }
                        if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                    // Every row is at least two lines tall, so one with a second line doesn't stand out from the rest.
                    }.frame(minHeight: 30).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(UpOnlyRowButtonStyle(selected: selected)).disabled(action == nil)
                    .contextMenu { ForEach(Array(options.enumerated()), id: \.offset) { _, option in Button(option.title, action: option.action) } }
                    .accessibilityLabel(title).accessibilityValue(spokenValue)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                menu()
            }
        }
    }
    /// "<value>, <caption>, +0.4% over the past 30 days": the title is the label, so VoiceOver reads "<title>, <value>".
    private var spokenValue: String {
        var parts: [String] = []
        if let value { parts.append(session.privacyMode ? "Hidden value" : value) }
        if let caption, !(captionIsPrivate && session.privacyMode) { parts.append(caption) }
        if let valueDetail, !session.privacyMode { parts.append(valueDetail) }
        if let change {
            let range = session.worthRange
            parts.append(UpOnlyFormat.percent(change) + (range == .all ? " since the first saved value" : " over the " + range.phrase))
        }
        return parts.joined(separator: ", ")
    }
}
extension UpOnlyRow where Options == EmptyView {
    /// A row with nothing to offer beyond its own click (and any right-click options).
    init(title: String, caption: String? = nil, captionIsPrivate: Bool = false, value: String? = nil, change: Decimal? = nil,
         valueDetail: String? = nil, chevron: Bool = false, selected: Bool = false,
         options: [(title: String, action: () -> Void)] = [], action: (() -> Void)? = nil, @ViewBuilder badge: @escaping () -> Badge) {
        self.init(title: title, caption: caption, captionIsPrivate: captionIsPrivate, value: value, change: change, valueDetail: valueDetail, chevron: chevron, selected: selected, options: options, action: action, badge: badge, menu: { EmptyView() })
    }
}
/// A source of personal transactions: a bank account, a Wise profile, or "Added by hand".
struct PersonalAccountGroup: Identifiable {
    var id: String
    var name: String
    var entries: [Entry]
}
/// How much net worth history the chart shows. The headline value is always today's.
nonisolated enum WorthRange: CaseIterable {
    case day, week, month, year, all
    /// The segment above the chart.
    var title: String {
        switch self { case .day: "24H"; case .week: "7D"; case .month: "30D"; case .year: "1Y"; case .all: "All" }
    }
    /// "No saved values in the past year", and the range's spoken name.
    var phrase: String {
        switch self { case .day: "past 24 hours"; case .week: "past 7 days"; case .month: "past 30 days"; case .year: "past year"; case .all: "all time" }
    }
    var spokenTitle: String { phrase.prefix(1).uppercased() + String(phrase.dropFirst()) }
    /// " in the past year", or nothing for All: "No saved values in the past year."
    var within: String { self == .all ? "" : " in the " + phrase }
    /// What a change is measured against, as on the admin dashboard: "vs $4,304.28 prev 30D".
    var previous: String { self == .all ? "at start" : "prev " + title }
    /// Whole months the company figures cover, ending with the current month. Nil for All: every reported month.
    var months: Int? {
        switch self { case .day, .week, .month: 1; case .year: 12; case .all: nil }
    }
    /// How far back a rolling range reaches. All starts at the first saved value instead.
    var seconds: TimeInterval? {
        switch self { case .day: 86400; case .week: 7 * 86400; case .month: 30 * 86400; case .year: 365 * 86400; case .all: nil }
    }
    /// 24 hours is drawn hour by hour from the prices saved through the day; the rest from saved daily values.
    var hourly: Bool { self == .day }
    /// Finer steps for the shorter ranges, drawn from intraday price history when it has been fetched: 15 minutes
    /// over 24 hours, an hour over 7 days, four hours over 30.
    var intradayStep: TimeInterval? {
        switch self { case .day: 15 * 60; case .week: 3600; case .month: 4 * 3600; case .year, .all: nil }
    }
    /// Binance's candle size for `intradayStep`.
    var candleInterval: String? {
        switch self { case .day: "15m"; case .week: "1h"; case .month: "4h"; case .year, .all: nil }
    }
    /// Days between chart points: every day up to a year (at most 365 points), and for All by how long the
    /// history is, so it too stays near a year's worth of points.
    func chartStepDays(span: TimeInterval) -> Int {
        switch self {
        case .day, .week, .month, .year: 1
        case .all: span <= 400 * 86400 ? 1 : span <= 1100 * 86400 ? 3 : 7
        }
    }
    /// Short ranges name days ("Sep 17"); a year or more also names the year ("Sep 24, 2025").
    var showsYear: Bool { self == .year || self == .all }
}

/// Dashboard arithmetic kept out of the views, so it can be tested on its own.
nonisolated enum DashboardChart {
    /// Chart stops walk back from the last sample's day every `strideDays` days to the start of the range, so the
    /// last point is always the latest value. Each stop takes the latest sample in (stop − stride, stop]: a real
    /// valuation from that day, week or month, never an invented one. `sampleDays` must be in ascending order; the
    /// result runs oldest first, with the index of each stop's sample.
    static func stops(sampleDays: [Date], rangeStart: Date, strideDays: Int) -> [(day: Date, sample: Int?)] {
        guard let first = sampleDays.first, let last = sampleDays.last else { return [] }
        let stride = TimeInterval(max(1, strideDays) * 86400)
        let start = min(UTCDay.start(of: first), UTCDay.start(of: rangeStart))
        var days: [Date] = [], cursor = UTCDay.start(of: last)
        while cursor >= start && days.count < 10000 { days.append(cursor); cursor = cursor.addingTimeInterval(-stride) }
        var result: [(day: Date, sample: Int?)] = [], next = 0
        for day in days.reversed() {
            var chosen: Int?
            while next < sampleDays.count, UTCDay.start(of: sampleDays[next]) <= day {
                if UTCDay.start(of: sampleDays[next]) > day.addingTimeInterval(-stride) { chosen = next }
                next += 1
            }
            result.append((day, chosen))
        }
        return result
    }
    /// X-axis marks, one where each period starts, named briefly: every day over 7 days ("Thu"), Mondays over 30
    /// ("Sep 7"), month starts over a year ("Oct", with January as its year, "2026"), and for All months or years
    /// by how long the history is. The chart labels as many as fit, evenly spaced, each over a faint line.
    static func axisMarks(_ days: [Date], range: WorthRange) -> [String?] {
        guard let first = days.first, let last = days.last else { return [] }
        let span = last.timeIntervalSince(first)
        enum Unit { case day, week, month, year }
        let unit: Unit = switch range {
        case .day, .week: .day
        case .month: .week
        case .year: .month
        case .all: span > 3 * 365 * 86400 ? .year : span > 100 * 86400 ? .month : span > 14 * 86400 ? .week : .day
        }
        let calendar = UTCDay.calendar
        return days.indices.map { index in
            let day = days[index], parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            // A period starts at this point when it's the first day of it, or the first point since the last one.
            let previous = index > 0 ? calendar.dateComponents([.year, .month], from: days[index - 1]) : nil
            switch unit {
            case .day: return UpOnlyFormat.weekday(day)
            case .week: return parts.weekday == 2 ? UpOnlyFormat.utcDay(day) : nil
            case .month:
                let starts = previous.map { $0.month != parts.month || $0.year != parts.year } ?? (parts.day == 1)
                return starts ? UpOnlyFormat.monthName(day) : nil
            case .year:
                let starts = previous.map { $0.year != parts.year } ?? (parts.month == 1 && parts.day == 1)
                return starts ? UpOnlyFormat.year(day) : nil
            }
        }
    }
    /// Marks every six hours of a 24-hour chart, in the Mac's time zone: "6 AM", "12 PM", "6 PM", and the weekday
    /// at midnight.
    static func hourMarks(_ moments: [Date], calendar: Calendar = .current) -> [String?] { localMarks(moments, range: .day, calendar: calendar) }
    /// Marks for the finer charts, on the Mac's clock: every six hours over 24 hours (the weekday at midnight), each
    /// midnight over 7 days ("Thu"), each Monday over 30 ("Sep 7").
    static func localMarks(_ moments: [Date], range: WorthRange, calendar: Calendar = .current) -> [String?] {
        moments.map { moment in
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: moment)
            guard parts.minute == 0, let hour = parts.hour else { return nil }
            switch range {
            case .day:
                guard hour % 6 == 0 else { return nil }
                return hour == 0 ? UpOnlyFormat.localWeekday(moment, calendar: calendar) : UpOnlyFormat.localHour(moment, calendar: calendar)
            case .week: return hour == 0 ? UpOnlyFormat.localWeekday(moment, calendar: calendar) : nil
            default: return hour == 0 && parts.weekday == 2 ? UpOnlyFormat.localDay(moment, calendar: calendar) : nil
            }
        }
    }
    /// Whether a chart's line ends at or above where it starts, for the green-up / red-down colour. Nil with fewer
    /// than two values.
    static func risesOrHolds(_ values: [Decimal]) -> Bool? {
        guard values.count > 1, let first = values.first, let last = values.last else { return nil }
        return last >= first
    }
    /// Whole percentages of each value that add up to exactly 100 (largest remainder first); zero and negative
    /// values get 0. For each switcher row's share of the whole.
    static func percentages(_ values: [Decimal]) -> [Int] {
        let parts = values.map { max($0, 0) }
        let total = parts.reduce(Decimal(0), +)
        guard total > 0 else { return values.map { _ in 0 } }
        let exact = parts.map { NSDecimalNumber(decimal: $0 / total * 100).doubleValue }
        var result = exact.map { Int($0.rounded(.down)) }
        let remainders = exact.indices.map { exact[$0] - Double(result[$0]) }
        let order = exact.indices.sorted { remainders[$0] != remainders[$1] ? remainders[$0] > remainders[$1] : $0 < $1 }
        for index in order.prefix(max(0, 100 - result.reduce(0, +))) { result[index] += 1 }
        return result
    }
}
