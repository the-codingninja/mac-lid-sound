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
    private var baseSoundsDir: String

    init?(soundsDir: String, pack: String = "hinge") {
        baseSoundsDir = soundsDir

        // Load from pack subdirectory
        let packDir = (soundsDir as NSString).appendingPathComponent(pack)
        closeBuffers = CreakPlayer.loadBuffers(dir: packDir, prefix: "close_")
        openBuffers = CreakPlayer.loadBuffers(dir: packDir, prefix: "open_")

        guard !closeBuffers.isEmpty, !openBuffers.isEmpty else {
            log("ERROR: No sound files found in \(packDir)")
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

    func loadSoundPack(name: String) -> Bool {
        let packDir = (baseSoundsDir as NSString).appendingPathComponent(name)
        let newClose = CreakPlayer.loadBuffers(dir: packDir, prefix: "close_")
        let newOpen = CreakPlayer.loadBuffers(dir: packDir, prefix: "open_")
        guard !newClose.isEmpty, !newOpen.isEmpty else {
            log("ERROR: Could not load sound pack '\(name)'")
            return false
        }

        playerNode.stop()
        isPlaying = false

        // Reconnect if audio format changed
        let newFormat = newClose[0].format
        if closeBuffers.isEmpty || newFormat != closeBuffers[0].format {
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(playerNode, to: timePitch, format: newFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: newFormat)
        }

        closeBuffers = newClose
        openBuffers = newOpen
        log("Switched to sound pack: \(name)")
        return true
    }

    static func availablePacks(in dir: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = (dir as NSString).appendingPathComponent(entry)
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    static func displayName(for pack: String) -> String {
        switch pack {
        case "hinge": return "Door Hinge"
        case "garage": return "Garage Door"
        default: return pack.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func loadBuffers(dir: String, prefix: String) -> [AVAudioPCMBuffer] {
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

        let rate = max(0.5, min(1.8, Float(velocity) / 35.0 + 0.3))
        timePitch.rate = rate
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
    var restAngle: Int = -1
    var angleHistory: [(time: Date, angle: Int)] = []
    var lastCreakTime: Date = .distantPast
    var lastMovementTime: Date = .distantPast
    var movementStartAngle: Int = -1
    var isMoving = false
    var stableCount: Int = 0
    var fadeOutScheduled = false
    private var timer: DispatchSourceTimer?

    // Observable state for menu bar
    var currentAngle: Int = -1
    var onAngleUpdate: ((Int) -> Void)?

    // Tuning
    let pollInterval: TimeInterval = 1.0 / 30.0
    let velocityThreshold: Double = 8.0
    let stopThreshold: Double = 3.0
    let minCreakInterval: TimeInterval = 0.15
    let historyWindow: TimeInterval = 0.3
    let deadZone: Int = 3
    let stableFrames: Int = 10

    init(sensor: LidAngleSensor, player: CreakPlayer) {
        self.sensor = sensor
        self.player = player
    }

    func start() {
        log("Daemon started, polling at \(Int(1.0/pollInterval)) Hz")

        if let angle = sensor.readAngle() {
            lastAngle = angle
            restAngle = angle
            currentAngle = angle
            log("Initial angle: \(angle)")
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        if Int.random(in: 0..<30) == 0 && isMuted() { return }

        guard let angle = sensor.readAngle() else { return }
        let now = Date()

        // Update observable angle on every change
        if currentAngle != angle {
            currentAngle = angle
            onAngleUpdate?(angle)
        }

        angleHistory.append((time: now, angle: angle))
        angleHistory.removeAll { now.timeIntervalSince($0.time) > historyWindow * 2 }

        let velocity = calculateVelocity(now: now)
        let absVelocity = abs(velocity)

        if abs(angle - restAngle) <= deadZone / 2 {
            stableCount += 1
            if stableCount >= stableFrames && restAngle != angle {
                restAngle = angle
            }
        } else {
            stableCount = 0
        }

        let distFromRest = abs(angle - restAngle)

        if absVelocity > velocityThreshold && distFromRest >= deadZone && !isMoving {
            isMoving = true
            movementStartAngle = restAngle
            log("Movement started at \(angle) (rest=\(restAngle)) velocity=\(String(format: "%.1f", velocity))/s")
        }

        if isMoving {
            if absVelocity > velocityThreshold && distFromRest >= deadZone {
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
                isMoving = false
                restAngle = angle
                stableCount = stableFrames
                log("Movement stopped at \(angle)")
            }
        }

        if !isMoving && player.playing && !fadeOutScheduled {
            player.fadeOut(duration: 0.3)
            fadeOutScheduled = true
            log("Fading out sound")
        }

        lastAngle = angle
    }

    private func calculateVelocity(now: Date) -> Double {
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

// MARK: - Auto-Update

class UpdateChecker {
    private let repo = "the-codingninja/mac-lid-sound"
    private(set) var latestVersion: String?
    private var downloadURL: String?
    var onUpdateAvailable: ((String) -> Void)?

    func check() {
        // GET releases/latest — URLSession follows the redirect automatically,
        // so response.url contains the final URL with the tag
        let urlString = "https://github.com/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] _, response, error in
            guard let self = self else { return }

            if let error = error {
                log("Update check failed: \(error.localizedDescription)")
                return
            }

            // Final URL after redirect: .../releases/tag/v1.3.2
            guard let finalURL = response?.url?.absoluteString,
                  let tag = finalURL.split(separator: "/").last else {
                log("Update check: could not determine latest tag")
                return
            }

            let tagStr = String(tag)
            let remote = tagStr.hasPrefix("v") ? String(tagStr.dropFirst()) : tagStr
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            log("Update check: local=v\(current) remote=v\(remote)")

            guard self.isNewer(remote, than: current) else {
                log("Up to date (v\(current))")
                return
            }

            let dmgURL = "https://github.com/\(self.repo)/releases/download/\(tagStr)/Door-Hinge.dmg"

            DispatchQueue.main.async {
                self.latestVersion = remote
                self.downloadURL = dmgURL
                self.onUpdateAvailable?(remote)
                log("Update available: v\(remote)")
            }
        }.resume()
    }

    private func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    func performUpdate(onStatus: @escaping (String) -> Void) {
        guard let urlString = downloadURL, let url = URL(string: urlString) else {
            log("Update failed: no download URL")
            return
        }

        onStatus("Downloading v\(latestVersion ?? "")...")
        log("Downloading update from \(urlString)")

        URLSession.shared.downloadTask(with: url) { localURL, _, error in
            guard let localURL = localURL else {
                log("Update download failed: \(error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async { onStatus("Download failed") }
                return
            }

            // Copy to stable path before the temp file is cleaned up
            let dmgPath = "/tmp/Door-Hinge-update.dmg"
            do {
                try? FileManager.default.removeItem(atPath: dmgPath)
                try FileManager.default.copyItem(atPath: localURL.path, toPath: dmgPath)
                log("Downloaded update to \(dmgPath)")
            } catch {
                log("Failed to save DMG: \(error)")
                DispatchQueue.main.async { onStatus("Download failed") }
                return
            }

            DispatchQueue.main.async {
                self.installUpdate(dmgPath: dmgPath, onStatus: onStatus)
            }
        }.resume()
    }

    private func installUpdate(dmgPath: String, onStatus: (String) -> Void) {
        onStatus("Installing...")
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = Bundle.main.bundlePath
        let logPath = NSHomeDirectory() + "/.hinge_sound.log"

        let script = [
            "#!/bin/bash",
            "LOG='\(logPath)'",
            "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) [updater] Waiting for app to exit (pid \(pid))\" >> \"$LOG\"",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done",
            "",
            "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) [updater] Mounting DMG\" >> \"$LOG\"",
            "hdiutil attach '\(dmgPath)' -quiet -nobrowse -mountpoint /tmp/dh-update-mount",
            "if [ ! -d '/tmp/dh-update-mount/Door Hinge.app' ]; then",
            "  echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) [updater] ERROR: Mount failed or app not found\" >> \"$LOG\"",
            "  hdiutil detach /tmp/dh-update-mount -quiet 2>/dev/null",
            "  rm -f '\(dmgPath)'",
            "  exit 1",
            "fi",
            "",
            "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) [updater] Replacing app at \(appPath)\" >> \"$LOG\"",
            "rm -rf '\(appPath)'",
            "cp -R '/tmp/dh-update-mount/Door Hinge.app' '\(appPath)'",
            "xattr -cr '\(appPath)'",
            "",
            "hdiutil detach /tmp/dh-update-mount -quiet",
            "rm -f '\(dmgPath)' /tmp/door-hinge-updater.sh",
            "",
            "echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) [updater] Launching updated app\" >> \"$LOG\"",
            "open '\(appPath)'",
        ].joined(separator: "\n")

        let scriptPath = "/tmp/door-hinge-updater.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            log("Failed to write updater script: \(error)")
            onStatus("Update failed")
            return
        }

        // Launch with nohup so it survives our termination
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup /bin/bash '\(scriptPath)' &>/dev/null &"]
        do {
            try process.run()
            log("Update script launched, terminating for update...")
            NSApp.terminate(nil)
        } catch {
            log("Failed to launch updater: \(error)")
            onStatus("Update failed")
        }
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var daemon: HingeDaemon?
    var muteItem: NSMenuItem!
    var angleItem: NSMenuItem!
    var updateItem: NSMenuItem!
    var launchAtLoginItem: NSMenuItem!
    var soundPackMenu: NSMenu!
    var baseSoundsDir: String = ""
    var currentPack: String = "hinge"
    let updateChecker = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        currentPack = UserDefaults.standard.string(forKey: "soundPack") ?? "hinge"
        setupMenuBar()
        startDaemon()

        // Check for updates on launch and every 24 hours
        updateChecker.onUpdateAvailable = { [weak self] version in
            self?.updateItem.title = "Update to v\(version)"
            self?.updateItem.isHidden = false
        }
        updateChecker.check()
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.updateChecker.check()
        }
    }

    // MARK: Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeIcon(muted: isMuted())
        }

        let menu = NSMenu()
        menu.delegate = self

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "Door Hinge v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        angleItem = NSMenuItem(title: "Lid angle: --", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        menu.addItem(angleItem)

        menu.addItem(NSMenuItem.separator())

        // Sound pack submenu
        let soundItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        soundPackMenu = NSMenu()
        soundItem.submenu = soundPackMenu
        menu.addItem(soundItem)

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

        updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdate), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Door Hinge", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refreshSoundPackMenu() {
        soundPackMenu.removeAllItems()
        let packs = CreakPlayer.availablePacks(in: baseSoundsDir)
        for pack in packs {
            let item = NSMenuItem(
                title: CreakPlayer.displayName(for: pack),
                action: #selector(selectSoundPack(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pack
            item.state = (pack == currentPack) ? .on : .off
            soundPackMenu.addItem(item)
        }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh angle display when menu opens
        if let angle = daemon?.currentAngle, angle >= 0 {
            angleItem.title = "Lid angle: \(angle)\u{00B0}"
        }
        // Refresh mute state
        let muted = isMuted()
        muteItem.title = muted ? "Unmute" : "Mute"
        statusItem.button?.image = makeIcon(muted: muted)
        // Refresh sound pack checkmarks
        refreshSoundPackMenu()
    }

    // MARK: Icon

    private func makeIcon(muted: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let doorRect = NSRect(x: 6, y: 1, width: 10, height: 16)
            let door = NSBezierPath(roundedRect: doorRect, xRadius: 1, yRadius: 1)
            door.lineWidth = 1.5
            NSColor.black.setStroke()
            door.stroke()

            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 11, width: 3.5, height: 3.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3.5, width: 3.5, height: 3.5)).fill()

            if muted {
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
        baseSoundsDir = resolveSoundsDir()

        guard let sensor = LidAngleSensor() else {
            log("FATAL: Could not initialize lid angle sensor")
            angleItem.title = "Sensor not found"
            showSensorNotFoundAlert()
            return
        }

        guard let player = CreakPlayer(soundsDir: baseSoundsDir, pack: currentPack) else {
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

        refreshSoundPackMenu()
    }

    private func resolveSoundsDir() -> String {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("sounds")
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
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

    @objc private func selectSoundPack(_ sender: NSMenuItem) {
        guard let pack = sender.representedObject as? String else { return }
        guard pack != currentPack else { return }

        if daemon?.player.loadSoundPack(name: pack) == true {
            currentPack = pack
            UserDefaults.standard.set(pack, forKey: "soundPack")
            log("Sound pack changed to: \(CreakPlayer.displayName(for: pack))")
        }
    }

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

    @objc private func checkForUpdate() {
        if updateChecker.latestVersion != nil {
            // Update available — install it
            updateChecker.performUpdate { [weak self] status in
                self?.updateItem.title = status
            }
        } else {
            // No update known yet — trigger a check
            updateItem.title = "Checking..."
            updateChecker.onUpdateAvailable = { [weak self] version in
                self?.updateItem.title = "Update to v\(version)"
            }
            updateChecker.check()
            // Reset title after timeout if no update found
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.updateChecker.latestVersion == nil {
                    self?.updateItem.title = "Up to date"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        if self?.updateChecker.latestVersion == nil {
                            self?.updateItem.title = "Check for Updates..."
                        }
                    }
                }
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

    let pack = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "hinge"

    log("Starting hinge daemon...")
    log("Sounds directory: \(soundsDir), pack: \(pack)")

    signal(SIGTERM) { _ in log("Received SIGTERM, shutting down"); exit(0) }
    signal(SIGINT) { _ in log("Received SIGINT, shutting down"); exit(0) }

    guard let sensor = LidAngleSensor() else {
        log("FATAL: Could not initialize lid angle sensor")
        exit(1)
    }

    guard let player = CreakPlayer(soundsDir: soundsDir, pack: pack) else {
        log("FATAL: Could not initialize audio player")
        exit(1)
    }

    let daemon = HingeDaemon(sensor: sensor, player: player)
    daemon.start()
    dispatchMain()
}
