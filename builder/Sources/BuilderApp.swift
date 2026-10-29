import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BuilderApp: App {
    var body: some Scene {
        WindowGroup("Digger HD Builder") {
            ContentView()
                .frame(minWidth: 620, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        Settings { SettingsView() }
    }
}

struct ContentView: View {
    @StateObject private var pipeline = Pipeline()
    @State private var pkg: URL?
    @State private var cover: URL?
    @State private var buildMac = true
    @State private var buildIOS = false
    @State private var buildTV = false
    @State private var devices: [Device] = []
    @State private var iosDevice: String?
    @State private var tvDevice: String?
    @State private var targeted = false

    private var running: Bool { pipeline.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dropZone
            targets
            HStack {
                Button(action: build) {
                    Label(running ? "Building..." : "Build", systemImage: "hammer.fill")
                        .frame(minWidth: 110)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(pkg == nil || running || !(buildMac || buildIOS || buildTV))
                if running {
                    Button("Cancel", role: .cancel) { pipeline.cancel() }.controlSize(.large)
                }
                Spacer()
            }
            progress
            logView
        }
        .padding(22)
        .task { await refreshDevices() }
    }

    // MARK: - Package

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(targeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
            VStack(spacing: 8) {
                Image(systemName: pkg == nil ? "shippingbox" : "checkmark.seal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(pkg == nil ? Color.secondary : Color.green)
                if let pkg {
                    Text(pkg.lastPathComponent).font(.headline)
                    Text(sizeText(pkg)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Drop your Digger HD package (.pkg) here").font(.headline)
                    Text("The PSN package you own. It is decrypted, recompiled and built on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Package...") { choosePackage() }
                    Button(cover == nil ? "Cover Image..." : "Cover: \(cover!.lastPathComponent)") { chooseCover() }
                        .help("Optional: the icons are made from this image instead of the package's own art")
                }
                .disabled(running)
            }
            .padding()
        }
        .frame(height: 170)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if url.pathExtension.lowercased() == "pkg" { pkg = url }
                    else if ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) { cover = url }
                }
            }
            return true
        }
    }

    // MARK: - Targets

    private var targets: some View {
        GroupBox("Build for") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Mac", isOn: $buildMac)
                HStack {
                    Toggle("iPad / iPhone", isOn: $buildIOS)
                    Spacer()
                    devicePicker(selection: $iosDevice, kind: .phoneOrPad).disabled(!buildIOS)
                }
                HStack {
                    Toggle("Apple TV", isOn: $buildTV)
                    Spacer()
                    devicePicker(selection: $tvDevice, kind: .tv).disabled(!buildTV)
                }
                HStack {
                    Spacer()
                    Button("Refresh Devices") { Task { await refreshDevices() } }.controlSize(.small)
                }
            }
            .padding(6)
            .disabled(running)
        }
    }

    private func devicePicker(selection: Binding<String?>, kind: Device.Kind) -> some View {
        Picker("", selection: selection) {
            Text("Build only").tag(String?.none)
            ForEach(devices.filter { $0.kind == kind }) { d in
                Text(d.available ? "Install on \(d.name)" : "\(d.name) (not reachable)").tag(String?.some(d.id))
            }
        }
        .labelsHidden()
        .frame(width: 260)
    }

    // MARK: - Progress

    @ViewBuilder private var progress: some View {
        switch pipeline.state {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(max(pipeline.step - 1, 0)), total: Double(max(pipeline.total, 1)))
                Text("Step \(pipeline.step) of \(pipeline.total): \(pipeline.stepText)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .done(let summary):
            HStack(alignment: .top) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Done").font(.headline)
                    Text(summary.replacingOccurrences(of: "; ", with: "\n"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        if buildMac, FileManager.default.fileExists(atPath: Paths.macApp) {
                            Button("Play on Mac") { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.macApp)) }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.work + "/out")])
                        }
                    }
                }
            }
        case .failed(let message):
            HStack(alignment: .top) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title2)
                Text(message).font(.callout).textSelection(.enabled)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(pipeline.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("STEP") ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(8)
                .textSelection(.enabled)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .onChange(of: pipeline.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
    }

    // MARK: - Actions

    private func build() {
        guard let pkg else { return }
        pipeline.start(pkg: pkg, mac: buildMac,
                       ios: buildIOS ? (iosDevice ?? "") : nil,
                       tvos: buildTV ? (tvDevice ?? "") : nil,
                       cover: cover)
    }

    private func refreshDevices() async {
        devices = await Devices.list()
        if iosDevice == nil { iosDevice = devices.first { $0.kind == .phoneOrPad && $0.available }?.id }
        if tvDevice == nil { tvDevice = devices.first { $0.kind == .tv && $0.available }?.id }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { pkg = panel.url }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        if panel.runModal() == .OK { cover = panel.url }
    }

    private func sizeText(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct SettingsView: View {
    @State private var repo = Paths.repo
    @State private var python = Paths.python
    @State private var xcode = Paths.xcode

    var body: some View {
        Form {
            TextField("Port repository", text: $repo)
            TextField("Python (with the tools' packages)", text: $python)
            TextField("Xcode developer directory", text: $xcode)
            HStack {
                Spacer()
                Button("Save") { Paths.repo = repo; Paths.python = python; Paths.xcode = xcode }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
