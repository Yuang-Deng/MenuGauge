import SwiftUI

struct UsageBar: View {
    let fraction: Double?
    let tint: Color
    let label: String
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let fraction {
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "不可用")
    }
}
