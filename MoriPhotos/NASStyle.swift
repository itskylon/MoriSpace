import SwiftUI

enum NASStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.065, green: 0.071, blue: 0.078, alpha: 1)
            : .white
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.095, green: 0.103, blue: 0.111, alpha: 1)
            : UIColor(red: 0.965, green: 0.969, blue: 0.973, alpha: 1)
    })
    static let surfaceRaised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.14, blue: 0.15, alpha: 1)
            : .white
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.39, green: 0.88, blue: 0.72, alpha: 1)
            : UIColor(red: 0.04, green: 0.46, blue: 0.35, alpha: 1)
    })
    static let outline = Color.primary.opacity(0.07)
    static let inset = Color.primary.opacity(0.035)
}

struct NASSectionTabs: View {
    @Binding var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 20) {
            ForEach(["照片", "文件", "状态"], id: \.self) { title in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selection = title }
                } label: {
                    Text(title).font(.subheadline.weight(selection == title ? .semibold : .regular))
                        .foregroundStyle(selection == title ? Color.primary : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(selection == title ? NASStyle.accent : .clear).frame(height: 2)
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == title ? .isSelected : [])
                    .accessibilityIdentifier(title == "照片" ? "nasSectionPhotos" : (title == "文件" ? "nasSectionFiles" : "nasSectionMonitor"))
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("群晖内容")
    }
}

struct NASActionLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                .foregroundStyle(NASStyle.accent).frame(width: 28, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct NASFolderChip: View {
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder").font(.system(size: 15, weight: .medium)).foregroundStyle(NASStyle.accent)
            Text(title).font(.subheadline).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
        }.padding(.horizontal, 12).frame(minHeight: 44)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore).accessibilityLabel("文件夹，\(title)")
    }
}

struct MoriFilterBar: View {
    let titles: [String]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 22) {
            ForEach(titles, id: \.self) { title in
                Button { selection = title } label: {
                    Text(title).font(.subheadline.weight(selection == title ? .semibold : .regular))
                        .foregroundStyle(selection == title ? Color.primary : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(selection == title ? Color.primary : .clear).frame(height: 2)
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == title ? .isSelected : [])
                    .accessibilityIdentifier("photoFilter_" + title)
            }
        }
    }
}
