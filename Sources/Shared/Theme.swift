import SwiftUI

enum Theme {
    static let bg1 = Color(red: 0.05, green: 0.06, blue: 0.09)
    static let bg2 = Color(red: 0.12, green: 0.08, blue: 0.19)
    static let accent = Color(red: 1.0, green: 0.56, blue: 0.22)
    static let accent2 = Color(red: 0.96, green: 0.27, blue: 0.47)
    static let card = Color.white.opacity(0.07)
}

struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [Theme.bg1, Theme.bg2], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(RadialGradient(colors: [Theme.accent2.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 380))
            .ignoresSafeArea()
    }
}

struct Knob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let def: Double
    var unit = "dB"
    @State private var start: Double?

    private var norm: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * max(norm, 0.001))
                    .stroke(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                ZStack { Capsule().fill(.white).frame(width: 3, height: 11).offset(y: -17) }
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-135 + 270 * norm))
            }
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if start == nil { start = norm }
                let n = min(1, max(0, start! - g.translation.height / 170))
                value = range.lowerBound + n * (range.upperBound - range.lowerBound)
            }.onEnded { _ in start = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = def })
            Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text(String(format: "%.1f %@", value, unit)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
        }
    }
}
