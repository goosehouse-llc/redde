import SwiftUI

/// Under a message with a web link, with Settings → Appearance → Link previews on: the first
/// link's page as a card (`LinkPreviews`). It reads the setting itself, so turning it on or off
/// shows or hides every card without the messages being drawn again.
struct LinkPreviewSlot: View {
    let text: String
    @State private var settings = Settings.shared

    var body: some View {
        if settings.linkPreviews, let url = LinkPreviewLinks.first(in: text) {
            LinkPreviewCard(url: url)
        }
    }
}

/// A page's card: its picture or icon, its title and its site. Always the same height, loaded or
/// not, so a card that fills in doesn't move the conversation under someone reading back
/// through it. Until the page has been read, or if it can't be, the card names the site.
struct LinkPreviewCard: View {
    let url: URL
    @State private var previews = LinkPreviews.shared
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 72
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 52

    var body: some View {
        let preview = previews.preview(for: url)
        let site = preview?.site ?? LinkPreviews.site(url.host(percentEncoded: false) ?? url.absoluteString)
        Button { openURL(url) } label: {
            HStack(spacing: 12) {
                picture(preview)
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.title ?? site)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if preview?.title != nil {
                        Text(site)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: 340, minHeight: height, maxHeight: height, alignment: .leading)
            .background(theme.surfaceColor.opacity(0.6), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", systemImage: "safari") { openURL(url) }
            Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
        }
        .task(id: url) { await previews.request(url) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview?.title.map { "\($0), \(site)" } ?? site)
        .accessibilityHint("Opens the page")
        .accessibilityAddTraits(.isLink)
    }

    @ViewBuilder private func picture(_ preview: LinkPreview?) -> some View {
        if let data = preview?.image, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "link")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.accent.opacity(0.12))
        }
    }
}
