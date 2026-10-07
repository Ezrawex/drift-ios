import SwiftUI

enum Palette {
    static let background = Color(light: 0xF6F5F0, dark: 0x111514)
    static let surface = Color(light: 0xEAEDE7, dark: 0x1B211E)
    static let ink = Color(light: 0x18251E, dark: 0xF4F3ED)
    static let secondary = Color(light: 0x536259, dark: 0xA8B7AE)
    static let accent = Color(light: 0x215B42, dark: 0xBFE8D5)
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x16281F)
}

extension Color {
    init(hex: UInt) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
    init(light: UInt, dark: UInt) {
        self.init(uiColor: UIColor { traits in UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light)) })
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol = "arrow.right"
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Text(title).font(.headline); Spacer(); Image(systemName: symbol) }
                .padding(.horizontal, 20).padding(.vertical, 17)
                .foregroundStyle(Palette.onAccent)
                .background(Palette.accent.opacity(disabled ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 16))
        }.disabled(disabled).buttonStyle(.plain)
    }
}

struct DemoBadge: View {
    var body: some View {
        Label("Demo", systemImage: "circle.dotted")
            .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.surface, in: Capsule())
            .accessibilityLabel("Demo mode. Fictional music; no cloud AI or Qobuz connection.")
    }
}

struct Sleeve: View {
    let index: Int
    var size: CGFloat = 52
    private let colors: [UInt] = [0x547A65,0xAB785A,0x526D86,0x95735D,0x879271,0x88718A,0x497D7B,0xB69B70]
    var body: some View {
        ZStack {
            Color(hex: colors[index % colors.count])
            if index % 3 == 0 {
                Circle().fill(.white.opacity(0.32)).frame(width: size * 0.72).offset(x: size * 0.19, y: -size * 0.16)
                Rectangle().fill(.black.opacity(0.25)).frame(height: size * 0.28).rotationEffect(.degrees(-25)).offset(y: size * 0.28)
            } else if index % 3 == 1 {
                ForEach(0..<5) { n in
                    Rectangle().fill(.white.opacity(0.1 + Double(n) * 0.035)).frame(width: size * 0.13).rotationEffect(.degrees(28)).offset(x: CGFloat(n - 2) * size * 0.23)
                }
                Circle().fill(.black.opacity(0.2)).frame(width: size * 0.4).offset(y: size * 0.15)
            } else {
                ForEach(0..<4) { n in
                    Circle().stroke(.white.opacity(0.35), lineWidth: max(1, size * 0.025)).frame(width: size * (0.3 + Double(n) * 0.25)).offset(x: -size * 0.15, y: size * 0.1)
                }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.14)).accessibilityHidden(true)
    }
}

struct SourceArtwork: View {
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) { Sleeve(index: 0, size: 30); Sleeve(index: 1, size: 30) }
            HStack(spacing: 2) { Sleeve(index: 2, size: 30); Sleeve(index: 5, size: 30) }
        }.clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }
}

struct TrackRow: View {
    let track: Track
    var position: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        positionLabel
                        Sleeve(index: track.sleeve)
                        Spacer(minLength: 4)
                        durationLabel.fixedSize(horizontal: true, vertical: false)
                    }
                    songLabels
                }
            } else {
                HStack(spacing: 12) {
                    positionLabel
                    Sleeve(index: track.sleeve)
                    songLabels
                    Spacer(minLength: 4)
                    durationLabel
                }
            }
        }.padding(.vertical, 5).accessibilityElement(children: .combine)
    }
    @ViewBuilder private var positionLabel: some View {
        if let position {
            Text(String(format: "%02d", position)).font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary).frame(minWidth: 20)
        }
    }
    private var songLabels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
            Text(track.artist).font(.subheadline).foregroundStyle(Palette.secondary)
        }
    }
    private var durationLabel: some View {
        Text(track.time).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
    }
}
