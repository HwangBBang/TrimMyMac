import SwiftUI
import TrimCore

/// Minimal line chart of memory used-ratio history. Flat baseline until enough samples.
struct Sparkline: View {
    let samples: [MemoryMonitor.PressureSample]
    var body: some View {
        GeometryReader { geo in
            let pts = samples
            Path { path in
                guard pts.count >= 2 else {
                    let y = geo.size.height * 0.9
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    return
                }
                let maxR = max(pts.map(\.usedRatio).max() ?? 1, 0.0001)
                for (i, s) in pts.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                    let y = geo.size.height * (1 - CGFloat(s.usedRatio / maxR))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.secondary, lineWidth: 1)
        }
        .frame(width: 56, height: 16)
        .accessibilityHidden(true)
    }
}
