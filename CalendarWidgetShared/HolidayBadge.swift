import SwiftUI

struct HolidayBadge: View {
    let kind: ChinaHolidayDay.Kind
    var fontSize: CGFloat = 9
    var body: some View {
        Text(kind == .rest ? "休" : "班")
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(kind == .rest ? Color.red : Color.blue)
            .frame(width: fontSize + 5, height: fontSize + 5)
            .background(.background, in: RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder((kind == .rest ? Color.red : Color.blue).opacity(0.3), lineWidth: 0.5) }
            .accessibilityLabel(kind == .rest ? "放假" : "调休上班")
    }
}
