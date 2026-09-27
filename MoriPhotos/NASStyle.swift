import SwiftUI

enum NASStyle {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.035, green: 0.048, blue: 0.063, alpha: 1)
            : UIColor(red: 0.965, green: 0.973, blue: 0.944, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.094, blue: 0.113, alpha: 1)
            : .white
    })
    static let surfaceRaised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.16, blue: 0.18, alpha: 1)
            : UIColor(red: 0.90, green: 0.93, blue: 0.86, alpha: 1)
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.79, green: 0.97, blue: 0.32, alpha: 1)
            : UIColor(red: 0.26, green: 0.39, blue: 0.04, alpha: 1)
    })
    static let signal = Color(red: 0.81, green: 0.98, blue: 0.34)
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
    static let outline = Color.primary.opacity(0.11)
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
                        Text(title).font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(selection == title ? NASStyle.ink : Color.primary.opacity(0.6))
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(selection == title ? NASStyle.signal : .clear, in: RoundedRectangle(cornerRadius: 13))
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
            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
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
            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
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
                    Text(title).font(.subheadline.weight(selection == title ? .bold : .medium))
                        .foregroundStyle(selection == title ? NASStyle.ink : Color.primary.opacity(0.6))
                        .padding(.horizontal, 17).frame(minWidth: 44, minHeight: 44)
                        .background(selection == title ? NASStyle.signal : NASStyle.surface, in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == title ? .isSelected : [])
                    .accessibilityIdentifier("photoFilter_" + title)
            }
        }
    }
}
