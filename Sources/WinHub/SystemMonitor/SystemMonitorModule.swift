import AppKit

/// A compact RAM / temperature / CPU read-out in the menu bar. Owns its own
/// status item (separate from WinHub's hub icon) and refreshes on a timer. Which
/// metrics show is configurable in Settings — read live, so toggles apply at once.
///
/// Sampling runs off the main thread and the label is only re-rendered when the
/// text it would show actually changes: this module ships on by default and ticks
/// forever, so its cost is the app's floor. See `sampleQueue` and `render(_:)`.
final class SystemMonitorModule: NSObject, HubModule, NSMenuDelegate {
    let id = "system-monitor"
    let title = "System monitor"
    let summary = "RAM, temperature, and CPU in the menu bar — pick what shows in Settings."
    let requiredPermissions: [Permission] = []
    private(set) var isRunning = false

    private let metrics = SystemMetrics()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var scheduledInterval: Double = 0

    /// `SystemMetrics` is single-threaded state and `temperature()` blocks on a
    /// synchronous IOKit IPC per sensor — keep every reading on this one queue and
    /// off the main thread, which only ever receives the finished `Sample`.
    private let sampleQueue = DispatchQueue(label: "hr.version2.winhub.sysmon", qos: .utility)
    /// Set while a sample is in flight, so a slow read can't stack up ticks.
    private var isSampling = false

    // Latest readings, refreshed each tick and reused by the dropdown menu.
    private let stats = SystemStatsStore()
    private var hasCPUBaseline = false
    private var hasReading = false
    private var lastCPU: Double = 0
    private var lastMemory = SystemMetrics.Memory(usedBytes: 0, totalBytes: 0)
    private var lastTemp: Double?

    /// Die temperature moves far slower than the refresh interval, and reading it
    /// is the single most expensive thing this module does — sample it on its own
    /// relaxed cadence and carry the value between reads.
    private static let temperatureInterval: TimeInterval = 6
    private var lastTemperatureRead = Date.distantPast

    func start() {
        guard !isRunning else { return }
        MainActor.assumeIsolated {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            // The stat rows have no action; without this AppKit greys them out as
            // "disabled". They're a readout, so keep them full-strength.
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
            render(nil)          // placeholder glyph until the first sample lands
            scheduleTimer()
            requestSample()
        }
        isRunning = true
        NSLog("[WinHub.sysmon] started")
    }

    func stop() {
        guard isRunning else { return }
        MainActor.assumeIsolated {
            timer?.invalidate(); timer = nil
            stats.flush()
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            lastLabelKey = nil
        }
        isRunning = false
        NSLog("[WinHub.sysmon] stopped")
    }

    // MARK: - Refresh

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = SystemMonitorSettings.interval
        scheduledInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = interval * 0.2
        // Common modes, so the read-out keeps updating while a menu is tracking —
        // otherwise our own "Now" row freezes the moment you open it.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One refresh, plus a cheap check for a Settings change. We deliberately do
    /// NOT observe `UserDefaults.didChangeNotification`: `apply()` writes today's
    /// stats to defaults, and reacting to our own write would recurse. Metric
    /// toggles are read live when rendering, so they apply on the next tick;
    /// an interval change just reschedules the timer here.
    private func tick() {
        requestSample()
        if SystemMonitorSettings.interval != scheduledInterval {
            scheduleTimer()
        }
    }

    /// Kick one background sample. No-op while one is already in flight.
    private func requestSample() {
        guard !isSampling else { return }
        isSampling = true
        let wantsTemperature = Date().timeIntervalSince(lastTemperatureRead) >= Self.temperatureInterval
        sampleQueue.async { [weak self] in
            guard let self else { return }
            let sample = self.metrics.sample(includeTemperature: wantsTemperature)
            DispatchQueue.main.async {
                self.isSampling = false
                self.apply(sample, readTemperature: wantsTemperature)
            }
        }
    }

    /// Fold a finished sample into today's stats and update the menu-bar label.
    private func apply(_ sample: SystemMetrics.Sample, readTemperature: Bool) {
        lastCPU = sample.cpu
        lastMemory = sample.memory
        if readTemperature {
            lastTemperatureRead = Date()
            lastTemp = sample.temperature
        }
        hasReading = true

        // Only fold in valid samples: CPU's first reading has no delta (skip it),
        // and a zero memory read means host_statistics64 failed. Temperature is
        // only recorded on the ticks we actually read it.
        let cpuSample: Double? = hasCPUBaseline ? lastCPU * 100 : nil
        hasCPUBaseline = true
        let ramSample: Double? = lastMemory.usedBytes > 0 ? usedRAMGB : nil
        stats.record(cpuPercent: cpuSample, ramGB: ramSample,
                     tempC: readTemperature ? lastTemp : nil)

        render(currentLabelKey())
    }

    private var usedRAMGB: Double { Double(lastMemory.usedBytes) / 1_073_741_824 }

    // MARK: - Menu-bar label

    // Sized to sit with the system's own menu-bar glyphs: a touch larger than the
    // number and medium weight so the icons read crisply rather than thin.
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let iconPointSize: CGFloat = 15

    /// The pieces the label would show right now: (SF Symbol, text). Nil while we
    /// have no reading yet.
    private func currentLabelKey() -> [(symbol: String, text: String)]? {
        guard hasReading else { return nil }
        var parts: [(symbol: String, text: String)] = []
        if SystemMonitorSettings.showCpu {
            parts.append(("cpu", "\(Int(round(lastCPU * 100)))%"))
        }
        if SystemMonitorSettings.showRam {
            parts.append(("memorychip", String(format: "%.1fG", usedRAMGB)))
        }
        if SystemMonitorSettings.showTemp, let t = lastTemp {
            parts.append(("thermometer.medium", "\(Int(round(t)))°"))
        }
        return parts
    }

    /// The last rendered label, as a plain string. Setting `attributedTitle` forces
    /// `NSStatusItem._adjustLength` → Auto Layout → a layer redraw, so skip it
    /// entirely when the text hasn't moved (RAM in 0.1 GB steps and whole-degree
    /// temperature hold still for many ticks at a time).
    private var lastLabelKey: String?

    private func render(_ parts: [(symbol: String, text: String)]?) {
        guard let button = statusItem?.button else { return }
        let key = parts.map { $0.map { "\($0.symbol):\($0.text)" }.joined(separator: "|") } ?? "\u{0}"
        guard key != lastLabelKey else { return }
        lastLabelKey = key

        guard let parts, !parts.isEmpty else {
            // No reading yet, or everything hidden (or temp the only pick and it's
            // unavailable): fall back to a glyph so the item is still findable.
            button.attributedTitle = NSAttributedString(string: "")
            let glyph = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                                accessibilityDescription: "System monitor")
            glyph?.isTemplate = true
            button.image = glyph
            return
        }

        let label = NSMutableAttributedString()
        for part in parts {
            append(to: label, symbol: part.symbol, text: part.text)
        }
        button.image = nil
        button.attributedTitle = label
    }

    private func append(to string: NSMutableAttributedString, symbol: String, text: String) {
        if string.length > 0 {
            // Wider gap between metric groups than between an icon and its number.
            string.append(NSAttributedString(string: "  ", attributes: [.font: labelFont, .kern: 1.0]))
        }
        string.append(symbolAttachment(symbol))
        string.append(NSAttributedString(string: "\u{2009}" + text, attributes: [.font: labelFont]))
    }

    /// The glyphs never change — build each once instead of re-resolving an
    /// `NSImage` out of the symbol catalog on every tick, forever.
    private var symbolCache: [String: NSAttributedString] = [:]

    private func symbolAttachment(_ name: String) -> NSAttributedString {
        if let cached = symbolCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(scale: .medium))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = image
        if let size = image?.size {
            // Centre the glyph on the number's cap height so icon and digits share
            // one optical axis (no more eyeballed nudge).
            let y = (labelFont.capHeight - size.height) / 2
            attachment.bounds = CGRect(x: 0, y: y, width: size.width, height: size.height)
        }
        let built = NSAttributedString(attachment: attachment)
        symbolCache[name] = built
        return built
    }

    // MARK: - Dropdown stats menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Build from the latest reading and kick a fresh one — the timer runs in
        // common modes, so the menu keeps updating while it's open.
        requestSample()
        menu.removeAllItems()

        addSection(to: menu, title: "Temperature", stat: stats.temp,
                   now: lastTemp, unit: "°C", decimals: 0)
        menu.addItem(.separator())
        addSection(to: menu, title: "Memory", stat: stats.ram,
                   now: hasReading ? usedRAMGB : nil, unit: " GB", decimals: 1)
        if SystemMonitorSettings.showCpu {
            menu.addItem(.separator())
            addSection(to: menu, title: "CPU", stat: stats.cpu,
                       now: hasReading ? lastCPU * 100 : nil, unit: "%", decimals: 0)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "System Monitor Settings…",
                                  action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    private func addSection(to menu: NSMenu, title: String, stat: MetricDay,
                            now: Double?, unit: String, decimals: Int) {
        func fmt(_ v: Double) -> String { String(format: "%.\(decimals)f%@", v, unit) }

        menu.addItem(headerRow(title))
        menu.addItem(statRow("Now", now.map(fmt) ?? "—"))
        if stat.hasData {
            menu.addItem(statRow("High today", fmt(stat.high)))
            menu.addItem(statRow("Low today", fmt(stat.low)))
            menu.addItem(statRow("Average", fmt(stat.average)))
        } else {
            menu.addItem(statRow("Today", "collecting…"))
        }
    }

    private func headerRow(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        item.isEnabled = true
        return item
    }

    /// "label………value" with a secondary-coloured label and the value column
    /// aligned via a tab stop — a deliberate readout, not a disabled row.
    private func statRow(_ label: String, _ value: String) -> NSMenuItem {
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 16
        para.tabStops = [NSTextTab(textAlignment: .left, location: 120)]
        let font = NSFont.menuFont(ofSize: 0)
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: label + "\t", attributes: [
            .font: font, .paragraphStyle: para, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        s.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .paragraphStyle: para, .foregroundColor: NSColor.labelColor,
        ]))
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = s
        item.isEnabled = true
        return item
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .winhubOpenPreferences, object: nil)
    }
}
