import AppKit
import SwiftUI

/// Sizes of the wheel, plus the math that maps a cursor position to a slice.
/// Angles are measured from 12 o'clock, going clockwise, in radians.
/// Drawing coordinates are SwiftUI-style: origin top-left, y grows downward.
enum WheelGeometry {
    static let size: CGFloat = 420       // window size
    static let inner: CGFloat = 50       // centre hole radius (dropping here = cancel)
    static let outer: CGFloat = 122      // edge of the main disc
    static let ringInner: CGFloat = 130  // outer ring (sub-choices like JPG/PNG)
    static let ringOuter: CGFloat = 186
    static let optionSpan = Double.pi / 6  // each ring choice is 30° wide
    static let center = CGPoint(x: size / 2, y: size / 2)

    /// Distance and angle of `point` from the centre. `point` uses AppKit coordinates (y up).
    static func polar(_ point: CGPoint, in bounds: CGRect) -> (radius: CGFloat, angle: Double) {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        var angle = Double(atan2(dx, dy))   // 0 = up, increases clockwise
        if angle < 0 { angle += 2 * .pi }
        return (hypot(dx, dy), angle)
    }

    static func sliceAngle(_ index: Int, count: Int) -> Double {
        Double(index) * 2 * .pi / Double(count)
    }

    static func sliceIndex(at angle: Double, count: Int) -> Int {
        let slice = 2 * .pi / Double(count)
        return Int((angle + slice / 2) / slice) % count
    }

    /// Ring choices are centred on their slice's angle.
    static func optionAngle(_ index: Int, count: Int, around center: Double) -> Double {
        center + (Double(index) - Double(count - 1) / 2) * optionSpan
    }

    static func optionIndex(at angle: Double, count: Int, around center: Double) -> Int? {
        var delta = angle - center
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let index = Int(floor(delta / optionSpan + Double(count) / 2))
        return (0..<count).contains(index) ? index : nil
    }

    static func point(angle: Double, radius: CGFloat, center: CGPoint = center) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    // MARK: Shapes

    /// A ring-shaped slice with rounded corners, shrunk by `margin` on every side
    /// (so neighbours get a clean gap between them, like Apple's segmented controls).
    static func roundedSector(start: Double, end: Double, inner: CGFloat, outer: CGFloat,
                              margin: CGFloat, corner: CGFloat) -> CGPath {
        let inset = margin + corner
        let r1 = inner + inset, r2 = outer - inset
        // Shrink the angles by the same *distance* at each radius, so the side edges stay parallel.
        let a1 = start + Double(inset / r2), b1 = end - Double(inset / r2)
        let a2 = start + Double(inset / r1), b2 = end - Double(inset / r1)
        let core = CGMutablePath()
        let steps = 40
        for k in 0...steps {
            let pt = point(angle: a1 + (b1 - a1) * Double(k) / Double(steps), radius: r2)
            if k == 0 { core.move(to: pt) } else { core.addLine(to: pt) }
        }
        for k in 0...steps {
            core.addLine(to: point(angle: b2 - (b2 - a2) * Double(k) / Double(steps), radius: r1))
        }
        core.closeSubpath()
        // Growing the shape back out with a round-joined stroke rounds the corners.
        let rim = core.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return core.union(rim)
    }

    /// Ring choice `index` of a slice.
    static func optionShape(_ index: Int, count: Int, around center: Double) -> CGPath {
        let angle = optionAngle(index, count: count, around: center)
        return roundedSector(start: angle - optionSpan / 2, end: angle + optionSpan / 2,
                             inner: ringInner, outer: ringOuter, margin: 2.5, corner: 12)
    }

    /// Where the frosted glass shows: the disc, plus the ring when it's open.
    static func maskImage(slices: [WheelSlice], hot: Int?) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            if let hot, hot < slices.count, slices[hot].hasRing {
                let count = slices[hot].options.count
                for i in 0..<count {
                    ctx.addPath(optionShape(i, count: count, around: sliceAngle(hot, count: slices.count)))
                }
            }
            ctx.setFillColor(.black)
            ctx.fillPath()
            return true
        }
    }
}

/// Lets SwiftUI draw a CGPath.
struct PathShape: Shape {
    let outline: Path
    init(cgPath: CGPath) { outline = Path(cgPath) }
    func path(in rect: CGRect) -> Path { outline }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    private typealias G = WheelGeometry
    private let hairline = Color.primary.opacity(0.12)

    var body: some View {
        let count = model.slices.count

        ZStack {
            // Thin dividers between slices (hidden next to the selection, like a segmented control).
            if count > 1 {
                ForEach(0..<count, id: \.self) { i in
                    let nextToSelection = model.hotSlice == i || model.hotSlice == (i + count - 1) % count
                    let a = G.sliceAngle(i, count: count) - .pi / Double(count)
                    Path { p in
                        p.move(to: G.point(angle: a, radius: G.inner + 10))
                        p.addLine(to: G.point(angle: a, radius: G.outer - 10))
                    }
                    .stroke(hairline, lineWidth: 1)
                    .opacity(nextToSelection ? 0 : 1)
                }
            }

            selection(count: count)

            ForEach(Array(model.slices.enumerated()), id: \.offset) { index, item in
                let lit = model.hotSlice == index && (!item.hasRing || model.hotOption != nil)
                VStack(spacing: 4) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .frame(height: 22)
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(lit ? Color.white : Color.primary)
                .position(G.point(angle: G.sliceAngle(index, count: count), radius: (G.inner + G.outer) / 2))
            }

            if let s = model.hotSlice, s < count, model.slices[s].hasRing {
                ring(for: model.slices[s], around: G.sliceAngle(s, count: count))
            }

            // Disc edge and centre well.
            Circle().strokeBorder(hairline, lineWidth: 0.5)
                .frame(width: G.outer * 2, height: G.outer * 2)
            Circle().fill(Color.primary.opacity(0.06))
                .frame(width: G.inner * 2 - 8, height: G.inner * 2 - 8)
            centre
        }
        .frame(width: G.size, height: G.size)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: model.hotSlice)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: model.hotOption)
    }

    /// Rounded highlight behind the slice under the cursor: grey while a ring choice
    /// is still needed, accent colour once letting go would do something.
    @ViewBuilder
    private func selection(count: Int) -> some View {
        if let s = model.hotSlice, s < count {
            let lit = !model.slices[s].hasRing || model.hotOption != nil
            let fill = lit ? Color.accentColor : Color.primary.opacity(0.1)
            if count == 1 {
                Circle()
                    .stroke(fill, lineWidth: G.outer - G.inner - 12)
                    .frame(width: G.outer + G.inner, height: G.outer + G.inner)
            } else {
                let a = G.sliceAngle(s, count: count), half = .pi / Double(count)
                PathShape(cgPath: G.roundedSector(start: a - half, end: a + half, inner: G.inner, outer: G.outer,
                                                  margin: 5, corner: 12))
                    .fill(fill)
            }
        }
    }

    private func ring(for item: WheelSlice, around center: Double) -> some View {
        let count = item.options.count
        return ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
            let shape = PathShape(cgPath: G.optionShape(index, count: count, around: center))
            let hot = model.hotOption == index
            ZStack {
                shape.fill(hot ? Color.accentColor : Color.clear)
                shape.stroke(hairline, lineWidth: 0.5)
                Text(option.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hot ? Color.white : Color.primary)
                    .position(G.point(angle: G.optionAngle(index, count: count, around: center),
                                      radius: (G.ringInner + G.ringOuter) / 2))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch model.status {
        case .working?:
            ProgressView().controlSize(.small)
        case .done?:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .transition(.scale.combined(with: .opacity))
        case .failed(let n)?:
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.multicolor)
                Text("\(n) failed").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        case nil:
            Group {
                if let action = model.selectedAction {
                    Text(action.subtitle).foregroundStyle(.primary)
                } else if let s = model.hotSlice, s < model.slices.count {
                    Text("Choose \(model.slices[s].title.lowercased())").foregroundStyle(.secondary)
                } else {
                    Text("\(model.fileCount) \(model.fileCount == 1 ? "file" : "files")").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(width: G.inner * 2 - 16)
        }
    }
}
