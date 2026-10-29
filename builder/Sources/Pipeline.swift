import Foundation

/// Where the tools live. The defaults are this machine's; Settings overrides them.
struct Paths {
    static let defaults = UserDefaults.standard

    /// The repository this app was built from (builder/Sources/ is two levels down).
    private static let sourceRepo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path

    static var repo: String {
        get { defaults.string(forKey: "repo") ?? sourceRepo }
        set { defaults.set(newValue, forKey: "repo") }
    }
    /// A virtualenv at <repo>/.venv when there is one, else the system Python.
    static var python: String {
        get {
            if let p = defaults.string(forKey: "python") { return p }
            let venv = repo + "/.venv/bin/python"
            return FileManager.default.isExecutableFile(atPath: venv) ? venv : "/usr/bin/python3"
        }
        set { defaults.set(newValue, forKey: "python") }
    }
    /// Empty: the Xcode xcode-select points at (or the one in config.local.json).
    static var xcode: String {
        get { defaults.string(forKey: "xcode") ?? "" }
        set { defaults.set(newValue, forKey: "xcode") }
    }
    static var work: String { repo + "/work" }
    static var macApp: String { work + "/out/Digger HD.app" }
}

/// A paired iPad, iPhone or Apple TV, from `devicectl list devices`.
struct Device: Identifiable, Hashable {
    let id: String          // UDID
    let name: String
    let kind: Kind
    let available: Bool
    enum Kind { case phoneOrPad, tv }
}

enum Devices {
    static func list() async -> [Device] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["devicectl", "list", "devices", "--json-output", tmp.path, "--quiet"]
        var env = ProcessInfo.processInfo.environment
        if !Paths.xcode.isEmpty { env["DEVELOPER_DIR"] = Paths.xcode }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        await withCheckedContinuation { c in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        guard let data = try? Data(contentsOf: tmp),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        var out: [Device] = []
        for d in devices {
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            guard (hw["reality"] as? String) == "physical",
                  (conn["pairingState"] as? String) == "paired",
                  let udid = hw["udid"] as? String else { continue }
            let type = (hw["deviceType"] as? String ?? "").lowercased()
            let kind: Device.Kind
            if type.contains("tv") { kind = .tv }
            else if type.contains("ipad") || type.contains("iphone") { kind = .phoneOrPad }
            else { continue }
            let tunnel = conn["tunnelState"] as? String ?? ""
            out.append(Device(id: udid, name: props["name"] as? String ?? udid, kind: kind,
                              available: tunnel != "unavailable"))
        }
        return out.sorted { $0.name < $1.name }
    }
}

/// Runs tools/build_from_pkg.py and turns its STEP / DONE / ERROR lines into state.
@MainActor
final class Pipeline: ObservableObject {
    enum State: Equatable { case idle, running, done(String), failed(String) }

    @Published var state: State = .idle
    @Published var step = 0
    @Published var total = 1
    @Published var stepText = ""
    @Published var log: [String] = []

    private var process: Process?
    private var buffer = Data()

    func start(pkg: URL, mac: Bool, ios: String?, tvos: String?, cover: URL?) {
        guard process == nil else { return }
        state = .running
        step = 0; total = 1; stepText = "Starting"; log = []
        var args = [Paths.repo + "/tools/build_from_pkg.py", pkg.path]
        if mac { args.append("--mac") }
        // nil: not built; "": built, not installed; otherwise the device to install on.
        if let ios { args += ios.isEmpty ? ["--ios"] : ["--install-ios", ios] }
        if let tvos { args += tvos.isEmpty ? ["--tvos"] : ["--install-tvos", tvos] }
        if let cover { args += ["--cover", cover.path] }
        if !Paths.xcode.isEmpty { args += ["--xcode", Paths.xcode] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.python)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: Paths.repo)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finished(code: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
        } catch {
            state = .failed("Could not start \(Paths.python): \(error.localizedDescription)")
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self)
            buffer.removeSubrange(...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        if line.hasPrefix("STEP ") {
            // STEP 3/9 decrypt: decrypting EBOOT.BIN ...
            let body = line.dropFirst(5)
            let parts = body.split(separator: " ", maxSplits: 1)
            let nums = parts.first?.split(separator: "/") ?? []
            if nums.count == 2, let n = Int(nums[0]), let t = Int(nums[1]) { step = n; total = t }
            if parts.count > 1, let colon = parts[1].firstIndex(of: ":") {
                stepText = String(parts[1][parts[1].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        } else if line.hasPrefix("DONE ") {
            state = .done(String(line.dropFirst(5)))
        } else if line.hasPrefix("ERROR ") {
            state = .failed(String(line.dropFirst(6)))
        } else if case .failed(let msg) = state, line.hasPrefix("    ") {
            state = .failed(msg + "\n" + line.trimmingCharacters(in: .whitespaces))
        }
    }

    private func finished(code: Int32) {
        if !buffer.isEmpty { handle(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
        process = nil
        if state == .running {
            state = code == 0 ? .done("Finished") : .failed("Stopped (exit code \(code))")
        }
    }
}
