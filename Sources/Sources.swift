import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps

/// Jalanin helper Now Playing lewat /usr/bin/perl dan terusin hasilnya ke model.
final class MediaBridge {
    private let model: IslandModel
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopped = false
    private var loaded = false

    init(model: IslandModel) {
        self.model = model
        model.send = { [weak self] in self?.write($0) }
    }

    func start() {
        guard let res = Bundle.main.resourceURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res.appendingPathComponent("run.pl").path, res.appendingPathComponent("media.dylib").path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if self?.stopped == false { self?.start() }
            }
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.consume(d) }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("Nusa: helper gagal jalan: \(error)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }

    private func write(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            apply(o)
        }
    }

    private func apply(_ o: [String: Any]) {
        var m = Media()
        m.title = o["title"] as? String ?? ""
        m.artist = o["artist"] as? String ?? ""
        m.album = o["album"] as? String ?? ""
        m.source = o["bundle"] as? String
        m.duration = o["duration"] as? Double ?? 0
        m.elapsed = o["elapsed"] as? Double ?? 0
        m.timestamp = o["timestamp"] as? Double ?? Date().timeIntervalSince1970
        m.rate = o["rate"] as? Double ?? 0
        m.playing = o["playing"] as? Bool ?? false
        m.artId = o["artId"] as? String
        let image = (o["art"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) }
        DispatchQueue.main.async { [self, model] in
            if let image {
                model.setArt(image)
            } else if m.artId == nil, m.title != model.media.title {
                model.setArt(nil)
            }
            let newTrack = self.loaded && m.playing && !m.title.isEmpty && m.title != model.media.title
            self.loaded = true
            model.media = m
            guard newTrack else { return }
            // Cover datang sesaat setelah judul, jadi tunggu sebentar biar pop-up nggak kosong
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard model.media.title == m.title, !model.expanded, !model.slim, model.focus?.phase != .focus else { return }
                model.show(.track, for: 2.6)
            }
        }
    }
}

/// Status baterai: colok/cabut charger dan peringatan baterai lemah.
final class BatteryWatcher {
    private let model: IslandModel
    private var warned = false
    private var known = false

    init(model: IslandModel) { self.model = model }

    func start() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<BatteryWatcher>.fromOpaque(ctx!).takeUnretainedValue().update()
        }, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        update()
    }

    private func update() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let d = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any] else { return }
        let percent = d[kIOPSCurrentCapacityKey] as? Int ?? 100
        let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let changed = plugged != model.charging
        model.batteryPercent = percent
        model.charging = plugged
        let toFull = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
        model.minutesToFull = toFull > 0 ? toFull : nil
        if known, changed { model.show(.charging(percent: percent, on: plugged), for: plugged ? 3.5 : 2.4) }
        known = true
        if plugged || percent > 20 {
            warned = false
        } else if !warned {
            warned = true
            model.show(.lowBattery(percent: percent), for: 4)
        }
    }
}

/// Volume output sistem, termasuk kalau pindah perangkat (mis. ke AirPods).
final class VolumeWatcher {
    private let model: IslandModel
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: (Double, Bool)?
    private let queue = DispatchQueue.main
    private lazy var changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.read(announce: true) }
    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }

    init(model: IslandModel) {
        self.model = model
        model.setVolume = { [weak self] in self?.write($0) }
    }

    private func write(_ level: Double) {
        var value = Float32(level)
        var v = Self.volume
        AudioObjectSetPropertyData(device, &v, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static let volume = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    private static let mute = address(kAudioDevicePropertyMute)

    func start() {
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, deviceChanged)
        attach()
    }

    private func attach() {
        var v = Self.volume, m = Self.mute
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &v, queue, changed)
            AudioObjectRemovePropertyListenerBlock(device, &m, queue, changed)
        }
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device)
        AudioObjectAddPropertyListenerBlock(device, &v, queue, changed)
        AudioObjectAddPropertyListenerBlock(device, &m, queue, changed)
        read(announce: false)
        announceDevice()
    }

    private var lastDevice: AudioObjectID?

    /// Output pindah ke headphone Bluetooth (AirPods dll.): munculin nama + baterainya.
    private func announceDevice() {
        defer { lastDevice = device }
        guard let lastDevice, lastDevice != device, BluetoothInfo.isBluetooth(device),
              let name = BluetoothInfo.deviceName(device) else { return }
        let model = self.model
        BluetoothInfo.fetchBattery(name: name) { battery in
            model.show(.device(name: name, symbol: BluetoothInfo.symbol(for: name), detail: battery ?? "Connected"), for: 4)
        }
    }

    private func read(announce: Bool) {
        var level = Float32(0), muted = UInt32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var v = Self.volume, m = Self.mute
        guard AudioObjectGetPropertyData(device, &v, 0, nil, &size, &level) == noErr else { return }
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &m, 0, nil, &size, &muted)
        let now = (Double(level), muted != 0)
        model.volume = now.0
        defer { last = now }
        guard announce, let last, last != now, !model.expanded else { return }
        model.show(.volume(level: now.0, muted: now.1), for: 1.6)
    }
}
