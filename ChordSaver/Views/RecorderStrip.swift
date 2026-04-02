import SwiftUI

struct RecorderStrip: View {
    @ObservedObject var audio: AudioCaptureEngine
    @ObservedObject var vm: AppViewModel
    var canRecord: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(audio.inputFormatDescription)
                        .font(.caption.monospaced())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(audio.isRecording ? "Recording" : "Ready")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(audio.isRecording ? Color.red : Color.secondary)
                    if audio.isRecording {
                        Text(formatTime(audio.elapsed))
                            .font(.title3.monospacedDigit())
                    }
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Peak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    MeterBar(levelDB: audio.peakDB, style: .peak, clipped: audio.clipped, recording: audio.isRecording)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("RMS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    MeterBar(levelDB: audio.rmsDB, style: .rms, clipped: false, recording: audio.isRecording)
                }
            }

            HStack {
                Button {
                    vm.toggleRecord()
                } label: {
                    Label(
                        audio.isRecording ? "Stop (Space)" : "Record (Space)",
                        systemImage: audio.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .disabled(vm.isFinalizingAudio || (!audio.isRecording && !canRecord))

                if vm.isFinalizingAudio {
                    ProgressView()
                        .scaleEffect(0.85)
                        .padding(.leading, 8)
                }

                Spacer()

                if let err = audio.lastError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
        )
        .padding(.horizontal)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, ms)
    }
}

enum MeterStyle {
    case peak
    case rms
}

struct MeterBar: View {
    var levelDB: Float
    var style: MeterStyle
    var clipped: Bool
    var recording: Bool

    private var normalized: CGFloat {
        let floor: Float = -60
        let ceil: Float = 0
        let x = (levelDB - floor) / (ceil - floor)
        return CGFloat(min(max(x, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: recording
                                ? (style == .rms
                                    ? [Color.green.opacity(0.55), Color.yellow.opacity(0.65)]
                                    : [Color.yellow.opacity(0.55), Color.orange.opacity(0.75), Color.red.opacity(0.85)])
                                : (style == .rms
                                    ? [Color.cyan.opacity(0.35), Color.blue.opacity(0.45)]
                                    : [Color.blue.opacity(0.35), Color.indigo.opacity(0.5)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, geo.size.width * normalized))
                if clipped {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(0.9), lineWidth: 2)
                }
            }
        }
        .frame(height: 18)
        .accessibilityLabel(style == .peak ? "Peak meter" : "RMS meter")
        .accessibilityValue(String(format: "%.1f dB", levelDB))
    }
}
