import SwiftUI

enum NASStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.060, blue: 0.070, alpha: 1)
            : UIColor(red: 0.960, green: 0.965, blue: 0.970, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.115, blue: 0.130, alpha: 1)
            : .white
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.43, green: 0.80, blue: 0.68, alpha: 1)
            : UIColor(red: 0.12, green: 0.42, blue: 0.34, alpha: 1)
    })
    static let outline = Color.primary.opacity(0.08)
    static let inset = Color.primary.opacity(0.035)
}

struct NASSectionTabs: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(["照片", "文件", "状态"], id: \.self) { title in
                Button { selection = title } label: {
                    Text(title).font(.subheadline.weight(selection == title ? .semibold : .medium))
                        .foregroundStyle(selection == title ? NASStyle.accent : .secondary)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(selection == title ? NASStyle.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
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
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .foregroundStyle(NASStyle.accent).frame(width: 38, height: 38)
                .background(NASStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct NASFolderChip: View {
    let title: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(NASStyle.accent)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
        }.padding(.horizontal, 12).frame(minHeight: 44)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore).accessibilityLabel("文件夹，\(title)")
    }
}

/// A compact content filter that stays readable at larger text sizes.
struct MoriFilterBar: View {
    let titles: [String]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(titles, id: \.self) { title in
                Button { selection = title } label: {
                    Text(title).font(.subheadline.weight(selection == title ? .semibold : .medium))
                        .foregroundStyle(selection == title ? NASStyle.accent : .secondary)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(selection == title ? NASStyle.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == title ? .isSelected : [])
                    .accessibilityIdentifier("photoFilter_" + title)
            }
        }
    }
}
