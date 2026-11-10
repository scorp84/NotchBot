import SwiftUI

/// Harness marks with no tile: Clawd for Claude, the ChatGPT blossom for Codex, the cube for Cursor.
///
/// Each mark has its own motion while working (Clawd hops and blinks, the blossom turns,
/// the cube flips onto its edge) and a light sweeps across it every couple of seconds.
/// Waiting, done and failed show as a small badge, and finishing makes the mark hop.
struct HarnessIcon: View {
    let harness: Harness
    var state: AgentState = .idle
    var size: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebratedAt: Date?

    private var moving: Bool { state == .working && !reduceMotion }
    private var ticking: Bool { moving || (state == .waiting && !reduceMotion) || celebratedAt != nil }
    private var markSize: CGFloat { size * 0.86 }
    /// Clawd is wide and short, so it gets extra width to carry the same visual weight.
    private var markWidth: CGFloat { harness == .claude ? size : markSize }
    private var width: CGFloat { harness == .claude ? size * 1.04 : size }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !ticking)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate + phase
            mark(t)
                .overlay {
                    if moving {
                        Shimmer(t: t).mask(mark(t, solid: true))
                    }
                }
                .frame(width: markWidth, height: markSize)
                .offset(y: -hop(at: timeline.date))
                .frame(width: width, height: size)
                .overlay(alignment: .topTrailing) { badge(t) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: state)
        .opacity(state == .idle ? 0.92 : 1)
        .onChange(of: state) { old, new in
            guard new == .done, old != .done, !reduceMotion else { return }
            celebratedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { celebratedAt = nil }
        }
        .accessibilityLabel("\(harness.displayName), \(state.label)")
    }

    /// Keeps several marks from moving in lockstep.
    private var phase: Double {
        switch harness {
        case .claude: return 0
        case .codex: return 0.7
        case .cursor: return 1.4
        }
    }

    @ViewBuilder private func mark(_ t: Double, solid: Bool = false) -> some View {
        // White marks sit a little dimmer while working so the sweep has something to light up.
        let white = Color.white.opacity(solid ? 1 : (moving ? 0.78 : 0.95))
        switch harness {
        case .claude:
            // A light, steady hop while working.
            Clawd(blink: moving && t.truncatingRemainder(dividingBy: 3.4) < 0.13)
                .fill(solid ? Color.white : harness.tint)
                .offset(y: moving ? -abs(sin(t * 5)) * markSize * 0.08 : 0)
        case .codex:
            ChatGPTBlossom()
                .fill(white)
                .rotationEffect(.radians(moving ? t * 0.9 : 0))
                .scaleEffect(moving ? 0.95 + 0.05 * sin(t * 2.4) : 1)
        case .cursor:
            // A small yaw wobble never changed the silhouette at menu-bar size.
            // Flip onto the edge and back, then rest so the mark stays readable.
            let flip = moving ? cursorFlip(t) : (width: CGFloat(1), tilt: 0.0, lift: CGFloat(0))
            CursorCube()
                .fill(white, style: FillStyle(eoFill: true))
                .rotationEffect(.degrees(flip.tilt))
                .scaleEffect(x: flip.width, y: moving ? 1 + (1 - flip.width) * 0.28 : 1)
                .offset(y: -flip.lift)
        }
    }

    /// One quick turn onto the cube's edge, then a rest facing forward.
    private func cursorFlip(_ t: Double) -> (width: CGFloat, tilt: Double, lift: CGFloat) {
        let period = 1.15
        let p = t.truncatingRemainder(dividingBy: period) / period
        let turn = 0.4
        guard p < turn else { return (1, 0, 0) }
        let pinch = sin((p / turn) * .pi)
        return (CGFloat(1 - 0.86 * pinch), 16 * pinch, CGFloat(pinch) * markSize * 0.1)
    }

    /// Two quick hops, the second smaller, when a task finishes.
    private func hop(at date: Date) -> CGFloat {
        guard let start = celebratedAt else { return 0 }
        let p = date.timeIntervalSince(start) / 0.7
        guard p < 1 else { return 0 }
        return CGFloat(abs(sin(p * .pi * 2)) * (1 - p)) * size * 0.22
    }

    @ViewBuilder private func badge(_ t: Double) -> some View {
        let d = max(7, size * 0.3)
        if state == .waiting {
            dot(AgentState.waiting.color, d)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.12 * (0.5 + 0.5 * sin(t * 4)))
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        } else if state == .done || state == .failed {
            dot(state.color, d)
                .overlay {
                    if size >= 24 {
                        Image(systemName: state == .done ? "checkmark" : "exclamationmark")
                            .font(.system(size: d * 0.5, weight: .heavy))
                            .foregroundStyle(.black)
                    }
                }
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
    }

    /// A badge cut out of the mark by a black rim.
    private func dot(_ color: Color, _ d: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: d, height: d)
            .overlay(Circle().stroke(.black, lineWidth: max(1.5, d * 0.18)))
            .offset(x: d * 0.15, y: -d * 0.15)
    }
}

/// A soft band of light that crosses the mark, then rests before the next pass.
private struct Shimmer: View {
    var t: Double

    var body: some View {
        GeometryReader { g in
            let period = 2.2
            let p = t.truncatingRemainder(dividingBy: period) / period
            let sweep = min(1, p / 0.5)
            let w = g.size.width
            LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 0.5, height: g.size.height * 1.6)
                .rotationEffect(.degrees(20))
                .offset(x: -w * 0.6 + sweep * w * 1.7, y: -g.size.height * 0.3)
        }
        .blendMode(.plusLighter)
    }
}

/// Bars in the working harnesses' colours: the notch's "agents are busy" signal.
struct WorkWave: View {
    var colors: [Color]
    var bars = 4
    var height: CGFloat = 11

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let v = 0.3 + 0.7 * abs(sin(t * 3.2 + Double(i) * 0.75) * cos(t * 1.3 + Double(i) * 0.4))
                    Capsule()
                        .fill(colors.isEmpty ? Color.white : colors[i % colors.count])
                        .frame(width: 2.5, height: max(3, height * v))
                }
            }
            .frame(height: height)
        }
        .accessibilityLabel("Working")
    }
}

/// Clawd, the Claude Code mascot, from its terminal block art.
/// The grid is 18 x 5 terminal half-cells; each cell is twice as tall as it is wide.
private struct Clawd: Shape {
    var blink = false

    private var rows: [String] {
        [
            "...############...",
            blink ? "...############..." : "...##.######.##...",
            ".################.",
            "...############...",
            "....#.#....#.#....",
        ]
    }

    func path(in rect: CGRect) -> Path {
        let rows = self.rows
        let cols = CGFloat(rows[0].count)
        let lines = CGFloat(rows.count)
        let cell = min(rect.width / cols, rect.height / (lines * 2))
        let w = cell * cols, h = cell * lines * 2
        let origin = CGPoint(x: rect.midX - w / 2, y: rect.midY - h / 2)
        var path = Path()
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch == "#" {
                path.addRect(CGRect(x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(r) * cell * 2,
                                    width: cell, height: cell * 2))
            }
        }
        return path
    }
}

/// Cursor's cube mark, from the logo shipped inside the Cursor app (viewBox 0 0 49 56).
private struct CursorCube: Shape {
    func path(in rect: CGRect) -> Path {
        let box = CGSize(width: 49, height: 56)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(
            translationX: rect.midX - box.width * scale / 2,
            y: rect.midY - box.height * scale / 2
        ).scaledBy(x: scale, y: scale)
        return SVGPath.parse(Self.d).applying(transform)
    }

    private static let d = "M48.0226 13.2547L25.6601 0.311786C24.942 -0.103929 24.0559 -0.103929 23.3378 0.311786L0.976347 13.2547C0.372691 13.6041 0 14.2503 0 14.9502V41.0498C0 41.7496 0.372691 42.3958 0.976347 42.7453L23.3389 55.6882C24.057 56.1039 24.943 56.1039 25.6611 55.6882L48.0237 42.7453C48.6273 42.3958 49 41.7496 49 41.0498V14.9502C49 14.2503 48.6273 13.6041 48.0237 13.2547H48.0226ZM46.6179 15.9964L25.0302 53.4802C24.8842 53.7328 24.4989 53.6296 24.4989 53.337V28.793C24.4989 28.3026 24.2375 27.849 23.8134 27.6027L2.61094 15.3312C2.35898 15.1849 2.46186 14.7987 2.75372 14.7987H45.9292C46.5423 14.7987 46.9255 15.4649 46.619 15.9974L46.6179 15.9964Z"
}

/// OpenAI Blossom, the current ChatGPT mark, with no background tile.
/// Path: published monoblossom, viewBox 0 0 485 481 (https://indexofmarks.com/openai).
private struct ChatGPTBlossom: Shape {
    func path(in rect: CGRect) -> Path {
        let box = CGRect(x: 0, y: 0, width: 485, height: 481)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let fitted = CGRect(
            x: rect.midX - box.width * scale / 2,
            y: rect.midY - box.height * scale / 2,
            width: box.width * scale,
            height: box.height * scale
        )
        let transform = CGAffineTransform(translationX: fitted.minX + 0.557 * scale, y: fitted.minY + 0.958 * scale)
            .scaledBy(x: scale, y: scale)
        return SVGPath.parse(Self.d).applying(transform)
    }

    private static let d = "M185.689,174.653 L185.689,129.07 C185.689,125.231 187.13,122.351 190.487,120.434 L282.135,67.654 C294.61,60.457 309.485,57.1 324.837,57.1 C382.414,57.1 418.883,101.724 418.883,149.224 C418.883,152.582 418.883,156.421 418.402,160.26 L323.397,104.6 C317.64,101.243 311.88,101.243 306.123,104.6 L185.689,174.653 Z M399.688,352.187 L399.688,243.266 C399.688,236.547 396.807,231.749 391.051,228.391 L270.617,158.338 L309.962,135.785 C313.32,133.868 316.2,133.868 319.558,135.785 L411.205,188.565 C437.597,203.921 455.348,236.547 455.348,268.213 C455.348,304.678 433.758,338.267 399.688,352.183 L399.688,352.187 Z M157.38,256.224 L118.035,233.194 C114.678,231.277 113.237,228.396 113.237,224.557 L113.237,118.998 C113.237,67.659 152.582,28.791 205.843,28.791 C225.998,28.791 244.707,35.51 260.545,47.505 L166.021,102.206 C160.265,105.563 157.385,110.361 157.385,117.081 L157.385,256.228 L157.38,256.224 Z M242.069,305.164 L185.689,273.497 L185.689,206.325 L242.069,174.658 L298.445,206.325 L298.445,273.497 L242.069,305.164 Z M278.295,451.031 C258.141,451.031 239.432,444.312 223.594,432.318 L318.117,377.616 C323.874,374.259 326.754,369.461 326.754,362.741 L326.754,223.594 L366.581,246.624 C369.938,248.541 371.379,251.421 371.379,255.261 L371.379,360.82 C371.379,412.159 331.552,451.027 278.295,451.027 L278.295,451.031 Z M164.577,344.032 L72.929,291.253 C46.537,275.896 28.786,243.271 28.786,211.604 C28.786,174.658 50.858,141.551 84.923,127.635 L84.923,237.033 C84.923,243.752 87.804,248.55 93.56,251.908 L213.517,321.479 L174.172,344.032 C170.815,345.949 167.934,345.949 164.577,344.032 Z M159.302,422.722 C105.082,422.722 65.256,381.937 65.256,331.556 C65.256,327.717 65.737,323.878 66.214,320.039 L160.738,374.74 C166.494,378.098 172.255,378.098 178.011,374.74 L298.445,305.169 L298.445,350.752 C298.445,354.591 297.005,357.471 293.647,359.388 L202,412.168 C189.524,419.365 174.649,422.722 159.297,422.722 L159.302,422.722 Z M278.295,479.818 C336.354,479.818 384.813,438.555 395.853,383.854 C449.592,369.938 484.139,319.557 484.139,268.218 C484.139,234.629 469.746,202.004 443.835,178.492 C446.234,168.415 447.674,158.338 447.674,148.266 C447.674,79.653 392.014,28.309 327.717,28.309 C314.765,28.309 302.289,30.226 289.813,34.547 C268.218,13.434 238.469,2.84217094e-14 205.843,2.84217094e-14 C147.785,2.84217094e-14 99.326,41.262 88.286,95.963 C34.547,109.879 -1.42108547e-14,160.26 -1.42108547e-14,211.599 C-1.42108547e-14,245.188 14.393,277.813 40.304,301.325 C37.905,311.402 36.465,321.479 36.465,331.552 C36.465,400.165 92.125,451.508 156.421,451.508 C169.374,451.508 181.85,449.591 194.326,445.27 C215.916,466.383 245.665,479.818 278.295,479.818 Z"
}

/// Enough of an SVG path for the marks: M, L, H, V, C and Z.
private enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var index = d.startIndex
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero

        func skipSeparators() {
            while index < d.endIndex {
                let c = d[index]
                if c == " " || c == "," || c == "\n" || c == "\t" { index = d.index(after: index) } else { break }
            }
        }

        func readNumber() -> Double? {
            skipSeparators()
            guard index < d.endIndex else { return nil }
            let head = d[index]
            if head.isLetter { return nil }
            let begin = index
            if head == "-" || head == "+" { index = d.index(after: index) }
            var sawDigit = false
            var sawDot = false
            while index < d.endIndex {
                let c = d[index]
                if c.isNumber {
                    sawDigit = true
                    index = d.index(after: index)
                } else if c == ".", !sawDot {
                    sawDot = true
                    index = d.index(after: index)
                } else if c == "e" || c == "E" {
                    index = d.index(after: index)
                    if index < d.endIndex, d[index] == "-" || d[index] == "+" { index = d.index(after: index) }
                    while index < d.endIndex, d[index].isNumber { index = d.index(after: index) }
                } else {
                    break
                }
            }
            guard sawDigit else { return nil }
            return Double(d[begin..<index])
        }

        while index < d.endIndex {
            skipSeparators()
            guard index < d.endIndex else { break }
            if d[index].isLetter {
                command = d[index]
                index = d.index(after: index)
            }

            switch command {
            case "Z", "z":
                path.closeSubpath()
                current = start
            case "M", "m":
                guard let x = readNumber(), let y = readNumber() else { return path }
                let point = command == "m"
                    ? CGPoint(x: current.x + x, y: current.y + y)
                    : CGPoint(x: x, y: y)
                path.move(to: point)
                current = point
                start = point
                command = command == "m" ? "l" : "L"
            case "L", "l":
                guard let x = readNumber(), let y = readNumber() else { return path }
                let point = command == "l"
                    ? CGPoint(x: current.x + x, y: current.y + y)
                    : CGPoint(x: x, y: y)
                path.addLine(to: point)
                current = point
            case "H", "h":
                guard let x = readNumber() else { return path }
                current = CGPoint(x: command == "h" ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V", "v":
                guard let y = readNumber() else { return path }
                current = CGPoint(x: current.x, y: command == "v" ? current.y + y : y)
                path.addLine(to: current)
            case "C", "c":
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { return path }
                let c1: CGPoint
                let c2: CGPoint
                let end: CGPoint
                if command == "c" {
                    c1 = CGPoint(x: current.x + x1, y: current.y + y1)
                    c2 = CGPoint(x: current.x + x2, y: current.y + y2)
                    end = CGPoint(x: current.x + x, y: current.y + y)
                } else {
                    c1 = CGPoint(x: x1, y: y1)
                    c2 = CGPoint(x: x2, y: y2)
                    end = CGPoint(x: x, y: y)
                }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
            default:
                return path
            }
        }
        return path
    }
}
