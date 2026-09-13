import SwiftUI
import QuickLook

enum FilePreviewError: LocalizedError {
    case tooLarge, unsupported
    var errorDescription: String? {
        switch self {
        case .tooLarge: "快速预览支持 30 MB 以内的文件，请先下载较大的文件。"
        case .unsupported: "这种文件暂不支持快速预览，可以下载后用相应应用打开。"
        }
    }
}

@MainActor
final class NASFilePreviewModel: ObservableObject {
    static let limit: Int64 = 30_000_000
    @Published var url: URL?
    @Published var error: String?
    @Published var received: Int64 = 0
    @Published var expected: Int64?
    private var directory: URL?
    private var generation = UUID()
    private var transfer: FileTransfer?

    func load(file: NASFile, client: SynologyClient, configuration: URLSessionConfiguration = .ephemeral) async {
        stop(); error = nil; received = 0; expected = nil
        let ticket = generation
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            guard file.canQuickLook else { throw FilePreviewError.unsupported }
            let current = try await client.fileInfo(path: file.path)
            try Task.checkCancellation()
            guard ticket == generation else { return }
            expected = current.size
            if let size = current.size, size > Self.limit { throw FilePreviewError.tooLarge }
            let request = try await client.fileDownloadRequest(path: current.path)
            try Task.checkCancellation()
            guard ticket == generation else { return }
            let operation = FileTransfer(configuration: configuration, byteLimit: Self.limit) { [weak self] bytes, _ in
                Task { @MainActor in
                    guard let self, ticket == self.generation else { return }
                    self.received = bytes
                }
            }
            transfer = operation
            let (location, response) = try await operation.run(request); temporary = location
            try Task.checkCancellation()
            guard ticket == generation else { return }
            try FileTransfer.validate(file: location, response: response, expected: current.size)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MoriPreview-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            directory = folder
            let safeName = NASDownload(id: UUID(), owner: "", file: current, created: Date()).localName
            let target = folder.appendingPathComponent(safeName)
            try FileManager.default.moveItem(at: location, to: target)
            #if targetEnvironment(macCatalyst)
            guard QLPreviewController.canPreviewItem(target as NSURL) else { throw FilePreviewError.unsupported }
            #else
            guard QLPreviewController.canPreview(target as NSURL) else { throw FilePreviewError.unsupported }
            #endif
            url = target
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            self.error = friendlyError(error)
        }
    }
    func stop() {
        generation = UUID(); transfer?.cancel(); transfer = nil; url = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

struct NASQuickPreview: View {
    let file: NASFile
    let client: SynologyClient
    let owner: String
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = NASFilePreviewModel()
    @State private var downloaded = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(downloaded ? "已加入下载" : AppPlatform.downloadTitle, systemImage: "arrow.down.circle") {
                    app.downloads.enqueue(file, owner: owner, client: client); downloaded = true
                }.disabled(downloaded)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            Group {
                if let url = model.url { NativeQuickLook(url: url).accessibilityIdentifier("quickLookContent") }
                else if let error = model.error { ContentUnavailableView("无法预览", systemImage: "doc", description: Text(error)) }
                else {
                    VStack(spacing: 12) {
                        ProgressView("正在准备预览…")
                        Text(ByteCountFormatter.string(fromByteCount: model.received, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.desktopSheet(width: 760, height: 580)
            .task {
                var configuration = URLSessionConfiguration.ephemeral
                #if DEBUG && (targetEnvironment(simulator) || MORI_DESKTOP_QA)
                if FileStationFixture.enabled || NASConnectionFixture.enabled { configuration = FileStationFixture.configuration() }
                #endif
                await model.load(file: file, client: client, configuration: configuration)
            }.onDisappear { model.stop() }
    }
}

private struct NativeQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
