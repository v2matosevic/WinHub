import Foundation

/// Rolling high / low / average for one metric over the current calendar day.
/// Resets automatically when the local day rolls over.
struct MetricDay: Codable {
    var day: Int          // local-day index (days since the epoch, timezone-adjusted)
    var low: Double
    var high: Double
    var sum: Double
    var count: Int

    static func empty(day: Int) -> MetricDay {
        MetricDay(day: day, low: .infinity, high: -.infinity, sum: 0, count: 0)
    }

    var average: Double { count > 0 ? sum / Double(count) : 0 }
    var hasData: Bool { count > 0 }

    mutating func add(_ value: Double, today: Int) {
        if day != today { self = .empty(day: today) }
        low = Swift.min(low, value)
        high = Swift.max(high, value)
        sum += value
        count += 1
    }
}

/// Tracks today's CPU / RAM / temperature highs, lows, and averages. Fed one
/// sample per refresh tick; persisted so the day's figures survive a relaunch.
final class SystemStatsStore {
    private let defaults = UserDefaults.standard
    private let key = "sysmon.stats.v1"

    private(set) var cpu: MetricDay     // percent
    private(set) var ram: MetricDay     // used GB
    private(set) var temp: MetricDay    // °C

    /// In-memory each tick; flushed to defaults at most this often (and on stop)
    /// so we don't churn UserDefaults — the day's figures only need to survive a
    /// relaunch, where losing the last few seconds is immaterial.
    private var lastPersist = Date.distantPast
    private let persistInterval: TimeInterval = 15

    init() {
        let today = Self.todayKey()
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: MetricDay].self, from: data) {
            cpu = saved["cpu"] ?? .empty(day: today)
            ram = saved["ram"] ?? .empty(day: today)
            temp = saved["temp"] ?? .empty(day: today)
        } else {
            cpu = .empty(day: today)
            ram = .empty(day: today)
            temp = .empty(day: today)
        }
    }

    /// Fold one reading into today's stats. Temperature is optional (the sensor
    /// can be briefly unavailable) — when missing we still keep its day in sync.
    /// Fold one reading into today's stats. Each value is optional — a nil means
    /// "no valid sample this tick" (sensor unavailable, a failed memory read, or
    /// CPU's first sample with no delta yet) and is skipped rather than poisoning
    /// the min/average with a bogus zero.
    func record(cpuPercent: Double?, ramGB: Double?, tempC: Double?) {
        let today = Self.todayKey()
        update(&cpu, cpuPercent, today)
        update(&ram, ramGB, today)
        update(&temp, tempC, today)
        if Date().timeIntervalSince(lastPersist) >= persistInterval { flush() }
    }

    private func update(_ stat: inout MetricDay, _ value: Double?, _ today: Int) {
        if let v = value {
            stat.add(v, today: today)
        } else if stat.day != today {
            stat = .empty(day: today)   // keep the day current even without a sample
        }
    }

    /// Write the current figures to defaults now (called on a relaxed interval and
    /// when the module stops).
    func flush() {
        lastPersist = Date()
        let dict: [String: MetricDay] = ["cpu": cpu, "ram": ram, "temp": temp]
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: key) }
    }

    /// Days since the epoch in local time, so the day boundary is local midnight.
    private static func todayKey() -> Int {
        let now = Date()
        let offset = TimeZone.current.secondsFromGMT(for: now)
        return Int((now.timeIntervalSince1970 + Double(offset)) / 86_400)
    }
}
