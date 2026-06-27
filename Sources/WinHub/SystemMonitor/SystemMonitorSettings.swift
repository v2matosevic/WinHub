import Foundation

/// UserDefaults-backed knobs for the System monitor module. Read live at the
/// point of use so Settings changes apply without restarting the module.
enum SystemMonitorSettings {
    static let showCpuKey = "sysmon.showCpu"
    static let showRamKey = "sysmon.showRam"
    static let showTempKey = "sysmon.showTemp"
    static let intervalKey = "sysmon.interval"

    static func registerDefaults() {
        // RAM + temperature show by default; CPU is available but off — so the
        // read-out stays minimal out of the box but "edit what shows" has teeth.
        UserDefaults.standard.register(defaults: [
            showCpuKey: false,
            showRamKey: true,
            showTempKey: true,
            intervalKey: 2.0,
        ])
    }

    static var showCpu: Bool { UserDefaults.standard.bool(forKey: showCpuKey) }
    static var showRam: Bool { UserDefaults.standard.bool(forKey: showRamKey) }
    static var showTemp: Bool { UserDefaults.standard.bool(forKey: showTempKey) }
    static var interval: Double {
        let v = UserDefaults.standard.double(forKey: intervalKey)
        return v > 0 ? v : 2.0
    }
}
