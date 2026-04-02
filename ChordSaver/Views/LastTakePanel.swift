import SwiftUI

struct LastTakePanel: View {
    let take: RecordingTake?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last take")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if let take {
                HStack(alignment: .top, spacing: 16) {
                    WaveformSilhouette(envelope: take.waveformEnvelope)
                        .frame(height: 64)
                        .frame(maxWidth: 280)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(take.displayName)
                            .font(.headline)
                        Text(String(format: "%.2f s · peak %.1f dBFS · take %02d", take.duration, take.peakDBFS, take.takeIndex))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(take.fileURL.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            } else {
                Text("No takes yet — Space to record.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
        .padding(.horizontal)
    }
}

struct WaveformSilhouette: View {
    let envelope: [Float]

    var body: some View {
        WaveformSilhouetteShape(envelope: envelope)
            .stroke(Color.accentColor.opacity(0.75), lineWidth: 1.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
    }
}

private struct WaveformSilhouetteShape: Shape {
    var envelope: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let pairs = max(envelope.count / 2, 1)
        let w = rect.width
        for i in 0..<pairs {
            let mn = envelope[2 * i]
            let mx = envelope[2 * i + 1]
            let x = w * CGFloat(i) / CGFloat(max(pairs - 1, 1))
            let y1 = mid - CGFloat(mx) * mid * 0.95
            let y2 = mid - CGFloat(mn) * mid * 0.95
            path.move(to: CGPoint(x: x, y: y1))
            path.addLine(to: CGPoint(x: x, y: y2))
        }
        return path
    }
}
