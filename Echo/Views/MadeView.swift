import SwiftUI

/// Something an agent made, found in one of its replies kept on this device: a page it wrote for
/// the chat (`::preview`), a picture, a document, or a file it named on the server.
nonisolated struct MadeItem: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case page, picture, document, serverFile }

    var id: String
    var kind: Kind
    var name: String
    var attachment: Attachment?
    /// Where it is on the server, for a page or a file the reply named.
    var path: String?
    var conversationID: UUID
    var chat: String
    var agent: String?
    var at: Date
    /// The bot's profile, for its face; none for the main agent's chats.
    var profile: String? = nil

    /// What a conversation's replies made, newest first. Pictures the person sent, and their
    /// messages, are not the agent's.
    static func found(in record: ConversationRecord, agent: String?, profile: String? = nil) -> [MadeItem] {
        var items: [MadeItem] = []
        for message in record.messages where message.role == .assistant {
            var named = Set<String>()
            for attachment in message.attachments {
                named.insert(attachment.filename)
                if let page = attachment.page { named.insert(page) }
                let kind: Kind = attachment.page != nil ? .page : attachment.kind == .image ? .picture : .document
                items.append(MadeItem(id: "\(record.id)/\(attachment.id)", kind: kind, name: attachment.filename,
                                      attachment: attachment, path: attachment.page, conversationID: record.id,
                                      chat: record.title, agent: agent, at: message.createdAt, profile: profile))
            }
            // What it handed over (`MEDIA:`, `::preview`, a document's path), as the chat shows
            // them as files.
            for file in ServeMedia.candidates(in: message.text) where !file.isPicture && !named.contains(file.path) && !named.contains(file.filename) {
                named.insert(file.path)
                items.append(MadeItem(id: "\(record.id)/\(message.id)/\(file.path)", kind: file.isPage ? .page : .serverFile,
                                      name: file.filename, path: file.path, conversationID: record.id,
                                      chat: record.title, agent: agent, at: message.createdAt, profile: profile))
            }
        }
        return items.reversed()
    }

    /// A picture or a document is looked at here; a page lives in its reply, and a file on the
    /// server is fetched there: both open the chat.
    var opensHere: Bool { attachment != nil && (kind == .picture || kind == .document) }

    /// What sort of thing it is, for its icon and colour: by the file's name, or its type.
    var look: MadeLook { MadeLook.of(kind: kind, filename: name, mimeType: attachment?.mimeType) }
}

/// What a made thing looks like on the Made page: a page, a picture, a PDF, a spreadsheet,
/// code… by the file's extension, so a file named on the server (no bytes here) gets one too.
nonisolated enum MadeLook: Equatable, Sendable {
    case page, picture, pdf, sheet, slides, code, text, video, audio, archive, other

    private static let byExtension: [String: MadeLook] = {
        var map: [String: MadeLook] = [:]
        let groups: [(MadeLook, [String])] = [
            (.page, ["html", "htm", "xhtml"]),
            (.picture, ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff", "svg"]),
            (.pdf, ["pdf"]),
            (.sheet, ["csv", "tsv", "xls", "xlsx", "numbers", "ods"]),
            (.slides, ["key", "ppt", "pptx", "odp"]),
            (.code, ["swift", "py", "js", "mjs", "ts", "tsx", "jsx", "json", "sh", "zsh", "bash", "rb", "go", "rs", "c", "h",
                     "cc", "cpp", "hpp", "m", "mm", "java", "kt", "yaml", "yml", "toml", "sql", "css", "scss", "xml", "php",
                     "lua", "ini", "conf", "ipynb", "r", "pl", "cs", "dart", "vue", "env"]),
            (.text, ["txt", "md", "markdown", "rtf", "log", "doc", "docx", "pages", "odt", "tex", "org", "epub"]),
            (.video, ["mp4", "mov", "m4v", "webm", "mkv", "avi"]),
            (.audio, ["mp3", "m4a", "wav", "aac", "ogg", "opus", "flac", "aiff"]),
            (.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg"]),
        ]
        for (look, exts) in groups { for ext in exts { map[ext] = look } }
        return map
    }()

    static func of(kind: MadeItem.Kind, filename: String, mimeType: String? = nil) -> MadeLook {
        switch kind {
        case .page: return .page
        case .picture: return .picture
        case .document, .serverFile: break
        }
        if let found = byExtension[(filename as NSString).pathExtension.lowercased()] { return found }
        let mime = mimeType ?? ""
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("image/") { return .picture }
        if mime == "application/pdf" { return .pdf }
        if mime.hasPrefix("text/") { return .text }
        return .other
    }

    var symbol: String {
        switch self {
        case .page: "globe"
        case .picture: "photo.fill"
        case .pdf: "doc.richtext.fill"
        case .sheet: "tablecells.fill"
        case .slides: "rectangle.on.rectangle.angled.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .other: "doc.fill"
        }
    }

    /// The little word on its tile: the file's own extension ("PDF", "CSV"), short, or none.
    static func badge(for filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5 else { return nil }
        return ext.uppercased()
    }
}

/// The counts the Made page's top shows: how many of each, and how many lately.
nonisolated struct MadeCounts: Equatable, Sendable {
    var pictures = 0, pages = 0, documents = 0, onServer = 0
    var today = 0, week = 0
    var total: Int { pictures + pages + documents + onServer }
    /// Files sent and files named on the server, as one count.
    var files: Int { documents + onServer }

    init(_ items: [MadeItem], now: Date = .now, calendar: Calendar = .current) {
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        for item in items {
            switch item.kind {
            case .picture: pictures += 1
            case .page: pages += 1
            case .document: documents += 1
            case .serverFile: onServer += 1
            }
            if calendar.isDate(item.at, inSameDayAs: now) { today += 1 }
            if item.at > weekAgo { week += 1 }
        }
    }

    func count(_ kind: MadeItem.Kind?) -> Int {
        switch kind {
        case nil: total
        case .picture?: pictures
        case .page?: pages
        case .document?: documents
        case .serverFile?: onServer
        }
    }

    /// "2 today · 5 this week · 14 in all": what there is, leaving out what says nothing new.
    var summary: String {
        var parts: [String] = []
        if today > 0 { parts.append(String(localized: "\(today) today", comment: "Made page: how many things the agents made today, as “3 today”")) }
        if week > today { parts.append(String(localized: "\(week) this week", comment: "Made page: how many things the agents made in the last seven days, as “9 this week”")) }
        if total > week || parts.isEmpty { parts.append(String(localized: "\(total) in all", comment: "Made page: how many things the agents made altogether, as “14 in all”")) }
        return parts.joined(separator: " · ")
    }
}

/// The Made page laid out: the newest thing on its own at the top, then the rest by day, each
/// day's pictures in rows of a grid and its pages and files as cards.
enum MadeLayout {
    enum Row: Identifiable, Equatable, Sendable {
        case day(String)
        case pictures([MadeItem])
        case card(MadeItem)

        var id: String {
            switch self {
            case .day(let title): "day:" + title
            case .pictures(let items): "pics:" + (items.first?.id ?? "")
            case .card(let item): "card:" + item.id
            }
        }
    }

    static func rows(_ items: [MadeItem], columns: Int, now: Date = .now) -> (featured: MadeItem?, rows: [Row]) {
        guard let featured = items.first else { return (nil, []) }
        var rows: [Row] = []
        for day in DateGroup.group(Array(items.dropFirst()), by: { $0.at }, now: now) {
            rows.append(.day(day.title))
            let pictures = day.items.filter { $0.kind == .picture }
            rows += chunks(pictures, of: max(1, columns)).map(Row.pictures)
            rows += day.items.filter { $0.kind != .picture }.map(Row.card)
        }
        return (featured, rows)
    }

    static func chunks<T>(_ items: [T], of size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

/// The chat list's Made tab: everything the agents made, from the replies kept on this device,
/// newest first (asked 2026-10-28, after OpenDuet's Make tab). Read again each time it opens.
@MainActor
@Observable
final class MadeIndex {
    static let shared = MadeIndex()

    private(set) var items: [MadeItem] = []
    private(set) var looking = false
    /// How many conversations are read, newest first: enough for months, quick to go through.
    static let conversations = 400

    func refresh(store: ConversationStore = .shared) async {
        guard !looking else { return }
        looking = true
        defer { looking = false }
        #if DEBUG
        // `-echo.demoMade`: a gallery of sample things, of every kind (screenshots).
        if DevHooks.has("-echo.demoMade") {
            if items.isEmpty { items = MadeItem.demo(chats: store.sorted.prefix(6).map(\.id)) }
            return
        }
        #endif
        var found: [MadeItem] = []
        for summary in store.sorted.prefix(Self.conversations) {
            guard let record = await store.peekRecord(id: summary.id) else { continue }
            found += MadeItem.found(in: record, agent: summary.bot?.name, profile: summary.bot?.profile)
        }
        items = found.sorted { $0.at > $1.at }
    }
}

// MARK: - The page

/// The Made page (2026-11-13, after the new drawer): a gallery of what the agents made. Its top
/// in Made's colour with the counts, chips to show one kind, the newest thing large, then the
/// rest by day: pictures as a grid of thumbnails, pages and files as cards with a tile for their
/// type and the face of the bot that made them.
struct MadeView: View {
    /// Opens the chat a thing was made in.
    let openChat: (UUID) -> Void

    @State private var index = MadeIndex.shared
    @State private var kind: MadeItem.Kind?
    @State private var previewing: Attachment?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var shown: [MadeItem] { index.items.filter { kind == nil || $0.kind == kind } }

    var body: some View {
        let tone = DrawerTone(Settings.shared.resolvedTheme)
        let counts = MadeCounts(index.items)
        let layout = MadeLayout.rows(shown, columns: sizeClass == .regular ? 5 : 3)
        let actions = MadeActions(open: open, look: { previewing = $0 }, openChat: openChat)
        List {
            AnyView(MadeHero(counts: counts, tone: tone).madeRow(top: 6, bottom: 10))
            if counts.total > 0 {
                AnyView(MadeChips(kind: $kind, counts: counts, tone: tone).madeRow(top: 0, bottom: 8, side: 0))
            }
            if shown.isEmpty {
                if index.looking {
                    ProgressView().frame(maxWidth: .infinity).madeRow(top: 24, bottom: 24)
                } else {
                    ContentUnavailableView("Nothing made yet", systemImage: "sparkles",
                                           description: Text("Pages, pictures and files your agents put in their replies show here."))
                        .madeRow(top: 24, bottom: 24)
                }
            }
            if let featured = layout.featured {
                AnyView(MadeFeatured(item: featured, tone: tone, actions: actions).madeRow(top: 4, bottom: 6))
            }
            ForEach(layout.rows) { row in
                MadeRowView(row: row, columns: sizeClass == .regular ? 5 : 3, tone: tone, actions: actions)
            }
        }
        .listStyle(.plain)
        .themedPage(Settings.shared.theme.listPage)
        .animation(.snappy, value: kind)
        .refreshable { await index.refresh() }
        .task {
            #if DEBUG
            // `-echo.madeKind picture|page|document|serverFile`: one kind shown (screenshots).
            if let name = DevHooks.value("-echo.madeKind") { kind = MadeItem.Kind(rawValue: name) }
            #endif
            await index.refresh()
        }
        .sheet(item: $previewing) { DocumentPreview(attachment: $0).ignoresSafeArea() }
    }

    static func title(_ kind: MadeItem.Kind) -> String {
        switch kind {
        case .page: String(localized: "Pages", comment: "Made tab: pages the agent wrote for the chat")
        case .picture: String(localized: "Pictures", comment: "Made tab: pictures the agent made or sent")
        case .document: String(localized: "Files", comment: "Made tab: documents the agent sent")
        case .serverFile: String(localized: "On Server", comment: "Made tab: files the agent named on the server")
        }
    }

    static func symbol(_ kind: MadeItem.Kind) -> String {
        switch kind {
        case .page: "globe"
        case .picture: "photo.on.rectangle"
        case .document: "doc.on.doc.fill"
        case .serverFile: "externaldrive.fill"
        }
    }

    private func open(_ item: MadeItem) {
        if let attachment = item.attachment, item.opensHere {
            previewing = attachment
        } else {
            openChat(item.conversationID)
        }
    }
}

/// What a thing on the page does: shown here, or its chat opened.
private struct MadeActions {
    let open: (MadeItem) -> Void
    let look: (Attachment) -> Void
    let openChat: (UUID) -> Void
}

/// Each kind's colour, from the drawer's: pages blue, pictures Made's own, files amber, files on
/// the server green; a file's type picks its own.
private extension DrawerTone {
    var made: Color { places[3] }

    func hue(_ kind: MadeItem.Kind) -> Color {
        switch kind {
        case .page: places[1]
        case .picture: places[3]
        case .document: places[0]
        case .serverFile: places[2]
        }
    }

    func tint(_ look: MadeLook) -> Color {
        switch look {
        case .page, .audio: places[1]
        case .picture, .video: places[3]
        case .pdf: warm
        case .sheet, .other: places[2]
        case .slides: places[0]
        case .code: accent
        case .text, .archive: ink
        }
    }
}

// MARK: Top

private struct MadeHero: View {
    let counts: MadeCounts
    let tone: DrawerTone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tone.page)
                    .symbolEffect(.bounce, value: counts.total)
                    .frame(width: 60, height: 60)
                    .background(tone.made, in: .rect(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What your agents made", comment: "Made page: the heading at its top, over the counts of the pages, pictures and files the agents made")
                        .font(.system(.title3, design: tone.design, weight: .heavy))
                        .foregroundStyle(tone.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if counts.total > 0 {
                        Text(verbatim: counts.summary)
                            .font(.system(.subheadline, design: tone.design, weight: .medium))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
            }
            if counts.total > 0 {
                HStack(spacing: 8) {
                    MadeStat(count: counts.pictures, label: MadeView.title(.picture), color: tone.hue(.picture), tone: tone)
                    MadeStat(count: counts.pages, label: MadeView.title(.page), color: tone.hue(.page), tone: tone)
                    MadeStat(count: counts.files, label: MadeView.title(.document), color: tone.hue(.document), tone: tone)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A counter as the drawer's are: a big number over a small word in capitals.
private struct MadeStat: View {
    let count: Int
    let label: String
    let color: Color
    let tone: DrawerTone

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(count)")
                .font(.system(size: 26, weight: .heavy, design: tone.design))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? color : Color.secondary)
                .contentTransition(.numericText())
            Text(verbatim: label.localizedUppercase)
                .font(.system(size: 10, weight: .bold, design: tone.design))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone.surface, in: shape)
        .overlay { shape.strokeBorder(color.opacity(count > 0 ? 0.35 : 0.1), lineWidth: 1) }
    }
}

/// All, or one kind: chips in a row that scrolls sideways when the words are long.
private struct MadeChips: View {
    @Binding var kind: MadeItem.Kind?
    let counts: MadeCounts
    let tone: DrawerTone

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(nil, String(localized: "All", comment: "Inbox Select bar: pick every email in the pile"), "sparkles")
                ForEach([MadeItem.Kind.picture, .page, .document, .serverFile], id: \.self) { kind in
                    chip(kind, MadeView.title(kind), MadeView.symbol(kind))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: kind)
    }

    private func chip(_ value: MadeItem.Kind?, _ title: String, _ symbol: String) -> some View {
        let on = kind == value
        let hue = value.map { tone.hue($0) } ?? tone.made
        let none = value != nil && counts.count(value) == 0
        return Button { kind = value } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(on ? tone.ink : hue)
                Text(verbatim: title)
            }
            .font(.system(.footnote, design: tone.design, weight: .bold))
            .foregroundStyle(on ? tone.ink : Color.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background { Capsule().fill(tone.surface); if on { Capsule().fill(hue.opacity(0.24)) } }
            .overlay { Capsule().strokeBorder(on ? hue : hue.opacity(0.18), lineWidth: on ? 1.5 : 1) }
            .opacity(none && !on ? 0.5 : 1)
            .contentShape(.capsule)
        }
        .buttonStyle(DrawerSquish())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Things

/// Who made it: the bot's face and name, the main agent's for its own chats.
private struct MadeMaker {
    let face: BotFace
    let name: String

    init(_ item: MadeItem) {
        let directory = BotDirectory.shared
        if let profile = item.profile, profile != "default" {
            let here = directory.key == Settings.shared.connectionKey ? directory.roster?.faces[profile] : nil
            face = here ?? BotFace(seed: profile)
            name = item.agent ?? profile
        } else {
            face = directory.mainFace
            name = item.agent ?? Settings.shared.headerTitle
        }
    }
}

/// The newest thing, large: a picture across the page, or a page or file with a big tile.
private struct MadeFeatured: View {
    let item: MadeItem
    let tone: DrawerTone
    let actions: MadeActions

    var body: some View {
        let maker = MadeMaker(item)
        let tint = tone.tint(item.look)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Button { actions.open(item) } label: {
            Group {
                if item.kind == .picture, let attachment = item.attachment {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 230)
                            .overlay { MadeThumb(attachment: attachment, maxPixel: 1100, tone: tone) }
                            .clipped()
                        HStack(spacing: 10) {
                            BotAvatar(face: maker.face, name: maker.name, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: item.name)
                                    .font(.system(.subheadline, design: tone.design, weight: .bold))
                                    .foregroundStyle(tone.ink)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(verbatim: "\(maker.name) · \(DateGroup.rowTime(item.at))")
                                    .font(.system(.caption, design: tone.design, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            MadeLatest(tint: tint, tone: tone)
                        }
                        .padding(12)
                    }
                    .background(tone.surface)
                    .clipShape(shape)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            MadeTypeTile(look: item.look, badge: MadeLook.badge(for: item.name), size: 72, tone: tone)
                            Spacer(minLength: 0)
                            MadeLatest(tint: tint, tone: tone)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.name)
                                .font(.system(.title3, design: tone.design, weight: .bold))
                                .foregroundStyle(tone.ink)
                                .lineLimit(2).truncationMode(.middle)
                            Text(verbatim: item.chat)
                                .font(.system(.subheadline, design: tone.design, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            BotAvatar(face: maker.face, name: maker.name, size: 24)
                            Text(verbatim: "\(maker.name) · \(DateGroup.rowTime(item.at))")
                                .font(.system(.footnote, design: tone.design, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            MadePill(item: item, tint: tint, tone: tone)
                        }
                    }
                    .padding(16)
                    .background { shape.fill(tone.surface); shape.fill(tint.opacity(0.08)) }
                    .overlay { shape.strokeBorder(tint.opacity(0.32), lineWidth: 1) }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(DrawerSquish())
        .madeMenu(item, actions: actions)
        .accessibilityElement(children: .combine)
        .accessibilityHint(MadeRowView.hint(item))
    }
}

/// "LATEST", on the newest thing.
private struct MadeLatest: View {
    let tint: Color
    let tone: DrawerTone

    var body: some View {
        Text(String(localized: "Latest").localizedUppercase)
            .font(.system(size: 10, weight: .heavy, design: tone.design))
            .tracking(1)
            .foregroundStyle(tone.ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.22), in: .capsule)
    }
}

/// What a tap does, written on the newest thing: Look, or Open Chat.
private struct MadePill: View {
    let item: MadeItem
    let tint: Color
    let tone: DrawerTone

    var body: some View {
        Text(item.opensHere ? String(localized: "Look") : String(localized: "Open Chat"))
            .font(.system(.footnote, design: tone.design, weight: .bold))
            .foregroundStyle(tone.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(tint.opacity(0.22), in: .capsule)
            .accessibilityHidden(true)
    }
}

/// A file's type as a big tile in its colour: its symbol, and its extension under it.
private struct MadeTypeTile: View {
    let look: MadeLook
    let badge: String?
    let size: CGFloat
    let tone: DrawerTone

    var body: some View {
        let tint = tone.tint(look)
        VStack(spacing: size * 0.04) {
            Image(systemName: look.symbol)
                .font(.system(size: size * (badge == nil ? 0.42 : 0.36), weight: .semibold))
            if let badge {
                Text(verbatim: badge)
                    .font(.system(size: max(8, size * 0.15), weight: .heavy, design: .rounded))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .background(tint.opacity(0.15), in: .rect(cornerRadius: size * 0.28, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// One row of the page after the newest: a day's heading, a row of the picture grid, or a card.
private struct MadeRowView: View {
    let row: MadeLayout.Row
    let columns: Int
    let tone: DrawerTone
    let actions: MadeActions

    var body: some View {
        switch row {
        case .day(let title):
            Text(verbatim: title.localizedUppercase)
                .font(.system(size: 12, weight: .heavy, design: tone.design))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .madeRow(top: 16, bottom: 4)
        case .pictures(let items):
            HStack(spacing: 6) {
                ForEach(items) { MadeTile(item: $0, tone: tone, actions: actions) }
                ForEach(items.count..<columns, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
            }
            .madeRow(top: 3, bottom: 3)
        case .card(let item):
            MadeCard(item: item, tone: tone, actions: actions)
                .madeRow(top: 4, bottom: 4)
        }
    }

    static func hint(_ item: MadeItem) -> Text {
        item.opensHere ? Text("Shows it") : Text("Opens the chat it was made in")
    }
}

/// A picture in the grid: its thumbnail, square, with the face of the bot that made it.
private struct MadeTile: View {
    let item: MadeItem
    let tone: DrawerTone
    let actions: MadeActions

    var body: some View {
        let maker = MadeMaker(item)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button { actions.open(item) } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let attachment = item.attachment {
                        MadeThumb(attachment: attachment, maxPixel: 420, tone: tone)
                    } else {
                        MadePlaceholder(tone: tone)
                    }
                }
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) {
                    BotAvatar(face: maker.face, name: maker.name, size: 20)
                        .padding(2)
                        .background(tone.surface, in: .circle)
                        .padding(5)
                }
                .contentShape(shape)
        }
        .buttonStyle(DrawerSquish())
        .madeMenu(item, actions: actions)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.name), \(maker.name), \(DateGroup.rowTime(item.at))"))
        .accessibilityAddTraits([.isImage, .isButton])
        .accessibilityHint(MadeRowView.hint(item))
    }
}

/// A page or a file: the tile for its type, its name, who made it, in which chat and when.
private struct MadeCard: View {
    let item: MadeItem
    let tone: DrawerTone
    let actions: MadeActions

    var body: some View {
        let maker = MadeMaker(item)
        Button { actions.open(item) } label: {
            HStack(spacing: 12) {
                MadeTypeTile(look: item.look, badge: MadeLook.badge(for: item.name), size: 50, tone: tone)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.name)
                        .font(.system(.subheadline, design: tone.design, weight: .semibold))
                        .foregroundStyle(tone.ink)
                        .lineLimit(2).truncationMode(.middle)
                    HStack(spacing: 5) {
                        BotAvatar(face: maker.face, name: maker.name, size: 16)
                        Text(verbatim: "\(maker.name) · \(item.chat)")
                            .font(.system(.caption, design: tone.design, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(verbatim: DateGroup.rowTime(item.at))
                        .font(.system(.caption, design: tone.design, weight: .semibold))
                        .foregroundStyle(tone.tint(item.look))
                    if item.kind == .serverFile {
                        Image(systemName: "externaldrive.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(MadeView.title(.serverFile))
                    }
                }
            }
            .padding(12)
            .background(tone.surface, in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(DrawerSquish())
        .madeMenu(item, actions: actions)
        .accessibilityElement(children: .combine)
        .accessibilityHint(MadeRowView.hint(item))
    }
}

/// A picture's thumbnail, decoded off the main thread at the size it is shown and kept for the
/// run, so scrolling back up shows it at once rather than decoding it again.
private struct MadeThumb: View {
    let attachment: Attachment
    let maxPixel: CGFloat
    let tone: DrawerTone
    @State private var image: UIImage?

    init(attachment: Attachment, maxPixel: CGFloat, tone: DrawerTone) {
        self.attachment = attachment
        self.maxPixel = maxPixel
        self.tone = tone
        _image = State(initialValue: MadeThumbs.kept(attachment.id, maxPixel))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                MadePlaceholder(tone: tone)
            }
        }
        .task(id: attachment.id) {
            guard image == nil else { return }
            let att = attachment, px = maxPixel
            image = await Task.detached(priority: .utility) { MadeThumbs.make(att, px) }.value
        }
    }
}

private struct MadePlaceholder: View {
    let tone: DrawerTone
    var body: some View {
        ZStack {
            tone.surface
            Image(systemName: "photo").font(.title3).foregroundStyle(tone.made.opacity(0.5))
        }
    }
}

nonisolated enum MadeThumbs {
    // NSCache is thread-safe by contract; the annotation just tells Swift so.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        return cache
    }()

    static func kept(_ id: UUID, _ maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: "\(id.uuidString)@\(Int(maxPixel))" as NSString)
    }

    static func make(_ attachment: Attachment, _ maxPixel: CGFloat) -> UIImage? {
        if let kept = kept(attachment.id, maxPixel) { return kept }
        guard let made = ImageThumbnail.decode(attachment.data, maxPixel: maxPixel) else { return nil }
        cache.setObject(made, forKey: "\(attachment.id.uuidString)@\(Int(maxPixel))" as NSString)
        return made
    }
}

private extension View {
    /// A row of the Made page that draws its own look: no separator, no row background.
    func madeRow(top: CGFloat, bottom: CGFloat, side: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: side, bottom: bottom, trailing: side))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Open Chat, and Look for a picture or a file that is here.
    func madeMenu(_ item: MadeItem, actions: MadeActions) -> some View {
        contextMenu {
            Button("Open Chat", systemImage: "bubble.left") { actions.openChat(item.conversationID) }
            if let attachment = item.attachment, item.kind != .page {
                Button("Look", systemImage: "eye") { actions.look(attachment) }
            }
        }
    }
}

// MARK: - Sample things (screenshots)

#if DEBUG
extension MadeItem {
    /// `-echo.demoMade`: pictures, pages, documents and files on the server, made by the sample
    /// bots (`-echo.demoBots`) over the last weeks, in the chats there are (or none).
    static func demo(chats: [UUID], now: Date = .now) -> [MadeItem] {
        let ids = chats.isEmpty ? [UUID()] : chats
        var n = 0
        func item(_ kind: Kind, _ name: String, _ chat: String, _ profile: String?, _ agent: String?, ago minutes: Double,
                  attachment: Attachment? = nil, path: String? = nil) -> MadeItem {
            n += 1
            return MadeItem(id: "demo/\(n)", kind: kind, name: name, attachment: attachment, path: path,
                            conversationID: ids[n % ids.count], chat: chat, agent: agent, at: now.addingTimeInterval(-minutes * 60),
                            profile: profile)
        }
        func page(_ name: String) -> Attachment {
            var page = Attachment(kind: .other, filename: name, mimeType: "text/html", data: Data("<html><body><h1>\(name)</h1></body></html>".utf8))
            page.page = "/home/hermes/pages/" + name
            return page
        }
        func text(_ name: String, _ mime: String, _ body: String) -> Attachment {
            Attachment(kind: .text, filename: name, mimeType: mime, data: Data(body.utf8))
        }
        var items = [
            item(.page, "lisbon-weekend.html", "A weekend in Lisbon", "scout", "Scout", ago: 18, attachment: page("lisbon-weekend.html")),
            item(.serverFile, "nightly-backup.sh", "Backups", "fixit", "Fix-it", ago: 140, path: "/home/hermes/bin/nightly-backup.sh"),
            item(.document, "trip-costs.csv", "A weekend in Lisbon", "scout", "Scout", ago: 200,
                 attachment: text("trip-costs.csv", "text/csv", "item,cost\nflights,240\nhotel,310\nfood,120\n")),
            item(.document, "chapter-3-edits.md", "The novel", "writer", "Quill", ago: 60 * 26,
                 attachment: text("chapter-3-edits.md", "text/markdown", "# Chapter 3\n\nTightened the opening; the storm now comes first.\n")),
            item(.page, "garden-planner.html", "Garden", nil, nil, ago: 60 * 30, attachment: page("garden-planner.html")),
            item(.serverFile, "Q4 budget.xlsx", "Budget", nil, nil, ago: 60 * 52, path: "/home/hermes/out/Q4 budget.xlsx"),
            item(.serverFile, "photos-2026.zip", "Photo cleanup", "fixit", "Fix-it", ago: 60 * 24 * 9, path: "/home/hermes/out/photos-2026.zip"),
            item(.document, "reading-list.pdf", "Books", "writer", "Quill", ago: 60 * 24 * 12, attachment: demoPDF()),
        ]
        #if canImport(UIKit)
        let art: [(String, String, String?, String?, Double, Int)] = [
            ("sunset-poster.png", "Poster ideas", "writer", "Quill", 50, 0),
            ("trail-map.png", "A weekend in Lisbon", "scout", "Scout", 95, 1),
            ("sales-chart.png", "Budget", nil, nil, 170, 2),
            ("kitchen-plan.png", "Kitchen", nil, nil, 60 * 27, 3),
            ("logo-sketches.png", "Poster ideas", "writer", "Quill", 60 * 28, 4),
            ("moodboard.png", "Poster ideas", "writer", "Quill", 60 * 29, 5),
            ("rack-diagram.png", "Home server", "fixit", "Fix-it", 60 * 24 * 4, 2),
        ]
        for (name, chat, profile, agent, ago, style) in art {
            let picture = demoPicture(style).map { Attachment(kind: .image, filename: name, mimeType: "image/png", data: $0) }
            items.append(item(.picture, name, chat, profile, agent, ago: ago, attachment: picture))
        }
        #endif
        return items.sorted { $0.at > $1.at }
    }

    private static func demoPDF() -> Attachment {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(red: 0.85, green: 0.45, blue: 0.3, alpha: 1))
            pdf.fill(CGRect(x: 72, y: 640, width: 468, height: 80))
            pdf.endPDFPage()
            pdf.closePDF()
        }
        return Attachment(kind: .pdf, filename: "reading-list.pdf", mimeType: "application/pdf", data: data as Data)
    }

    #if canImport(UIKit)
    /// Made-up art for the sample pictures: gradients and shapes, no files needed.
    private static func demoPicture(_ style: Int) -> Data? {
        let size = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let palettes: [[UIColor]] = [
            [.systemOrange, .systemPink, .systemPurple], [.systemGreen, .systemTeal, .systemBlue],
            [.white, .systemGray6, .systemGray5], [.systemYellow, .systemOrange, .brown],
            [.systemIndigo, .systemPurple, .systemPink], [.systemMint, .systemCyan, .systemIndigo],
        ]
        let colors = palettes[style % palettes.count]
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.55, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            switch style % palettes.count {
            case 0:   // a sun going down over the sea
                UIColor.white.withAlphaComponent(0.85).setFill()
                cg.fillEllipse(in: CGRect(x: 180, y: 170, width: 240, height: 240))
                UIColor.systemIndigo.withAlphaComponent(0.8).setFill()
                cg.fill(CGRect(x: 0, y: 380, width: 600, height: 220))
            case 1:   // a trail over hills
                UIColor.white.withAlphaComponent(0.25).setFill()
                cg.fillEllipse(in: CGRect(x: -100, y: 330, width: 500, height: 400))
                cg.fillEllipse(in: CGRect(x: 260, y: 380, width: 480, height: 380))
                UIColor.white.setStroke()
                cg.setLineWidth(10)
                cg.setLineDash(phase: 0, lengths: [22, 14])
                cg.move(to: CGPoint(x: 60, y: 540))
                cg.addCurve(to: CGPoint(x: 520, y: 90), control1: CGPoint(x: 420, y: 520), control2: CGPoint(x: 120, y: 160))
                cg.strokePath()
            case 2:   // a bar chart
                let bars: [CGFloat] = [180, 260, 220, 340, 300, 420]
                for (i, height) in bars.enumerated() {
                    (i == bars.count - 1 ? UIColor.systemBlue : UIColor.systemTeal).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 70 + CGFloat(i) * 80, y: 520 - height, width: 54, height: height), cornerRadius: 10).fill()
                }
                UIColor.systemGray.setFill()
                cg.fill(CGRect(x: 50, y: 524, width: 500, height: 4))
            case 3:   // a floor plan
                UIColor.white.withAlphaComponent(0.9).setStroke()
                cg.setLineWidth(12)
                cg.stroke(CGRect(x: 80, y: 80, width: 440, height: 440))
                cg.stroke(CGRect(x: 80, y: 80, width: 260, height: 220))
                cg.stroke(CGRect(x: 340, y: 300, width: 180, height: 220))
            case 4:   // logo sketches
                UIColor.white.withAlphaComponent(0.9).setFill()
                for (i, rect) in [CGRect(x: 90, y: 90, width: 170, height: 170), CGRect(x: 340, y: 90, width: 170, height: 170),
                                  CGRect(x: 90, y: 340, width: 170, height: 170), CGRect(x: 340, y: 340, width: 170, height: 170)].enumerated() {
                    i.isMultiple(of: 2) ? cg.fillEllipse(in: rect) : UIBezierPath(roundedRect: rect, cornerRadius: 40).fill()
                }
            default:  // a mood board
                for (i, color) in [UIColor.systemPink, .systemYellow, .white, .systemOrange].enumerated() {
                    color.withAlphaComponent(0.85).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 60 + CGFloat(i % 2) * 250, y: 60 + CGFloat(i / 2) * 250, width: 230, height: 230), cornerRadius: 24).fill()
                }
            }
        }
        return image.pngData()
    }
    #endif
}
#endif
