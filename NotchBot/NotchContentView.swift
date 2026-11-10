import SwiftUI

/// Everything drawn in and around the notch.
///
/// One black `NotchShape` morphs between the collapsed, peek and expanded sizes.
/// Each state's content is laid out at its final size and revealed by the shape's
/// clip, so nothing reflows mid-animation.
struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var store: AgentStore

    private var mode: NotchMode { viewModel.mode }
    /// Constant so the top corners stay flush with the menu bar while the shape morphs.
    private let topRadius: CGFloat = 6
    private var bottomRadius: CGFloat { mode == .collapsed ? 14 : 22 }

    private var shape: NotchShape { NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius) }

    var body: some View {
        let size = viewModel.shapeSize
        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(mode == .collapsed ? 0 : 0.45), radius: 14, y: 6)

            ZStack(alignment: .top) {
                if mode == .collapsed {
                    CollapsedView(store: store, notchWidth: viewModel.notchWidth, notchHeight: viewModel.notchHeight)
                        .frame(width: size.width, height: viewModel.notchHeight)
                        .transition(.reveal(delay: 0.12))
                }
                if mode == .peek, let peek = viewModel.peek {
                    PeekView(event: peek)
                        .padding(.top, viewModel.notchHeight + 4)
                        .padding(.horizontal, 26)
                        .frame(width: size.width, alignment: .top)
                        .transition(.reveal(delay: 0.08))
                }
                if mode == .expanded {
                    ExpandedView(store: store)
                        .padding(.top, viewModel.notchHeight + 8)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 14)
                        .frame(width: NotchWindow.expandedWidth, height: size.height, alignment: .top)
                        .transition(.reveal(delay: 0.1))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private extension AnyTransition {
    /// Content fades in once the shape has mostly opened, and leaves quickly so the
    /// shrinking shape never squeezes it.
    static func reveal(delay: Double) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -4)).animation(.easeOut(duration: 0.22).delay(delay)),
            removal: .opacity.animation(.easeIn(duration: 0.08))
        )
    }
}

// MARK: - Collapsed

private struct CollapsedView: View {
    @ObservedObject var store: AgentStore
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// Menu-bar scale, like the status items around the notch.
    private let activeIcon: CGFloat = 22
    private let idleIcon: CGFloat = 17

    private var workingColors: [Color] {
        let tints = Harness.allCases.filter { h in store.working.contains { $0.harness == h } }.map(\.tint)
        return tints.isEmpty ? [.white] : tints
    }

    var body: some View {
        HStack(spacing: 0) {
            leftWing.frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth - 30)
            rightWing.fixedSize().frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder private var leftWing: some View {
        let inPlay = store.harnessesInPlay()
        HStack(spacing: inPlay.isEmpty ? 4 : 5) {
            if inPlay.isEmpty {
                ForEach(Harness.allCases) { h in
                    HarnessIcon(harness: h, state: .idle, size: idleIcon)
                        .opacity(0.5)
                }
            } else {
                ForEach(inPlay) { h in
                    HarnessIcon(harness: h, state: aggregate(h), size: activeIcon)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: inPlay)
    }

    @ViewBuilder private var rightWing: some View {
        if !store.waiting.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9, weight: .bold))
                    .symbolEffect(.pulse, options: .repeating)
                Text("\(store.waiting.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundColor(AgentState.waiting.color)
        } else if let just = store.justFinished {
            let failed = just.state == .failed
            Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(just.state.color)
                .symbolEffect(.bounce, value: just.id)
                .transition(.scale.combined(with: .opacity))
        } else if !store.working.isEmpty {
            HStack(spacing: 5) {
                WorkWave(colors: workingColors)
                if store.working.count > 1 {
                    Text("\(store.working.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        } else if !store.failed.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                Text("\(store.failed.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundColor(AgentState.failed.color)
        } else if let hot = store.hotPlan, hot.percent >= 75 {
            Text("\(hot.harness.displayName) \(Int(hot.percent.rounded()))%")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(hot.percent >= 90 ? AgentState.failed.color : AgentState.waiting.color)
                .help("\(hot.harness.displayName) \(hot.label) limit \(Int(hot.percent.rounded()))%")
        } else if store.completedToday > 0 {
            Text("\(store.completedToday) done")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    /// What one icon stands for when a harness has several sessions. A busy session
    /// outranks an older failure so the icon keeps moving.
    private func aggregate(_ h: Harness) -> AgentState {
        let states = Set(store.sessions.filter { $0.harness == h }.map(\.state))
        return [.waiting, .working, .failed, .done].first(where: states.contains) ?? .idle
    }
}


// MARK: - Peek

private struct PeekView: View {
    let event: PeekEvent

    private var finished: Bool { event.kind == .finished }
    private var s: AgentSession { event.session }

    private var state: AgentState {
        switch event.kind {
        case .finished: return .done
        case .needsInput: return .waiting
        case .failed: return .failed
        }
    }

    private var headline: String {
        switch event.kind {
        case .finished: return "\(s.harness.displayName) finished"
        case .needsInput: return "\(s.harness.displayName) needs input"
        case .failed: return "\(s.harness.displayName) stopped with an error"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HarnessIcon(harness: s.harness, state: state, size: 32)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: finished ? "checkmark" : "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(state.color)
                    Text(headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                // For errors and approvals the message matters more than the title.
                Text(event.kind == .finished ? s.title : (s.activity ?? s.title))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if finished, let took = s.lastTurnDuration {
                Text(Fmt.friendly(took))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { AppLauncher.focus(s) }
    }
}

// MARK: - Expanded

private struct ExpandedView: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !store.plans.isEmpty {
                VStack(spacing: 2) {
                    ForEach(store.plans) { plan in
                        PlanUsageRow(plan: plan, now: store.now)
                    }
                }
            }
            if store.sessions.isEmpty {
                Text("No active agent sessions")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(store.sessions) { s in
                            AgentRow(session: s, now: store.now)
                        }
                    }
                }
            }
            if !store.cursorConnected || !store.claudeConnected {
                HStack(spacing: 14) {
                    if !store.cursorConnected {
                        Button("Connect Cursor…") { store.connectCursor() }
                            .help("Adds NotchBot's hook bridge to ~/.cursor/hooks.json (a backup is saved first)")
                    }
                    if !store.claudeConnected {
                        Button("Show Claude approvals…") { store.connectClaude() }
                            .help("Adds a Notification hook to ~/.claude/settings.json (a backup is saved first)")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 8)
                .frame(height: 22)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            if !store.waiting.isEmpty, !store.working.isEmpty {
                Text("\(store.waiting.count) needs input")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AgentState.waiting.color)
            }
            if !store.failed.isEmpty {
                Text("\(store.failed.count) failed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AgentState.failed.color)
            }
            Spacer()
            if store.completedToday > 0 {
                Text(todayText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var headline: String {
        let working = store.working.count
        let waiting = store.waiting.count
        if working > 0 { return "\(working) working" }
        if waiting > 0 { return "\(waiting) needs input" }
        return "Agents"
    }

    private var todayText: String {
        var t = "\(store.completedToday) done today"
        if store.workedToday >= 60 { t += " · \(Fmt.friendly(store.workedToday))" }
        return t
    }
}

private struct PlanUsageRow: View {
    let plan: PlanUsage
    let now: Date

    private var primary: UsageWindow? { plan.windows.first }
    private var secondary: UsageWindow? { plan.windows.dropFirst().first }

    var body: some View {
        HStack(spacing: 8) {
            Text(plan.harness.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(plan.harness.tint)
                .frame(width: 52, alignment: .leading)
            meter
            if let primary {
                Text("\(Int(primary.percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(tone(primary.percent))
                    .frame(width: 34, alignment: .trailing)
                Text(primary.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 28, alignment: .leading)
            }
            if let secondary {
                Text("\(secondary.label) \(Int(secondary.percent.rounded()))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer(minLength: 4)
            if let note = plan.note {
                Text(note)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 18)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var meter: some View {
        GeometryReader { geo in
            let fraction = CGFloat(min(max(primary?.percent ?? 0, 0), 100) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(tone(primary?.percent ?? 0))
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 3 : 0))
            }
        }
        .frame(width: 64, height: 4)
    }

    private func tone(_ percent: Double) -> Color {
        if percent >= 90 { return AgentState.failed.color }
        if percent >= 75 { return AgentState.waiting.color }
        return plan.harness.tint
    }

    private var helpText: String {
        var parts = plan.windows.map { window -> String in
            var text = "\(plan.harness.displayName) \(window.label) \(Int(window.percent.rounded()))%"
            if let resets = window.resetsAt { text += ", resets \(Fmt.resets(resets, now: now))" }
            return text
        }
        if let note = plan.note { parts.append(note) }
        if now.timeIntervalSince(plan.asOf) > 10 * 60 {
            parts.append("as of \(Fmt.ago(now.timeIntervalSince(plan.asOf)))")
        }
        return parts.joined(separator: ". ")
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HarnessIcon(harness: session.harness, state: session.state, size: 32)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(session.state == .idle ? .white.opacity(0.6) : .white)
                        .lineLimit(1)
                    if session.helpers > 0 {
                        Text("+\(session.helpers) sub-agent\(session.helpers == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                HStack(spacing: 0) {
                    Text(session.project + "  ")
                        .foregroundColor(.white.opacity(0.35))
                    detail
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { AppLauncher.focus(session) }
        .help("Open in \(session.harness.displayName)")
    }

    @ViewBuilder private var detail: some View {
        switch session.state {
        case .working, .waiting:
            let text = session.activity ?? (session.state == .waiting ? "Waiting for input" : "Working")
            if text.hasPrefix("$ ") {
                Text(text).font(.system(size: 10.5, design: .monospaced)).foregroundColor(.white.opacity(0.55))
            } else {
                Text(text).foregroundColor(.white.opacity(0.55))
            }
        case .done:
            Text(session.lastTurnDuration.map { "Finished in \(Fmt.friendly($0))" } ?? "Finished")
                .foregroundColor(.white.opacity(0.45))
        case .failed:
            Text(session.activity ?? "Stopped with an error")
                .foregroundColor(AgentState.failed.color.opacity(0.85))
        case .idle:
            Text("Idle").foregroundColor(.white.opacity(0.35))
        }
    }

    @ViewBuilder private var trailing: some View {
        let style = Font.system(size: 11).monospacedDigit()
        switch session.state {
        case .working:
            Text(session.workingSince.map { Fmt.duration(now.timeIntervalSince($0)) } ?? "")
                .font(style).foregroundColor(.white.opacity(0.5))
        case .waiting:
            Text("Needs input").font(.system(size: 11, weight: .medium)).foregroundColor(AgentState.waiting.color)
        case .done, .failed:
            HStack(spacing: 4) {
                Image(systemName: session.state == .done ? "checkmark" : "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(session.state.color)
                Text(session.finishedAt.map { Fmt.ago(now.timeIntervalSince($0)) } ?? "")
                    .font(style).foregroundColor(.white.opacity(0.4))
            }
        case .idle:
            Text(Fmt.ago(now.timeIntervalSince(session.lastActivity)))
                .font(style).foregroundColor(.white.opacity(0.3))
        }
    }
}
