import SwiftUI

enum NASStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.060, blue: 0.065, alpha: 1)
            : UIColor(red: 0.975, green: 0.982, blue: 0.978, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.085, green: 0.110, blue: 0.115, alpha: 1)
            : .white
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.49, green: 0.83, blue: 0.70, alpha: 1)
            : UIColor(red: 0.13, green: 0.39, blue: 0.30, alpha: 1)
    })
    static let outline = Color.primary.opacity(0.07)
}

struct NASSectionTabs: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 18) {
            ForEach(["照片", "文件", "状态"], id: \.self) { title in
                Button { selection = title } label: {
                    VStack(spacing: 5) {
                        Text(title).font(.headline)
                            .foregroundStyle(selection == title ? Color.primary : .secondary)
                        Capsule().fill(selection == title ? NASStyle.accent : .clear)
                            .frame(width: 18, height: 3)
                    }.frame(minWidth: 48, minHeight: 44)
                        .contentShape(Rectangle())
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
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                .foregroundStyle(NASStyle.accent).frame(width: 42, height: 42)
                .background(NASStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct NASFolderChip: View {
    let title: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(NASStyle.accent)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
        }.padding(.horizontal, 14).frame(minHeight: 48)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore).accessibilityLabel("文件夹，\(title)")
    }
}
