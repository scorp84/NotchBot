import SwiftUI
import AppKit
import Combine

enum NotchMode { case collapsed, peek, expanded }

/// The main notch window controller.
///
/// The panel itself never moves or resizes: it is a fixed, transparent canvas big
/// enough for the largest state. Only the SwiftUI notch shape morphs between sizes
/// (one spring drives width, height and corner radii together), which keeps the
/// animation on the render server instead of resizing a window every frame.
/// Everything outside the visible shape lets clicks through to the apps below.
///
/// Three sizes:
/// - **Collapsed**: wings either side of the camera. Narrow when nothing is going on,
///   wider while agents are busy.
/// - **Peek**: a short drop-down banner when an agent finishes or needs you.
/// - **Expanded**: the full tray on hover, sized to the number of sessions.
class NotchWindow: NSObject {
    private var panel: NotchPanel!
    private(set) var viewModel: NotchViewModel!
    private let store: AgentStore
    private var cancellables = Set<AnyCancellable>()
    private var peekWork: DispatchWorkItem?
    private var mouseTimer: Timer?
    private var rightClickMonitor: Any?
    private var outsideSince: Date?
    private var insideSince: Date?
    private var settingsMenuOpen = false

    /// Presents the menu-bar menu at a screen point. Set by the app delegate.
    var onOpenSettings: ((NSPoint) -> Void)?

    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.82)

    private let shadowPadding: CGFloat = 24
    static let expandedWidth: CGFloat = 440
    private let peekWidth: CGFloat = 400
    private let busyWings: CGFloat = 200
    private let quietWings: CGFloat = 170
    private let maxRows = 6

    init(store: AgentStore) {
        self.store = store
        super.init()

        let screen = Self.notchScreen()
        let dims = Self.detectNotch(screen: screen)
        viewModel = NotchViewModel(notchWidth: dims.width, notchHeight: dims.height, shadowPadding: shadowPadding)
        viewModel.shapeSize = size(for: .collapsed)

        panel = NotchPanel(
            contentRect: canvasFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: NotchContentView(
            viewModel: viewModel,
            store: store,
            onOpenSettings: { [weak self] in self?.onOpenSettings?(NSEvent.mouseLocation) }
        ))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.orderFrontRegardless()

        // Grow / shrink as sessions, plan meters or connect buttons come and go.
        Publishers.CombineLatest4(
            store.$sessions
                .map { s in (s.count, s.contains { $0.state != .idle }) }
                .removeDuplicates { $0 == $1 },
            store.$cursorConnected.removeDuplicates(),
            store.$claudeConnected.removeDuplicates(),
            store.$plans.map(\.count).removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.morph(to: self?.viewModel.mode ?? .collapsed) }
        .store(in: &cancellables)

        store.onPeek = { [weak self] event in self?.peek(event) }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        startMouseWatch()
        startRightClickWatch()
    }

    // MARK: - Geometry

    /// Prefer the built-in display (the one with the notch).
    private static func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func detectNotch(screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        var width: CGFloat = 185
        if let topLeft = screen.auxiliaryTopLeftArea, let topRight = screen.auxiliaryTopRightArea {
            width = screen.frame.width - topLeft.width - topRight.width + 4
        }
        let height = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        return (width, height)
    }

    private func expandedHeight(rows: Int, connectRow: Bool, planRows: Int) -> CGFloat {
        let list: CGFloat = rows == 0 ? 56 : CGFloat(rows) * 40 + CGFloat(rows - 1) * 2
        // Header-to-list gap is already the +6. Plan rows add their own block plus the gap under it.
        let plans: CGFloat = planRows == 0 ? 0 : CGFloat(planRows) * 18 + CGFloat(planRows - 1) * 2 + 6
        return viewModel.notchHeight + 8 + 22 + 6 + plans + list + (connectRow ? 28 : 0) + 14
    }

    /// The size of the visible black shape for a mode.
    private func size(for mode: NotchMode) -> CGSize {
        switch mode {
        case .collapsed:
            let wings = store.isBusy || !store.sessions.isEmpty ? busyWings : quietWings
            return CGSize(width: viewModel.notchWidth + wings, height: viewModel.notchHeight)
        case .peek:
            return CGSize(width: peekWidth, height: viewModel.notchHeight + 50)
        case .expanded:
            let rows = min(store.sessions.count, maxRows)
            let connect = !store.cursorConnected || !store.claudeConnected
            return CGSize(width: Self.expandedWidth, height: expandedHeight(rows: rows, connectRow: connect, planRows: store.plans.count))
        }
    }

    /// Fixed canvas: wide and tall enough for every state, plus room for the shadow.
    private func canvasFrame(on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let w = max(Self.expandedWidth, peekWidth, viewModel.notchWidth + busyWings) + shadowPadding * 2
        let h = expandedHeight(rows: maxRows, connectRow: true, planRows: 2) + shadowPadding
        return NSRect(x: sf.midX - w / 2, y: sf.maxY - h, width: w, height: h)
    }

    /// Where the visible shape currently is, in screen coordinates.
    private var shapeRect: NSRect {
        let s = viewModel.shapeSize
        let f = panel.frame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private func morph(to mode: NotchMode) {
        let target = size(for: mode)
        guard viewModel.mode != mode || viewModel.shapeSize != target else { return }
        withAnimation(Self.morph) {
            viewModel.mode = mode
            viewModel.shapeSize = target
        }
    }

    @objc private func screensChanged() {
        let screen = Self.notchScreen()
        let dims = Self.detectNotch(screen: screen)
        viewModel.notchWidth = dims.width
        viewModel.notchHeight = dims.height
        panel.setFrame(canvasFrame(on: screen), display: true)
        viewModel.shapeSize = size(for: viewModel.mode)
    }

    // MARK: - Mouse

    /// Polls the pointer (cheap, and immune to lost enter/exit events): lets clicks through
    /// outside the shape, opens on hover, and closes shortly after the pointer leaves.
    private func startMouseWatch() {
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.mouseTick() }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    /// Right-click (and control-click) anywhere on the notch opens settings,
    /// including while the collapsed wings are covering the status item.
    private func startRightClickWatch() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, !self.settingsMenuOpen, let open = self.onOpenSettings else { return event }
            let point = NSEvent.mouseLocation
            guard self.shapeRect.insetBy(dx: -4, dy: -4).contains(point) else { return event }
            // Menu tracking must not start inside the monitor.
            DispatchQueue.main.async { open(point) }
            return nil
        }
    }

    /// Shows `menu` with its top-left at `screenPoint`. Blocks until it closes.
    func popUp(_ menu: NSMenu, at screenPoint: NSPoint) {
        guard let view = panel.contentView, !settingsMenuOpen else { return }
        settingsMenuOpen = true
        outsideSince = nil
        let windowPoint = panel.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        let viewPoint = view.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: view)
        settingsMenuOpen = false
    }

    private func mouseTick() {
        // The menu hangs below the notch, outside the shape. Leave the tray
        // where it is until the menu closes.
        if settingsMenuOpen { return }

        let p = NSEvent.mouseLocation
        let hit = shapeRect.insetBy(dx: viewModel.mode == .collapsed ? -4 : -8, dy: -8)
        let inside = hit.contains(p)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = Date() }
            // A short dwell so sweeping past the menu bar doesn't pop it open.
            if viewModel.mode != .expanded, Date().timeIntervalSince(insideSince!) > 0.08 { expand() }
        } else {
            insideSince = nil
            guard viewModel.mode == .expanded else { return }
            if outsideSince == nil { outsideSince = Date() }
            if Date().timeIntervalSince(outsideSince!) > 0.35 { collapse() }
        }
    }

    private var mouseInside: Bool {
        shapeRect.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    // MARK: - Expand / Peek / Collapse

    func expand() {
        peekWork?.cancel()
        outsideSince = nil
        guard viewModel.mode != .expanded else { return }
        viewModel.peek = nil
        morph(to: .expanded)
    }

    func collapse() {
        guard viewModel.mode != .collapsed else { return }
        morph(to: .collapsed)
        viewModel.peek = nil
    }

    func toggle() {
        if viewModel.mode == .expanded {
            collapse()
        } else {
            expand()
            outsideSince = Date().addingTimeInterval(3)  // give the menu-triggered tray a moment
        }
    }

    /// Drop down a short banner, then tuck it away again unless the user hovers it.
    func peek(_ event: PeekEvent) {
        guard viewModel.mode != .expanded else { return }
        viewModel.peek = event
        morph(to: .peek)

        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.mouseInside, self.viewModel.mode == .peek else { return }
            self.collapse()
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (event.kind == .finished ? 4.5 : 7), execute: work)
    }

    // MARK: - Show / Hide / Destroy

    func hide() { panel.orderOut(nil) }
    func show() { panel.orderFrontRegardless() }
    var isVisible: Bool { panel.isVisible }

    func destroy() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        }
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }
}

/// Observable state shared between NotchWindow and SwiftUI views.
class NotchViewModel: ObservableObject {
    @Published var mode: NotchMode = .collapsed
    @Published var peek: PeekEvent?
    @Published var shapeSize: CGSize = .zero
    @Published var notchWidth: CGFloat
    @Published var notchHeight: CGFloat
    let shadowPadding: CGFloat

    var isExpanded: Bool { mode == .expanded }

    init(notchWidth: CGFloat = 185, notchHeight: CGFloat = 32, shadowPadding: CGFloat = 20) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.shadowPadding = shadowPadding
    }
}
