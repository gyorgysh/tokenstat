// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ChatImageResource: Equatable {
    let attachment: ChatAttachment
    var data: Data?
    var file: URL?
    var loading = false
    var error: String?
    var available: Bool { data != nil || file != nil }
}

extension ChatModel {
    func imageResources(for files: [ChatAttachment]) -> [ChatImageResource] {
        files.map { file in
            ChatImageResource(attachment: file, data: responseAttachmentData[file.id],
                file: responseAttachmentFiles[file.id], loading: loadingResponseAttachments.contains(file.id),
                error: responseAttachmentErrors[file.id])
        }
    }
}

private struct PresentChatImagesKey: EnvironmentKey {
    static let defaultValue: (([ChatAttachment], String) -> Void)? = nil
}
extension EnvironmentValues {
    var presentChatImages: (([ChatAttachment], String) -> Void)? {
        get { self[PresentChatImagesKey.self] }
        set { self[PresentChatImagesKey.self] = newValue }
    }
}

/// A bounded group of image previews, shared by desktop and mobile rows.
/// Four cells are enough to recognize a set; the viewer retains every file.
struct ChatImageGallery: View {
    let resources: [ChatImageResource]
    var compact = false
    @Environment(\.presentChatImages) private var present
    @State private var dimensions: [String: ChatImageDimensions] = [:]
    private struct MetadataRequest: Equatable { let id: String; let file: URL?; let data: Data? }
    private var metadataRequests: [MetadataRequest] {
        resources.prefix(4).map { MetadataRequest(id: $0.attachment.id, file: $0.file, data: $0.data) }
    }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 6) {
                    ForEach(Array(resources.prefix(4).enumerated()), id: \.element.attachment.id) { index, resource in
                        tile(resource, index: index).frame(width: compactSize, height: compactSize)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ChatImageRowsLayout(dimensions: resources.prefix(4).map { dimensions[$0.attachment.id] }) {
                        ForEach(Array(resources.prefix(4).enumerated()), id: \.element.attachment.id) { index, resource in
                            tile(resource, index: index)
                        }
                    }
                    Text(resources.count == 1 ? resources[0].attachment.name : L10n.text("common.chat.images.count", "\(resources.count)"))
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: metadataRequests) {
            guard !compact else { return }
            var loaded: [String: ChatImageDimensions] = [:]
            for resource in resources.prefix(4) {
                loaded[resource.attachment.id] = await ChatImageMetadata.shared.dimensions(data: resource.data, file: resource.file)
                guard !Task.isCancelled else { return }
            }
            dimensions = loaded
        }
    }

    private var compactSize: CGFloat {
        #if os(macOS)
        64
        #else
        52
        #endif
    }

    private func tile(_ resource: ChatImageResource, index: Int) -> some View {
        Button {
            present?(resources.map(\.attachment), resource.attachment.id)
        } label: {
            ChatImageSurface(resource: resource, maxPixel: compact ? 192 : 1280)
                .overlay(alignment: .bottomTrailing) {
                    if index == 3, resources.count > 4 {
                        Text(L10n.text("common.chat.images.more", "\(resources.count - 4)"))
                            .font(Theme.callout.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.7), in: Capsule()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(L10n.text("common.chat.images.view", resource.attachment.name))
        .accessibilityLabel(L10n.text("common.chat.images.view", resource.attachment.name))
        .accessibilityValue(L10n.text("common.chat.images.position", "\(index + 1)", "\(resources.count)"))
    }
}

private struct ChatImageRowsLayout: Layout {
    let dimensions: [ChatImageDimensions?]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        ChatImageGalleryGeometry(width: proposal.width ?? 640, dimensions: dimensions).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let geometry = ChatImageGalleryGeometry(width: bounds.width, dimensions: dimensions)
        for (index, frame) in geometry.frames.enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Decode a bounded, alpha-preserving image away from the UI executor.
/// The layout proposal bounds the preview; decoded pixels do not size it.
private struct ChatImageSurface: View {
    let resource: ChatImageResource
    var maxPixel: CGFloat = 3072
    @State private var decoded: CGImage?
    @State private var decodedSource: Source?
    private struct Source: Equatable { let data: Data?; let file: URL?; let maxPixel: CGFloat }
    private var source: Source { Source(data: resource.data, file: resource.file, maxPixel: maxPixel) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.panel
                if decodedSource == source, let decoded {
                    Image(decoded, scale: 1, label: Text(verbatim: resource.attachment.name))
                        .resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if resource.loading || (resource.available && decodedSource != source) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: resource.error == nil && !resource.available ? "photo" : "exclamationmark.triangle")
                        .font(Theme.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: source) {
            // Published attachment bytes/cache files stay immutable until the
            // model resets their resource. Lazy reappearance still requests
            // the cache again, which revalidates file identity before reuse.
            let requested = source
            let image = await ChatImageDecodeCache.shared.image(data: requested.data, file: requested.file, maxPixel: requested.maxPixel)
            guard !Task.isCancelled else { return }
            decodedSource = requested
            decoded = image
        }
    }
}

private struct ChatImagePresentation: Identifiable {
    let id = UUID()
    let reference: WorkReference?
    let attachments: [ChatAttachment]
    let selectedID: String
}

/// A chat owns the lightbox, so lazy row recycling cannot dismiss it.
private struct ChatImageViewerHost: ViewModifier {
    @Bindable var model: ChatModel
    @State private var presentation: ChatImagePresentation?
    func body(content: Content) -> some View {
        content
            .environment(\.presentChatImages, { files, selected in
                guard !files.isEmpty else { return }
                presentation = ChatImagePresentation(reference: model.currentReference, attachments: files, selectedID: selected)
            })
            .sheet(item: $presentation) { request in
                ChatImageViewer(model: model, request: request)
            }
            .onChange(of: model.currentReference) { _, _ in presentation = nil }
            .onChange(of: WorkSessionContext.shared.scope) { _, _ in presentation = nil }
    }
}
extension View {
    func chatImageViewer(model: ChatModel) -> some View { modifier(ChatImageViewerHost(model: model)) }
}

private struct ChatImageViewer: View {
    @Bindable var model: ChatModel
    let request: ChatImagePresentation
    @State private var selection = 0
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var error: String?
    #if !os(macOS)
    @State private var openingFile: ChatPreviewedFile?
    @State private var savingFile: ChatPreviewedFile?
    #endif
    @Environment(\.dismiss) private var dismiss
    init(model: ChatModel, request: ChatImagePresentation) {
        self.model = model
        self.request = request
        _selection = State(initialValue: request.attachments.firstIndex(where: { $0.id == request.selectedID }) ?? 0)
    }
    private var attachment: ChatAttachment { request.attachments[min(selection, request.attachments.count - 1)] }
    private var resource: ChatImageResource { model.imageResources(for: [attachment])[0] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ThemeRule()
            viewport
            downloadNotice
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.danger).padding(.horizontal, 16) }
            ThemeRule()
            navigationControls
            fileActions
        }
        .background(Theme.background)
        .modifier(ChatFileRelayConsent(model: model, presenter: request.id))
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 880, minHeight: 480, idealHeight: 680)
        .background(ChatImageOutsideDismiss { dismiss() })
        .onExitCommand { dismiss() }
        #else
        .presentationDetents([.large])
        .fullScreenCover(item: $openingFile) { file in ClientFilePreview(file: file) { openingFile = nil } }
        .sheet(item: $savingFile) { file in ChatImageExporter(file: file.url) { savingFile = nil } }
        #endif
        .onAppear { model.fileRelayPresenter = request.id }
        .onDisappear {
            if model.fileRelayPresenter == request.id {
                model.fileRelayPresenter = nil
                model.answerFileRelay(false)
            }
        }
        .task(id: attachment.id) { await loadSelected() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.name).font(Theme.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(L10n.text("common.chat.images.position", "\(selection + 1)", "\(request.attachments.count)"))
                    .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            iconButton(L10n.text("common.close"), symbol: "xmark") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }.padding(16)
    }
    private var viewport: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ChatImageSurface(resource: resource)
                    .frame(width: max(1, geometry.size.width) * zoom, height: max(1, geometry.size.height) * zoom)
                    .accessibilityLabel(attachment.name)
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                zoom = min(4, max(1, gestureZoom * value.magnification))
            }.onEnded { _ in gestureZoom = zoom })
        }
    }
    @ViewBuilder private var downloadNotice: some View {
        if !resource.available, !resource.loading {
            HStack {
                Text(resource.error ?? L10n.text("common.chat.images.unavailable"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                if model.savedCopy == nil {
                    Button(L10n.text("common.retry"), .refresh) { Task { await loadSelected() } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }.padding(12)
        }
    }
    private var navigationControls: some View {
        HStack(spacing: 8) {
            iconButton(L10n.text("common.chat.images.previous"), symbol: "chevron.left") { move(-1) }
                .disabled(selection == 0).keyboardShortcut(.leftArrow, modifiers: [])
            Spacer(minLength: 0)
            iconButton(L10n.text("common.chat.images.zoom_out"), symbol: "minus.magnifyingglass") { setZoom(zoom - 0.5) }
                .disabled(zoom <= 1)
            iconButton(L10n.text("common.chat.images.reset_zoom"), symbol: "arrow.up.left.and.arrow.down.right") { setZoom(1) }
            iconButton(L10n.text("common.chat.images.zoom_in"), symbol: "plus.magnifyingglass") { setZoom(zoom + 0.5) }
                .disabled(zoom >= 4)
            Spacer(minLength: 0)
            iconButton(L10n.text("common.chat.images.next"), symbol: "chevron.right") { move(1) }
                .disabled(selection + 1 >= request.attachments.count).keyboardShortcut(.rightArrow, modifiers: [])
        }
        .labelStyle(.iconOnly).buttonStyle(SecondaryButtonStyle(comfortable: true)).padding(.horizontal, 16).padding(.top, 10)
    }
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 20) }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
            .help(title).accessibilityLabel(title)
    }
    private var fileActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { openSaveButtons }
            VStack(spacing: 8) { openSaveButtons }
        }
        .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(!resource.available).padding(12)
    }
    private var openSaveButtons: some View {
        Group {
            Button(L10n.text("common.chat.images.open"), .preview) { openImage() }
            Button(L10n.text("common.chat.images.save"), .download) { saveImage() }
        }
    }

    private func setZoom(_ value: CGFloat) { zoom = min(4, max(1, value)); gestureZoom = zoom }
    private func move(_ direction: Int) {
        let next = selection + direction
        guard request.attachments.indices.contains(next) else { return }
        selection = next; setZoom(1); error = nil
    }
    private func loadSelected() async {
        let selected = attachment
        // A canceled predecessor or an automatic preview can still be
        // settling. Wait for its transfer slot so Next opens the new image
        // directly, including when the background read declined relay use.
        while model.fileTransferInFlight || model.loadingResponseAttachments.contains(selected.id) {
            guard !Task.isCancelled, model.currentReference == request.reference, attachment.id == selected.id else { return }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        }
        guard !Task.isCancelled, model.currentReference == request.reference,
              attachment.id == selected.id, !resource.available else { return }
        await model.downloadResponseAttachment(selected)
    }
    private func sourceFile() throws -> URL {
        guard let reference = request.reference, model.currentReference == reference,
              WorkCacheAccess.canRead(reference) else { throw CancellationError() }
        if let file = resource.file { return file }
        guard let data = resource.data else { throw CocoaError(.fileNoSuchFile) }
        return try ChatFileStaging.stage(data, id: attachment.id, name: attachment.name)
    }
    private func openImage() {
        do {
            let file = try sourceFile()
            #if os(macOS)
            NSWorkspace.shared.open(file)
            #else
            openingFile = ChatPreviewedFile(id: attachment.id, url: file, name: attachment.name)
            #endif
        } catch { self.error = L10n.text("common.chat.images.unavailable") }
    }
    private func saveImage() {
        do {
            guard let reference = request.reference else { throw CancellationError() }
            let source = try sourceFile()
            #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.name
            panel.begin { result in
                guard result == .OK, let destination = panel.url,
                      source.standardizedFileURL != destination.standardizedFileURL,
                      model.currentReference == reference, WorkCacheAccess.canRead(reference) else { return }
                Task { await copyImage(source, to: destination, reference: reference) }
            }
            #else
            savingFile = ChatPreviewedFile(id: attachment.id, url: source, name: attachment.name)
            #endif
        } catch { self.error = L10n.text("common.chat.images.save_failed") }
    }

    private func copyImage(_ source: URL, to destination: URL, reference: WorkReference) async {
        guard !Task.isCancelled, model.currentReference == reference, WorkCacheAccess.canRead(reference) else { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".tokenstat-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: temporary)
            }.value
            // The slow copy never publishes a destination. Only this actor
            // may finish it, after checking the owner and access again.
            guard !Task.isCancelled, model.currentReference == reference, WorkCacheAccess.canRead(reference) else { return }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch {
            if model.currentReference == reference, WorkCacheAccess.canRead(reference) {
                self.error = L10n.text("common.chat.images.save_failed")
            }
        }
    }
}

#if os(macOS)
/// Keep native sheet focus and keyboard behavior while making its dimmed
/// parent a dismissal target. Consume the click so it cannot activate chat.
private struct ChatImageOutsideDismiss: NSViewRepresentable {
    let dismiss: () -> Void
    func makeNSView(context: Context) -> OutsideDismissView { OutsideDismissView() }
    func updateNSView(_ view: OutsideDismissView, context: Context) { view.dismiss = dismiss }
    static func dismantleNSView(_ view: OutsideDismissView, coordinator: ()) { view.stopMonitoring() }

    final class OutsideDismissView: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let sheet = self.window, let parent = sheet.sheetParent,
                      event.window === parent, parent.attachedSheet === sheet,
                      sheet.attachedSheet == nil,
                      NSApp.modalWindow == nil || NSApp.modalWindow === sheet else { return event }
                // Wait until AppKit finishes dispatching this event before
                // ending the sheet whose modal loop is handling it.
                DispatchQueue.main.async { [weak self, weak sheet, weak parent] in
                    guard let self, let sheet, let parent, self.window === sheet,
                          sheet.sheetParent === parent, parent.attachedSheet === sheet,
                          sheet.attachedSheet == nil,
                          NSApp.modalWindow == nil || NSApp.modalWindow === sheet else { return }
                    self.dismiss?()
                }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif

#if !os(macOS)
private struct ChatImageExporter: UIViewControllerRepresentable {
    let file: URL
    let onDone: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onDone() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onDone() }
    }
}
#endif
