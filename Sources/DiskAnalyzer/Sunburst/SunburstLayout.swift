import Foundation
import CoreGraphics

struct SunburstSegment: Identifiable {
    let id: String
    let node: FileNode
    let depth: Int          // 1 = ring 1 (innermost), 2 = ring 2, …
    let ring: Int           // = depth - 1, 0-based
    let startAngle: Double  // radians, clockwise from top (-π/2)
    let endAngle: Double
    let innerRadius: CGFloat  // fraction of total radius [0, 1]
    let outerRadius: CGFloat
    let color: CGColor
    let hue: CGFloat        // retained for hover highlight and child inheritance
}

enum SunburstLayout {

    static let maxDepth: Int = 4
    static let minArcAngle: Double = 1.5 * Double.pi / 180  // skip arcs < 1.5°
    static let ringWidth: CGFloat = 0.175
    static let centerHoleRadius: CGFloat = 0.24
    static let gapFraction: CGFloat = 0.010

    static func layout(root: FileNode, metric: SizeMetric, isDarkMode: Bool) -> [SunburstSegment] {
        guard root.bytes(for: metric) > 0 else { return [] }

        var result: [SunburstSegment] = []

        let visibleTop = root.children.filter { $0.bytes(for: metric) > 0 }
        guard !visibleTop.isEmpty else { return [] }

        let topTotal = visibleTop.reduce(Int64(0)) { $0 + $1.bytes(for: metric) }
        guard topTotal > 0 else { return [] }

        let hueStep: CGFloat = 1.0 / CGFloat(visibleTop.count)

        // Stack item: (node, depth, startAngle, endAngle, hue, fraction of visible siblings)
        typealias Item = (
            node: FileNode,
            depth: Int,
            start: Double,
            end: Double,
            hue: CGFloat,
            fraction: Double
        )
        var stack: [Item] = []

        // Seed with top-level children, angles computed cumulatively from top (−π/2)
        var cursor = -Double.pi / 2
        for (i, child) in visibleTop.enumerated() {
            let fraction = Double(child.bytes(for: metric)) / Double(topTotal)
            let span = fraction * 2 * Double.pi
            let hue = hueStep * CGFloat(i)
            stack.append((child, 1, cursor, cursor + span, hue, fraction))
            cursor += span
        }

        while !stack.isEmpty {
            let item = stack.removeLast()
            guard item.depth <= maxDepth else { continue }

            let span = item.end - item.start
            guard span >= minArcAngle else { continue }

            let ring = item.depth - 1
            let innerR = centerHoleRadius + CGFloat(ring) * ringWidth
            let outerR = innerR + ringWidth - gapFraction

            let color = segmentColor(
                hue: item.hue,
                depth: item.depth,
                fractionOfParent: item.fraction,
                isDarkMode: isDarkMode
            )

            result.append(SunburstSegment(
                id: item.node.id,
                node: item.node,
                depth: item.depth,
                ring: ring,
                startAngle: item.start,
                endAngle: item.end,
                innerRadius: innerR,
                outerRadius: outerR,
                color: color,
                hue: item.hue
            ))

            // Push children onto stack
            if item.node.isDirectory && item.depth < maxDepth {
                let childrenVisible = item.node.children.filter { $0.bytes(for: metric) > 0 }
                let childrenTotal = childrenVisible.reduce(Int64(0)) { $0 + $1.bytes(for: metric) }
                guard !childrenVisible.isEmpty, childrenTotal > 0 else { continue }

                var childCursor = item.start
                for child in childrenVisible {
                    let childFraction = Double(child.bytes(for: metric)) / Double(childrenTotal)
                    let childSpan = childFraction * span
                    stack.append((
                        child,
                        item.depth + 1,
                        childCursor,
                        childCursor + childSpan,
                        item.hue,
                        childFraction
                    ))
                    childCursor += childSpan
                }
            }
        }

        // Sort by depth ascending so Canvas draws inner rings first, outer rings on top
        result.sort { $0.depth < $1.depth }
        return result
    }

    // MARK: - Color

    private static func segmentColor(
        hue: CGFloat,
        depth: Int,
        fractionOfParent: Double,
        isDarkMode: Bool
    ) -> CGColor {
        let baseSaturation: CGFloat = isDarkMode ? 0.75 : 0.70
        let baseBrightness: CGFloat = isDarkMode ? 0.62 : 0.80

        let depthFactor = CGFloat(depth - 1)
        let saturation = max(baseSaturation - depthFactor * 0.09, 0.20)
        let brightness: CGFloat
        if isDarkMode {
            brightness = max(baseBrightness - depthFactor * 0.08, 0.28)
        } else {
            brightness = min(baseBrightness + depthFactor * 0.05, 0.96)
        }

        // Slight brightness variation within siblings based on relative size
        let sizeBias = CGFloat(fractionOfParent) * 0.06
        let finalBrightness = min(max(brightness + sizeBias, 0.15), 1.0)

        let (r, g, b) = hsvToRgb(h: hue, s: saturation, v: finalBrightness)
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    private static func hsvToRgb(h: CGFloat, s: CGFloat, v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        guard s > 0 else { return (v, v, v) }
        let hi = Int(h * 6) % 6
        let f  = h * 6 - CGFloat(Int(h * 6))
        let p  = v * (1 - s)
        let q  = v * (1 - f * s)
        let t  = v * (1 - (1 - f) * s)
        switch hi {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
