import SwiftUI

/// A template's preview pictures (schema 3, optional): desktop and phone,
/// for the template itself (`previews:` in the playbook's header) and for
/// each choice of a choice question that asks for them. They live in the registry repo (kstrat2001/muxbot-templates
/// `previews/<template>/`), never in the template, whose files are copied
/// into every new project.
enum TemplatePreview {
    enum Viewport: String, CaseIterable, Identifiable, Sendable {
        case desktop, phone
        var id: String { rawValue }
        var title: String { self == .desktop ? String(localized: "Desktop") : String(localized: "Phone") }
        var icon: String { self == .desktop ? "desktopcomputer" : "iphone" }
        /// Width over height of the picture.
        var aspect: CGFloat { self == .desktop ? 1280.0 / 800.0 : 390.0 / 844.0 }
    }

    /// `desktop, phone` (either or both, no other words); nil otherwise.
    static func viewports(_ value: String) -> [Viewport]? {
        let words = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let viewports = words.compactMap(Viewport.init(rawValue:))
        guard !words.isEmpty, viewports.count == words.count, Set(viewports).count == viewports.count else { return nil }
        return viewports
    }

    static let base = "https://raw.githubusercontent.com/kstrat2001/muxbot-templates/main/previews/"

    /// `previews/<template>/desktop.jpg`, or `<choice>-desktop.jpg` for a choice.
    static func url(template: String, choice: String? = nil, _ viewport: Viewport) -> URL? {
        guard PlaybookChoice.isId(template), choice.map(PlaybookChoice.isId) ?? true else { return nil }
        let file = choice.map { "\($0)-\(viewport.rawValue)" } ?? viewport.rawValue
        return URL(string: base + "\(template)/\(file).jpg")
    }
}

/// A preview picture, or a quiet placeholder while it loads or when it
/// can't be read (the choice still works without it).
struct PreviewPicture: View {
    let url: URL?
    let viewport: TemplatePreview.Viewport

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.12))
                    .overlay { Image(systemName: viewport.icon).foregroundStyle(Color.secondaryText) }
            }
        }
        .aspectRatio(viewport.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

/// A choice question on the start form: the question, a Desktop/Phone
/// switch, and each choice as a picture you tap. The picked one is
/// outlined, its sentence is under the row, and Enlarge shows it full size.
struct ChoiceField: View {
    let template: String
    let choice: PlaybookChoice
    @Binding var picked: String?
    @State private var shown: TemplatePreview.Viewport?
    private var viewport: TemplatePreview.Viewport { shown.flatMap { choice.previews.contains($0) ? $0 : nil } ?? choice.previews.first ?? .desktop }
    private var viewportBinding: Binding<TemplatePreview.Viewport> { Binding { viewport } set: { shown = $0 } }
    @State private var enlarged: PlaybookChoice.Option?

    private var current: PlaybookChoice.Option? {
        choice.options.first { $0.id == picked } ?? choice.options.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(choice.label)
                    .font(AppFont.body(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if choice.previews.count > 1 { viewportPicker.labelsHidden().fixedSize() }
            }
            if choice.previews.isEmpty {
                WrappingStack(spacing: Spacing.sm) {
                    ForEach(choice.options) { option in
                        Button(option.title) { picked = option.id }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(option.id == current?.id ? Color.brandGreen : Color.accentText)
                            .accessibilityAddTraits(option.id == current?.id ? .isSelected : [])
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Spacing.md) {
                        ForEach(choice.options) { option in
                            Button { picked = option.id } label: { card(option) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.title)
                                .accessibilityHint(option.detail)
                                .accessibilityAddTraits(option.id == current?.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }
            }
            if let current {
                HStack(alignment: .firstTextBaseline) {
                    Text(current.detail.isEmpty ? current.title : "\(current.title): \(current.detail)")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !choice.previews.isEmpty {
                        Button("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = current }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .sheet(item: $enlarged) { option in
            NavigationStack {
                ScrollView {
                    PreviewPicture(url: TemplatePreview.url(template: template, choice: option.id, viewport), viewport: viewport)
                        .frame(maxWidth: viewport == .desktop ? 900 : 360)
                        .padding(Spacing.lg)
                        .frame(maxWidth: .infinity)
                }
                .navigationTitle(option.title)
                .toolbar {
                    if choice.previews.count > 1 {
                        ToolbarItem(placement: .principal) { viewportPicker }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Pick this one") { picked = option.id; enlarged = nil }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { enlarged = nil } }
                }
            }
            #if os(macOS)
            .frame(minWidth: 640, minHeight: 520)
            #endif
        }
    }

    private var viewportPicker: some View {
        Picker("Show", selection: viewportBinding) {
            ForEach(choice.previews) { Label($0.title, systemImage: $0.icon).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func card(_ option: PlaybookChoice.Option) -> some View {
        let selected = option.id == current?.id
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            PreviewPicture(url: TemplatePreview.url(template: template, choice: option.id, viewport), viewport: viewport)
                .frame(width: viewport == .desktop ? 176 : 84)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.brandGreen : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1)
                }
            Text(option.title)
                .font(AppFont.footnote(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondaryText)
        }
        .contentShape(Rectangle())
    }
}
