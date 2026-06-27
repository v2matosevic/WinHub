import AppKit

/// A compact RAM / temperature / CPU read-out in the menu bar. Owns its own
/// status item (separate from WinHub's hub icon) and refreshes on a timer. Which
/// metrics show is configurable in Settings — read live, so toggles apply at once.
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

    // Latest readings, refreshed each tick and reused by the dropdown menu.
    private let stats = SystemStatsStore()
    private var hasCPUBaseline = false
    private var lastCPU: Double = 0
    private var lastMemory = SystemMetrics.Memory(usedBytes: 0, totalBytes: 0)
    private var lastTemp: Double?

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
            scheduleTimer()
            refresh()
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
        }
        isRunning = false
        NSLog("[WinHub.sysmon] stopped")
    }

    // MARK: - Refresh

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = SystemMonitorSettings.interval
        scheduledInterval = interval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = interval * 0.2
        timer = t
    }

    /// One refresh, plus a cheap check for a Settings change. We deliberately do
    /// NOT observe `UserDefaults.didChangeNotification`: `refresh()` writes today's
    /// stats to defaults, and reacting to our own write would recurse. Metric
    /// toggles are read live inside `refresh()`, so they apply on the next tick;
    /// an interval change just reschedules the timer here.
    private func tick() {
        refresh()
        if SystemMonitorSettings.interval != scheduledInterval {
            scheduleTimer()
        }
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }

        // All three reads are cheap; sample every tick so values are fresh the
        // instant a metric is switched on, and fold them into today's stats.
        lastCPU = metrics.cpuUsage()
        lastMemory = metrics.memory()
        lastTemp = metrics.temperature()

        // Only fold in valid samples: CPU's first reading has no delta (skip it),
        // and a zero memory read means host_statistics64 failed.
        let cpuSample: Double? = hasCPUBaseline ? lastCPU * 100 : nil
        hasCPUBaseline = true
        let ramSample: Double? = lastMemory.usedBytes > 0 ? usedRAMGB : nil
        stats.record(cpuPercent: cpuSample, ramGB: ramSample, tempC: lastTemp)

        let label = NSMutableAttributedString()
        if SystemMonitorSettings.showCpu {
            append(to: label, symbol: "cpu", text: "\(Int(round(lastCPU * 100)))%")
        }
        if SystemMonitorSettings.showRam {
            append(to: label, symbol: "memorychip", text: String(format: "%.1fG", usedRAMGB))
        }
        if SystemMonitorSettings.showTemp, let t = lastTemp {
            append(to: label, symbol: "thermometer.medium", text: "\(Int(round(t)))°")
        }

        if label.length == 0 {
            // Everything hidden (or temp the only pick and it's unavailable): fall
            // back to a glyph so the item is still findable and clickable.
            button.attributedTitle = NSAttributedString(string: "")
            let glyph = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                                accessibilityDescription: "System monitor")
            glyph?.isTemplate = true
            button.image = glyph
        } else {
            button.image = nil
            button.attributedTitle = label
        }
    }

    private var usedRAMGB: Double { Double(lastMemory.usedBytes) / 1_073_741_824 }

    // MARK: - Menu-bar label

    // Sized to sit with the system's own menu-bar glyphs: a touch larger than the
    // number and medium weight so the icons read crisply rather than thin.
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let iconPointSize: CGFloat = 15

    private func append(to string: NSMutableAttributedString, symbol: String, text: String) {
        if string.length > 0 {
            // Wider gap between metric groups than between an icon and its number.
            string.append(NSAttributedString(string: "  ", attributes: [.font: labelFont, .kern: 1.0]))
        }
        string.append(symbolAttachment(symbol))
        string.append(NSAttributedString(string: "\u{2009}" + text, attributes: [.font: labelFont]))
    }

    private func symbolAttachment(_ name: String) -> NSAttributedString {
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
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Dropdown stats menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        addSection(to: menu, title: "Temperature", stat: stats.temp,
                   now: lastTemp, unit: "°C", decimals: 0)
        menu.addItem(.separator())
        addSection(to: menu, title: "Memory", stat: stats.ram,
                   now: usedRAMGB, unit: " GB", decimals: 1)
        if SystemMonitorSettings.showCpu {
            menu.addItem(.separator())
            addSection(to: menu, title: "CPU", stat: stats.cpu,
                       now: lastCPU * 100, unit: "%", decimals: 0)
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
