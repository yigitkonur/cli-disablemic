import CoreAudio
import Foundation
import os.log

// MARK: - Logging (Apple Unified Logging)

private let logger = OSLog(subsystem: "com.local.mic-guard", category: "audio")

func log(_ message: String) {
    os_log("%{public}@", log: logger, type: .default, message)
}

func logError(_ message: String) {
    os_log("%{public}@", log: logger, type: .error, message)
}

// MARK: - Pause State (sentinel file)

/// The daemon checks this file lazily on each audio event — no polling.
/// - File missing → enforcement active
/// - File contains "0" or empty → paused indefinitely
/// - File contains a Unix timestamp → paused until that time
private let pauseFile: String = {
    let dir = NSString(string: "~/.config/mic-guard").expandingTildeInPath
    return "\(dir)/paused"
}()

private let pauseDir: String = {
    NSString(string: "~/.config/mic-guard").expandingTildeInPath
}()

enum PauseState {
    case active                // enforcement on
    case pausedIndefinitely    // enforcement off until manual resume
    case pausedUntil(Date)     // enforcement off until timestamp
}

func readPauseState() -> PauseState {
    guard FileManager.default.fileExists(atPath: pauseFile) else {
        return .active
    }
    guard let content = try? String(contentsOfFile: pauseFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !content.isEmpty,
          content != "0" else {
        return .pausedIndefinitely
    }
    if let timestamp = TimeInterval(content) {
        let deadline = Date(timeIntervalSince1970: timestamp)
        if deadline > Date() {
            return .pausedUntil(deadline)
        }
        // Deadline passed — auto-resume: remove the file
        try? FileManager.default.removeItem(atPath: pauseFile)
        return .active
    }
    return .pausedIndefinitely
}

func isPaused() -> Bool {
    switch readPauseState() {
    case .active: return false
    case .pausedIndefinitely: return true
    case .pausedUntil(let deadline):
        if deadline > Date() { return true }
        // Expired — clean up
        try? FileManager.default.removeItem(atPath: pauseFile)
        return false
    }
}

func writePause(minutes: Int?) {
    try? FileManager.default.createDirectory(atPath: pauseDir, withIntermediateDirectories: true)
    if let minutes = minutes, minutes > 0 {
        let deadline = Date().addingTimeInterval(Double(minutes) * 60)
        try? String(format: "%.0f", deadline.timeIntervalSince1970)
            .write(toFile: pauseFile, atomically: true, encoding: .utf8)
    } else {
        try? "0".write(toFile: pauseFile, atomically: true, encoding: .utf8)
    }
}

func clearPause() {
    try? FileManager.default.removeItem(atPath: pauseFile)
}

// MARK: - Mode Configuration

enum GuardMode: String {
    case strict = "strict"
    case smart = "smart"
}

private let modeFile: String = {
    let dir = NSString(string: "~/.config/mic-guard").expandingTildeInPath
    return "\(dir)/mode"
}()

func readMode() -> GuardMode {
    guard let content = try? String(contentsOfFile: modeFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
        return .strict
    }
    return GuardMode(rawValue: content) ?? .strict
}

func modeName(_ mode: GuardMode) -> String {
    switch mode {
    case .strict: return "always block"
    case .smart:  return "respect manual override"
    }
}

// MARK: - CoreAudio Helpers

func getDefaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
        return nil
    }
    let bufferPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
    defer { bufferPtr.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferPtr) == noErr else {
        return nil
    }
    let cfStr = Unmanaged<CFString>.fromOpaque(bufferPtr.load(as: UnsafeRawPointer.self))
    return cfStr.takeUnretainedValue() as String
}

func getTransportType(_ deviceID: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
    guard status == noErr else { return nil }
    return transport
}

func getAllInputDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
    ) == noErr else { return [] }

    return devices.filter { deviceID in
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
        return streamSize > 0
    }
}

func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var mutableID = deviceID
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &mutableID
    )
    return status == noErr
}

func transportName(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBluetooth:   return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
    case kAudioDeviceTransportTypeBuiltIn:     return "BuiltIn"
    case kAudioDeviceTransportTypeUSB:         return "USB"
    case kAudioDeviceTransportTypeAggregate:   return "Aggregate"
    case kAudioDeviceTransportTypeVirtual:     return "Virtual"
    default:
        let chars = (0..<4).map { i in
            Character(UnicodeScalar((type >> (24 - i * 8)) & 0xFF) ?? UnicodeScalar(0x3F))
        }
        return "Unknown(\(String(chars))/\(type))"
    }
}

// MARK: - Device Discovery

func findBuiltInInputDevice() -> AudioDeviceID? {
    for deviceID in getAllInputDevices() {
        if let transport = getTransportType(deviceID),
           transport == kAudioDeviceTransportTypeBuiltIn {
            return deviceID
        }
    }
    return nil
}

func shouldBlockAsInput(_ transport: UInt32) -> Bool {
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn:     return false
    case kAudioDeviceTransportTypeUSB:         return false
    case kAudioDeviceTransportTypeAggregate:   return false
    case kAudioDeviceTransportTypeBluetooth:   return true
    case kAudioDeviceTransportTypeBluetoothLE: return true
    default:                                   return true
    }
}

// MARK: - Enforcement Logic

private var isStabilizing = false
private let stabilizationTicks = 10
private let stabilizationInterval: TimeInterval = 0.5
private var lastStabilizationEnd: Date? = nil

@discardableResult
func enforceBuiltInInput() -> Bool {
    // Check pause state on every enforcement attempt (lazy, not polling)
    if isPaused() {
        log("Paused — skipping enforcement")
        return false
    }

    guard let currentID = getDefaultInputDeviceID(),
          let transport = getTransportType(currentID) else {
        return false
    }

    guard shouldBlockAsInput(transport) else { return false }

    let currentName = getDeviceName(currentID) ?? "?"
    log("Blocked input detected: \"\(currentName)\" (\(transportName(transport)))")

    guard let builtIn = findBuiltInInputDevice() else {
        logError("No built-in input device found — cannot enforce")
        return false
    }

    guard builtIn != currentID else { return false }

    let builtInName = getDeviceName(builtIn) ?? "?"
    if setDefaultInputDevice(builtIn) {
        log("Forced input to: \"\(builtInName)\"")
        return true
    } else {
        logError("Failed to set input to \"\(builtInName)\"")
        return false
    }
}

func stabilize() {
    guard !isStabilizing else { return }

    // Smart mode: if a new stabilization triggers within 10s of the last one ending,
    // the user intentionally switched back → pause for 1 hour.
    if readMode() == .smart, let lastEnd = lastStabilizationEnd {
        let elapsed = Date().timeIntervalSince(lastEnd)
        if elapsed < 10.0 {
            log("Smart mode: manual re-switch detected (\(String(format: "%.1f", elapsed))s after last correction) — pausing for 1 hour")
            writePause(minutes: 60)
            lastStabilizationEnd = nil
            return
        }
    }

    isStabilizing = true

    var remaining = stabilizationTicks
    var didEnforce = false

    func tick() {
        if enforceBuiltInInput() { didEnforce = true }
        remaining -= 1
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationInterval) { tick() }
        } else {
            isStabilizing = false
            if didEnforce {
                lastStabilizationEnd = Date()
            }
            log("Stabilization complete\(didEnforce ? "" : " (no action needed)")")
        }
    }
    tick()
}

// MARK: - CoreAudio Listener Callbacks

func onDefaultInputChanged(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { stabilize() }
    return noErr
}

func onDeviceListChanged(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            stabilize()
        }
    }
    return noErr
}

// MARK: - Listener Registration

func registerListeners() {
    var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let s1 = AudioObjectAddPropertyListener(
        AudioObjectID(kAudioObjectSystemObject), &inputAddress, onDefaultInputChanged, nil
    )
    if s1 != noErr {
        logError("Failed to register default-input listener (status: \(s1))")
        exit(1)
    }

    var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let s2 = AudioObjectAddPropertyListener(
        AudioObjectID(kAudioObjectSystemObject), &devicesAddress, onDeviceListChanged, nil
    )
    if s2 != noErr {
        logError("Failed to register device-list listener (status: \(s2))")
        exit(1)
    }
}

// MARK: - Signal Handling

func setupSignalHandlers() {
    let shutdownHandler: @convention(c) (Int32) -> Void = { sig in
        log("Received signal \(sig), shutting down")
        exit(0)
    }
    signal(SIGTERM, shutdownHandler)
    signal(SIGINT, shutdownHandler)

    // SIGUSR1: poke from `mic-guard resume` to re-check immediately
    let pokeHandler: @convention(c) (Int32) -> Void = { _ in
        DispatchQueue.main.async {
            log("Received SIGUSR1 — re-checking enforcement")
            isStabilizing = false  // allow a fresh stabilization cycle
            lastStabilizationEnd = nil  // prevent false smart detection on resume
            stabilize()
        }
    }
    signal(SIGUSR1, pokeHandler)
}

// MARK: - Startup Diagnostics

func printDiagnostics() {
    log("mic-guard started (pid: \(ProcessInfo.processInfo.processIdentifier))")

    let mode = readMode()
    log("Mode: \(modeName(mode))")

    if let builtIn = findBuiltInInputDevice(), let name = getDeviceName(builtIn) {
        log("Built-in input device: \"\(name)\" (id: \(builtIn))")
    } else {
        logError("WARNING: No built-in input device found!")
    }

    if let current = getDefaultInputDeviceID(),
       let name = getDeviceName(current),
       let transport = getTransportType(current) {
        log("Current default input: \"\(name)\" (\(transportName(transport)))")
    }

    switch readPauseState() {
    case .active:
        log("Enforcement: active")
    case .pausedIndefinitely:
        log("Enforcement: PAUSED (indefinitely)")
    case .pausedUntil(let date):
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        log("Enforcement: PAUSED (until \(fmt.string(from: date)))")
    }

    log("All input devices:")
    for deviceID in getAllInputDevices() {
        let name = getDeviceName(deviceID) ?? "?"
        let transport = getTransportType(deviceID).map { transportName($0) } ?? "?"
        let blocked = getTransportType(deviceID).map { shouldBlockAsInput($0) ? " [BLOCKED]" : "" } ?? ""
        let isDefault = deviceID == getDefaultInputDeviceID() ? " [DEFAULT]" : ""
        log("  \(deviceID): \"\(name)\" (\(transport))\(blocked)\(isDefault)")
    }
}

// MARK: - CLI Subcommands

/// Print to stdout (not os_log) for interactive CLI responses.
func printCLI(_ message: String) {
    print(message)
}

func runPauseCommand(args: [String]) -> Never {
    var minutes: Int? = nil
    if args.count > 2 {
        if let m = Int(args[2]), m > 0 {
            minutes = m
        } else {
            printCLI("Usage: mic-guard pause [minutes]")
            exit(1)
        }
    }

    writePause(minutes: minutes)

    if let m = minutes {
        printCLI("mic-guard paused for \(m) minute\(m == 1 ? "" : "s"). Bluetooth mic input is allowed.")
        printCLI("Will auto-resume at \(autoResumeTimeString(minutes: m)).")
    } else {
        printCLI("mic-guard paused. Bluetooth mic input is allowed.")
        printCLI("Run 'mic-guard resume' to re-enable enforcement.")
    }
    exit(0)
}

func runResumeCommand() -> Never {
    clearPause()

    // Poke the running daemon to re-check immediately by sending SIGUSR1.
    // Get the daemon PID from launchctl (most reliable source).
    if let pid = getDaemonPID() {
        kill(pid, SIGUSR1)
    }

    printCLI("mic-guard resumed. Bluetooth mic input is blocked.")
    exit(0)
}

/// Get the PID of the running mic-guard daemon from launchctl.
func getDaemonPID() -> pid_t? {
    let label = "com.local.mic-guard"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["list", label]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch { return nil }
    guard task.terminationStatus == 0 else { return nil }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // launchctl list output contains: "PID" = 12345;
    if let range = output.range(of: "\"PID\" = "),
       let endRange = output[range.upperBound...].range(of: ";") {
        let pidStr = output[range.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(pidStr)
    }
    return nil
}

func runStatusCommand() -> Never {
    // Daemon running?
    let label = "com.local.mic-guard"
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["list", label]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    let running: Bool
    do {
        try task.run()
        task.waitUntilExit()
        running = task.terminationStatus == 0
    } catch {
        running = false
    }

    printCLI("Daemon:  \(running ? "running" : "not running")")

    // Mode
    let mode = readMode()
    printCLI("Mode:    \(modeName(mode))")

    // Pause state
    switch readPauseState() {
    case .active:
        printCLI("Guard:   active (Bluetooth mic blocked)")
    case .pausedIndefinitely:
        printCLI("Guard:   PAUSED (Bluetooth mic allowed)")
    case .pausedUntil(let date):
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        printCLI("Guard:   PAUSED until \(fmt.string(from: date))")
    }

    // Current input
    if let current = getDefaultInputDeviceID(),
       let name = getDeviceName(current),
       let transport = getTransportType(current) {
        printCLI("Input:   \"\(name)\" (\(transportName(transport)))")
    }

    // All devices
    printCLI("")
    printCLI("Input devices:")
    for deviceID in getAllInputDevices() {
        let name = getDeviceName(deviceID) ?? "?"
        let transport = getTransportType(deviceID).map { transportName($0) } ?? "?"
        let blocked = getTransportType(deviceID).map { shouldBlockAsInput($0) ? " [blocked]" : "" } ?? ""
        let isDefault = deviceID == getDefaultInputDeviceID() ? " *" : ""
        printCLI("  \(name) (\(transport))\(blocked)\(isDefault)")
    }

    exit(0)
}

func autoResumeTimeString(minutes: Int) -> String {
    let date = Date().addingTimeInterval(Double(minutes) * 60)
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    return fmt.string(from: date)
}

func printUsage() -> Never {
    printCLI("""
    mic-guard — keep your Mac's built-in mic as the default input

    Usage:
      mic-guard              Run as daemon (used by launchd)
      mic-guard pause        Pause enforcement — allow Bluetooth mic
      mic-guard pause <min>  Pause for N minutes, then auto-resume
      mic-guard resume       Resume enforcement — block Bluetooth mic
      mic-guard status       Show current state, mode, and audio devices
      mic-guard help         Show this help

    Modes (set during install):
      strict                 Always block Bluetooth mic input
      smart                  Auto-pause 1 hour if you switch back within 10s
    """)
    exit(0)
}

// MARK: - Main

let args = CommandLine.arguments

if args.count > 1 {
    switch args[1] {
    case "pause":   runPauseCommand(args: args)
    case "resume":  runResumeCommand()
    case "status":  runStatusCommand()
    case "help", "--help", "-h": printUsage()
    default:
        printCLI("Unknown command: \(args[1])")
        printUsage()
    }
}

// No subcommand → run as daemon
setupSignalHandlers()
printDiagnostics()
registerListeners()

log("Listening for audio device changes...")

enforceBuiltInInput()

// dispatchMain() parks the main thread on the GCD main queue.
// The process is fully idle between CoreAudio events (zero CPU).
dispatchMain()
