import SwiftUI

/// Six strings (low E → high e), frets left-to-right from `baseFret`.
struct FretboardDiagramView: View {
    let chord: Chord

    private let numFretsShown = 5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let nutWidth: CGFloat = 5
            let fretCount = CGFloat(numFretsShown)
            let innerW = w - nutWidth - 8
            let fretSpacing = innerW / fretCount
            let stringCount: CGFloat = 6
            let stringSpacing = h / (stringCount + 1)

            Canvas { ctx, size in
                let bg = Path(CGRect(origin: .zero, size: size))
                ctx.fill(bg, with: .color(Color(nsColor: .controlBackgroundColor)))

                var nut = Path()
                nut.addRect(CGRect(x: 4, y: 8, width: nutWidth, height: size.height - 16))
                ctx.fill(nut, with: .color(Color(nsColor: .separatorColor).opacity(0.35)))

                for f in 0...Int(fretCount) {
                    let x = 4 + nutWidth + CGFloat(f) * fretSpacing
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 8))
                    line.addLine(to: CGPoint(x: x, y: size.height - 8))
                    ctx.stroke(line, with: .color(.gray.opacity(0.45)), lineWidth: f == 0 ? 2 : 1)
                }

                for s in 0..<6 {
                    let y = stringSpacing * CGFloat(s + 1)
                    var line = Path()
                    line.move(to: CGPoint(x: 4, y: y))
                    line.addLine(to: CGPoint(x: size.width - 4, y: y))
                    ctx.stroke(line, with: .color(.black.opacity(0.25)), lineWidth: 1.2)
                }

                let base = chord.baseFret
                for (si, fret) in chord.strings.enumerated() {
                    let y = stringSpacing * CGFloat(si + 1)
                    if fret < 0 {
                        let t = Text("×")
                            .font(.system(size: 14, weight: .bold))
                        ctx.draw(t, at: CGPoint(x: 4 + nutWidth * 0.35, y: y))
                    } else if fret == 0 && base <= 1 {
                        let dot = Path(ellipseIn: CGRect(x: 4 + nutWidth * 0.1, y: y - 6, width: 12, height: 12))
                        ctx.fill(dot, with: .color(.blue.opacity(0.85)))
                    } else {
                        let rel = CGFloat(fret - base + 1) - 0.5
                        if rel >= 0.25 && rel <= fretCount - 0.25 {
                            let cx = 4 + nutWidth + rel * fretSpacing
                            let dot = Path(ellipseIn: CGRect(x: cx - 9, y: y - 9, width: 18, height: 18))
                            ctx.fill(dot, with: .color(.orange.opacity(0.9)))
                        }
                    }
                }

                let label = Text("Fret \(base)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ctx.draw(label, at: CGPoint(x: size.width - 36, y: 14))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
