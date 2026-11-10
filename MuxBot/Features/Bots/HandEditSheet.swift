import SwiftUI

/// "Edit" on text selected in the preview: the words in a focused editor.
/// Save is the approval (you typed the exact words; the result has Undo):
/// darkmux changes the one place in the project that holds them and commits
/// it (`RunCoordinator.handEdit`). The Mac app only: darkmux holds the files.
struct HandEditSheet: View {
    let element: PickedElement
    let crop: Data?
    let save: (String) -> Void
    let cancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(element: PickedElement, crop: Data?, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.element = element
        self.crop = crop
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: element.selectedText ?? "")
    }

    private var original: String { element.selectedText ?? "" }
    private var changed: Bool { text != original }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Edit text").font(AppFont.headline())
            if let image = snapshot {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 120)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityLabel("The part of the page you picked")
            }
            TextEditor(text: $text)
                .font(AppFont.body())
                .focused($focused)
                .frame(minHeight: 90, maxHeight: 240)
                .scrollContentBackground(.hidden)
                .padding(Spacing.xs)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
                .accessibilityLabel("New text")
            Text("Saves the change to this bot's project. You can undo it from the thread.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.secondaryText)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed)
            }
        }
        .padding(Spacing.lg)
        .frame(minWidth: 380, idealWidth: 460)
        .onAppear { focused = true }
    }

    private var snapshot: Image? {
        guard let crop else { return nil }
        #if os(macOS)
        return NSImage(data: crop).map(Image.init(nsImage:))
        #else
        return UIImage(data: crop).map(Image.init(uiImage:))
        #endif
    }
}
