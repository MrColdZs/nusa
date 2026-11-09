import AppKit
import SwiftUI

struct FocusSession: Equatable {
    enum Phase { case focus, rest }
    var phase: Phase
    var end: Date
    var total: TimeInterval
    var taskId: String?
    var title: String?
}

private let mint = Color(red: 0.36, green: 0.86, blue: 0.66)
private let restTint = Color(red: 1, green: 0.72, blue: 0.35)

extension IslandModel {
    private static var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "focusCount-" + f.string(from: Date())
    }

    var focusToday: Int { UserDefaults.standard.integer(forKey: Self.todayKey) }

    func startFocus(minutes: Double = 25, task: TaskItem? = nil) {
        begin(FocusSession(phase: .focus, end: Date().addingTimeInterval(minutes * 60), total: minutes * 60, taskId: task?.id, title: task?.title))
    }

    func startBreak(minutes: Double = 5) {
        begin(FocusSession(phase: .rest, end: Date().addingTimeInterval(minutes * 60), total: minutes * 60, taskId: nil, title: nil))
    }

    func stopFocus() {
        focusWork?.cancel()
        focus = nil
    }

    private func begin(_ s: FocusSession) {
        focusWork?.cancel()
        flash = nil
        focus = s
        let work = DispatchWorkItem { [weak self] in self?.finishFocus() }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + s.total, execute: work)
    }

    private func finishFocus() {
        guard let s = focus else { return }
        focus = nil
        if s.phase == .focus {
            UserDefaults.standard.set(focusToday + 1, forKey: Self.todayKey)
            NSSound(named: "Hero")?.play()
        } else {
            NSSound(named: "Pop")?.play()
        }
        if !pinned { expanded = false }
        show(.focusEnd(rest: s.phase == .rest, title: s.title), for: 60)
    }
}

/// Notch kecil pas fokus: tugasnya + sisa waktu.
struct CompactFocus: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let f = model.focus {
                let left = max(0, f.end.timeIntervalSince(ctx.date))
                let tint = f.phase == .focus ? mint : restTint
                HStack(spacing: 7) {
                    ZStack {
                        Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: f.total > 0 ? 1 - left / f.total : 0)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    if model.notch == nil {
                        Text(f.phase == .focus ? (f.title ?? "Focus") : "Break")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(clock(left.rounded(.up))).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
                }
                .padding(.horizontal, 11)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(f.phase == .focus ? "Focusing" : "On a break"), \(clock(left)) left")
            }
        }
    }
}

/// Pop-up akhir sesi fokus / istirahat.
struct FocusEndPopup: View {
    let rest: Bool
    let title: String?
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rest ? "cup.and.saucer.fill" : "target")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(rest ? restTint : mint)
                .frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(rest ? "Break’s over" : "Focus session done").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(rest ? "Ready for another round?" : "\(model.focusToday) today\(title.map { " · \($0)" } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            if rest {
                pill("Focus", "target", mint) { model.startFocus() }
            } else {
                pill("Break", "cup.and.saucer.fill", restTint) { model.startBreak() }
            }
            Button { model.flash = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(0.12))).foregroundStyle(.white)
            }
            .buttonStyle(Press())
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
    }

    private func pill(_ text: String, _ symbol: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 11).frame(height: 28).background(Capsule().fill(tint))
        }
        .buttonStyle(Press())
    }
}
