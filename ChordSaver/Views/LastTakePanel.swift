import AVFoundation
#if os(macOS)
import AppKit
#endif
import SwiftUI

struct LastTakePanel: View {
    let takes: [RecordingTake]
    let lastTake: RecordingTake?
    var emptyMessage: String = "No takes yet — Space to record."

    @State private var selectedTakeID: RecordingTake.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Take preview")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if takes.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    takeList
                        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                        .frame(height: 220)

                    if let selectedTake {
                        LastTakeInteractiveBlock(take: selectedTake)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
        .padding(.horizontal)
        .onAppear {
            if selectedTakeID == nil {
                selectedTakeID = lastTake?.id
            }
        }
        .onChange(of: lastTake?.id) { _, newID in
            selectedTakeID = newID
        }
        .onChange(of: takes.map(\.id)) { _, ids in
            if let selectedTakeID, ids.contains(selectedTakeID) {
                return
            }
            self.selectedTakeID = lastTake?.id
        }
    }

    private var selectedTake: RecordingTake? {
        guard let selectedTakeID else { return lastTake }
        return takes.first(where: { $0.id == selectedTakeID }) ?? lastTake
    }

    private var takesNewestFirst: [RecordingTake] {
        Array(takes.reversed())
    }

    private var takeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(takesNewestFirst) { take in
                    Button {
                        selectedTakeID = take.id
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(take.displayName)
                                .font(.body.weight(.medium))
                            Text(String(format: "Take %02d · %.2f s · peak %.1f dBFS", take.takeIndex, take.duration, take.peakDBFS))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedTakeID == take.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Interactive block

private struct LastTakeInteractiveBlock: View {
    let take: RecordingTake
    @EnvironmentObject private var vm: AppViewModel
    @StateObject private var player = TakePreviewPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                LastTakeWaveformColumn(
                    take: take,
                    player: player,
                    zoom: $zoom,
                    scroll: $scroll,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd
                )
                .frame(height: 120)
                .frame(maxWidth: 520)

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
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    if player.isPlaying {
                        player.pause()
                    } else {
                        player.play()
                    }
                } label: {
                    Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(take.duration <= 0)

                Button("Stop") {
                    player.stop()
                }
                .disabled(!player.isPlaying && player.currentTime <= 0.001)

                Text(String(format: "%.2f / %.2f s", player.currentTime, player.duration))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }

            HStack {
                Button("Apply trim") {
                    applyTrim()
                }
                .disabled(trimDisabled || isApplyingTrim)

                if isApplyingTrim {
                    ProgressView()
                        .controlSize(.small)
                }
                if let trimError {
                    Text(trimError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .id("\(take.id.uuidString)-\(take.fileURL.path)")
        .onAppear {
            syncTrimToTake()
            try? player.load(url: take.fileURL)
        }
        .onChange(of: take.fileURL) { _, newURL in
            player.stop()
            try? player.load(url: newURL)
            syncTrimToTake()
        }
        .onChange(of: take.duration) { _, _ in
            syncTrimToTake()
        }
        .onChange(of: vm.lastTakePreviewStopToken) { _, _ in
            player.stop()
        }
    }

    @State private var zoom: CGFloat = 1
    @State private var scroll: CGFloat = 0
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0
    @State private var isApplyingTrim = false
    @State private var trimError: String?

    private var trimDisabled: Bool {
        let d = take.duration
        guard d > 0 else { return true }
        let minKeep = max(0.05, d * 0.02)
        let span = trimEnd - trimStart
        return span < minKeep || (trimStart <= 0.02 && trimEnd >= d - 0.02)
    }

    private func syncTrimToTake() {
        let d = take.duration
        trimStart = 0
        trimEnd = d
        trimError = nil
    }

    private func applyTrim() {
        trimError = nil
        isApplyingTrim = true
        let takeCaptured = take
        let t0 = trimStart
        let t1 = trimEnd
        Task {
            do {
                let dir = takeCaptured.fileURL.deletingLastPathComponent()
                let base = takeCaptured.fileURL.deletingPathExtension().lastPathComponent
                let dest = dir.appendingPathComponent("\(base)_trim_\(UUID().uuidString.prefix(6)).wav")
                try WAVTrimService.trim(source: takeCaptured.fileURL, startSeconds: t0, endSeconds: t1, destination: dest)
                if takeCaptured.fileURL != takeCaptured.originalFileURL {
                    try? FileManager.default.removeItem(at: takeCaptured.fileURL)
                }
                let analysis = try WaveformEnvelopeBuilder.analyze(url: dest)
                let newTake = RecordingTake(
                    id: takeCaptured.id,
                    chordId: takeCaptured.chordId,
                    displayName: takeCaptured.displayName,
                    takeIndex: takeCaptured.takeIndex,
                    originalFileURL: takeCaptured.originalFileURL,
                    fileURL: dest,
                    duration: analysis.duration,
                    peakLinear: analysis.peakLinear,
                    rmsLinear: analysis.rmsLinear,
                    waveformEnvelope: analysis.envelope
                )
                await MainActor.run {
                    vm.replaceTake(id: takeCaptured.id, with: newTake)
                    isApplyingTrim = false
                }
            } catch {
                await MainActor.run {
                    trimError = error.localizedDescription
                    isApplyingTrim = false
                }
            }
        }
    }
}

// MARK: - Waveform column

private struct LastTakeWaveformColumn: View {
    let take: RecordingTake
    @ObservedObject var player: TakePreviewPlayer
    @Binding var zoom: CGFloat
    @Binding var scroll: CGFloat
    @Binding var trimStart: TimeInterval
    @Binding var trimEnd: TimeInterval

    @State private var trimDragAnchor: (kind: TrimHandleKind, trimStart: TimeInterval, trimEnd: TimeInterval)?

    private enum TrimHandleKind { case start, end }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let vis = visibleWindow(zoom: zoom, scroll: scroll)
            let mapper = WaveformTimeMapper(duration: take.duration, visibleStart: vis.start, visibleEnd: vis.end)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))

                if take.waveformEnvelope.isEmpty {
                    ProgressView("Loading waveform…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WaveformMountainShape(envelope: take.waveformEnvelope, visibleStart: vis.start, visibleEnd: vis.end)
                        .fill(Color.accentColor.opacity(0.38))
                    WaveformMountainShape(envelope: take.waveformEnvelope, visibleStart: vis.start, visibleEnd: vis.end)
                        .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)

                    Path { p in
                        let y = h / 2
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.primary.opacity(0.2))

                    trimShade(mapper: mapper, width: w, height: h)

                    if let x = mapper.xInRect(time: player.currentTime, width: w) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.9))
                            .frame(width: 2, height: h)
                            .position(x: x, y: h / 2)
                    }

                    trimHandles(mapper: mapper, width: w, height: h)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .overlay {
                #if os(macOS)
                TrackpadWaveformInputSurface(
                    onMagnify: { magnification, location, size in
                        adjustZoom(by: magnification, focusX: location.x, width: size.width)
                    },
                    onScroll: { delta, _, size in
                        pan(by: delta, width: size.width)
                    }
                )
                #endif
            }
            .help("Pinch to zoom. Two-finger scroll to pan when zoomed in.")
        }
    }

    private func visibleWindow(zoom: CGFloat, scroll: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let z = max(1, min(zoom, 32))
        let span = CGFloat(1) / z
        let slack = max(0, 1 - span)
        let start = slack > 0 ? scroll * slack : 0
        let end = start + span
        return (start, end)
    }

    @discardableResult
    private func adjustZoom(by magnification: CGFloat, focusX: CGFloat, width w: CGFloat) -> Bool {
        guard take.duration > 0, w > 0 else { return false }
        let vis = visibleWindow(zoom: zoom, scroll: scroll)
        let oldSpan = max(CGFloat(1e-6), vis.end - vis.start)
        let focusRatio = (focusX / w).clamped(to: 0...1)
        let focus = vis.start + focusRatio * oldSpan
        let scale = max(CGFloat(0.25), 1 + magnification)
        let newZoom = (zoom * scale).clamped(to: 1...16)
        guard abs(newZoom - zoom) > 0.0001 else { return false }
        let newSpan = CGFloat(1) / newZoom
        let newStart = focus - focusRatio * newSpan
        setVisibleWindow(start: newStart, zoom: newZoom)
        return true
    }

    @discardableResult
    private func pan(by delta: CGFloat, width w: CGFloat) -> Bool {
        guard take.duration > 0, w > 0, zoom > 1.0001 else { return false }
        let vis = visibleWindow(zoom: zoom, scroll: scroll)
        let span = max(CGFloat(1e-6), vis.end - vis.start)
        let oldScroll = scroll
        let newStart = vis.start - (delta / w) * span
        setVisibleWindow(start: newStart, zoom: zoom)
        return abs(scroll - oldScroll) > 0.0001
    }

    private func setVisibleWindow(start: CGFloat, zoom newZoom: CGFloat) {
        let clampedZoom = newZoom.clamped(to: 1...16)
        let span = CGFloat(1) / clampedZoom
        let slack = max(0, 1 - span)
        let clampedStart = slack > 0 ? start.clamped(to: 0...slack) : 0
        zoom = clampedZoom
        scroll = slack > 0 ? clampedStart / slack : 0
    }

    @ViewBuilder
    private func trimShade(mapper: WaveformTimeMapper, width w: CGFloat, height h: CGFloat) -> some View {
        if take.duration > 0, let xs = mapper.xInRect(time: trimStart, width: w),
           let xe = mapper.xInRect(time: trimEnd, width: w)
        {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, xs), height: h)
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, w - xe), height: h)
                    .offset(x: xe)
            }
            .allowsHitTesting(false)
        }
    }

    private func trimHandles(mapper: WaveformTimeMapper, width w: CGFloat, height h: CGFloat) -> some View {
        ZStack {
            if take.duration > 0, let xs = xForTrimHandle(time: trimStart, mapper: mapper, width: w) {
                trimHandle(x: xs, width: w, height: h, kind: .start)
            }
            if take.duration > 0, let xe = xForTrimHandle(time: trimEnd, mapper: mapper, width: w) {
                trimHandle(x: xe, width: w, height: h, kind: .end)
            }
        }
    }

    /// Maps trim time to x; pins to the nearest edge when zoomed outside the visible window.
    private func xForTrimHandle(time t: TimeInterval, mapper: WaveformTimeMapper, width w: CGFloat) -> CGFloat? {
        guard take.duration > 0, w > 0 else { return nil }
        let tn = CGFloat(t / take.duration)
        if tn < mapper.visibleStart { return 0 }
        if tn > mapper.visibleEnd { return w }
        return mapper.xInRect(time: t, width: w)
    }

    private func trimHandle(x: CGFloat, width w: CGFloat, height h: CGFloat, kind: TrimHandleKind) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(0.95))
            .frame(width: 10, height: min(h - 8, 88))
            .position(x: x, y: h / 2)
            .highPriorityGesture(
                DragGesture()
                    .onChanged { g in
                        if trimDragAnchor == nil {
                            trimDragAnchor = (kind, trimStart, trimEnd)
                        }
                        guard let anchor = trimDragAnchor else { return }
                        let vis = visibleWindow(zoom: zoom, scroll: scroll)
                        let span = max(CGFloat(1e-6), vis.end - vis.start)
                        let d = take.duration
                        guard d > 0, w > 0 else { return }
                        let deltaT = TimeInterval(g.translation.width / w * span) * d
                        let minGap = max(0.05, d * 0.02)
                        switch anchor.kind {
                        case .start:
                            let hi = max(0, anchor.trimEnd - minGap)
                            trimStart = (anchor.trimStart + deltaT).clamped(to: 0...hi)
                        case .end:
                            let lo = min(d, anchor.trimStart + minGap)
                            trimEnd = (anchor.trimEnd + deltaT).clamped(to: lo...d)
                        }
                    }
                    .onEnded { _ in trimDragAnchor = nil }
            )
    }
}

#if os(macOS)
private struct TrackpadWaveformInputSurface: NSViewRepresentable {
    let onMagnify: (CGFloat, CGPoint, CGSize) -> Bool
    let onScroll: (CGFloat, CGPoint, CGSize) -> Bool

    func makeNSView(context: Context) -> TrackpadWaveformInputView {
        let view = TrackpadWaveformInputView()
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: TrackpadWaveformInputView, context: Context) {
        nsView.onMagnify = onMagnify
        nsView.onScroll = onScroll
    }
}

private final class TrackpadWaveformInputView: NSView {
    var onMagnify: ((CGFloat, CGPoint, CGSize) -> Bool)?
    var onScroll: ((CGFloat, CGPoint, CGSize) -> Bool)?

    private var eventMonitors: [Any] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateEventMonitors()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        removeEventMonitors()
    }

    private func updateEventMonitors() {
        removeEventMonitors()
        guard window != nil else { return }

        if let magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] event in
            guard let self,
                  self.window === event.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            let handled = self.onMagnify?(event.magnification, CGPoint(x: location.x, y: location.y), self.bounds.size) ?? false
            return handled ? nil : event
        }) {
            eventMonitors.append(magnifyMonitor)
        }

        if let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self,
                  self.window === event.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            let dominantDelta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            let handled = self.onScroll?(dominantDelta, CGPoint(x: location.x, y: location.y), self.bounds.size) ?? false
            return handled ? nil : event
        }) {
            eventMonitors.append(scrollMonitor)
        }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }
}
#endif

// MARK: - Time mapping

private struct WaveformTimeMapper {
    let duration: TimeInterval
    let visibleStart: CGFloat
    let visibleEnd: CGFloat

    func xInRect(time t: TimeInterval, width w: CGFloat) -> CGFloat? {
        guard duration > 0, w > 0 else { return nil }
        let tn = CGFloat(t / duration)
        guard tn >= visibleStart - 1e-5, tn <= visibleEnd + 1e-5 else { return nil }
        let span = visibleEnd - visibleStart
        guard span > 1e-8 else { return nil }
        let x = (tn - visibleStart) / span * w
        return min(w, max(0, x))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Shapes

struct WaveformMountainShape: Shape {
    var envelope: [Float]
    var visibleStart: CGFloat
    var visibleEnd: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let pairCount = envelope.count / 2
        guard pairCount > 0 else { return path }

        let span = max(visibleEnd - visibleStart, 1e-6)
        let w = rect.width

        var topPts: [CGPoint] = []
        topPts.reserveCapacity(pairCount)
        for i in 0..<pairCount {
            let t = CGFloat(i) / CGFloat(max(pairCount - 1, 1))
            if t < visibleStart || t > visibleEnd { continue }
            let x = (t - visibleStart) / span * w
            let mx = envelope[2 * i + 1]
            let y = midY - clampedWaveYScale(mx) * midY * 0.95
            topPts.append(CGPoint(x: x, y: y))
        }
        guard !topPts.isEmpty else { return path }

        path.move(to: topPts[0])
        for k in 1..<topPts.count {
            path.addLine(to: topPts[k])
        }

        var bottomPts: [CGPoint] = []
        for i in (0..<pairCount).reversed() {
            let t = CGFloat(i) / CGFloat(max(pairCount - 1, 1))
            if t < visibleStart || t > visibleEnd { continue }
            let x = (t - visibleStart) / span * w
            let mn = envelope[2 * i]
            let y = midY - clampedWaveYScale(mn) * midY * 0.95
            bottomPts.append(CGPoint(x: x, y: y))
        }
        for pt in bottomPts {
            path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }

    private func clampedWaveYScale(_ v: Float) -> CGFloat {
        guard v.isFinite else { return 0 }
        return CGFloat(max(-1, min(1, v)))
    }
}

// MARK: - Preview player

@MainActor
final class TakePreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var currentTime: TimeInterval = 0

    private var audioPlayer: AVAudioPlayer?
    private var ticker: Timer?

    var duration: TimeInterval { audioPlayer?.duration ?? 0 }

    func load(url: URL) throws {
        stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.prepareToPlay()
        audioPlayer = p
        currentTime = 0
    }

    func play() {
        guard let p = audioPlayer else { return }
        if p.play() {
            isPlaying = true
            startTicker()
        }
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTicker()
        currentTime = audioPlayer?.currentTime ?? 0
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        stopTicker()
        currentTime = 0
    }

    private func startTicker() {
        stopTicker()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.audioPlayer else { return }
                if p.isPlaying {
                    self.currentTime = p.currentTime
                    if self.currentTime >= p.duration - 0.02 {
                        self.stop()
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
