import SwiftUI

@MainActor
final class DesktopFileDirectory: ObservableObject {
    let folder: NASFile?
    let store = NASFileBrowserStore()
    @Published var query = ""
    @Published var selection: String?
    @Published var sort = FileSort.name
    @Published var ascending = true
    var loadedSort: String?
    var sortKey: String { sort.rawValue + String(ascending) }
    var key: String { folder?.path ?? "/" }
    init(folder: NASFile?) { self.folder = folder }
}

@MainActor
final class DesktopFileNavigation: ObservableObject {
    @Published private(set) var current = DesktopFileDirectory(folder: nil)
    @Published private(set) var back: [NASFile?] = []
    @Published private(set) var forward: [NASFile?] = []
    private var directories: [String: DesktopFileDirectory] = [:]
    private var recent: [String] = []
    var canGoUp: Bool { current.folder != nil }
    var breadcrumbs: [NASFile] {
        guard let path = current.folder?.path else { return [] }
        var prefix = ""
        return path.split(separator: "/").map { component in
            prefix += "/" + component
            return NASFile(name: String(component), path: prefix, isdir: true, additional: nil)
        }
    }
    func open(_ folder: NASFile?) {
        guard folder?.isdir != false, (folder?.path ?? "/") != current.key else { return }
        back.append(current.folder); back = Array(back.suffix(100)); forward = []
        move(to: folder)
    }
    func goBack() {
        guard !back.isEmpty else { return }
        let target = back.removeLast(); forward.append(current.folder); move(to: target)
    }
    func goForward() {
        guard !forward.isEmpty else { return }
        let target = forward.removeLast(); back.append(current.folder); move(to: target)
    }
    func goUp() { guard canGoUp else { return }; open(breadcrumbs.dropLast().last) }
    private func move(to folder: NASFile?) {
        directories[current.key] = current
        let key = folder?.path ?? "/"
        recent.removeAll { $0 == current.key || $0 == key }; recent.append(current.key); recent.append(key)
        if let cached = directories[key] { current = cached }
        else { current = DesktopFileDirectory(folder: folder); directories[key] = current }
        while recent.count > 32 { let oldest = recent.removeFirst(); directories.removeValue(forKey: oldest) }
    }
}

extension NASFile {
    var kindLabel: String {
        if isdir { return "文件夹" }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : ext + " 文件"
    }
    var canQuickLook: Bool {
        !isdir && ["jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "pdf", "txt", "md", "csv", "json", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key"].contains((name as NSString).pathExtension.lowercased())
    }
}
