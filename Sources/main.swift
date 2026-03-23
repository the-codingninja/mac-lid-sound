import Cocoa
import IOKit
import IOKit.hid
import AVFoundation
import ServiceManagement

// MARK: - Lid Angle Sensor

class LidAngleSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else { return nil }

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x0020,
            kIOHIDPrimaryUsageKey: 0x008A
        ]

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let dev = deviceSet.first else {
            log("ERROR: Lid angle sensor not found")
            return nil
        }
        device = dev
    }

    func readAngle() -> Int? {
        guard let device = device else { return nil }
        var report = [UInt8](repeating: 0, count: 64)
        var reportLength = report.count
        report[0] = 1
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &reportLength)
        guard result == kIOReturnSuccess else { return nil }
        return Int(report[1])
    }
}

// MARK: - Audio Engine

class CreakPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var closeBuffers: [AVAudioPCMBuffer] = []
    private var openBuffers: [AVAudioPCMBuffer] = []
    private var isPlaying = false

    init?(soundsDir: String) {
        // Load sound files
        closeBuffers = loadBuffers(dir: soundsDir, prefix: "close_")
        openBuffers = loadBuffers(dir: soundsDir, prefix: "open_")

        guard !closeBuffers.isEmpty, !openBuffers.isEmpty else {
            log("ERROR: No sound files found in \(soundsDir)")
            return nil
        }

        // Setup audio engine
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: closeBuffers[0].format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: closeBuffers[0].format)

        do {
            try engine.start()
            log("Audio engine started")
        } catch {
            log("ERROR: Failed to start audio engine: \(error)")
            return nil
        }
    }

    private func loadBuffers(dir: String, prefix: String) -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return buffers }

        for file in files.sorted() where file.hasPrefix(prefix) && file.hasSuffix(".wav") {
            let path = (dir as NSString).appendingPathComponent(file)
            let absPath = (path as NSString).standardizingPath
            let url = URL(fileURLWithPath: absPath)
            guard
                  let audioFile = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: audioFile.processingFormat,
                      frameCapacity: AVAudioFrameCount(audioFile.length)
                  ) else {
                log("Warning: Could not load \(file)")
                continue
            }
            do {
                try audioFile.read(into: buffer)
                buffers.append(buffer)
                log("Loaded \(file)")
            } catch {
                log("Warning: Could not read \(file): \(error)")
            }
        }
        return buffers
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        log("Audio engine died, restarting...")
        do {
            try engine.start()
            log("Audio engine restarted")
        } catch {
            log("ERROR: Failed to restart audio engine: \(error)")
        }
    }

    func play(direction: Direction, velocity: Double) {
        ensureEngineRunning()
        let buffers = direction == .closing ? closeBuffers : openBuffers
        let buffer = buffers[Int.random(in: 0..<buffers.count)]

        // Map velocity to playback rate:
        //   slow movement (8°/s)  -> 0.7x (slow, drawn-out creak)
        //   medium (30°/s)        -> 1.0x (normal)
        //   fast (80°/s)          -> 1.8x (quick, snappy creak)
        let rate = max(0.5, min(1.8, Float(velocity) / 35.0 + 0.3))
        timePitch.rate = rate

        // Random pitch variation: +/- 300 cents (3 semitones) for organic feel
        timePitch.pitch = Float.random(in: -300...300)

        if isPlaying {
            playerNode.stop()
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
            }
        })
        playerNode.play()
        isPlaying = true
    }

    func fadeOut(duration: TimeInterval = 0.3) {
        guard isPlaying else { return }
        // Ramp volume down then stop
        let steps = 10
        let interval = duration / Double(steps)
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) { [weak self] in
                guard let self = self else { return }
                let vol = Float(steps - i) / Float(steps)
                self.playerNode.volume = vol
                if i == steps {
                    self.playerNode.stop()
                    self.playerNode.volume = 1.0
                    self.isPlaying = false
                }
            }
        }
    }

    func stop() {
        if isPlaying {
            playerNode.stop()
            playerNode.volume = 1.0
            isPlaying = false
        }
    }

    var playing: Bool { isPlaying }
}

// MARK: - Direction

enum Direction {
    case closing
    case opening
}

// MARK: - Logging

let logFile: FileHandle? = {
    let path = NSHomeDirectory() + "/.hinge_sound.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    return FileHandle(forWritingAtPath: path)
}()

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) [daemon] \(message)\n"
    if let data = line.data(using: .utf8) {
        logFile?.seekToEndOfFile()
        logFile?.write(data)
    }
    fputs(line, stderr)
}

// MARK: - Mute Check

func isMuted() -> Bool {
    FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.hinge_mute")
}

// MARK: - Main Daemon

class HingeDaemon {
    let sensor: LidAngleSensor
    let player: CreakPlayer

    // State
    var lastAngle: Int = -1
    var restAngle: Int = -1                       // angle when lid was last at rest
    var angleHistory: [(time: Date, angle: Int)] = []
    var lastCreakTime: Date = .distantPast
    var lastMovementTime: Date = .distantPast     // when we last saw real movement
    var movementStartAngle: Int = -1
    var isMoving = false
    var stableCount: Int = 0                      // consecutive polls with no significant change
    var fadeOutScheduled = false                   // whether we've scheduled a fade-out
    private var timer: DispatchSourceTimer?

    // Observable state for menu bar
    var currentAngle: Int = -1
    var onAngleUpdate: ((Int) -> Void)?

    // Tuning
    let pollInterval: TimeInterval = 1.0 / 30.0  // 30 Hz
    let velocityThreshold: Double = 8.0           // deg/s to trigger sound
    let stopThreshold: Double = 3.0               // deg/s to stop sound
    let minCreakInterval: TimeInterval = 0.15     // min time between creak triggers
    let historyWindow: TimeInterval = 0.3         // seconds of angle history for velocity calc
    let deadZone: Int = 3                         // minimum deg change from rest to trigger
    let stableFrames: Int = 10                    // polls with <deadZone change = at rest

    init(sensor: LidAngleSensor, player: CreakPlayer) {
        self.sensor = sensor
        self.player = player
    }

    func start() {
        log("Daemon started, polling at \(Int(1.0/pollInterval)) Hz")

        // Initial reading
        if let angle = sensor.readAngle() {
            lastAngle = angle
            restAngle = angle
            currentAngle = angle
            log("Initial angle: \(angle)")
        }

        // Poll timer on main run loop
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        // Mute check (infrequent — every ~1s worth of polls)
        if Int.random(in: 0..<30) == 0 && isMuted() { return }

        guard let angle = sensor.readAngle() else { return }
        let now = Date()

        // Update observable angle (throttled to ~2Hz for menu bar)
        if currentAngle != angle {
            currentAngle = angle
            if Int.random(in: 0..<15) == 0 {
                onAngleUpdate?(angle)
            }
        }

        // Record history
        angleHistory.append((time: now, angle: angle))
        // Trim old entries
        angleHistory.removeAll { now.timeIntervalSince($0.time) > historyWindow * 2 }

        // Calculate velocity from history
        let velocity = calculateVelocity(now: now)
        let absVelocity = abs(velocity)

        // Track stability — if angle stays within deadZone for enough frames, update rest position
        if abs(angle - restAngle) <= deadZone / 2 {
            stableCount += 1
            if stableCount >= stableFrames && restAngle != angle {
                restAngle = angle
            }
        } else {
            stableCount = 0
        }

        // Dead zone: only consider movement if we've moved enough from rest position
        let distFromRest = abs(angle - restAngle)

        if absVelocity > velocityThreshold && distFromRest >= deadZone && !isMoving {
            // Real movement started (not jitter)
            isMoving = true
            movementStartAngle = restAngle
            log("Movement started at \(angle) (rest=\(restAngle)) velocity=\(String(format: "%.1f", velocity))/s")
        }

        if isMoving {
            if absVelocity > velocityThreshold && distFromRest >= deadZone {
                // Still moving — trigger creak if enough time has passed
                lastMovementTime = now
                fadeOutScheduled = false
                let timeSinceLastCreak = now.timeIntervalSince(lastCreakTime)

                if timeSinceLastCreak > minCreakInterval && !player.playing {
                    let direction: Direction = velocity < 0 ? .closing : .opening
                    player.play(direction: direction, velocity: absVelocity)
                    lastCreakTime = now
                    log("Playing \(direction == .closing ? "close" : "open") creak at \(angle) vel=\(String(format: "%.1f", absVelocity))/s")
                }
            } else if absVelocity < stopThreshold || distFromRest < deadZone {
                // Movement stopped
                isMoving = false
                restAngle = angle
                stableCount = stableFrames
                log("Movement stopped at \(angle)")
            }
        }

        // Fade out sound immediately when movement stops
        if !isMoving && player.playing && !fadeOutScheduled {
            player.fadeOut(duration: 0.3)
            fadeOutScheduled = true
            log("Fading out sound")
        }

        lastAngle = angle
    }

    private func calculateVelocity(now: Date) -> Double {
        // Use history window to smooth velocity
        let cutoff = now.addingTimeInterval(-historyWindow)
        let recent = angleHistory.filter { $0.time >= cutoff }
        guard recent.count >= 2,
              let first = recent.first,
              let last = recent.last else { return 0 }

        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0.01 else { return 0 }

        return Double(last.angle - first.angle) / dt
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var daemon: HingeDaemon?
    var muteItem: NSMenuItem!
    var angleItem: NSMenuItem!
    var launchAtLoginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        startDaemon()
    }

    // MARK: Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeIcon(muted: isMuted())
        }

        let menu = NSMenu()

        angleItem = NSMenuItem(title: "Lid angle: --", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        menu.addItem(angleItem)

        menu.addItem(NSMenuItem.separator())

        let muted = isMuted()
        muteItem = NSMenuItem(title: muted ? "Unmute" : "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(NSMenuItem.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        if #available(macOS 13.0, *) {
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Door Hinge", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: Icon

    private func makeIcon(muted: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // Door rectangle
            let doorRect = NSRect(x: 6, y: 1, width: 10, height: 16)
            let door = NSBezierPath(roundedRect: doorRect, xRadius: 1, yRadius: 1)
            door.lineWidth = 1.5
            NSColor.black.setStroke()
            door.stroke()

            // Hinge pins
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 11, width: 3.5, height: 3.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3.5, width: 3.5, height: 3.5)).fill()

            if muted {
                // Diagonal slash
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2, y: 2))
                slash.line(to: NSPoint(x: 16, y: 16))
                slash.lineWidth = 2
                NSColor.black.setStroke()
                slash.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: Daemon Lifecycle

    private func startDaemon() {
        let soundsDir = resolveSoundsDir()

        guard let sensor = LidAngleSensor() else {
            log("FATAL: Could not initialize lid angle sensor")
            angleItem.title = "Sensor not found"
            showSensorNotFoundAlert()
            return
        }

        guard let player = CreakPlayer(soundsDir: soundsDir) else {
            log("FATAL: Could not initialize audio player")
            angleItem.title = "Audio error"
            return
        }

        daemon = HingeDaemon(sensor: sensor, player: player)
        daemon?.onAngleUpdate = { [weak self] angle in
            self?.angleItem.title = "Lid angle: \(angle)\u{00B0}"
        }
        daemon?.start()

        if let angle = daemon?.currentAngle, angle >= 0 {
            angleItem.title = "Lid angle: \(angle)\u{00B0}"
        }
    }

    private func resolveSoundsDir() -> String {
        // Prefer sounds bundled inside the .app
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("sounds")
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        // Fallback: next to the executable
        let execDir = (Bundle.main.executablePath! as NSString).deletingLastPathComponent
        let candidates = [
            (execDir as NSString).appendingPathComponent("../Resources/sounds"),
            (execDir as NSString).appendingPathComponent("sounds"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    private func showSensorNotFoundAlert() {
        let alert = NSAlert()
        alert.messageText = "Lid Angle Sensor Not Found"
        alert.informativeText = "Door Hinge requires a compatible MacBook lid sensor.\n\nSupported:\n  \u{2022} M4 MacBooks (all models)\n  \u{2022} MacBook Pro 16\" 2019 (Intel)\n\nNot supported:\n  \u{2022} M1/M2/M3 MacBooks\n  \u{2022} External displays / desktops"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Running")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    // MARK: Actions

    @objc private func toggleMute() {
        let mutePath = NSHomeDirectory() + "/.hinge_mute"
        let wasMuted = FileManager.default.fileExists(atPath: mutePath)
        if wasMuted {
            try? FileManager.default.removeItem(atPath: mutePath)
        } else {
            FileManager.default.createFile(atPath: mutePath, contents: nil)
        }
        let nowMuted = !wasMuted
        muteItem.title = nowMuted ? "Unmute" : "Mute"
        statusItem.button?.image = makeIcon(muted: nowMuted)
        log(nowMuted ? "Muted via menu bar" : "Unmuted via menu bar")
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                    launchAtLoginItem.state = .off
                    log("Disabled launch at login")
                } else {
                    try service.register()
                    launchAtLoginItem.state = .on
                    log("Enabled launch at login")
                }
            } catch {
                log("Failed to toggle launch at login: \(error)")
            }
        }
    }

    @objc private func quitApp() {
        log("Quit from menu bar")
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")

if isAppBundle {
    // ---- Menu bar app mode ----
    log("Starting Door Hinge app...")

    signal(SIGTERM) { _ in log("Received SIGTERM, shutting down"); exit(0) }
    signal(SIGINT) { _ in log("Received SIGINT, shutting down"); exit(0) }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
} else {
    // ---- CLI daemon mode (backward compatible with LaunchAgent) ----
    let execPath = CommandLine.arguments[0]
    let execDir = (execPath as NSString).deletingLastPathComponent
    let soundsDir: String

    if CommandLine.arguments.count > 1 {
        soundsDir = CommandLine.arguments[1]
    } else {
        let candidates = [
            (execDir as NSString).appendingPathComponent("../sounds"),
            (execDir as NSString).appendingPathComponent("sounds"),
            NSHomeDirectory() + "/personal/mac-door-hinge-sound/sounds"
        ]
        soundsDir = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    log("Starting hinge daemon...")
    log("Sounds directory: \(soundsDir)")

    signal(SIGTERM) { _ in log("Received SIGTERM, shutting down"); exit(0) }
    signal(SIGINT) { _ in log("Received SIGINT, shutting down"); exit(0) }

    guard let sensor = LidAngleSensor() else {
        log("FATAL: Could not initialize lid angle sensor")
        exit(1)
    }

    guard let player = CreakPlayer(soundsDir: soundsDir) else {
        log("FATAL: Could not initialize audio player")
        exit(1)
    }

    let daemon = HingeDaemon(sensor: sensor, player: player)
    daemon.start()
    dispatchMain()
}
