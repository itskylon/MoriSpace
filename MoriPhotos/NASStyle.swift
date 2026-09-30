import SwiftUI

enum NASStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.065, blue: 0.075, alpha: 1)
            : UIColor(red: 0.965, green: 0.973, blue: 0.973, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.119, blue: 0.130, alpha: 1)
            : .white
    })
    static let surfaceRaised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.175, blue: 0.185, alpha: 1)
            : UIColor(red: 0.925, green: 0.940, blue: 0.938, alpha: 1)
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.79, blue: 0.72, alpha: 1)
            : UIColor(red: 0.10, green: 0.43, blue: 0.38, alpha: 1)
    })
    // Filled actions use white labels; selection surfaces use the adaptive accent.
    static let signal = Color(red: 0.16, green: 0.48, blue: 0.43)
    static let selection = accent.opacity(0.12)
    static let sidebar = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.080, green: 0.097, blue: 0.102, alpha: 1)
            : UIColor(red: 0.937, green: 0.949, blue: 0.948, alpha: 1)
    })
    static let ink = Color(red: 0.035, green: 0.055, blue: 0.075)
    static let violet = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.72, green: 0.64, blue: 1, alpha: 1)
            : UIColor(red: 0.41, green: 0.28, blue: 0.84, alpha: 1)
    })
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.69, blue: 1, alpha: 1)
            : UIColor(red: 0.12, green: 0.37, blue: 0.84, alpha: 1)
    })
    static let coral = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.57, blue: 0.42, alpha: 1)
            : UIColor(red: 0.76, green: 0.24, blue: 0.13, alpha: 1)
    })
    static let outline = Color.primary.opacity(0.07)
    static let inset = Color.primary.opacity(0.045)
}

struct NASSectionTabs: View {
    @Binding var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal) { choices }.scrollIndicators(.hidden)
        } else { choices }
    }
    private var choices: some View {
        HStack(spacing: 5) {
            ForEach(["照片", "文件", "状态"], id: \.self) { title in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = title }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: title == "照片" ? "photo.stack" : title == "文件" ? "folder" : "waveform.path.ecg")
                            .font(.system(size: 13, weight: .semibold))
                        Text(title).font(.subheadline.weight(selection == title ? .semibold : .medium))
                    }
                    .foregroundStyle(selection == title ? NASStyle.accent : Color.secondary)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(selection == title ? NASStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 11))
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
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                .foregroundStyle(NASStyle.accent).frame(width: 28, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct NASFolderChip: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").font(.system(size: 15, weight: .medium)).foregroundStyle(NASStyle.accent)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 13).frame(minHeight: 44)
            .background(NASStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(NASStyle.outline, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 13))
            .accessibilityElement(children: .ignore).accessibilityLabel("文件夹，\(title)")
    }
}

struct MoriFilterBar: View {
    let titles: [String]
    @Binding var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal) { choices }.scrollIndicators(.hidden)
        } else { choices }
    }
    private var choices: some View {
        HStack(spacing: 6) {
            ForEach(titles, id: \.self) { title in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { selection = title }
                } label: {
                    Text(title).font(.subheadline.weight(selection == title ? .semibold : .medium))
                        .foregroundStyle(selection == title ? NASStyle.accent : Color.secondary)
                        .padding(.horizontal, 17).frame(minWidth: 44, minHeight: 44)
                        .background(selection == title ? NASStyle.selection : .clear, in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == title ? .isSelected : [])
                    .accessibilityIdentifier("photoFilter_" + title)
            }
        }
    }
}
