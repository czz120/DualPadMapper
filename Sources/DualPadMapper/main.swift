import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

private struct PlayerLayout {
    let up: CGKeyCode
    let down: CGKeyCode
    let left: CGKeyCode
    let right: CGKeyCode
    let chop: CGKeyCode
    let pickup: CGKeyCode
    let dash: CGKeyCode
    let emote: CGKeyCode
    let switchChef: CGKeyCode
}

private enum KeyCodes {
    static let a: CGKeyCode = 0
    static let s: CGKeyCode = 1
    static let d: CGKeyCode = 2
    static let x: CGKeyCode = 7
    static let c: CGKeyCode = 8
    static let b: CGKeyCode = 11
    static let w: CGKeyCode = 13
    static let z: CGKeyCode = 6
    static let e: CGKeyCode = 14
    static let t: CGKeyCode = 17
    static let u: CGKeyCode = 32
    static let i: CGKeyCode = 34
    static let p: CGKeyCode = 35
    static let n: CGKeyCode = 45
    static let m: CGKeyCode = 46
    static let o: CGKeyCode = 31
    static let minus: CGKeyCode = 27
    static let equal: CGKeyCode = 24
    static let space: CGKeyCode = 49
    static let escape: CGKeyCode = 53
}

private let layouts = [
    PlayerLayout(up: KeyCodes.w, down: KeyCodes.s, left: KeyCodes.a, right: KeyCodes.d,
                 chop: KeyCodes.z, pickup: KeyCodes.x, dash: KeyCodes.c,
                 emote: KeyCodes.e, switchChef: KeyCodes.t),
    PlayerLayout(up: KeyCodes.u, down: KeyCodes.i, left: KeyCodes.o, right: KeyCodes.p,
                 chop: KeyCodes.b, pickup: KeyCodes.n, dash: KeyCodes.m,
                 emote: KeyCodes.minus, switchChef: KeyCodes.equal)
]

/// Posts keyboard events while reference-counting keys. This is important when
/// both controllers use a shared key such as Space or Escape: releasing one
/// controller must not release a key that the other controller is still holding.
private final class KeyboardOutput {
    private var owners: [CGKeyCode: Set<String>] = [:]
    private let lock = NSLock()
    private let postEvent: (CGKeyCode, Bool) -> Void
    private let eventLogURL = URL(fileURLWithPath: "/tmp/DualPadMapper-events.log")

    init(postEvent: @escaping (CGKeyCode, Bool) -> Void = { key, pressed in
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: pressed)?.post(tap: .cghidEventTap)
    }) {
        self.postEvent = postEvent
    }

    func set(_ key: CGKeyCode, owner: String, pressed: Bool) {
        lock.lock()
        var set = owners[key, default: []]
        let wasPressed = !set.isEmpty
        if pressed { set.insert(owner) } else { set.remove(owner) }
        let isPressed = !set.isEmpty
        owners[key] = set
        lock.unlock()

        guard wasPressed != isPressed else { return }
        postEvent(key, isPressed)
        let line = "\(Date().timeIntervalSince1970) owner=\(owner) key=\(key) \(isPressed ? "down" : "up")\n"
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: eventLogURL.path) {
                FileManager.default.createFile(atPath: eventLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: eventLogURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }

    func releaseAll(ownedBy prefix: String) {
        lock.lock()
        let keys = owners.keys.filter { key in owners[key]?.contains(where: { $0.hasPrefix(prefix) }) == true }
        lock.unlock()
        for key in keys {
            lock.lock()
            var set = owners[key, default: []]
            let wasPressed = !set.isEmpty
            set = Set(set.filter { !$0.hasPrefix(prefix) })
            owners[key] = set
            let isPressed = !set.isEmpty
            lock.unlock()
            if wasPressed && !isPressed {
                postEvent(key, false)
            }
        }
    }

    func releaseEverything() {
        lock.lock()
        let keys = owners.filter { !$0.value.isEmpty }.map(\.key)
        owners.removeAll()
        lock.unlock()
        for key in keys {
            postEvent(key, false)
        }
    }
}

private func runSelfTest() -> Bool {
    var events: [(CGKeyCode, Bool)] = []
    let output = KeyboardOutput { key, pressed in events.append((key, pressed)) }

    // Shared-key regression: P1 and P2 both hold Space. P1 releasing must not
    // emit key-up while P2 still owns the key.
    output.set(KeyCodes.space, owner: "p1.accept", pressed: true)
    output.set(KeyCodes.space, owner: "p2.accept", pressed: true)
    output.set(KeyCodes.space, owner: "p1.accept", pressed: false)
    guard events.count == 1, events[0].0 == KeyCodes.space, events[0].1 else { return false }
    output.set(KeyCodes.space, owner: "p2.accept", pressed: false)
    guard events.count == 2, events[1].0 == KeyCodes.space, !events[1].1 else { return false }

    // Independent directions: W and U must both be down concurrently and each
    // release must be emitted independently.
    events.removeAll()
    output.set(KeyCodes.w, owner: "p1.up", pressed: true)
    output.set(KeyCodes.u, owner: "p2.up", pressed: true)
    output.set(KeyCodes.w, owner: "p1.up", pressed: false)
    output.set(KeyCodes.u, owner: "p2.up", pressed: false)
    let expected: [(CGKeyCode, Bool)] = [
        (KeyCodes.w, true), (KeyCodes.u, true), (KeyCodes.w, false), (KeyCodes.u, false)
    ]
    guard events.count == expected.count else { return false }
    return zip(events, expected).allSatisfy { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
}

private final class HIDControllerBinding {
    let device: IOHIDDevice
    let player: Int
    let serial: String
    private let keyboard: KeyboardOutput
    private let layout: PlayerLayout
    private let threshold = 0.45
    private var stick = (up: false, down: false, left: false, right: false)
    private var dpad = (up: false, down: false, left: false, right: false)

    init(device: IOHIDDevice, player: Int, keyboard: KeyboardOutput) {
        self.device = device
        self.player = player
        self.keyboard = keyboard
        self.layout = layouts[player]
        self.serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? "未知序列号"
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDControllerBinding>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func owner(_ name: String) -> String { "p\(player + 1).\(name)" }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)

        if page == 0x01 {
            switch usage {
            case 0x30: updateHorizontal(element: element, raw: raw)
            case 0x31: updateVertical(element: element, raw: raw)
            case 0x39: updateHat(raw: raw)
            default: break
            }
        } else if page == 0x09 {
            updateButton(usage: Int(usage), pressed: raw != 0)
        }
    }

    private func normalized(element: IOHIDElement, raw: CFIndex) -> Double {
        let minimum = IOHIDElementGetLogicalMin(element)
        let maximum = IOHIDElementGetLogicalMax(element)
        guard maximum > minimum else { return 0 }
        return (Double(raw - minimum) / Double(maximum - minimum)) * 2.0 - 1.0
    }

    private func updateHorizontal(element: IOHIDElement, raw: CFIndex) {
        let x = normalized(element: element, raw: raw)
        stick.left = x < -threshold
        stick.right = x > threshold
        publishDirections()
    }

    private func updateVertical(element: IOHIDElement, raw: CFIndex) {
        let y = normalized(element: element, raw: raw)
        stick.up = y < -threshold
        stick.down = y > threshold
        publishDirections()
    }

    private func updateHat(raw: CFIndex) {
        // Xbox Bluetooth HID hat values: 1=N, 2=NE, 3=E, ... 8=NW;
        // neutral is reported outside that range (normally 0).
        dpad.up = [1, 2, 8].contains(raw)
        dpad.right = [2, 3, 4].contains(raw)
        dpad.down = [4, 5, 6].contains(raw)
        dpad.left = [6, 7, 8].contains(raw)
        publishDirections()
    }

    private func updateButton(usage: Int, pressed: Bool) {
        // Standard Xbox Bluetooth HID button order.
        switch usage {
        case 1: keyboard.set(KeyCodes.space, owner: owner("accept"), pressed: pressed) // A
        case 2: keyboard.set(layout.chop, owner: owner("chop"), pressed: pressed)       // B
        case 3: keyboard.set(layout.pickup, owner: owner("pickup"), pressed: pressed) // X
        case 4: keyboard.set(layout.dash, owner: owner("dash"), pressed: pressed)     // Y
        case 5: keyboard.set(layout.emote, owner: owner("emote"), pressed: pressed)   // LB
        case 6: keyboard.set(layout.switchChef, owner: owner("switch"), pressed: pressed) // RB
        case 8: keyboard.set(KeyCodes.escape, owner: owner("menu"), pressed: pressed) // Menu
        default: break
        }
    }

    private func publishDirections() {
        keyboard.set(layout.up, owner: owner("up"), pressed: stick.up || dpad.up)
        keyboard.set(layout.down, owner: owner("down"), pressed: stick.down || dpad.down)
        keyboard.set(layout.left, owner: owner("left"), pressed: stick.left || dpad.left)
        keyboard.set(layout.right, owner: owner("right"), pressed: stick.right || dpad.right)
    }

    func disconnect() { keyboard.releaseAll(ownedBy: "p\(player + 1).") }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let keyboard = KeyboardOutput()
    private let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var bindings: [Int64: HIDControllerBinding] = [:]
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var permissionLine: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            let passed = runSelfTest()
            print(passed ? "SELF_TEST_OK" : "SELF_TEST_FAILED")
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        startHID()
        requestAccessibility()
        refreshMenu()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎮 0/2"
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "等待手柄…", action: nil, keyEquivalent: "")
        permissionLine = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(permissionLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打开辅助功能设置…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出双手柄映射器", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        keyboard.releaseEverything()
        NSApp.terminate(nil)
    }

    private func startHID() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x045e,
            kIOHIDProductIDKey: 0x02e0,
            kIOHIDPrimaryUsagePageKey: 0x01,
            kIOHIDPrimaryUsageKey: 0x05
        ]
        IOHIDManagerSetDeviceMatching(hidManager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().add(device)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().remove(device)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

        if let devices = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> {
            for device in devices.sorted(by: { serial(of: $0) > serial(of: $1) }) { add(device) }
        }
    }

    private func deviceID(_ device: IOHIDDevice) -> Int64 {
        (IOHIDDeviceGetProperty(device, kIOHIDUniqueIDKey as CFString) as? NSNumber)?.int64Value
            ?? Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())))
    }

    private func serial(of device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""
    }

    private func remove(_ device: IOHIDDevice) {
        bindings.removeValue(forKey: deviceID(device))?.disconnect()
        refreshMenu()
    }

    private func add(_ device: IOHIDDevice) {
        let id = deviceID(device)
        guard bindings[id] == nil, bindings.count < 2 else { return }
        let used = Set(bindings.values.map(\.player))
        guard let slot = (0..<2).first(where: { !used.contains($0) }) else { return }
        bindings[id] = HIDControllerBinding(device: device, player: slot, keyboard: keyboard)
        refreshMenu()
    }

    private func refreshMenu() {
        let count = bindings.count
        statusItem.button?.title = "🎮 \(count)/2"
        let lines = bindings.values.sorted { $0.player < $1.player }.map {
            "P\($0.player + 1): Xbox …\($0.serial.suffix(5))"
        }
        statusLine.title = lines.isEmpty ? "等待两只手柄连接…" : lines.joined(separator: "  |  ")
        permissionLine.title = AXIsProcessTrusted() ? "辅助功能权限：已启用" : "辅助功能权限：需要启用（点此打开）"
        let status = "count=\(count) permission=\(AXIsProcessTrusted()) " + lines.joined(separator: " | ") + "\n"
        try? status.write(toFile: "/tmp/DualPadMapper-status.txt", atomically: true, encoding: .utf8)
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.releaseEverything()
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

private let application = NSApplication.shared
private let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
