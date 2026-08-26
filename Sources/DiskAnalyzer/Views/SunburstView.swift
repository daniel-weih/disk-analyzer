import SwiftUI

struct SunburstView: View {
    private static let segmentEdgeInset: CGFloat = 0.85

    let node: FileNode
    let metric: SizeMetric
    let onDrillDown: (FileNode) -> Void
    let onRevealInFinder: (FileNode) -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var segments: [SunburstSegment] = []
    @State private var hoveredID: String?

    init(
        node: FileNode,
        metric: SizeMetric,
        onDrillDown: @escaping (FileNode) -> Void,
        onRevealInFinder: @escaping (FileNode) -> Void,
        initialSegments: [SunburstSegment] = []
    ) {
        self.node = node
        self.metric = metric
        self.onDrillDown = onDrillDown
        self.onRevealInFinder = onRevealInFinder
        _segments = State(initialValue: initialSegments)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let radius = side / 2 * 0.92
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

                ZStack {
                    Canvas { ctx, _ in
                        drawSegments(ctx: ctx, center: center, radius: radius)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        handleHover(phase: phase, center: center, radius: radius)
                    }
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { event in
                            handleDoubleTap(at: event.location, center: center, radius: radius)
                        }
                    )
                    .contextMenu {
                        if let id = hoveredID,
                           let hit = segments.last(where: { $0.id == id }) {
                            Button(L10n.text("sunburst.reveal")) { onRevealInFinder(hit.node) }
                            if hit.node.isDirectory {
                                Button(L10n.text("sunburst.enter")) { onDrillDown(hit.node) }
                            }
                        } else {
                            Button(L10n.text("sunburst.none")) {}.disabled(true)
                        }
                    }

                    CenterLabelView(
                        title: focusedNode.name,
                        subtitle: focusedNode.formattedSize(for: metric),
                        holeRadius: radius * SunburstLayout.centerHoleRadius
                    )
                }
            }

            Label(L10n.text("sunburst.hint"), systemImage: "cursorarrow.click.2")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .frame(height: 24)
        }
        .onAppear { recompute() }
        .onChange(of: node.id) { _ in recompute() }
        .onChange(of: metric) { _ in recompute() }
        .onChange(of: colorScheme) { _ in recompute() }
    }

    // MARK: - Drawing

    private func drawSegments(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for seg in segments {
            let innerR = seg.innerRadius * radius
            let outerR = seg.outerRadius * radius
            let angles = renderedAngles(for: seg, radius: radius)
            let isHovered = seg.id == hoveredID

            // Build annular sector path
            var path = Path()
            path.addArc(
                center: center, radius: outerR,
                startAngle: .radians(angles.start),
                endAngle: .radians(angles.end),
                clockwise: false
            )
            path.addArc(
                center: center, radius: innerR,
                startAngle: .radians(angles.end),
                endAngle: .radians(angles.start),
                clockwise: true
            )
            path.closeSubpath()

            let baseColor = Color(cgColor: seg.color)
            let fillColor = isHovered ? baseColor.opacity(0.68) : baseColor
            ctx.fill(path, with: .color(fillColor))

            // Label for ring 1 arcs wide enough to show text
            if seg.ring == 0 {
                let spanDeg = (seg.endAngle - seg.startAngle) * 180 / Double.pi
                if spanDeg > 10 {
                    drawArcLabel(ctx: ctx, seg: seg, center: center, radius: radius)
                }
            }
        }
    }

    private func renderedAngles(
        for segment: SunburstSegment,
        radius: CGFloat
    ) -> (start: Double, end: Double) {
        let span = max(segment.endAngle - segment.startAngle, 0)
        let outerRadius = max(segment.outerRadius * radius, 1)
        let pointBasedInset = Double(Self.segmentEdgeInset / outerRadius)
        let inset = min(pointBasedInset, span * 0.12)
        return (segment.startAngle + inset, segment.endAngle - inset)
    }

    private func drawArcLabel(ctx: GraphicsContext, seg: SunburstSegment, center: CGPoint, radius: CGFloat) {
        let midAngle = (seg.startAngle + seg.endAngle) / 2
        let midR = ((seg.innerRadius + seg.outerRadius) / 2) * radius
        let labelPt = CGPoint(
            x: center.x + midR * CGFloat(cos(midAngle)),
            y: center.y + midR * CGFloat(sin(midAngle))
        )
        let spanDeg = (seg.endAngle - seg.startAngle) * 180 / Double.pi
        let fontSize = min(12.0, max(8.0, spanDeg * 0.55))
        let label = Text(seg.node.name)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(.white)
        ctx.draw(label, at: labelPt, anchor: .center)
    }

    // MARK: - Hit Testing

    private func hitTest(at point: CGPoint, center: CGPoint, radius: CGFloat) -> SunburstSegment? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = sqrt(dx * dx + dy * dy)

        // Angle in standard math coords (atan2), then shift to our top-origin system
        var angle = atan2(Double(dy), Double(dx))
        // Our angles start at -π/2; normalize so angle is in [-π/2, 3π/2)
        if angle < -Double.pi / 2 {
            angle += 2 * Double.pi
        }

        var best: SunburstSegment? = nil
        for seg in segments {
            let innerR = seg.innerRadius * radius
            let outerR = seg.outerRadius * radius
            guard dist >= innerR, dist <= outerR else { continue }

            let angles = renderedAngles(for: seg, radius: radius)

            // Normalize angle into segment's domain
            var normalizedAngle = angle
            if normalizedAngle < angles.start { normalizedAngle += 2 * Double.pi }
            let normalizedEnd = angles.end > angles.start
                ? angles.end
                : angles.end + 2 * Double.pi

            guard normalizedAngle >= angles.start,
                  normalizedAngle <= normalizedEnd else { continue }

            if best == nil || seg.ring > best!.ring {
                best = seg
            }
        }
        return best
    }

    // MARK: - Interaction Handlers

    private func handleHover(phase: HoverPhase, center: CGPoint, radius: CGFloat) {
        switch phase {
        case .active(let loc):
            if let hit = hitTest(at: loc, center: center, radius: radius) {
                hoveredID = hit.id
            } else {
                hoveredID = nil
            }
        case .ended:
            hoveredID = nil
        }
    }

    private func handleDoubleTap(at loc: CGPoint, center: CGPoint, radius: CGFloat) {
        guard let hit = hitTest(at: loc, center: center, radius: radius) else { return }
        if hit.node.isDirectory {
            onDrillDown(hit.node)
        } else {
            onRevealInFinder(hit.node)
        }
    }

    // MARK: - Recompute

    private func recompute() {
        let capturedNode = node
        let capturedMetric = metric
        let isDark = colorScheme == .dark
        Task.detached(priority: .userInitiated) {
            let segs = SunburstLayout.layout(
                root: capturedNode,
                metric: capturedMetric,
                isDarkMode: isDark
            )
            await MainActor.run { segments = segs }
        }
    }

    private var focusedNode: FileNode {
        guard let hoveredID,
              let segment = segments.last(where: { $0.id == hoveredID }) else {
            return node
        }
        return segment.node
    }
}

// MARK: - Center Label

private struct CenterLabelView: View {
    let title: String
    let subtitle: String
    let holeRadius: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: holeRadius * 1.7)
        .animation(.easeInOut(duration: 0.1), value: title)
    }
}
