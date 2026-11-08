import AppKit
import SwiftUI

private let mint = Color(red: 0.36, green: 0.86, blue: 0.66)
private let late = Color(red: 1, green: 0.45, blue: 0.42)

/// "Today 15:30", "Tomorrow 09:00", "Mon 10 · 09:00"
func dueText(_ d: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let time = f.string(from: d)
    if cal.isDateInToday(d) { return "Today \(time)" }
    if cal.isDateInTomorrow(d) { return "Tomorrow \(time)" }
    if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
    f.dateFormat = "EEE d MMM"
    f.locale = Locale(identifier: "en_US")
    return "\(f.string(from: d)) · \(time)"
}

struct TasksTab: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var store = TaskStore.shared
    @State private var text = ""
    @State private var pick: (label: String, date: Date)?
    @FocusState private var focused: Bool

    private var preview: Date? { pick?.date ?? TaskParser.parse(text).due }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let open = store.items.filter { !$0.done }
            let overdue = open.filter { ($0.due ?? .distantFuture) < now }.count
            VStack(spacing: 10) {
                input
                HStack(spacing: 6) {
                    ForEach(quickPicks(now), id: \.label) { p in
                        Chip(text: p.label, on: pick?.label == p.label) { pick = pick?.label == p.label ? nil : p }
                    }
                    Spacer()
                    focusButton
                    Text(overdue > 0 ? "\(open.count) to do · \(overdue) overdue" : "\(open.count) to do")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(overdue > 0 ? late : dim)
                }
                if store.items.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(dim)
                        Text("Nothing to do").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Type a task with a time, like “Rapat QC besok jam 9” or “Call Budi in 30 min”.")
                            .font(.system(size: 11.5)).foregroundStyle(dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.sorted) { t in TaskRow(task: t, now: now, model: model) }
                        }
                    }
                }
            }
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundStyle(mint)
            TextField("Add a task… “Rapat QC besok jam 9”", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(add)
            if let d = preview, !text.isEmpty {
                Label(dueText(d), systemImage: "bell.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(mint))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(.white.opacity(focused ? 0.14 : 0.09)))
        .onTapGesture { focused = true }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: preview)
    }

    /// Mulai fokus 25 menit (tanpa tugas), atau stop kalau lagi jalan.
    @ViewBuilder private var focusButton: some View {
        if let f = model.focus {
            Chip(text: f.phase == .focus ? "Stop focus" : "Skip break", on: true) { model.stopFocus() }
        } else {
            Chip(text: "🎯 Focus 25m\(model.focusToday > 0 ? " · \(model.focusToday) today" : "")", on: false) { model.startFocus() }
        }
    }

    private func add() {
        guard store.add(text, due: pick?.date) != nil else { return }
        text = ""
        pick = nil
    }

    private func quickPicks(_ now: Date) -> [(label: String, date: Date)] {
        let cal = Calendar.current
        let tonight = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)!
        let tomorrow = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        var out: [(String, Date)] = [("In 30 min", now.addingTimeInterval(1800)), ("In 1 hour", now.addingTimeInterval(3600))]
        if tonight > now.addingTimeInterval(3600) { out.append(("Tonight 20:00", tonight)) }
        out.append(("Tomorrow 09:00", tomorrow))
        return out
    }
}

private struct Chip: View {
    let text: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? .black : .white.opacity(0.85))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(on ? mint : .white.opacity(hovering ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let now: Date
    @ObservedObject var model: IslandModel
    @ObservedObject private var store = TaskStore.shared
    @State private var hovering = false

    var body: some View {
        let isLate = !task.done && (task.due ?? .distantFuture) < now
        HStack(spacing: 10) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.toggle(task.id) } } label: {
                ZStack {
                    Circle().stroke(task.done ? mint : .white.opacity(0.35), lineWidth: 1.6)
                    if task.done {
                        Circle().fill(mint)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(Press())
            .accessibilityLabel(task.done ? "Mark as not done" : "Mark as done")

            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .strikethrough(task.done, color: .white.opacity(0.4))
                .foregroundStyle(task.done ? .white.opacity(0.4) : .white)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let d = task.due {
                Label(isLate ? "Overdue · \(dueText(d, now: now))" : dueText(d, now: now), systemImage: "bell")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(task.done ? .white.opacity(0.3) : isLate ? late : dim)
            }
            if !task.done {
                Button { model.startFocus(task: task) } label: {
                    Image(systemName: "target").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(mint.opacity(model.focus?.taskId == task.id ? 1 : 0.18)))
                        .foregroundStyle(model.focus?.taskId == task.id ? .black : mint)
                }
                .buttonStyle(Press())
                .opacity(hovering || model.focus?.taskId == task.id ? 1 : 0)
                .help("Focus on this for 25 minutes")
                .accessibilityLabel("Focus on \(task.title)")
            }
            Button { store.remove(task.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(Press())
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Delete task")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remind me in 10 minutes") { store.snooze(task.id) }
            Button("Remind me in 1 hour") { store.snooze(task.id, minutes: 60) }
            Button("Tomorrow 09:00") {
                let cal = Calendar.current
                store.setDue(task.id, cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!))
            }
            if task.due != nil { Button("Remove reminder") { store.setDue(task.id, nil) } }
            Divider()
            Button("Delete", role: .destructive) { store.remove(task.id) }
        }
    }
}

/// Pop-up di notch pas tugas jatuh tempo.
struct TaskPopup: View {
    let id: String
    let title: String
    let time: String
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(mint, .white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("Reminder · \(time)").font(.system(size: 11)).foregroundStyle(dim)
            }
            Spacer(minLength: 6)
            Button {
                TaskStore.shared.snooze(id)
                model.flash = nil
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.12))).foregroundStyle(.white)
            }
            .buttonStyle(Press())
            .help("Snooze 10 minutes")
            .accessibilityLabel("Snooze 10 minutes")
            Button {
                TaskStore.shared.toggle(id)
                model.flash = nil
            } label: {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                    .frame(width: 30, height: 30).background(Circle().fill(mint)).foregroundStyle(.black)
            }
            .buttonStyle(Press())
            .help("Mark as done")
            .accessibilityLabel("Mark as done")
        }
        .padding(.horizontal, 12)
    }
}
