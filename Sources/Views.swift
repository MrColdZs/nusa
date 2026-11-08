import AppKit
import ServiceManagement
import SwiftUI

let dim = Color.white.opacity(0.58)
let hairline = Color.white.opacity(0.1)

private struct BlurFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale)
    }
}

private extension AnyTransition {
    static var morph: AnyTransition {
        .modifier(active: BlurFade(radius: 8, opacity: 0, scale: 0.92), identity: BlurFade(radius: 0, opacity: 1, scale: 1))
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Siluet notch: rata di tepi atas layar, bahu cekung, sudut bawah membulat.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let s = shoulder, c = min(radius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.minY + s), control: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.minX + s + c, y: r.maxY), control: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - c), control: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat
    @State private var height: CGFloat
    @State private var radius: CGFloat
    @State private var shoulder: CGFloat

    init(model: IslandModel) {
        self.model = model
        let s = model.size
        _width = State(initialValue: s.width)
        _height = State(initialValue: s.height)
        _radius = State(initialValue: s.radius)
        _shoulder = State(initialValue: s.shoulder)
    }

    private var wide: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.74)
    }

    private var tall: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.36, dampingFraction: 0.82)
    }

    /// Buka: melebar dulu baru turun. Tutup: naik dulu baru menyempit.
    private func morph(to s: IslandSize, from old: IslandSize) {
        let opening = s.height > old.height
        let lag = reduceMotion ? 0 : 0.07
        withAnimation(opening ? wide : wide.delay(s.height < old.height ? lag : 0)) { width = s.width }
        withAnimation(opening ? tall.delay(lag) : tall) {
            height = s.height
            radius = s.radius
            shoulder = s.shoulder
        }
    }

    var body: some View {
        let target = model.size
        let shape = NotchShape(shoulder: shoulder, radius: radius)
        ZStack(alignment: .top) {
            content
                .id(model.presentation.kind)
                .frame(width: target.width, height: target.height)
                .transition(.morph)
        }
        .frame(width: width, height: height, alignment: .top)
        .padding(.horizontal, shoulder)
        .background {
            ZStack {
                Color.black
                // Warna sampul tipis di pojok kiri atas panel Home; hitam lagi ke kanan bawah, tanpa glow
                if model.expanded, model.tab == .home, model.media.exists, model.tintVivid {
                    LinearGradient(colors: [model.tint.opacity(0.22), model.tint.opacity(0.05), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: model.tintVivid)
        }
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(model.expanded || model.flash == .track ? 0.3 : 0), radius: 14, y: 7)
        .offset(x: model.nudge)
        .animation(.spring(response: 0.26, dampingFraction: 0.5), value: model.nudge)
        .onTapGesture {
            if case .prayer = model.flash { return model.dismissPrayer() }
            if case .task = model.flash {
                model.flash = nil
                model.tab = .tasks
                model.expanded = true
                return
            }
            guard !model.expanded else { return }
            model.expanded = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        .contextMenu { IslandMenu() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.22), value: model.presentation.kind)
        .onChange(of: target) { old, new in morph(to: new, from: old) }
    }

    @ViewBuilder private var content: some View {
        switch model.presentation {
        case .idle: IdleCarousel(model: model)
        case .music: CompactMusic(model: model)
        case .timer: CompactTimer(model: model)
        case .flash(.track): TrackPopup(model: model)
        case .flash(.prayer(let name, let time, let soon)): PrayerPopup(name: name, time: time, soon: soon)
        case .flash(.task(let id, let title, let time)): TaskPopup(id: id, title: title, time: time, model: model)
        case .flash(.rain(let time, let chance)): RainPopup(time: time, chance: chance)
        case .flash(.charging(let percent, true)): ChargingPopup(percent: percent, minutesToFull: model.minutesToFull)
        case .flash(.device(let name, let symbol, let detail)): DevicePopup(name: name, symbol: symbol, detail: detail)
        case .flash(.focusEnd(let rest, let title)): FocusEndPopup(rest: rest, title: title, model: model)
        case .focus: CompactFocus(model: model)
        case .flash(let f): FlashView(flash: f)
        case .expanded: ExpandedView(model: model)
        }
    }
}

private struct IslandMenu: View {
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Button(atLogin ? "Don’t open at login" : "Open at login") {
            if atLogin { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
            atLogin = SMAppService.mainApp.status == .enabled
        }
        Divider()
        Button("Quit Nusa") { NSApp.terminate(nil) }
    }
}

// MARK: - Bagian kecil

struct Artwork: View {
    let image: NSImage?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "music.note").font(.system(size: side * 0.42, weight: .medium)).foregroundStyle(dim)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Animasinya jalan di render server Core Animation, jadi proses app tetap diem pas lagu muter.
struct Equalizer: NSViewRepresentable {
    let playing: Bool
    let tint: Color
    var height: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let durations: [CFTimeInterval] = [0.46, 0.34, 0.58, 0.40]
    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 2

    private var width: CGFloat { Self.barWidth * 4 + Self.gap * 3 }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.wantsLayer = true
        for i in 0..<4 {
            let bar = CALayer()
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            bar.position = CGPoint(x: CGFloat(i) * (Self.barWidth + Self.gap) + Self.barWidth / 2, y: height / 2)
            bar.cornerRadius = Self.barWidth / 2
            view.layer?.addSublayer(bar)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let animate = playing && !reduceMotion
        for (i, bar) in (view.layer?.sublayers ?? []).enumerated() {
            bar.backgroundColor = NSColor(tint).cgColor
            bar.transform = CATransform3DMakeScale(1, 0.28, 1)
            guard animate else {
                bar.removeAnimation(forKey: "wave")
                continue
            }
            guard bar.animation(forKey: "wave") == nil else { continue }
            let wave = CABasicAnimation(keyPath: "transform.scale.y")
            wave.fromValue = 0.28
            wave.toValue = 1
            wave.duration = Self.durations[i]
            wave.autoreverses = true
            wave.repeatCount = .infinity
            wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wave.timeOffset = Double(i) * 0.17
            wave.isRemovedOnCompletion = false
            wave.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
            bar.add(wave, forKey: "wave")
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: width, height: height)
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .foregroundStyle(.white)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Tampilan ringkas

private struct CompactMusic: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 8) {
            Artwork(image: model.art, side: 16, radius: 4)
            Text(model.media.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 6)
            Equalizer(playing: model.media.playing, tint: model.tint)
            if model.timerRunning { TimerRing(model: model) }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.media.title), \(model.media.artist)")
    }
}

struct Countdown: View {
    let end: Date
    var font: Font = .system(size: 11, weight: .semibold)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(clock(end.timeIntervalSince(ctx.date).rounded(.up)))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(.orange)
        }
    }
}

private struct CompactTimer: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack {
            Image(systemName: "timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            Spacer()
            if let end = model.timerEnd { Countdown(end: end) }
        }
        .padding(.horizontal, 10)
    }
}

private struct TimerRing: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = model.timerEnd?.timeIntervalSince(ctx.date) ?? 0
            let fraction = model.timerTotal > 0 ? max(0, left / model.timerTotal) : 0
            ZStack {
                Circle().stroke(.orange.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .accessibilityLabel("Time remaining \(clock(left))")
        }
    }
}

private struct TrackPopup: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            Artwork(image: model.art, side: 40, radius: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.media.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(model.media.artist).font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            Equalizer(playing: model.media.playing, tint: model.tint, height: 15)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing \(model.media.title), \(model.media.artist)")
    }
}

private struct FlashView: View {
    let flash: Flash

    var body: some View {
        switch flash {
        case .track, .prayer, .task, .rain, .focusEnd, .device:
            EmptyView()
        case .charging(let percent, let on):
            row(symbol: on ? "bolt.fill" : "powerplug", tint: on ? .green : dim,
                text: on ? "Charging" : "Charger removed", value: "\(percent)%", valueTint: on ? .green : .white)
        case .lowBattery(let percent):
            row(symbol: "battery.25percent", tint: .red, text: "Low battery", value: "\(percent)%", valueTint: .red)
        case .timerDone:
            row(symbol: "timer", tint: .orange, text: "Time’s up", value: "", valueTint: .orange)
        case .volume(let level, let muted):
            HStack(spacing: 8) {
                Image(systemName: muted || level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(hairline)
                        Capsule().fill(.white).frame(width: g.size.width * (muted ? 0 : level))
                    }
                }
                .frame(height: 4)
                Text(muted ? "Muted" : "\(Int((level * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
        }
    }

    private func row(symbol: String, tint: Color, text: String, value: String, valueTint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(valueTint)
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}
