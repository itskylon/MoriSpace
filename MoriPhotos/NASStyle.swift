import SwiftUI

enum NASStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.063, blue: 0.079, alpha: 1)
            : UIColor(red: 0.964, green: 0.964, blue: 0.957, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.094, green: 0.106, blue: 0.129, alpha: 1)
            : .white
    })
    static let surfaceRaised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.137, green: 0.153, blue: 0.180, alpha: 1)
            : UIColor(red: 0.937, green: 0.941, blue: 0.953, alpha: 1)
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.57, green: 0.70, blue: 1, alpha: 1)
            : UIColor(red: 0.20, green: 0.31, blue: 0.74, alpha: 1)
    })
    // Filled actions use white labels; selection surfaces use the adaptive accent.
    static let signal = Color(red: 0.23, green: 0.35, blue: 0.78)
    static let selection = accent.opacity(0.11)
    static let hero = LinearGradient(colors: [Color(red: 0.10, green: 0.15, blue: 0.25), Color(red: 0.16, green: 0.24, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let heroText = Color.white.opacity(0.84)
    static let sidebar = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.070, green: 0.078, blue: 0.098, alpha: 1)
            : UIColor(red: 0.945, green: 0.949, blue: 0.956, alpha: 1)
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
        HStack(spacing: 4) {
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
                    .background(selection == title ? NASStyle.selection : .clear, in: Capsule())
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
                        .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
                        .background(selection == title ? NASStyle.selection : .clear, in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == title ? .isSelected : [])
                    .accessibilityIdentifier("photoFilter_" + title)
            }
        }
    }
}

struct MoriSectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    func moriPanel(radius: CGFloat = 18) -> some View {
        background(NASStyle.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(NASStyle.outline, lineWidth: 0.5) }
    }
    func moriHeroPanel() -> some View {
        background(NASStyle.hero, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1) }
    }
}
