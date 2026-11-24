import SwiftUI

enum Theme {
    static let bg1 = Color(red: 0.05, green: 0.06, blue: 0.09)
    static let bg2 = Color(red: 0.12, green: 0.08, blue: 0.19)
    static let accent = Color(red: 1.0, green: 0.56, blue: 0.22)
    static let accent2 = Color(red: 0.96, green: 0.27, blue: 0.47)
    static let card = Color.white.opacity(0.07)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
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
    var size: CGFloat = 52
    @State private var start: Double?

    private var norm: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
    }

    private var readout: String {
        switch unit {
        case "Hz":
            return value >= 1000 ? String(format: "%.1f kHz", value / 1000) : String(format: "%.0f Hz", value)
        case "%", "ms":
            return String(format: "%.0f%@", value, unit == "%" ? "%" : " ms")
        case ":1":
            return String(format: "%.1f:1", value)
        case "s":
            return String(format: "%.1f s", value)
        default:
            return String(format: "%.1f %@", value, unit)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * max(norm, 0.001))
                    .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                ZStack { Capsule().fill(.white).frame(width: 2.5, height: size * 0.19).offset(y: -size * 0.30) }
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-135 + 270 * norm))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if start == nil { start = norm }
                let n = min(1, max(0, start! - g.translation.height / 160))
                value = range.lowerBound + n * (range.upperBound - range.lowerBound)
            }.onEnded { _ in start = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = def })
            Text(label).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            Text(readout).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
        }
    }
}

struct SegmentBar: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    selection = i
                } label: {
                    Text(options[i])
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(selection == i ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.06)),
                                    in: Capsule())
                        .foregroundStyle(selection == i ? Color.white : Color.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.28), in: Capsule())
    }
}