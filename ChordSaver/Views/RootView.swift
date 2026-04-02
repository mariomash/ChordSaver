import SwiftUI

struct RootView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var audio: AudioCaptureEngine
    @FocusState private var focusedField: SidebarFocus?

    private enum SidebarFocus {
        case search
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.35)
            HSplitView {
                chordSidebar
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 360)
                mainPane
                    .frame(minWidth: 560)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .onKeyPress(.space) {
            guard !vm.isFinalizingAudio else { return .ignored }
            if focusedField == .search { return .ignored }
            vm.toggleRecord()
            return .handled
        }
        .onAppear {
            vm.refreshDevices()
            vm.startAudioSessionIfNeeded()
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("ChordSaver")
                .font(.headline)
                .foregroundStyle(.secondary)

            Picker("Input", selection: Binding(
                get: { vm.selectedDevice.deviceID },
                set: { id in
                    if let d = vm.devices.first(where: { $0.deviceID == id }) {
                        vm.selectDevice(d)
                    }
                }
            )) {
                ForEach(vm.devices) { d in
                    Text(d.name).tag(d.deviceID)
                }
            }
            .frame(minWidth: 220)

            Button("Refresh devices") {
                vm.refreshDevices()
            }

            Spacer()

            formatBadge

            Button("Export Session…") {
                vm.exportSession()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var formatBadge: some View {
        HStack(spacing: 8) {
            Text("Capture")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("48 kHz · 24-bit · stereo WAV")
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    private var chordSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chord list")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            TextField("Search…", text: $vm.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .focused($focusedField, equals: .search)

            List(selection: Binding(
                get: { vm.currentChord?.id },
                set: { id in
                    if let id { vm.jumpToChord(id: id) }
                }
            )) {
                ForEach(vm.filteredChords) { chord in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chord.displayName)
                            .font(.body.weight(.medium))
                        Text(chord.category)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .tag(chord.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var mainPane: some View {
        VStack(spacing: 16) {
            RecorderStrip(audio: audio, vm: vm)

            if let chord = vm.currentChord {
                Text(chord.displayName)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                Text("Chord \(vm.currentIndex + 1) of \(vm.chords.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                FretboardDiagramView(chord: chord)
                    .frame(height: 280)
                    .padding(.horizontal)
            } else {
                ContentUnavailableView("No chords", systemImage: "guitars")
            }

            LastTakePanel(take: vm.lastTake)

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
    }
}
