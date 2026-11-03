import AppKit
import AVFoundation
import CryptoKit
import Carbon
import Combine
import SQLite3
import SwiftUI
import WebKit

// MARK: - 价格与时段

struct Price {
    let hit: Double
    let miss: Double
    let output: Double
}

struct PriceTable: Codable, Equatable {
    var hitOff: Double
    var hitPeak: Double
    var missOff: Double
    var missPeak: Double
    var outputOff: Double
    var outputPeak: Double

    func price(peak: Bool) -> Price {
        Price(
            hit: peak ? hitPeak : hitOff,
            miss: peak ? missPeak : missOff,
            output: peak ? outputPeak : outputOff
        )
    }

    static let flashDefault = PriceTable(
        hitOff: 0.02, hitPeak: 0.04,
        missOff: 1.0, missPeak: 2.0,
        outputOff: 4.0, outputPeak: 8.0
    )

    static let proDefault = PriceTable(
        hitOff: 0.15, hitPeak: 0.30,
        missOff: 4.5, missPeak: 9.0,
        outputOff: 13.5, outputPeak: 27.0
    )
}

enum AppLanguage: String {
    case zh
    case en
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var zh: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var en: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AppearanceStore {
    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "system") ?? .system
    }

    static func apply(_ choice: AppAppearance) {
        UserDefaults.standard.set(choice.rawValue, forKey: "appAppearance")
        let appearance = choice.appearance
        NSApp.appearance = appearance
        NSApp.mainMenu?.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
        AppearanceModel.shared.update(choice)
    }
}

final class AppearanceModel: ObservableObject {
    static let shared = AppearanceModel()

    @Published private(set) var choice: AppAppearance

    init() {
        choice = AppearanceStore.current
    }

    var colorScheme: ColorScheme {
        switch choice {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? .dark : .light
        }
    }

    func update(_ choice: AppAppearance) {
        self.choice = choice
    }
}

struct ThemedRoot<Content: View>: View {
    @ObservedObject private var model = AppearanceModel.shared
    private let scheme: ColorScheme?
    private let content: Content

    init(scheme: ColorScheme? = nil, @ViewBuilder content: () -> Content) {
        self.scheme = scheme
        self.content = content()
    }

    var body: some View {
        content.environment(\.colorScheme, scheme ?? model.colorScheme)
    }
}

enum Theme {
    static let accent = Color(red: 0.56, green: 0.66, blue: 1.0)
}

enum AppIconChoice: String, CaseIterable {
    case retro
    case watercolor
    case classic

    var zh: String {
        switch self {
        case .retro: return "复古版画"
        case .watercolor: return "水彩治愈"
        case .classic: return "经典"
        }
    }

    var en: String {
        switch self {
        case .retro: return "Retro"
        case .watercolor: return "Watercolor"
        case .classic: return "Classic"
        }
    }
}

enum AppIconStore {
    static var choice: AppIconChoice {
        AppIconChoice(rawValue: UserDefaults.standard.string(forKey: "appIcon") ?? "retro") ?? .retro
    }

    static func set(_ choice: AppIconChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: "appIcon")
        apply()
    }

    static func apply() {
        let resource: (name: String, ext: String)
        switch choice {
        case .retro:
            resource = ("AppIcon-retro", "png")
        case .watercolor:
            resource = ("AppIcon-watercolor", "png")
        case .classic:
            resource = ("AppIcon-classic", "icns")
        }

        if let url = Bundle.main.url(forResource: resource.name, withExtension: resource.ext),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            return
        }

        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = image
        }
    }
}

struct BackupFailure: Error {
    let message: String
}

struct BackupInfo: Identifiable {
    let id: String
    let url: URL
    let date: Date
}

enum BackupCrypto {
    static var keyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/backup.key")
    }

    static func key() -> SymmetricKey? {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try FileManager.default.createDirectory(
                at: keyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: keyURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
            return key
        } catch {
            return nil
        }
    }

    static func encrypt(_ data: Data) -> Data? {
        guard let key = key(),
              let sealed = try? AES.GCM.seal(data, using: key) else { return nil }
        return sealed.combined
    }

    static func decrypt(_ data: Data) -> Data? {
        guard let key = key(),
              let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: key) else { return nil }
        return opened
    }
}

enum BackupManager {
    static var cloudRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    static var appFolder: URL {
        cloudRoot.appendingPathComponent("TokenPeek")
    }

    static var backupsFolder: URL {
        appFolder.appendingPathComponent("backups")
    }

    static var dataFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: cloudRoot.path)
    }

    private static let settingsKeys = [
        "appLanguage", "currencyMode", "usdRate", "panelOpacity", "appIcon",
        "appAppearance",
        "showHeaderSection", "showPriceSection", "showUsageSection",
        "showBalanceSection", "showFooterSection", "showSubscriptions", "tier",
        "selectedSource", "selectedOfficialAccountID", "autoCheckUpdates",
        "autoICloudBackup", "showDockIcon",
        "priceSourceURL", "usageDisplayMode", "statusRingStyle",
        "subscriptionStyle", "subscriptionMode",
    ]

    static func listBackups() -> [BackupInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: backupsFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            return BackupInfo(
                id: url.lastPathComponent,
                url: url,
                date: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.date > $1.date }
    }

    static func backup() -> Result<URL, BackupFailure> {
        guard isAvailable else { return .failure(BackupFailure(message: "没有找到 iCloud Drive")) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = formatter.string(from: Date())
        let destination = backupsFolder.appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            let files = [
                "manual-costs.json",
                "local-sources.json",
                "pricing.json",
                "pricing-overrides.json",
                "custom-usage.jsonl",
            ]
            for file in files {
                let source = dataFolder.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(
                        at: source,
                        to: destination.appendingPathComponent(file)
                    )
                }
            }

            let accountsURL = dataFolder.appendingPathComponent("official-accounts.json")
            if let accountsData = try? Data(contentsOf: accountsURL),
               let encrypted = BackupCrypto.encrypt(accountsData) {
                try encrypted.write(to: destination.appendingPathComponent("official-accounts.enc"))
            }

            let sourcesFolder = dataFolder.appendingPathComponent("sources")
            if let files = try? FileManager.default.contentsOfDirectory(at: sourcesFolder, includingPropertiesForKeys: nil) {
                let target = destination.appendingPathComponent("sources")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for file in files where file.pathExtension.lowercased() == "jsonl" {
                    try FileManager.default.copyItem(
                        at: file,
                        to: target.appendingPathComponent(file.lastPathComponent)
                    )
                }
            }

            var settings: [String: Any] = [:]
            for key in settingsKeys {
                if let value = UserDefaults.standard.object(forKey: key) {
                    settings[key] = value
                }
            }
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination.appendingPathComponent("settings.json"))

            pruneOldBackups()
            return .success(destination)
        } catch {
            return .failure(BackupFailure(message: error.localizedDescription))
        }
    }

    static func restore(_ backup: BackupInfo) -> Result<Void, BackupFailure> {
        let source = backup.url
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(BackupFailure(message: "备份不存在"))
        }

        do {
            let encryptedAccounts = source.appendingPathComponent("official-accounts.enc")
            let legacyAccounts = source.appendingPathComponent("official-accounts.json")
            let accountsTarget = dataFolder.appendingPathComponent("official-accounts.json")

            if let encrypted = try? Data(contentsOf: encryptedAccounts),
               let decrypted = BackupCrypto.decrypt(encrypted) {
                try? FileManager.default.removeItem(at: accountsTarget)
                try decrypted.write(to: accountsTarget, options: .atomic)
            } else if FileManager.default.fileExists(atPath: legacyAccounts.path) {
                try? FileManager.default.removeItem(at: accountsTarget)
                try FileManager.default.copyItem(at: legacyAccounts, to: accountsTarget)
            }

            let files = [
                "manual-costs.json",
                "local-sources.json",
                "pricing.json",
                "pricing-overrides.json",
                "custom-usage.jsonl",
            ]
            for file in files {
                let from = source.appendingPathComponent(file)
                let to = dataFolder.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: from.path) {
                    try? FileManager.default.removeItem(at: to)
                    try FileManager.default.copyItem(at: from, to: to)
                }
            }

            let sources = source.appendingPathComponent("sources")
            if let files = try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) {
                let target = dataFolder.appendingPathComponent("sources")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for file in files where file.pathExtension.lowercased() == "jsonl" {
                    let to = target.appendingPathComponent(file.lastPathComponent)
                    try? FileManager.default.removeItem(at: to)
                    try FileManager.default.copyItem(at: file, to: to)
                }
            }

            let settingsURL = source.appendingPathComponent("settings.json")
            if let data = try? Data(contentsOf: settingsURL),
               let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in settings {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }

            NotificationCenter.default.post(name: .dsDataRestored, object: nil)
            return .success(())
        } catch {
            return .failure(BackupFailure(message: error.localizedDescription))
        }
    }

    static func autoBackupIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "autoICloudBackup") else { return }
        guard isAvailable else { return }
        if let latest = listBackups().first,
           Date().timeIntervalSince(latest.date) < 86_400 {
            return
        }
        _ = backup()
    }

    private static func pruneOldBackups() {
        let backups = listBackups()
        for old in backups.dropFirst(10) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }
}

enum L {
    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "zh") ?? .zh
    }

    static var isEnglish: Bool { language == .en }

    static func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
}

enum DisplayCurrency: String {
    case cny
    case usd

    var symbol: String { self == .cny ? "¥" : "$" }
    var code: String { self == .cny ? "CNY" : "USD" }
    var name: String { self == .cny ? "人民币" : "美元" }
    var priceUnit: String {
        self == .cny
            ? L.t("元 / 百万 tokens", "CNY / 1M tokens")
            : L.t("美元 / 百万 tokens", "USD / 1M tokens")
    }
}

enum Money {
    static var currency: DisplayCurrency {
        DisplayCurrency(rawValue: UserDefaults.standard.string(forKey: "currencyMode") ?? "cny") ?? .cny
    }

    static var usdRate: Double {
        let value = UserDefaults.standard.double(forKey: "usdRate")
        return value > 0 ? value : 7.2
    }

    static var symbol: String { currency.symbol }

    static func fromCNY(_ value: Double) -> Double {
        currency == .usd ? value / usdRate : value
    }

    static func toCNY(_ value: Double) -> Double {
        currency == .usd ? value * usdRate : value
    }

    static func number(_ value: Double, digits: Int? = nil) -> String {
        let v = max(0, value)
        let d = digits ?? (v == 0 ? 2 : v >= 1 ? 2 : v >= 0.01 ? 4 : 6)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.minimumFractionDigits = d
        formatter.maximumFractionDigits = d
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: v)) ?? String(format: "%.\(d)f", v)
    }

    static func display(_ cnyValue: Double, digits: Int? = nil) -> String {
        symbol + number(fromCNY(cnyValue), digits: digits)
    }

    static func price(_ cnyValue: Double) -> String {
        let converted = fromCNY(cnyValue)
        let digits = currency == .usd
            ? (converted >= 0.1 ? 3 : 4)
            : 2
        return display(cnyValue, digits: digits)
    }
}

enum Tier: String, CaseIterable, Identifiable {
    case flash
    case pro

    var id: String { rawValue }
    var name: String { self == .flash ? "Flash" : "Pro" }
    var modelID: String { self == .flash ? "deepseek-flash" : "deepseek-v4-pro" }
}

enum Pricing {
    // 人民币元 / 百万 tokens；默认值来自官方定价页，之后每月自动更新一次
    // 来源：https://api-docs.deepseek.com/zh-cn/quick_start/pricing/
    private static let priceLock = NSLock()
    private static var tables: [Tier: PriceTable] = [
        .flash: .flashDefault,
        .pro: .proDefault,
    ]
    private static var userTables: [Tier: PriceTable] = [:]

    static func price(_ tier: Tier, peak: Bool) -> Price {
        priceLock.lock()
        defer { priceLock.unlock() }
        let table = userTables[tier] ?? tables[tier] ?? (tier == .pro ? .proDefault : .flashDefault)
        return table.price(peak: peak)
    }

    static func apply(flash: PriceTable, pro: PriceTable) {
        priceLock.lock()
        tables[.flash] = flash
        tables[.pro] = pro
        priceLock.unlock()
    }

    static var currentTables: (flash: PriceTable, pro: PriceTable) {
        priceLock.lock()
        defer { priceLock.unlock() }
        return (
            userTables[.flash] ?? tables[.flash] ?? .flashDefault,
            userTables[.pro] ?? tables[.pro] ?? .proDefault
        )
    }

    static var hasUserTables: Bool {
        priceLock.lock()
        defer { priceLock.unlock() }
        return !userTables.isEmpty
    }

    /// 用户在设置里改过的价格。单独存文件，随 iCloud 备份一起走。
    static var userTablesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/pricing-overrides.json")
    }

    static func loadUserTables() {
        var loaded: [Tier: PriceTable] = [:]
        if let data = try? Data(contentsOf: userTablesURL),
           let stored = try? JSONDecoder().decode([String: PriceTable].self, from: data) {
            if let flash = stored[Tier.flash.rawValue] { loaded[.flash] = flash }
            if let pro = stored[Tier.pro.rawValue] { loaded[.pro] = pro }
        }
        priceLock.lock()
        userTables = loaded
        priceLock.unlock()
    }

    static func setUserTables(flash: PriceTable, pro: PriceTable) {
        priceLock.lock()
        userTables = [.flash: flash, .pro: pro]
        priceLock.unlock()

        let stored: [String: PriceTable] = [
            Tier.flash.rawValue: flash,
            Tier.pro.rawValue: pro,
        ]
        do {
            try FileManager.default.createDirectory(
                at: userTablesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(stored)
            try data.write(to: userTablesURL, options: .atomic)
        } catch {
            // 写入失败不影响当前运行
        }
    }

    static func clearUserTables() {
        priceLock.lock()
        userTables = [:]
        priceLock.unlock()
        try? FileManager.default.removeItem(at: userTablesURL)
    }

    static func cost(tier: Tier, peak: Bool, hit: Int64, miss: Int64, output: Int64) -> Double {
        let p = price(tier, peak: peak)
        return (Double(hit) * p.hit + Double(miss) * p.miss + Double(output) * p.output) / 1_000_000
    }

    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    // 中国法定节假日（2025–2026，北京时间自然日）
    private static let holidayRanges: [(String, String)] = [
        ("2025-01-01", "2025-01-01"),
        ("2025-01-28", "2025-02-04"),
        ("2025-04-04", "2025-04-06"),
        ("2025-05-01", "2025-05-05"),
        ("2025-05-31", "2025-06-02"),
        ("2025-10-01", "2025-10-08"),
        ("2026-01-01", "2026-01-03"),
        ("2026-02-15", "2026-02-23"),
        ("2026-04-04", "2026-04-06"),
        ("2026-05-01", "2026-05-05"),
        ("2026-06-19", "2026-06-21"),
        ("2026-09-25", "2026-09-27"),
        ("2026-10-01", "2026-10-07"),
    ]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        f.dateFormat = "EEE"
        return f
    }()

    private static let holidays: Set<String> = {
        var set = Set<String>()
        let cal = calendar
        for (startText, endText) in holidayRanges {
            guard let start = dayFormatter.date(from: startText),
                  let end = dayFormatter.date(from: endText) else { continue }
            var day = start
            while day <= end {
                set.insert(dayFormatter.string(from: day))
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return set
    }()

    static func isPeak(_ date: Date = Date()) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return false }
        if weekday == 1 || weekday == 7 { return false }
        if holidays.contains(dayFormatter.string(from: date)) { return false }
        let minutes = hour * 60 + minute
        return (540..<720).contains(minutes) || (840..<1080).contains(minutes)
    }

    static func nextChange(from now: Date = Date()) -> Date? {
        let current = isPeak(now)
        let cal = calendar
        let start = cal.startOfDay(for: now)

        // 时段切换只可能发生在 00:00 / 09:00 / 12:00 / 14:00 / 18:00
        for offset in 0..<22 {
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            for hour in [0, 9, 12, 14, 18] {
                guard let t = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day), t > now else { continue }
                if isPeak(t) != current { return t }
            }
        }
        return nil
    }

    static func timeText(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func targetText(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        let day: String
        if cal.isDate(date, inSameDayAs: now) {
            day = L.t("今天", "today")
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
                  cal.isDate(date, inSameDayAs: tomorrow) {
            day = L.t("明天", "tomorrow")
        } else {
            day = weekdayFormatter.string(from: date)
        }
        return "\(day) \(hmFormatter.string(from: date))"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if d > 0 { return m == 0 ? L.t("\(d) 天 \(h) 小时", "\(d)d \(h)h") : L.t("\(d) 天 \(h) 小时 \(m) 分", "\(d)d \(h)h \(m)m") }
        if h > 0 { return m == 0 ? L.t("\(h) 小时", "\(h)h") : L.t("\(h) 小时 \(m) 分", "\(h)h \(m)m") }
        if m > 0 { return L.t("\(m) 分 \(s) 秒", "\(m)m \(s)s") }
        return L.t("\(s) 秒", "\(s)s")
    }

    static func money(_ value: Double, digits: Int? = nil) -> String {
        let v = max(0, value)
        let d = digits ?? (v == 0 ? 2 : v >= 1 ? 2 : v >= 0.01 ? 4 : 6)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.minimumFractionDigits = d
        formatter.maximumFractionDigits = d
        let text = formatter.string(from: NSNumber(value: v)) ?? String(format: "%.\(d)f", v)
        return "¥" + text
    }

    static func digits(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(15))
    }
}

// MARK: - 官方定价同步

struct PricingCache: Codable {
    let fetchedAt: Date
    let flash: PriceTable
    let pro: PriceTable
}

enum PricingCacheStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/pricing.json")
    }

    static func load() -> PricingCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PricingCache.self, from: data)
    }

    static func save(_ cache: PricingCache) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 缓存失败不影响当前运行
        }
    }
}

enum PricingUpdateError: Error {
    case network
    case parse
}

struct FetchedPricing {
    let flash: PriceTable
    let pro: PriceTable
}

enum PricingUpdater {
    static let sourceURL = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing.md")!

    static func fetch() -> Result<FetchedPricing, PricingUpdateError> {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 20
        request.setValue("text/markdown, text/html;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<FetchedPricing, PricingUpdateError> = .failure(.network)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                outcome = .failure(.network)
                return
            }
            guard error == nil, let data,
                  let text = String(data: data, encoding: .utf8),
                  let parsed = parse(text) else {
                outcome = .failure(.parse)
                return
            }
            outcome = .success(parsed)
        }.resume()

        semaphore.wait()
        return outcome
    }

    static func parse(_ markdown: String) -> FetchedPricing? {
        var flash: [String: Double] = [:]
        var pro: [String: Double] = [:]

        for line in markdown.split(separator: "\n") {
            guard line.contains("| 价格") else { continue }
            let columns = line.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard columns.count >= 5, columns[0].hasPrefix("价格") else { continue }

            let category = columns[1]
            let period = columns[2]
            guard let flashPrice = money(columns[3]),
                  let proPrice = money(columns[4]) else { continue }

            let key: String
            if category.contains("缓存未命中") {
                key = "miss"
            } else if category.contains("缓存命中") {
                key = "hit"
            } else if category.contains("输出") {
                key = "output"
            } else {
                continue
            }

            let suffix = period.contains("高峰") ? "peak" : "off"
            flash["\(key)_\(suffix)"] = flashPrice
            pro["\(key)_\(suffix)"] = proPrice
        }

        guard let flashTable = table(from: flash),
              let proTable = table(from: pro) else {
            return nil
        }
        return FetchedPricing(flash: flashTable, pro: proTable)
    }

    private static func money(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    static func table(from values: [String: Double]) -> PriceTable? {
        guard let hitOff = values["hit_off"],
              let hitPeak = values["hit_peak"],
              let missOff = values["miss_off"],
              let missPeak = values["miss_peak"],
              let outputOff = values["output_off"],
              let outputPeak = values["output_peak"] else {
            return nil
        }

        guard hitOff <= hitPeak,
              missOff <= missPeak,
              outputOff <= outputPeak else {
            return nil
        }

        return PriceTable(
            hitOff: hitOff, hitPeak: hitPeak,
            missOff: missOff, missPeak: missPeak,
            outputOff: outputOff, outputPeak: outputPeak
        )
    }
}

enum PricingSource {
    static let officialURLString = "https://api-docs.deepseek.com/zh-cn/quick_start/pricing.md"

    static var urlString: String {
        let saved = UserDefaults.standard.string(forKey: "priceSourceURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty { return saved }
        return officialURLString
    }

    static func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "priceSourceURL")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "priceSourceURL")
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: "priceSourceURL")
    }
}

enum PricingSourceImporter {
    struct Failure: Error {
        let message: String
    }

    static func fetch(urlString: String) -> Result<FetchedPricing, Failure> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure(Failure(message: L.t(
                "请输入 http 或 https 开头的网址",
                "Enter an http or https URL"
            )))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("text/html, text/markdown, text/plain;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<FetchedPricing, Failure> = .failure(Failure(message: L.t(
            "网络请求失败",
            "Network request failed"
        )))

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                outcome = .failure(Failure(message: "HTTP \(http.statusCode)"))
                return
            }

            guard error == nil, let data,
                  let raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                outcome = .failure(Failure(message: L.t(
                    "网页内容读取失败",
                    "Could not read the page"
                )))
                return
            }

            let text = normalize(raw)
            if let parsed = PricingUpdater.parse(text) {
                outcome = .success(parsed)
                return
            }
            if let parsed = parseLoose(text) {
                outcome = .success(parsed)
                return
            }

            outcome = .failure(Failure(message: L.t(
                "没有识别到价格，可以手动填写",
                "No prices found; fill them in manually"
            )))
        }.resume()

        semaphore.wait()
        return outcome
    }

    // MARK: 解析

    private static func normalize(_ raw: String) -> String {
        var text = raw

        if text.range(of: "<tr", options: .caseInsensitive) != nil {
            let rows = tableRows(from: text)
            if !rows.isEmpty {
                text = rows.joined(separator: "\n")
            }
        }

        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</(p|div|li|h[1-6]|section|article|tr|table)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = stripTags(text)
        text = decodeEntities(text)
        return text
    }

    private static func tableRows(from html: String) -> [String] {
        guard let rowRegex = try? NSRegularExpression(
            pattern: "<tr(?:\\s[^>]*)?>(.*?)</tr>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let cellRegex = try? NSRegularExpression(
            pattern: "<t[hd](?:\\s[^>]*)?>(.*?)</t[hd]>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let source = html as NSString
        var rows: [String] = []

        for match in rowRegex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let inner = source.substring(with: match.range(at: 1))
            let innerSource = inner as NSString
            var cells: [String] = []

            for cellMatch in cellRegex.matches(in: inner, range: NSRange(location: 0, length: innerSource.length)) {
                var cell = innerSource.substring(with: cellMatch.range(at: 1))
                cell = stripTags(cell)
                cell = decodeEntities(cell)
                cell = cell.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                cell = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(cell)
            }

            if !cells.isEmpty {
                rows.append("| " + cells.joined(separator: " | ") + " |")
            }
        }

        return rows
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        let map = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&yen;": "¥",
            "&mdash;": "-",
            "&ndash;": "-",
        ]
        var text = text
        for (key, value) in map {
            text = text.replacingOccurrences(of: key, with: value)
        }
        return text
    }

    private static func parseLoose(_ text: String) -> FetchedPricing? {
        var flash: [String: Double] = [:]
        var pro: [String: Double] = [:]
        var currentPeriod: String?
        var currentTier: String?
        var usesUSD = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if lower.contains("usd") || line.contains("$") || line.contains("美元") {
                usesUSD = true
            }

            if let period = period(in: line) {
                currentPeriod = period
            }

            if lower.contains("flash") {
                currentTier = "flash"
            } else if lower.contains("pro") {
                currentTier = "pro"
            }

            guard let category = category(in: line),
                  let period = period(in: line) ?? currentPeriod else {
                continue
            }

            let prices = numbers(in: line, usesUSD: usesUSD)
            guard !prices.isEmpty else { continue }

            let key = "\(category)_\(period)"
            if prices.count >= 2 {
                flash[key] = prices[0]
                pro[key] = prices[1]
            } else if currentTier == "flash" {
                flash[key] = prices[0]
            } else if currentTier == "pro" {
                pro[key] = prices[0]
            } else {
                flash[key] = prices[0]
                pro[key] = prices[0]
            }
        }

        guard let flashTable = PricingUpdater.table(from: flash),
              let proTable = PricingUpdater.table(from: pro) else {
            return nil
        }
        return FetchedPricing(flash: flashTable, pro: proTable)
    }

    private static func category(in line: String) -> String? {
        let lower = line.lowercased()
        if line.contains("缓存未命中") || lower.contains("cache miss") || (lower.contains("miss") && lower.contains("input")) {
            return "miss"
        }
        if line.contains("缓存命中") || lower.contains("cache hit") || (lower.contains("hit") && lower.contains("input")) {
            return "hit"
        }
        if line.contains("输出") || lower.contains("output") {
            return "output"
        }
        return nil
    }

    private static func period(in line: String) -> String? {
        let lower = line.lowercased()
        if line.contains("空闲") || line.contains("闲时")
            || lower.contains("off-peak") || lower.contains("off peak") || lower.contains("offpeak") {
            return "off"
        }
        if line.contains("高峰") || lower.contains("peak") {
            return "peak"
        }
        return nil
    }

    private static func numbers(in line: String, usesUSD: Bool) -> [Double] {
        if line.contains("|") || line.contains("\t") {
            let cells: [String]
            if line.contains("|") {
                cells = line.split(separator: "|").map { String($0) }
            } else {
                cells = line.split(separator: "\t").map { String($0) }
            }

            var result: [Double] = []
            for cell in cells {
                let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = trimmed.first,
                      first.isNumber || first == "¥" || first == "￥" || first == "$" else {
                    continue
                }
                guard let value = firstNumber(in: trimmed) else { continue }
                let lower = trimmed.lowercased()
                let cellUSD = trimmed.contains("$") || lower.contains("usd") || trimmed.contains("美元")
                result.append(value * ((cellUSD || usesUSD) ? Money.usdRate : 1))
            }
            return result
        }

        guard let regex = try? NSRegularExpression(pattern: "[0-9]+(?:[.,][0-9]+)?") else { return [] }
        let source = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let raw = source.substring(with: match.range)
                .replacingOccurrences(of: ",", with: ".")
            guard let value = Double(raw), value > 0 else { return nil }
            return value * (usesUSD ? Money.usdRate : 1)
        }
    }

    private static func firstNumber(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9]+(?:[.,][0-9]+)?") else { return nil }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        let raw = source.substring(with: match.range)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(raw), value > 0 else { return nil }
        return value
    }
}

final class PricingStore: ObservableObject {
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var updating = false
    @Published private(set) var updateFailed = false

    private let attemptKey = "lastPricingAttempt"
    private var lastAttempt: Date?

    init() {
        if let cache = PricingCacheStore.load() {
            Pricing.apply(flash: cache.flash, pro: cache.pro)
            lastUpdated = cache.fetchedAt
        }
        Pricing.loadUserTables()
        lastAttempt = UserDefaults.standard.object(forKey: attemptKey) as? Date
    }

    func refreshIfNeeded(force: Bool = false) {
        if updating { return }

        if !force {
            if let lastUpdated,
               Date().timeIntervalSince(lastUpdated) < 30 * 24 * 3600 {
                return
            }
            if let lastAttempt,
               Date().timeIntervalSince(lastAttempt) < 12 * 3600 {
                return
            }
        }

        updating = true
        updateFailed = false
        lastAttempt = Date()
        UserDefaults.standard.set(lastAttempt, forKey: attemptKey)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = PricingUpdater.fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                self.updating = false

                switch result {
                case .success(let fetched):
                    let now = Date()
                    Pricing.apply(flash: fetched.flash, pro: fetched.pro)
                    PricingCacheStore.save(
                        PricingCache(fetchedAt: now, flash: fetched.flash, pro: fetched.pro)
                    )
                    self.lastUpdated = now
                    self.updateFailed = false
                    NotificationCenter.default.post(name: .dsUsageRefresh, object: nil)
                case .failure:
                    self.updateFailed = true
                }
            }
        }
    }

    func refreshNow() {
        refreshIfNeeded(force: true)
    }
}

// MARK: - 账户余额

enum OfficialLinks {
    static let topUp = URL(string: "https://platform.deepseek.com/top_up")!
    static let billing = URL(string: "https://platform.deepseek.com/billing")!
}

struct BalanceSnapshot {
    let currency: String
    let normal: Double
    let bonus: Double
    let totalCost: Double

    var total: Double { normal + bonus }
}

private struct BalanceResponse: Decodable {
    let code: Int?
    let msg: String?
    let data: BalanceEnvelope?

    struct BalanceEnvelope: Decodable {
        let biz_code: Int?
        let biz_msg: String?
        let biz_data: BalanceBiz?
    }

    struct BalanceBiz: Decodable {
        let normal_wallets: [Wallet]?
        let bonus_wallets: [Wallet]?
        let total_costs: [TotalCost]?
    }

    struct Wallet: Decodable {
        let currency: String?
        let balance: FlexString?
    }

    struct TotalCost: Decodable {
        let currency: String?
        let amount: FlexString?
    }
}

enum BalanceLoader {
    private static let url = URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!

    static func load(token: String) -> Result<BalanceSnapshot, OfficialError> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.deepseek.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "x-client-version")
        request.setValue("1.0.0", forHTTPHeaderField: "x-app-version")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<BalanceSnapshot, OfficialError> = .failure(.failed("网络请求失败"))

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    outcome = .failure(.invalidToken)
                    return
                }
                if !(200...299).contains(http.statusCode) {
                    outcome = .failure(.failed("HTTP \(http.statusCode)"))
                    return
                }
            }

            guard error == nil, let data else {
                outcome = .failure(.failed(error?.localizedDescription ?? "网络请求失败"))
                return
            }

            guard let response = try? JSONDecoder().decode(BalanceResponse.self, from: data) else {
                outcome = .failure(.failed("余额数据解析失败"))
                return
            }

            if let code = response.code, code != 0 {
                if code == 40002 || code == 40003 {
                    outcome = .failure(.invalidToken)
                } else {
                    outcome = .failure(.failed(response.msg ?? "接口返回 \(code)"))
                }
                return
            }
            guard let envelope = response.data else {
                outcome = .failure(.failed("余额数据为空"))
                return
            }
            if let code = envelope.biz_code, code != 0 {
                if code == 40002 || code == 40003 {
                    outcome = .failure(.invalidToken)
                } else {
                    outcome = .failure(.failed(envelope.biz_msg ?? "接口返回 \(code)"))
                }
                return
            }
            guard let biz = envelope.biz_data else {
                outcome = .failure(.failed("余额数据为空"))
                return
            }

            let normalWallets = biz.normal_wallets ?? []
            let bonusWallets = biz.bonus_wallets ?? []
            let currency = normalWallets.first?.currency
                ?? bonusWallets.first?.currency
                ?? "CNY"

            let normal = normalWallets
                .filter { ($0.currency ?? "CNY") == currency }
                .reduce(0.0) { $0 + (Double($1.balance?.value ?? "0") ?? 0) }
            let bonus = bonusWallets
                .filter { ($0.currency ?? "CNY") == currency }
                .reduce(0.0) { $0 + (Double($1.balance?.value ?? "0") ?? 0) }
            let totalCost = (biz.total_costs ?? [])
                .filter { ($0.currency ?? "CNY") == currency }
                .reduce(0.0) { $0 + (Double($1.amount?.value ?? "0") ?? 0) }

            outcome = .success(
                BalanceSnapshot(currency: currency, normal: normal, bonus: bonus, totalCost: totalCost)
            )
        }.resume()

        semaphore.wait()
        return outcome
    }
}

final class BalanceStore: ObservableObject {
    static let shared = BalanceStore()

    enum State {
        case idle
        case loading
        case ready
        case needsLogin
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var snapshot: BalanceSnapshot?

    private var lastLoaded = Date.distantPast
    private var activeToken: String?
    private var generation = 0

    func refresh(token: String?, force: Bool = false) {
        let cleaned = token.map { OfficialAccountsFile.cleanToken($0) }
        let next = (cleaned?.isEmpty ?? true) ? nil : cleaned

        if activeToken != next {
            activeToken = next
            snapshot = nil
            lastLoaded = Date.distantPast
            state = next == nil ? .needsLogin : .loading
            generation += 1
        } else if !force, Date().timeIntervalSince(lastLoaded) < 60 {
            return
        }

        guard let next else {
            state = .needsLogin
            snapshot = nil
            return
        }

        generation += 1
        let currentGeneration = generation
        if snapshot == nil { state = .loading }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = BalanceLoader.load(token: next)
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.lastLoaded = Date()

                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.state = .ready
                    NotificationCenter.default.post(name: .dsBalanceUpdated, object: nil)
                case .failure(.invalidToken):
                    self.snapshot = nil
                    self.state = .needsLogin
                case .failure:
                    self.state = .failed
                }
            }
        }
    }
}

// MARK: - 开机启动

enum LoginItem {
    static let label = "local.deepseekcost"

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isOn: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func set(_ enabled: Bool) {
        if enabled != isOn {
            toggle()
        }
    }

    static func toggle() {
        if isOn {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(executable)</string><string>--background</string></array>
          <key>RunAtLoad</key><true/>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """

        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? plist.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 本机用量

extension Notification.Name {
    static let dsUsageRefresh = Notification.Name("DeepSeekCostUsageRefresh")
    static let dsResizePopover = Notification.Name("DeepSeekCostResizePopover")
    static let dsShowWindow = Notification.Name("DeepSeekCostShowWindow")
    static let dsBalanceUpdated = Notification.Name("DeepSeekCostBalanceUpdated")
    static let dsCheckUpdates = Notification.Name("DeepSeekCostCheckUpdates")
    static let dsDataRestored = Notification.Name("DeepSeekCostDataRestored")
    static let dsPricingChanged = Notification.Name("DeepSeekCostPricingChanged")
    static let dsRingStyleChanged = Notification.Name("DeepSeekCostRingStyleChanged")
}

struct UsageBucket {
    var hit: Int64 = 0
    var miss: Int64 = 0
    var output: Int64 = 0
    var cost: Double = 0
    var savedFlash: Double = 0
    var savedPro: Double = 0

    var tokens: Int64 { hit + miss + output }
}

struct ApiUsage: Identifiable {
    let provider: String
    let model: String
    var bucket: UsageBucket

    var id: String { "\(provider)|\(model)" }
}

struct UsageSet {
    var apis: [String: ApiUsage] = [:]

    var all: UsageBucket {
        apis.values.reduce(into: UsageBucket()) { result, api in
            result.hit += api.bucket.hit
            result.miss += api.bucket.miss
            result.output += api.bucket.output
            result.cost += api.bucket.cost
            result.savedFlash += api.bucket.savedFlash
            result.savedPro += api.bucket.savedPro
        }
    }

    var providers: [String] {
        Array(Set(apis.values.map { $0.provider })).sorted()
    }

    func entries(source: String) -> [ApiUsage] {
        let list = source == "all"
            ? Array(apis.values)
            : apis.values.filter { $0.provider == source }
        return list
            .filter { $0.bucket.tokens > 0 || $0.bucket.cost > 0 }
            .sorted { lhs, rhs in
                if lhs.bucket.tokens == rhs.bucket.tokens {
                    return lhs.model < rhs.model
                }
                return lhs.bucket.tokens > rhs.bucket.tokens
            }
    }

    func bucket(source: String) -> UsageBucket {
        entries(source: source).reduce(into: UsageBucket()) { result, api in
            result.hit += api.bucket.hit
            result.miss += api.bucket.miss
            result.output += api.bucket.output
            result.cost += api.bucket.cost
            result.savedFlash += api.bucket.savedFlash
            result.savedPro += api.bucket.savedPro
        }
    }
}

struct DailyRate: Identifiable {
    let date: Date
    let provider: String
    var model: String? = nil
    var hit: Int64 = 0
    var miss: Int64 = 0
    var output: Int64 = 0

    var id: String { "\(provider)|\(date.timeIntervalSince1970)" }

    var rate: Double? {
        let total = hit + miss
        guard total > 0 else { return nil }
        return Double(hit) / Double(total)
    }
}

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L.t("全部", "All")
        case .today: return L.t("今日", "Today")
        case .week: return L.t("近 7 天", "7 days")
        case .month: return L.t("本月", "This month")
        }
    }
}

enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case numbers
    case bars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .numbers: return L.t("逐行数字", "Rows")
        case .bars: return L.t("并排柱状图", "Bars")
        }
    }
}

enum UsageLoadResult {
    case success(today: UsageSet, week: UsageSet, month: UsageSet, allTime: UsageSet, daily: [DailyRate])
    case unavailable
    case failed
}

enum UsageLoader {
    static func databasePath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            candidates.append((xdg as NSString).appendingPathComponent("opencode/opencode.db"))
        }

        candidates.append(
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/opencode/opencode.db").path
        )
        candidates.append(
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/opencode/opencode.db").path
        )

        return candidates.first { fm.fileExists(atPath: $0) }
    }

    static func load() -> UsageLoadResult {
        guard let path = databasePath() else { return .unavailable }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            return .failed
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)

        let now = Date()
        let cal = Pricing.calendar
        let startToday = cal.startOfDay(for: now)
        let startWeek = cal.date(byAdding: .day, value: -6, to: startToday) ?? startToday
        let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startToday
        let start30 = cal.date(byAdding: .day, value: -29, to: startToday) ?? startToday
        let trendStart = min(startMonth, start30)
        let cutoff = Date(timeIntervalSince1970: 0)
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)

        let sql = """
        SELECT time_created,
               json_extract(data, '$.tokens.input'),
               json_extract(data, '$.tokens.output'),
               json_extract(data, '$.tokens.reasoning'),
               json_extract(data, '$.tokens.cache.read'),
               json_extract(data, '$.tokens.cache.write'),
               json_extract(data, '$.model.id'),
               json_extract(data, '$.model.providerID')
        FROM session_message
        WHERE type = 'assistant'
          AND time_created >= ?
          AND json_extract(data, '$.tokens') IS NOT NULL
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            return .failed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)

        var today = UsageSet()
        var week = UsageSet()
        var month = UsageSet()
        var allTime = UsageSet()

        var dailyMap: [String: DailyRate] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let providerText = sqlite3_column_text(stmt, 7) else { continue }
            let provider = String(cString: providerText).lowercased()

            guard let modelText = sqlite3_column_text(stmt, 6) else { continue }
            let modelName = String(cString: modelText)

            // 免费模型不计入用量：OpenCode 免费 provider，以及名字带 -free 的模型
            guard provider != "opencode" else { continue }
            guard !modelName.lowercased().contains("-free") else { continue }

            let tier: Tier = modelName.lowercased().contains("pro") ? .pro : .flash

            let ms = sqlite3_column_int64(stmt, 0)
            let date = Date(timeIntervalSince1970: Double(ms) / 1000)

            let input = max(0, sqlite3_column_int64(stmt, 1))
            let output = max(0, sqlite3_column_int64(stmt, 2))
            let reasoning = max(0, sqlite3_column_int64(stmt, 3))
            let cacheRead = max(0, sqlite3_column_int64(stmt, 4))
            let cacheWrite = max(0, sqlite3_column_int64(stmt, 5))

            let hit = cacheRead
            let miss = input + cacheWrite
            let out = output + reasoning
            guard hit + miss + out > 0 else { continue }

            let isDeepSeek = provider == "deepseek"
            let peak = Pricing.isPeak(date)
            let cost = isDeepSeek
                ? Pricing.cost(tier: tier, peak: peak, hit: hit, miss: miss, output: out)
                : 0
            let savedFlash = isDeepSeek
                ? 0
                : Pricing.cost(tier: .flash, peak: peak, hit: hit, miss: miss, output: out)
            let savedPro = isDeepSeek
                ? 0
                : Pricing.cost(tier: .pro, peak: peak, hit: hit, miss: miss, output: out)

            add(&allTime, provider: provider, model: modelName, hit: hit, miss: miss, output: out, cost: cost, savedFlash: savedFlash, savedPro: savedPro)

            if date >= startToday {
                add(&today, provider: provider, model: modelName, hit: hit, miss: miss, output: out, cost: cost, savedFlash: savedFlash, savedPro: savedPro)
            }
            if date >= startWeek {
                add(&week, provider: provider, model: modelName, hit: hit, miss: miss, output: out, cost: cost, savedFlash: savedFlash, savedPro: savedPro)
            }
            if date >= startMonth {
                add(&month, provider: provider, model: modelName, hit: hit, miss: miss, output: out, cost: cost, savedFlash: savedFlash, savedPro: savedPro)
            }

            if date >= trendStart {
                let day = cal.startOfDay(for: date)
                let key = "\(provider)|\(modelName)|\(day.timeIntervalSince1970)"
                if var entry = dailyMap[key] {
                    entry.hit += hit
                    entry.miss += miss
                    entry.output += out
                    dailyMap[key] = entry
                } else {
                    dailyMap[key] = DailyRate(date: day, provider: provider, model: modelName, hit: hit, miss: miss, output: out)
                }
            }
        }

        let daily = dailyMap.values.sorted { $0.date < $1.date }
        return .success(today: today, week: week, month: month, allTime: allTime, daily: daily)
    }

    private static func add(
        _ set: inout UsageSet,
        provider: String,
        model: String,
        hit: Int64,
        miss: Int64,
        output: Int64,
        cost: Double,
        savedFlash: Double,
        savedPro: Double
    ) {
        let key = "\(provider)|\(model)"
        var api = set.apis[key] ?? ApiUsage(provider: provider, model: model, bucket: UsageBucket())
        add(&api.bucket, hit: hit, miss: miss, output: output, cost: cost, savedFlash: savedFlash, savedPro: savedPro)
        set.apis[key] = api
    }

    private static func add(
        _ bucket: inout UsageBucket,
        hit: Int64,
        miss: Int64,
        output: Int64,
        cost: Double,
        savedFlash: Double,
        savedPro: Double
    ) {
        bucket.hit += hit
        bucket.miss += miss
        bucket.output += output
        bucket.cost += cost
        bucket.savedFlash += savedFlash
        bucket.savedPro += savedPro
    }
}

final class UsageStore: ObservableObject {
    enum State {
        case loading
        case ready
        case unavailable
        case failed
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var today = UsageSet()
    @Published private(set) var week = UsageSet()
    @Published private(set) var month = UsageSet()
    @Published private(set) var allTime = UsageSet()
    @Published private(set) var daily: [DailyRate] = []
    @Published private(set) var providers: [String] = []
    @Published private(set) var loadCount = 0
    @Published var selectedPeriod: UsagePeriod = .month
    @Published var selectedSource: String = UserDefaults.standard.string(forKey: "selectedSource") ?? "official:none" {
        didSet { UserDefaults.standard.set(selectedSource, forKey: "selectedSource") }
    }
    @Published var selectedOfficialAccountID: String = UserDefaults.standard.string(forKey: "selectedOfficialAccountID") ?? "" {
        didSet { UserDefaults.standard.set(selectedOfficialAccountID, forKey: "selectedOfficialAccountID") }
    }
    @Published var showAllRanking = false

    init() {
        if selectedSource.hasPrefix("official:") {
            let id = String(selectedSource.dropFirst("official:".count))
            if id != "none", !id.isEmpty {
                selectedOfficialAccountID = id
            }
            selectedSource = "official"
        }
    }

    private var loading = false
    private var lastLoaded = Date.distantPast

    func refresh(force: Bool = false) {
        if loading { return }
        if !force, Date().timeIntervalSince(lastLoaded) < 20 { return }

        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = UsageLoader.load()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.lastLoaded = Date()

                switch result {
                case .success(let today, let week, let month, let allTime, let daily):
                    self.today = today
                    self.week = week
                    self.month = month
                    self.allTime = allTime
                    self.daily = daily

                    let allProviders = Array(
                        Set(["deepseek"] + today.providers + week.providers + month.providers)
                    ).sorted()
                    self.providers = allProviders
                    let isOfficial = self.selectedSource == "official"
                        || self.selectedSource.hasPrefix("official:")
                    let isLocal = self.selectedSource.hasPrefix("local:")
                    if self.selectedSource != "all",
                       self.selectedSource != "custom",
                       !isOfficial,
                       !isLocal,
                       !allProviders.contains(self.selectedSource) {
                        self.selectedSource = "all"
                    }

                    self.state = .ready
                    self.loadCount += 1
                case .unavailable:
                    self.state = .unavailable
                case .failed:
                    self.state = .failed
                }
            }
        }
    }
}

enum UsageFormat {
    static func tokens(_ value: Int64) -> String {
        if value <= 0 { return "0" }
        if value >= 100_000_000 {
            return String(format: "%.2f 亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1f 万", Double(value) / 10_000)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func money(_ value: Double) -> String {
        let converted = Money.fromCNY(value)
        let digits = converted >= 0.01 ? 2 : 4
        return Money.display(value, digits: digits)
    }
}

// MARK: - 官方用量（按 API Key）

enum TokenFile {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/platform-token")
    }

    static func load() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 官方账号（多账号）

struct OfficialAccount: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var token: String
    /// 旧版字段，仅保留解码兼容；总花费现在始终统计所有已登录账号。
    var countsTowardTotal: Bool

    var sourceID: String { "official:\(id)" }

    init(id: String, name: String, token: String, countsTowardTotal: Bool = true) {
        self.id = id
        self.name = name
        self.token = token
        self.countsTowardTotal = countsTowardTotal
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case token
        case countsTowardTotal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        token = try container.decode(String.self, forKey: .token)
        countsTowardTotal = try container.decodeIfPresent(Bool.self, forKey: .countsTowardTotal) ?? true
    }
}

enum OfficialAccountsFile {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/official-accounts.json")
    }

    static func cleanToken(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst(7))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load() -> [OfficialAccount] {
        if let data = try? Data(contentsOf: fileURL),
           let accounts = try? JSONDecoder().decode([OfficialAccount].self, from: data) {
            return accounts.filter {
                !$0.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        // 从旧版单 Token 文件迁移出一个账号
        guard let legacy = TokenFile.load() else { return [] }
        let token = cleanToken(legacy)
        guard !token.isEmpty, !token.lowercased().hasPrefix("sk-") else { return [] }
        let account = OfficialAccount(id: "default", name: "DeepSeek", token: token)
        save([account])
        return [account]
    }

    @discardableResult
    static func save(_ accounts: [OfficialAccount]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(accounts)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }
}

final class OfficialAccountsStore: ObservableObject {
    @Published private(set) var accounts: [OfficialAccount] = []

    init() {
        accounts = OfficialAccountsFile.load()
        migrateNames()
    }

    private func migrateNames() {
        var changed = false
        for index in accounts.indices {
            if accounts[index].name == "官方账号" {
                accounts[index].name = "DeepSeek"
                changed = true
            } else if accounts[index].name.hasPrefix("官方账号 ") {
                accounts[index].name = "DeepSeek " + accounts[index].name.dropFirst("官方账号 ".count)
                changed = true
            }
        }
        if changed {
            OfficialAccountsFile.save(accounts)
        }
    }

    func reload() {
        accounts = OfficialAccountsFile.load()
        migrateNames()
    }

    var first: OfficialAccount? { accounts.first }

    func account(forSourceID sourceID: String) -> OfficialAccount? {
        if sourceID == "official" { return accounts.first }
        guard sourceID.hasPrefix("official:") else { return nil }
        let id = String(sourceID.dropFirst("official:".count))
        return accounts.first { $0.id == id }
    }

    func account(id: String) -> OfficialAccount? {
        accounts.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, token: String) -> OfficialAccount? {
        let clean = OfficialAccountsFile.cleanToken(token)
        guard !clean.isEmpty, !clean.lowercased().hasPrefix("sk-") else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "DeepSeek \(accounts.count + 1)" : trimmedName
        let account = OfficialAccount(
            id: UUID().uuidString.lowercased(),
            name: finalName,
            token: clean
        )
        accounts.append(account)
        OfficialAccountsFile.save(accounts)
        return account
    }

    func update(id: String, name: String, token: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let clean = OfficialAccountsFile.cleanToken(token)
        guard !clean.isEmpty, !clean.lowercased().hasPrefix("sk-") else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].name = trimmedName.isEmpty ? accounts[index].name : trimmedName
        accounts[index].token = clean
        OfficialAccountsFile.save(accounts)
    }

    func rename(id: String, name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accounts[index].name = trimmed
        OfficialAccountsFile.save(accounts)
    }

    func remove(id: String) {
        accounts.removeAll { $0.id == id }
        OfficialAccountsFile.save(accounts)
    }
}

/// 拉取所有官方账号的历史总花费，用于「总花费」合计。
final class OfficialTotalsStore: ObservableObject {
    @Published private(set) var totals: [String: Double] = [:]

    private var loading = false
    private var lastLoaded = Date.distantPast
    private var generation = 0

    func set(id: String, value: Double) {
        totals[id] = value
    }

    func refresh(accounts: [OfficialAccount], force: Bool = false) {
        guard !accounts.isEmpty else {
            totals = [:]
            return
        }
        if loading { return }
        if !force, Date().timeIntervalSince(lastLoaded) < 120 { return }

        loading = true
        generation += 1
        let currentGeneration = generation
        let snapshot = accounts

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [String: Double] = [:]
            for account in snapshot {
                if case .success(let balance) = BalanceLoader.load(token: account.token) {
                    result[account.id] = balance.totalCost
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.totals.merge(result) { _, new in new }
                self.loading = false
                self.lastLoaded = Date()
            }
        }
    }
}

// MARK: - 手动花费（订阅费 / 一次性）

struct ManualCost: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var amount: Double
    var date: Double
    var recurring: Bool

    var dateValue: Date { Date(timeIntervalSince1970: date) }

    /// 订阅按开始月份累计到当前月；一次性只算一次。
    var chargedMonths: Int {
        guard recurring else { return 1 }
        let calendar = Pricing.calendar
        let start = calendar.startOfDay(for: dateValue)
        let now = Date()
        guard start <= now else { return 0 }
        let months = calendar.dateComponents([.month], from: start, to: now).month ?? 0
        return max(1, months + 1)
    }

    var total: Double { amount * Double(chargedMonths) }
}

enum ManualCostFile {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/manual-costs.json")
    }

    static func load() -> [ManualCost] {
        guard let data = try? Data(contentsOf: fileURL),
              let costs = try? JSONDecoder().decode([ManualCost].self, from: data) else {
            return []
        }
        return costs
    }

    @discardableResult
    static func save(_ costs: [ManualCost]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(costs).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }
}

final class ManualCostStore: ObservableObject {
    static let shared = ManualCostStore()

    @Published private(set) var costs: [ManualCost] = []

    init() {
        costs = ManualCostFile.load()
    }

    func reload() {
        costs = ManualCostFile.load()
    }

    var total: Double {
        costs.reduce(0) { $0 + $1.total }
    }

    @discardableResult
    func add(name: String, amount: Double, date: Date, recurring: Bool) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, amount > 0 else { return false }
        costs.append(
            ManualCost(
                id: UUID().uuidString.lowercased(),
                name: trimmed,
                amount: amount,
                date: date.timeIntervalSince1970,
                recurring: recurring
            )
        )
        costs.sort { $0.date > $1.date }
        ManualCostFile.save(costs)
        return true
    }

    func remove(id: String) {
        costs.removeAll { $0.id == id }
        ManualCostFile.save(costs)
    }
}

struct OfficialKeyUsage: Identifiable {
    let id: String
    var name: String
    var bucket: UsageBucket
    var requests: Int64
}

struct OfficialUsage {
    var keys: [OfficialKeyUsage] = []
    var daily: [DailyRate] = []

    var all: UsageBucket {
        keys.reduce(into: UsageBucket()) { result, key in
            result.hit += key.bucket.hit
            result.miss += key.bucket.miss
            result.output += key.bucket.output
            result.cost += key.bucket.cost
        }
    }

    var ranked: [OfficialKeyUsage] {
        keys.filter { $0.bucket.tokens > 0 || $0.bucket.cost > 0 }
            .sorted { lhs, rhs in
                if lhs.bucket.tokens == rhs.bucket.tokens {
                    return lhs.name < rhs.name
                }
                return lhs.bucket.tokens > rhs.bucket.tokens
            }
    }
}

enum OfficialError: Error {
    case noToken
    case invalidToken
    case failed(String)
}

private struct FlexString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = ""
        } else if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int64.self) {
            value = String(number)
        } else if let number = try? container.decode(Double.self) {
            value = String(number)
        } else {
            value = ""
        }
    }
}

private struct FlexInt: Decodable {
    let value: Int64?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Int64.self) {
            value = number
        } else if let number = try? container.decode(Double.self) {
            value = Int64(number)
        } else if let text = try? container.decode(String.self) {
            value = Int64(text)
        } else {
            value = nil
        }
    }
}

private enum OfficialDTO {
    struct AmountResponse: Decodable {
        let code: Int?
        let msg: String?
        let data: AmountEnvelope?
    }

    struct AmountEnvelope: Decodable {
        let biz_code: Int?
        let biz_msg: String?
        let biz_data: AmountBiz?
    }

    struct AmountBiz: Decodable {
        let series: [AmountSeries]?
    }

    struct AmountSeries: Decodable {
        let api_key: ApiKey?
        let model: String?
        let buckets: [AmountBucket]?
    }

    struct AmountBucket: Decodable {
        let time: FlexInt?
        let usage: AmountUsage?
    }

    struct AmountUsage: Decodable {
        let hit: FlexString?
        let miss: FlexString?
        let response: FlexString?
        let request: FlexString?

        enum CodingKeys: String, CodingKey {
            case hit = "PROMPT_CACHE_HIT_TOKEN"
            case miss = "PROMPT_CACHE_MISS_TOKEN"
            case response = "RESPONSE_TOKEN"
            case request = "REQUEST"
        }
    }

    struct CostResponse: Decodable {
        let code: Int?
        let msg: String?
        let data: CostEnvelope?
    }

    struct CostEnvelope: Decodable {
        let biz_code: Int?
        let biz_msg: String?
        let biz_data: CostBiz?
    }

    struct CostBiz: Decodable {
        let data: [CostCurrency]?
    }

    struct CostCurrency: Decodable {
        let currency: String?
        let series: [CostSeries]?
    }

    struct CostSeries: Decodable {
        let api_key: ApiKey?
        let model: String?
        let buckets: [CostBucket]?
    }

    struct CostBucket: Decodable {
        let time: FlexInt?
        let cost: FlexString?
    }

    struct ApiKey: Decodable {
        let tracking_id: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case tracking_id
            case name
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                tracking_id = try? container.decode(String.self, forKey: .tracking_id)
                name = try? container.decode(String.self, forKey: .name)
            } else {
                let container = try decoder.singleValueContainer()
                tracking_id = nil
                name = try? container.decode(String.self)
            }
        }
    }
}

private struct OfficialErrorEnvelope: Decodable {
    let code: Int?
    let msg: String?
    let data: ErrorData?

    struct ErrorData: Decodable {
        let biz_code: Int?
        let biz_msg: String?
    }
}

enum OfficialUsageLoader {
    private static let base = "https://platform.deepseek.com/api/v0/usage/by_api_key"
    private static let tzOffset = 28_800

    private static func codeError(code: Int, message: String?) -> OfficialError {
        if code == 40003 || code == 401 || code == 403 {
            return .invalidToken
        }
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(text.isEmpty ? "接口返回 \(code)" : text)
    }

    static func load(period: UsagePeriod, token: String) -> Result<OfficialUsage, OfficialError> {
        let cal = Pricing.calendar
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: startToday) else {
            return .failure(.failed("无法读取官方数据"))
        }

        let periodStart: Date
        let periodEnd: Date
        switch period {
        case .all:
            // 官方用量接口单次最多约 31 天，这里取最近 30 天，覆盖当前账户的全部可用记录
            periodStart = cal.date(byAdding: .day, value: -30, to: startToday) ?? startToday
            periodEnd = tomorrow
        case .today:
            periodStart = startToday
            periodEnd = tomorrow
        case .week:
            periodStart = cal.date(byAdding: .day, value: -6, to: startToday) ?? startToday
            periodEnd = tomorrow
        case .month:
            guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
                  let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else {
                return .failure(.failed("无法读取官方数据"))
            }
            periodStart = monthStart
            periodEnd = monthEnd
        }

        // 每日趋势覆盖本月 / 近 30 天，但官方接口单次最多约 31 天；
        // 月初选「本月」时两者叠加会超过上限（INVALID_PARAM），这里收敛到 30 天。
        let earliest = cal.date(byAdding: .day, value: -30, to: periodEnd) ?? periodStart
        let anchorMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startToday
        let start30 = cal.date(byAdding: .day, value: -29, to: startToday) ?? startToday
        let dailyStart = max(min(anchorMonth, start30), earliest)
        let queryStart = max(min(periodStart, dailyStart), earliest)
        let startSec = Int(queryStart.timeIntervalSince1970)
        let endSec = Int(periodEnd.timeIntervalSince1970)
        let periodStartSec = Int(periodStart.timeIntervalSince1970)
        let periodEndSec = Int(periodEnd.timeIntervalSince1970)
        let dailyStartSec = Int(dailyStart.timeIntervalSince1970)
        let dailyEndSec = Int(tomorrow.timeIntervalSince1970)

        let amountResult: Result<OfficialDTO.AmountResponse, OfficialError> = fetch(
            path: "amount", start: startSec, end: endSec, token: token
        )
        guard case .success(let amountResponse) = amountResult else {
            if case .failure(let error) = amountResult { return .failure(error) }
            return .failure(.failed("无法读取官方数据"))
        }
        if let code = amountResponse.code, code != 0 {
            return .failure(codeError(code: code, message: amountResponse.msg))
        }
        guard let amountEnvelope = amountResponse.data else { return .failure(.failed("无法读取官方数据")) }
        if let code = amountEnvelope.biz_code, code != 0 {
            return .failure(codeError(code: code, message: amountEnvelope.biz_msg))
        }
        guard let amountBiz = amountEnvelope.biz_data else { return .failure(.failed("无法读取官方数据")) }

        let costResult: Result<OfficialDTO.CostResponse, OfficialError> = fetch(
            path: "cost", start: startSec, end: endSec, token: token
        )
        var costMap: [String: Double] = [:]
        if case .success(let costResponse) = costResult {
            if let code = costResponse.code, code != 0 {
                return .failure(codeError(code: code, message: costResponse.msg))
            }
            if let costEnvelope = costResponse.data {
                if let code = costEnvelope.biz_code, code != 0 {
                    return .failure(codeError(code: code, message: costEnvelope.biz_msg))
                }
                let currencies = costEnvelope.biz_data?.data ?? []
                let currency = currencies.first { ($0.currency ?? "").uppercased() == "CNY" }
                    ?? currencies.first
                for series in currency?.series ?? [] {
                    guard let key = series.api_key else { continue }
                    let id = key.tracking_id ?? key.name ?? "unknown"
                    for bucket in series.buckets ?? [] {
                        guard let time = bucket.time?.value else { continue }
                        let sec = time > 10_000_000_000 ? time / 1000 : time
                        guard sec >= periodStartSec, sec < periodEndSec else { continue }
                        costMap[id, default: 0] += Double(bucket.cost?.value ?? "0") ?? 0
                    }
                }
            }
        } else if case .failure(.invalidToken) = costResult {
            return .failure(.invalidToken)
        }

        var keyMap: [String: OfficialKeyUsage] = [:]
        var dailyMap: [Date: (hit: Int64, miss: Int64, output: Int64)] = [:]

        for series in amountBiz.series ?? [] {
            guard let key = series.api_key else { continue }
            let rawName = key.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = rawName.isEmpty ? "未命名 Key" : rawName
            let id = key.tracking_id ?? name

            for bucket in series.buckets ?? [] {
                guard let time = bucket.time?.value else { continue }
                let sec = time > 10_000_000_000 ? time / 1000 : time
                guard sec >= dailyStartSec, sec < dailyEndSec else { continue }

                let usage = bucket.usage
                let hit = Int64(usage?.hit?.value ?? "0") ?? 0
                let miss = Int64(usage?.miss?.value ?? "0") ?? 0
                let output = Int64(usage?.response?.value ?? "0") ?? 0
                let requests = Int64(usage?.request?.value ?? "0") ?? 0

                let date = Date(timeIntervalSince1970: TimeInterval(sec))
                let day = cal.startOfDay(for: date)
                var dayValue = dailyMap[day] ?? (hit: 0, miss: 0, output: 0)
                dayValue.hit += hit
                dayValue.miss += miss
                dayValue.output += output
                dailyMap[day] = dayValue

                guard sec >= periodStartSec, sec < periodEndSec else { continue }

                var entry = keyMap[id] ?? OfficialKeyUsage(
                    id: id, name: name, bucket: UsageBucket(), requests: 0
                )
                entry.bucket.hit += hit
                entry.bucket.miss += miss
                entry.bucket.output += output
                entry.requests += requests
                keyMap[id] = entry
            }
        }

        for (id, cost) in costMap {
            if var entry = keyMap[id] {
                entry.bucket.cost = cost
                keyMap[id] = entry
            }
        }

        var daily: [DailyRate] = []
        let dayCount = max(1, (cal.dateComponents([.day], from: dailyStart, to: startToday).day ?? 6) + 1)
        for offset in 0..<dayCount {
            guard let date = cal.date(byAdding: .day, value: offset, to: dailyStart) else { continue }
            let day = cal.startOfDay(for: date)
            let value = dailyMap[day] ?? (hit: 0, miss: 0, output: 0)
            daily.append(
                DailyRate(date: day, provider: "official", hit: value.hit, miss: value.miss, output: value.output)
            )
        }

        return .success(OfficialUsage(keys: Array(keyMap.values), daily: daily))
    }

    private static func fetch<T: Decodable>(
        path: String,
        start: Int,
        end: Int,
        token: String
    ) -> Result<T, OfficialError> {
        var components = URLComponents(string: "\(base)/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "end", value: "\(end)"),
            URLQueryItem(name: "tz", value: "\(tzOffset)"),
        ]
        guard let url = components.url else { return .failure(.failed("请求地址无效")) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.deepseek.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "x-client-version")
        request.setValue("1.0.0", forHTTPHeaderField: "x-app-version")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, OfficialError> = .failure(.failed("网络请求失败"))

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    outcome = .failure(.invalidToken)
                    return
                }
                if !(200...299).contains(http.statusCode) {
                    outcome = .failure(.failed("HTTP \(http.statusCode)"))
                    return
                }
            }

            guard error == nil, let data else {
                outcome = .failure(.failed(error?.localizedDescription ?? "网络请求失败"))
                return
            }

            do {
                outcome = .success(try JSONDecoder().decode(T.self, from: data))
            } catch {
                if let envelope = try? JSONDecoder().decode(OfficialErrorEnvelope.self, from: data) {
                    let code = envelope.data?.biz_code ?? envelope.code
                    if code == 40003 {
                        outcome = .failure(.invalidToken)
                        return
                    }
                    let message = envelope.data?.biz_msg ?? envelope.msg
                    if let message, !message.isEmpty {
                        outcome = .failure(.failed(message))
                        return
                    }
                }
                outcome = .failure(.failed("返回数据解析失败"))
            }
        }.resume()

        semaphore.wait()
        return outcome
    }
}

final class OfficialLoginWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var timer: Timer?
    private var finished = false
    private let onToken: (String) -> Void
    private let onClose: () -> Void

    init(onToken: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onToken = onToken
        self.onClose = onClose

        let configuration = WKWebViewConfiguration()
        // 每次添加账号都用一个全新的会话，避免复用浏览器里已经登录的账号
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        window.title = L.t("登录 DeepSeek 官方（登录后自动获取 Token）", "Sign in to DeepSeek (token is read automatically)")
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        webView.autoresizingMask = [.width, .height]
        webView.load(URLRequest(url: URL(string: "https://platform.deepseek.com/usage")!))

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkToken()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    private func checkToken() {
        guard !finished else { return }
        let script = "(function(){try{var v=JSON.parse(localStorage.getItem('userToken')).value;return v||null;}catch(e){return null;}})()"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, !self.finished,
                  let token = result as? String,
                  !token.isEmpty else { return }
            self.finished = true
            self.timer?.invalidate()
            self.timer = nil
            self.onToken(token)
            self.window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if !finished {
            finished = true
            onClose()
        }
    }
}

final class OfficialStore: ObservableObject {
    enum State: Equatable {
        case needsToken
        case loading
        case ready
        case invalidToken
        case failed(String)
    }

    @Published private(set) var state: State = .needsToken
    @Published private(set) var usage = OfficialUsage()
    @Published var expandedKeyID: String?
    @Published private(set) var hasToken = false
    @Published private(set) var activeAccountID: String?

    private var token: String?
    private var lastLoaded = Date.distantPast
    private var lastPeriod: UsagePeriod?
    private var generation = 0

    func configure(account: OfficialAccount?) {
        let newID = account?.id
        let newToken = account.map { OfficialAccountsFile.cleanToken($0.token) }
        if activeAccountID == newID, token == newToken { return }

        activeAccountID = newID
        token = (newToken?.isEmpty ?? true) ? nil : newToken
        hasToken = token != nil
        usage = OfficialUsage()
        expandedKeyID = nil
        lastLoaded = Date.distantPast
        lastPeriod = nil
        generation += 1
        state = token == nil ? .needsToken : .loading
    }

    func refresh(period: UsagePeriod, force: Bool = false) {
        guard let token else {
            state = .needsToken
            return
        }
        if !force, lastPeriod == period, Date().timeIntervalSince(lastLoaded) < 60 {
            return
        }

        generation += 1
        let currentGeneration = generation
        if state != .ready { state = .loading }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OfficialUsageLoader.load(period: period, token: token)
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.lastLoaded = Date()
                self.lastPeriod = period

                switch result {
                case .success(let usage):
                    self.usage = usage
                    if let expanded = self.expandedKeyID,
                       !usage.keys.contains(where: { $0.id == expanded }) {
                        self.expandedKeyID = nil
                    }
                    self.state = .ready
                case .failure(.invalidToken):
                    self.state = .invalidToken
                case .failure(.noToken):
                    self.state = .needsToken
                case .failure(.failed(let message)):
                    self.state = .failed(message)
                }
            }
        }
    }

}

// MARK: - 自定义 App 用量

struct CustomAppUsage: Identifiable {
    let app: String
    var bucket: UsageBucket

    var id: String { app }
}

struct CustomUsage {
    var apps: [String: UsageBucket] = [:]

    var all: UsageBucket {
        apps.values.reduce(into: UsageBucket()) { result, bucket in
            result.hit += bucket.hit
            result.miss += bucket.miss
            result.output += bucket.output
            result.cost += bucket.cost
        }
    }

    var ranked: [CustomAppUsage] {
        apps.map { CustomAppUsage(app: $0.key, bucket: $0.value) }
            .filter { $0.bucket.tokens > 0 || $0.bucket.cost > 0 }
            .sorted { lhs, rhs in
                if lhs.bucket.tokens == rhs.bucket.tokens {
                    return lhs.app < rhs.app
                }
                return lhs.bucket.tokens > rhs.bucket.tokens
            }
    }
}

struct CustomSnapshot {
    var all = CustomUsage()
    var today = CustomUsage()
    var week = CustomUsage()
    var month = CustomUsage()
    var daily: [DailyRate] = []
}

enum CustomUsageFile {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/custom-usage.jsonl")
    }

    static var folderURL: URL {
        fileURL.deletingLastPathComponent()
    }

    private struct ReportRecord: Encodable {
        let app: String
        let time: String
        let model: String
        let hit: Int64
        let miss: Int64
        let output: Int64
        let cost: Double?
    }

    static func report(arguments: [String]) -> Bool {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let app = value("--app")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !app.isEmpty else {
            print("用法：DeepSeekCost --report --app <名称> [--model deepseek-flash] [--hit N] [--miss N] [--output N] [--cost N] [--time ISO8601]")
            return false
        }

        let model = value("--model") ?? "deepseek-flash"
        let hit = Int64(value("--hit") ?? "0") ?? 0
        let miss = Int64(value("--miss") ?? "0") ?? 0
        let output = Int64(value("--output") ?? "0") ?? 0
        let cost = Double(value("--cost") ?? "")
        let time = value("--time") ?? ISO8601DateFormatter().string(from: Date())

        let record = ReportRecord(
            app: app,
            time: time,
            model: model,
            hit: max(0, hit),
            miss: max(0, miss),
            output: max(0, output),
            cost: cost
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(record),
              var line = String(data: data, encoding: .utf8) else {
            return false
        }
        line += "\n"

        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: fileURL, options: .atomic)
            }

            print("已记录：\(app) · \(hit + miss + output) tokens")
            return true
        } catch {
            print("写入失败：\(fileURL.path)")
            return false
        }
    }
}

enum CustomUsageLoader {
    private struct Record: Decodable {
        let app: String?
        let time: String?
        let timestamp: Double?
        let model: String?
        let hit: Int64?
        let miss: Int64?
        let output: Int64?
        let cost: Double?
    }

    static func load(now: Date = Date()) -> CustomSnapshot? {
        guard let content = try? String(contentsOf: CustomUsageFile.fileURL, encoding: .utf8) else {
            return nil
        }
        return parse(content: content, now: now)
    }

    static func parse(content: String, now: Date = Date()) -> CustomSnapshot? {
        let calendar = Pricing.calendar
        let startToday = calendar.startOfDay(for: now)
        guard let startWeek = calendar.date(byAdding: .day, value: -6, to: startToday),
              let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) else {
            return nil
        }
        let start30 = calendar.date(byAdding: .day, value: -29, to: startToday) ?? startToday
        let trendStart = min(startMonth, start30)

        var snapshot = CustomSnapshot()
        var dailyMap: [Date: (hit: Int64, miss: Int64, output: Int64)] = [:]
        var validRecords = 0

        let decoder = JSONDecoder()

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(Record.self, from: data),
                  let app = record.app?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !app.isEmpty else {
                continue
            }

            let hit = max(0, record.hit ?? 0)
            let miss = max(0, record.miss ?? 0)
            let output = max(0, record.output ?? 0)
            guard hit + miss + output > 0 else { continue }

            let date = parseDate(record: record, fallback: now)
            let model = record.model ?? "deepseek-flash"
            let tier: Tier = model.lowercased().contains("pro") ? .pro : .flash
            let cost = record.cost ?? Pricing.cost(
                tier: tier,
                peak: Pricing.isPeak(date),
                hit: hit,
                miss: miss,
                output: output
            )

            let bucket = UsageBucket(hit: hit, miss: miss, output: output, cost: cost)
            validRecords += 1

            add(bucket, app: app, to: &snapshot.all)

            if date >= startToday {
                add(bucket, app: app, to: &snapshot.today)
            }
            if date >= startWeek {
                add(bucket, app: app, to: &snapshot.week)
            }
            if date >= trendStart {
                let day = calendar.startOfDay(for: date)
                if day < tomorrow {
                    var daily = dailyMap[day] ?? (hit: 0, miss: 0, output: 0)
                    daily.hit += hit
                    daily.miss += miss
                    daily.output += output
                    dailyMap[day] = daily
                }
            }
            if date >= startMonth {
                add(bucket, app: app, to: &snapshot.month)
            }
        }

        guard validRecords > 0 else {
            return snapshot
        }

        let dayCount = max(1, (calendar.dateComponents([.day], from: trendStart, to: startToday).day ?? 6) + 1)
        for offset in 0..<dayCount {
            guard let date = calendar.date(byAdding: .day, value: offset, to: trendStart) else { continue }
            let day = calendar.startOfDay(for: date)
            let daily = dailyMap[day] ?? (hit: 0, miss: 0, output: 0)
            snapshot.daily.append(
                DailyRate(date: day, provider: "custom", hit: daily.hit, miss: daily.miss, output: daily.output)
            )
        }

        return snapshot
    }

    private static func add(_ bucket: UsageBucket, app: String, to usage: inout CustomUsage) {
        var current = usage.apps[app] ?? UsageBucket()
        current.hit += bucket.hit
        current.miss += bucket.miss
        current.output += bucket.output
        current.cost += bucket.cost
        usage.apps[app] = current
    }

    private static func parseDate(record: Record, fallback: Date) -> Date {
        if let timestamp = record.timestamp {
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
        }

        if let text = record.time, !text.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Pricing.timeZone
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
        }

        return fallback
    }
}

final class CustomStore: ObservableObject {
    enum State {
        case loading
        case ready
        case empty
        case failed
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var all = CustomUsage()
    @Published private(set) var today = CustomUsage()
    @Published private(set) var week = CustomUsage()
    @Published private(set) var month = CustomUsage()
    @Published private(set) var daily: [DailyRate] = []
    @Published private(set) var loadCount = 0

    private var loading = false
    private var lastLoaded = Date.distantPast

    func refresh(force: Bool = false) {
        if loading { return }
        if !force, Date().timeIntervalSince(lastLoaded) < 20 { return }

        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = CustomUsageLoader.load()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.lastLoaded = Date()

                guard let snapshot else {
                    self.state = .empty
                    return
                }

                self.all = snapshot.all
                self.today = snapshot.today
                self.week = snapshot.week
                self.month = snapshot.month
                self.daily = snapshot.daily

                let isEmpty = snapshot.all.apps.isEmpty
                self.state = isEmpty ? .empty : .ready
                self.loadCount += 1
            }
        }
    }
}

// MARK: - 本地通用来源

struct LocalSourceFailure: Error {
    let message: String
}

struct LocalSource: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var command: String

    var sourceID: String { "local:\(id)" }
}

enum LocalSourcesFile {
    static var folderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/sources")
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/local-sources.json")
    }

    static func dataURL(for id: String) -> URL {
        folderURL.appendingPathComponent("\(id).jsonl")
    }

    static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    static func loadConfigs() -> [LocalSource] {
        guard let data = try? Data(contentsOf: configURL),
              let sources = try? JSONDecoder().decode([LocalSource].self, from: data) else {
            return []
        }
        return sources
    }

    @discardableResult
    static func saveConfigs(_ sources: [LocalSource]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sources).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
            return true
        } catch {
            return false
        }
    }

    static func merged() -> [LocalSource] {
        ensureFolder()
        var list = loadConfigs()
        let known = Set(list.map { $0.id })

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil
        )) ?? []

        for file in files where file.pathExtension.lowercased() == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard !id.isEmpty, !id.hasPrefix("."), !known.contains(id) else { continue }
            list.append(LocalSource(id: id, name: id, command: ""))
        }

        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func run(_ source: LocalSource) -> Result<Void, LocalSourceFailure> {
        let command = source.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .failure(LocalSourceFailure(message: "这个来源还没有配置命令")) }

        ensureFolder()
        let outURL = folderURL.appendingPathComponent(".\(source.id).out")
        let errURL = folderURL.appendingPathComponent(".\(source.id).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return .failure(LocalSourceFailure(message: "无法创建临时文件"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        environment["DS_SOURCE_FILE"] = dataURL(for: source.id).path
        environment["DS_SOURCE_NAME"] = source.name
        environment["DS_SOURCE_ID"] = source.id
        process.environment = environment
        process.standardOutput = outHandle
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            return .failure(LocalSourceFailure(message: "无法启动命令：\(error.localizedDescription)"))
        }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            done.signal()
        }

        if done.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            return .failure(LocalSourceFailure(message: "命令超过 20 秒，已停止"))
        }

        try? outHandle.close()
        try? errHandle.close()

        let output = (try? Data(contentsOf: outURL)) ?? Data()
        let outputText = (String(data: output, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = (try? String(contentsOf: errURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 命令可以直接写入 $DS_SOURCE_FILE。只有 stdout 看起来像 JSONL 时才覆盖文件，
        // 避免脚本打印的日志把数据文件冲掉。
        let targetURL = dataURL(for: source.id)
        if outputText.hasPrefix("{") {
            try? output.write(to: targetURL, options: .atomic)
        } else if !FileManager.default.fileExists(atPath: targetURL.path), !output.isEmpty {
            try? output.write(to: targetURL, options: .atomic)
        }

        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)

        guard process.terminationStatus == 0 else {
            let detail = errorText.isEmpty ? "" : "：\(errorText.prefix(240))"
            return .failure(LocalSourceFailure(message: "命令退出码 \(process.terminationStatus)\(detail)"))
        }
        return .success(())
    }
}

final class LocalSourcesStore: ObservableObject {
    @Published private(set) var sources: [LocalSource] = []

    init() {
        reload()
    }

    func reload() {
        sources = LocalSourcesFile.merged()
    }

    func source(forSourceID sourceID: String) -> LocalSource? {
        guard sourceID.hasPrefix("local:") else { return nil }
        let id = String(sourceID.dropFirst("local:".count))
        return sources.first { $0.id == id }
    }

    func source(id: String) -> LocalSource? {
        sources.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, command: String) -> LocalSource? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        LocalSourcesFile.ensureFolder()
        let source = LocalSource(
            id: UUID().uuidString.lowercased(),
            name: trimmed,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let fileURL = LocalSourcesFile.dataURL(for: source.id)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }

        var configs = LocalSourcesFile.loadConfigs()
        configs.append(source)
        LocalSourcesFile.saveConfigs(configs)
        reload()
        return source
    }

    func update(id: String, name: String, command: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? id : trimmed
        let finalCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        var configs = LocalSourcesFile.loadConfigs()
        if let index = configs.firstIndex(where: { $0.id == id }) {
            configs[index].name = finalName
            configs[index].command = finalCommand
        } else {
            configs.append(LocalSource(id: id, name: finalName, command: finalCommand))
        }
        LocalSourcesFile.saveConfigs(configs)
        reload()
    }

    func remove(_ source: LocalSource) {
        var configs = LocalSourcesFile.loadConfigs()
        configs.removeAll { $0.id == source.id }
        LocalSourcesFile.saveConfigs(configs)
        try? FileManager.default.removeItem(at: LocalSourcesFile.dataURL(for: source.id))
        reload()
    }

    func run(_ source: LocalSource) -> Result<Void, LocalSourceFailure> {
        LocalSourcesFile.run(source)
    }
}

final class LocalUsageStore: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case empty
        case failed(String)
    }

    @Published private(set) var snapshots: [String: CustomSnapshot] = [:]
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var loadCount = 0

    private var running: Set<String> = []

    func snapshot(for id: String) -> CustomSnapshot? {
        snapshots[id]
    }

    func state(for id: String) -> State {
        states[id] ?? .idle
    }

    func loadCached(_ source: LocalSource) {
        guard !running.contains(source.id) else { return }
        let content = try? String(contentsOf: LocalSourcesFile.dataURL(for: source.id), encoding: .utf8)
        if let snapshot = content.flatMap({ CustomUsageLoader.parse(content: $0) }) {
            snapshots[source.id] = snapshot
            states[source.id] = snapshot.all.apps.isEmpty ? .empty : .ready
        } else {
            snapshots[source.id] = CustomSnapshot()
            states[source.id] = .empty
        }
    }

    func refresh(_ source: LocalSource, run: Bool, force: Bool = false) {
        let id = source.id
        guard !running.contains(id) else { return }
        running.insert(id)
        states[id] = .loading

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failure: String?
            if run, !source.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if case .failure(let error) = LocalSourcesFile.run(source) {
                    failure = error.message
                }
            }

            let content = try? String(
                contentsOf: LocalSourcesFile.dataURL(for: id),
                encoding: .utf8
            )
            let snapshot = content.flatMap { CustomUsageLoader.parse(content: $0) }

            DispatchQueue.main.async {
                self.running.remove(id)
                if let snapshot {
                    self.snapshots[id] = snapshot
                } else {
                    self.snapshots[id] = CustomSnapshot()
                }

                if let failure {
                    self.states[id] = .failed(failure)
                } else if let snapshot, !snapshot.all.apps.isEmpty {
                    self.states[id] = .ready
                } else {
                    self.states[id] = .empty
                }
                self.loadCount += 1
            }
        }
    }
}

// MARK: - 检查更新

struct UpdateInfo {
    let version: String
    let pageURL: URL
    let notes: String
}

struct UpdateCheckError: Error {
    let message: String
}

enum UpdateChecker {
    static let repository = "0xTack/TokenPeek"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func check(completion: @escaping (Result<UpdateInfo?, UpdateCheckError>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.failure(UpdateCheckError(message: "更新地址无效")))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("TokenPeek", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(UpdateCheckError(message: "HTTP \(http.statusCode)")))
                return
            }
            guard error == nil, let data else {
                completion(.failure(UpdateCheckError(message: error?.localizedDescription ?? "网络请求失败")))
                return
            }

            struct Release: Decodable {
                let tag_name: String
                let html_url: String
                let body: String?
            }

            guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
                completion(.failure(UpdateCheckError(message: "更新数据解析失败")))
                return
            }

            let remote = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name

            guard compare(remote, currentVersion) > 0,
                  let pageURL = URL(string: release.html_url) else {
                completion(.success(nil))
                return
            }

            completion(.success(UpdateInfo(
                version: remote,
                pageURL: pageURL,
                notes: release.body ?? ""
            )))
        }.resume()
    }

    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b ? 1 : -1 }
        }
        return 0
    }
}

enum LocalSourceAI {
    static func prompt(sourceName: String? = nil) -> String {
        let target = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tool = target.isEmpty ? "我的一个本地 AI 工具" : "「\(target)」"
        let folder = LocalSourcesFile.folderURL.path

        return """
        我在使用 macOS 上的「TokenPeek」，想把\(tool)的用量接入成一个本地数据源。请直接帮我完成，不要只给示例。

        数据目录：\(folder)
        每个来源是一个 .jsonl 文件；App 会自动扫描这个目录，不需要改 App。

        每行一个 JSON，字段如下：
        {"app":"显示名称","time":"2026-11-01T12:00:00+08:00","model":"deepseek-flash","hit":0,"miss":1234,"output":567,"cost":0.01}

        字段说明：
        - app：显示在 App 里的名称，例如 "Claude Code"
        - time：ISO8601，或 "yyyy-MM-dd HH:mm:ss"（北京时间）
        - model：模型名；名字里带 pro 的按 Pro 计价，其余按 Flash
        - hit：缓存命中的输入 token；没有该字段就填 0
        - miss：未命中的输入 token；如果工具只给总输入 token，就全部填这里
        - output：输出 token
        - cost：可选；不填的话 App 会按 DeepSeek 官方价自动计算

        请按这个顺序做：
        1. 找到\(tool)在本机的用量数据（日志、SQLite、配置文件或本地 API），先告诉我数据在哪里、字段怎么对应；
        2. 写一个可重复运行的脚本（Python / Shell / Node 都可以），把历史记录转换成上面的 JSONL；
        3. 脚本不要写入任何 API Key、Cookie 或 Token，也不要上传数据；缺的字段按上面的规则补 0；
        4. 把脚本保存到 \(folder) 下，并立刻运行一次，生成 .jsonl；
        5. 校验每行都是合法 JSON，告诉我文件名、记录条数和总 tokens；
        6. 如果\(tool)根本没有可读的用量数据，请直接说明无法接入，不要编造数据。

        环境变量 DS_SOURCE_FILE 会指向目标文件（如果 App 运行脚本），手动运行时也可以直接用这个目录下的路径。
        """
    }

    static func openChatGPT(sourceName: String? = nil) {
        var components = URLComponents(string: "https://chatgpt.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: prompt(sourceName: sourceName))]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    static func copyPrompt(sourceName: String? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt(sourceName: sourceName), forType: .string)
    }

    static func present(sourceName: String? = nil) {
        AIHelpWindowController.shared.show(sourceName: sourceName)
    }
}

struct AIHelpView: View {
    let sourceName: String?

    @State private var copied = false

    private var prompt: String {
        LocalSourceAI.prompt(sourceName: sourceName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("让 AI 帮我接入新来源", "Let AI add a new source"))
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("1 复制下面的提示词", "1 Copy the prompt below"))
                Text(L.t("2 打开任意一个 AI 网页", "2 Open any AI chat"))
                Text(L.t("3 粘贴发送，等它写完脚本", "3 Paste, send, and let it finish the script"))
                Text(L.t("4 回到 TokenPeek 点刷新", "4 Back in TokenPeek, hit refresh"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            ScrollView {
                Text(prompt)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))

            HStack(spacing: 8) {
                Button(copied ? L.t("已复制", "Copied") : L.t("复制提示词", "Copy prompt")) {
                    LocalSourceAI.copyPrompt(sourceName: sourceName)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("ChatGPT") {
                    NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!)
                }
                .controlSize(.small)

                Button("Claude") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/new")!)
                }
                .controlSize(.small)

                Button("DeepSeek") {
                    NSWorkspace.shared.open(URL(string: "https://chat.deepseek.com/")!)
                }
                .controlSize(.small)

                Spacer()

                Button(L.t("打开来源文件夹", "Open sources")) {
                    LocalSourcesFile.ensureFolder()
                    NSWorkspace.shared.open(LocalSourcesFile.folderURL)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9))
            }
        }
        .padding(20)
        .frame(width: 520)
        .tint(Theme.accent)
    }
}

final class AIHelpWindowController {
    static let shared = AIHelpWindowController()

    private var window: NSWindow?

    func show(sourceName: String?) {
        let host = NSHostingController(rootView: ThemedRoot { AIHelpView(sourceName: sourceName) })
        let window: NSWindow

        if let existing = self.window {
            existing.contentViewController = host
            window = existing
        } else {
            window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        host.view.layoutSubtreeIfNeeded()
        window.title = L.t("让 AI 帮我接入新来源", "Let AI add a new source")
        window.setContentSize(host.view.fittingSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ChangelogView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5"
    }

    private let notes: [(zh: String, en: String)] = [
        ("新增「订阅监控」：任何返回 JSON 的接口都能接入，自动识别字段，显示剩余或已用的百分比",
         "New plan monitoring: plug in any JSON endpoint, detect fields automatically, and show remaining or used percent"),
        ("订阅支持胶囊 / 柱状图两种显示，设置里可切换",
         "Plans can be shown as capsules or bars; switch in Settings"),
        ("面板里订阅与余额合成一块，只留一个刷新按钮，同时刷新两项",
         "Plans and balance share one block with a single refresh button for both"),
        ("「充值」不再常驻，鼠标移到余额行才出现",
         "The top-up button appears only when hovering over the balance row"),
        ("设置里合并成「订阅与花费」，订阅和手动花费放在一起",
         "Settings now groups plans and manual costs under one section"),
        ("修复显示切换后不生效的问题",
         "Fixed display switches not taking effect"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L.t("更新日志", "Changelog"))
                    .font(.system(size: 16, weight: .semibold))
                Text("v\(version)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 7) {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(L.t(notes[index].zh, notes[index].en))
                                .font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)

            HStack {
                Button(L.t("查看历史版本", "Older versions")) {
                    if let url = URL(string: "https://0xtack.github.io/TokenPeek/#changelog") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9))

                Spacer()

                Text("TokenPeek")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Theme.accent)
    }
}

final class ChangelogWindowController {
    static let shared = ChangelogWindowController()

    private var window: NSWindow?

    func show() {
        let host = NSHostingController(rootView: ThemedRoot { ChangelogView() })
        let window: NSWindow

        if let existing = self.window {
            existing.contentViewController = host
            window = existing
        } else {
            window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        host.view.layoutSubtreeIfNeeded()
        window.title = L.t("更新日志", "Changelog")
        window.setContentSize(host.view.fittingSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 时钟

final class ClockModel: ObservableObject {
    @Published var now = Date()
    @Published var target: Date?

    private var timer: AnyCancellable?

    init() {
        target = Pricing.nextChange()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                guard let self else { return }
                self.now = date
                if self.target == nil || (self.target.map { $0 <= date } ?? false) {
                    self.target = Pricing.nextChange(from: date)
                }
            }
    }
}

struct ClockLine: View {
    @StateObject private var clock = ClockModel()

    var body: some View {
        let peak = Pricing.isPeak(clock.now)
        HStack(spacing: 4) {
            if let target = clock.target {
                Text(peak ? L.t("距空闲", "Off-peak in") : L.t("距高峰", "Peak in"))
                Text(Pricing.targetText(target, now: clock.now))
                Text("·").foregroundStyle(.tertiary)
                Text(Pricing.durationText(target.timeIntervalSince(clock.now)))
            } else {
                Text("—")
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .onAppear { clock.start() }
    }
}

final class PeriodModel: ObservableObject {
    @Published var peak = Pricing.isPeak()

    private var timer: AnyCancellable?

    func start() {
        guard timer == nil else { return }
        timer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                guard let self else { return }
                let current = Pricing.isPeak(date)
                if current != self.peak { self.peak = current }
            }
    }
}

// MARK: - 主界面

private final class SubtleMenuButton: NSButton {
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 16
        size.height = 24
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(hovered ? 0.09 : 0.045).setFill()
        path.fill()
        super.draw(dirtyRect)
    }
}

private struct MenuSubmenu {
    let id: String
    let title: String
    let options: [(id: String, title: String)]
}

private struct MenuButton: NSViewRepresentable {
    @Binding var selection: String
    let options: [(id: String, title: String)]
    let footer: String?
    var footerAction: (() -> Void)? = nil
    var footerHelp: String? = nil
    var actions: [(title: String, run: () -> Void)] = []
    var submenu: MenuSubmenu? = nil
    var displayTitle: String? = nil
    let help: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = SubtleMenuButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.isBordered = false
        button.focusRingType = .none
        button.controlSize = .mini
        button.font = .systemFont(ofSize: 11)
        button.imagePosition = .imageTrailing
        let chevron = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        button.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(chevron)
        button.imageScaling = .scaleProportionallyDown
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = displayTitle ?? options.first { $0.id == selection }?.title ?? selection
        button.toolTip = help
        button.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject {
        var parent: MenuButton

        init(_ parent: MenuButton) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()

            if let submenu = parent.submenu {
                let parentItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
                let childMenu = NSMenu()
                if submenu.options.isEmpty {
                    let empty = NSMenuItem(title: L.t("暂无账号", "No accounts"), action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    childMenu.addItem(empty)
                } else {
                    for option in submenu.options {
                        let item = NSMenuItem(
                            title: option.title,
                            action: #selector(selectItem(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = option.id
                        item.state = parent.selection == option.id ? .on : .off
                        childMenu.addItem(item)
                    }
                }
                parentItem.submenu = childMenu
                parentItem.state = parent.selection == submenu.id ? .on : .off
                menu.addItem(parentItem)
            }

            for option in parent.options {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(selectItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                item.state = parent.selection == option.id ? .on : .off
                menu.addItem(item)
            }

            if !parent.actions.isEmpty {
                menu.addItem(.separator())
                for (index, action) in parent.actions.enumerated() {
                    let item = NSMenuItem(
                        title: action.title,
                        action: #selector(runAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = index
                    menu.addItem(item)
                }
            }

            if let footer = parent.footer {
                menu.addItem(.separator())
                let item = NSMenuItem(
                    title: footer,
                    action: parent.footerAction == nil ? nil : #selector(Coordinator.runFooter),
                    keyEquivalent: ""
                )
                item.target = parent.footerAction == nil ? nil : self
                item.toolTip = parent.footerHelp
                menu.addItem(item)
            }

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 4),
                in: sender
            )
        }

        @objc func selectItem(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String else { return }
            parent.selection = id
        }

        @objc func runAction(_ item: NSMenuItem) {
            guard item.tag >= 0, item.tag < parent.actions.count else { return }
            parent.actions[item.tag].run()
        }

        @objc func runFooter() {
            parent.footerAction?()
        }
    }
}

struct UsageTrendChart: View {
    let values: [Double]
    let labels: [String]

    @Environment(\.colorScheme) private var scheme

    private var tint: Color {
        scheme == .dark
            ? Color(red: 0.60, green: 0.67, blue: 0.84)
            : Color(red: 0.45, green: 0.53, blue: 0.75)
    }

    private var maxValue: Double {
        max(1, values.max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Canvas { context, size in
                let topPadding: CGFloat = 4
                let bottomPadding: CGFloat = 2
                let sideInset: CGFloat = 1.5
                let plotHeight = max(1, size.height - topPadding - bottomPadding)
                let plotWidth = max(1, size.width - sideInset * 2)
                guard !values.isEmpty else { return }

                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                context.stroke(
                    baseline,
                    with: .color(Color.secondary.opacity(0.08)),
                    lineWidth: 0.5
                )

                let pointAt: (Int) -> CGPoint = { index in
                    let ratio = values.count == 1 ? 0.5 : CGFloat(values[index] / maxValue)
                    return CGPoint(
                        x: values.count == 1
                            ? size.width / 2
                            : sideInset + CGFloat(index) * plotWidth / CGFloat(values.count - 1),
                        y: topPadding + plotHeight - plotHeight * ratio
                    )
                }

                guard values.count > 1 else {
                    let point = pointAt(0)
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                        with: .color(tint.opacity(0.9))
                    )
                    return
                }

                let points = values.indices.map(pointAt)
                let path = Self.smoothPath(points)

                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height - 1))
                area.addLine(to: points[0])
                area.addPath(path)
                area.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                area.closeSubpath()
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.12), tint.opacity(0.0)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                context.stroke(
                    path,
                    with: .color(tint.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(height: 40)

            HStack(spacing: 0) {
                ForEach(labels.indices, id: \.self) { index in
                    Text(labels[index])
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Monotone cubic interpolation: smooth, but never overshoots the data.
    private static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        path.move(to: points[0])

        let count = points.count
        var deltas = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            deltas[index] = dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }

        var slopes = [CGFloat](repeating: 0, count: count)
        slopes[0] = deltas[0]
        slopes[count - 1] = deltas[count - 2]
        for index in 1..<(count - 1) {
            slopes[index] = deltas[index - 1] * deltas[index] <= 0
                ? 0
                : (deltas[index - 1] + deltas[index]) / 2
        }

        for index in 0..<(count - 1) {
            guard deltas[index] != 0 else {
                slopes[index] = 0
                slopes[index + 1] = 0
                continue
            }
            let start = slopes[index] / deltas[index]
            let end = slopes[index + 1] / deltas[index]
            let magnitude = (start * start + end * end).squareRoot()
            if magnitude > 3 {
                let scale = 3 / magnitude
                slopes[index] = scale * start * deltas[index]
                slopes[index + 1] = scale * end * deltas[index]
            }
        }

        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            let control1 = CGPoint(
                x: points[index].x + dx / 3,
                y: points[index].y + slopes[index] * dx / 3
            )
            let control2 = CGPoint(
                x: points[index + 1].x - dx / 3,
                y: points[index + 1].y - slopes[index + 1] * dx / 3
            )
            path.addCurve(to: points[index + 1], control1: control1, control2: control2)
        }
        return path
    }
}

// MARK: - 通用订阅监控

/// 订阅里的一个额度指标，例如 5 小时 / 本周 / 本月。
struct SubscriptionMetric: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// 接口给的是「已用百分比」
        case usedPercent
        /// 接口给的是「剩余百分比」
        case remainingPercent
        /// 接口分别给「剩余量」和「总量」
        case ratio

        var id: String { rawValue }

        var title: String {
            switch self {
            case .usedPercent: return L.t("已用 %", "Used %")
            case .remainingPercent: return L.t("剩余 %", "Left %")
            case .ratio: return L.t("剩余 / 总量", "Left / total")
            }
        }
    }

    var id = UUID()
    var label = ""
    var kind: Kind = .usedPercent
    /// 百分比路径，或 ratio 模式下的「剩余量」路径
    var path = ""
    /// ratio 模式下的「总量」路径
    var totalPath = ""
    /// 重置时间路径，可选
    var resetPath = ""

    var isReady: Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == .ratio {
            return !totalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    func evaluate(root: Any) -> SubscriptionMetricValue {
        let used: Double?
        let remaining: Double?
        let total: Double?

        switch kind {
        case .usedPercent:
            used = JSONPathLookup.number(path, in: root)
            remaining = nil
            total = nil
        case .remainingPercent:
            let left = JSONPathLookup.number(path, in: root)
            used = left.map { 100 - $0 }
            remaining = nil
            total = nil
        case .ratio:
            let left = JSONPathLookup.number(path, in: root)
            let all = JSONPathLookup.number(totalPath, in: root)
            remaining = left
            total = all
            if let left, let all, all > 0 {
                used = (1 - left / all) * 100
            } else {
                used = nil
            }
        }

        let reset = JSONPathLookup.string(resetPath, in: root).flatMap { ISODateText.parse($0) }
        return SubscriptionMetricValue(
            id: id,
            label: label.isEmpty ? "—" : label,
            usedPercent: used,
            remaining: remaining,
            total: total,
            reset: reset
        )
    }
}

enum SubscriptionAuth: String, Codable, CaseIterable, Identifiable {
    case none
    case bearer
    case header

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L.t("不需要", "None")
        case .bearer: return "Bearer"
        case .header: return L.t("自定义 Header", "Custom header")
        }
    }
}

struct SubscriptionSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var url = ""
    var auth: SubscriptionAuth = .bearer
    var token = ""
    var headerName = "X-API-Key"
    var metrics: [SubscriptionMetric] = []
    var enabled = true

    var isReady: Bool {
        guard enabled,
              let url = URL(string: url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return false }
        return metrics.contains { $0.isReady }
    }
}

struct SubscriptionMetricValue: Identifiable, Equatable {
    let id: UUID
    let label: String
    let usedPercent: Double?
    let remaining: Double?
    let total: Double?
    let reset: Date?

    var remainingPercent: Double? {
        if let remaining, let total, total > 0 {
            return max(0, min(100, remaining / total * 100))
        }
        if let usedPercent {
            return max(0, min(100, 100 - usedPercent))
        }
        return nil
    }

    var used: Double? {
        if let usedPercent { return max(0, min(100, usedPercent)) }
        if let remainingPercent { return 100 - remainingPercent }
        return nil
    }
}

struct SubscriptionResult {
    let values: [SubscriptionMetricValue]
    let error: String?
    let fetchedAt: Date
}

enum ISODateText {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }
}

enum JSONPathLookup {
    static func raw(_ path: String, in root: Any) -> Any? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var current: Any = root
        for part in trimmed.split(separator: ".") {
            let key = String(part)
            if let dict = current as? [String: Any], let next = dict[key] {
                current = next
            } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    static func number(_ path: String, in root: Any) -> Double? {
        guard let value = raw(path, in: root) else { return nil }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func string(_ path: String, in root: Any) -> String? {
        guard let value = raw(path, in: root) else { return nil }
        if let text = value as? String { return text }
        return nil
    }
}

enum AppUserAgent {
    static var value: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "TokenPeek/\(version) (macOS)"
    }
}

enum SubscriptionLoader {
    static func fetch(_ source: SubscriptionSource, completion: @escaping (SubscriptionResult) -> Void) {
        guard let url = URL(string: source.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            completion(SubscriptionResult(
                values: [],
                error: L.t("地址无效", "Invalid URL"),
                fetchedAt: Date()
            ))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppUserAgent.value, forHTTPHeaderField: "User-Agent")

        switch source.auth {
        case .bearer:
            if !source.token.isEmpty {
                request.setValue("Bearer \(source.token)", forHTTPHeaderField: "Authorization")
            }
        case .header:
            if !source.headerName.isEmpty {
                request.setValue(source.token, forHTTPHeaderField: source.headerName)
            }
        case .none:
            break
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(SubscriptionResult(
                    values: [],
                    error: error.localizedDescription,
                    fetchedAt: Date()
                ))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(SubscriptionResult(
                    values: [],
                    error: L.t("没有响应", "No response"),
                    fetchedAt: Date()
                ))
                return
            }
            guard http.statusCode == 200 else {
                completion(SubscriptionResult(
                    values: [],
                    error: L.t("接口返回 \(http.statusCode)", "HTTP \(http.statusCode)"),
                    fetchedAt: Date()
                ))
                return
            }
            guard let data, let root = try? JSONSerialization.jsonObject(with: data) else {
                completion(SubscriptionResult(
                    values: [],
                    error: L.t("返回内容不是 JSON", "Response is not JSON"),
                    fetchedAt: Date()
                ))
                return
            }

            let values = source.metrics.filter { $0.isReady }.map { $0.evaluate(root: root) }
            completion(SubscriptionResult(
                values: values,
                error: values.isEmpty ? L.t("没有可用的指标", "No usable metrics") : nil,
                fetchedAt: Date()
            ))
        }.resume()
    }
}

final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()

    @Published var sources: [SubscriptionSource] = [] {
        didSet { save() }
    }
    @Published private(set) var results: [UUID: SubscriptionResult] = [:]

    private var lastFetch: [UUID: Date] = [:]
    private let minimumInterval: TimeInterval = 60

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeekCost/subscriptions.json")
    }

    init() {
        reload()
    }

    var activeSources: [SubscriptionSource] {
        sources.filter { $0.isReady }
    }

    func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([SubscriptionSource].self, from: data) else {
            return
        }
        sources = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    func add(_ source: SubscriptionSource) {
        sources.append(source)
        refresh(sourceID: source.id, force: true)
    }

    func remove(_ id: UUID) {
        sources.removeAll { $0.id == id }
        results[id] = nil
        lastFetch[id] = nil
    }

    func refresh(force: Bool = false) {
        for source in activeSources {
            refresh(sourceID: source.id, force: force)
        }
    }

    func refresh(sourceID: UUID, force: Bool) {
        guard let source = sources.first(where: { $0.id == sourceID }), source.isReady else { return }
        if !force, let last = lastFetch[sourceID], Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        lastFetch[sourceID] = Date()
        SubscriptionLoader.fetch(source) { [weak self] result in
            DispatchQueue.main.async {
                self?.results[sourceID] = result
            }
        }
    }
}

enum SubscriptionPreset {
    static func opencodeGo() -> SubscriptionSource {
        SubscriptionSource(
            name: "OpenCode Go",
            url: "https://opencode.ai/zen/go/v1/usage",
            auth: .bearer,
            token: localOpenCodeKey() ?? "",
            metrics: [
                SubscriptionMetric(
                    label: "5h",
                    kind: .usedPercent,
                    path: "usage.rolling.percent",
                    resetPath: "usage.rolling.resetsAt"
                ),
                SubscriptionMetric(
                    label: L.t("周", "Wk"),
                    kind: .usedPercent,
                    path: "usage.weekly.percent",
                    resetPath: "usage.weekly.resetsAt"
                ),
                SubscriptionMetric(
                    label: L.t("月", "Mo"),
                    kind: .usedPercent,
                    path: "usage.monthly.percent",
                    resetPath: "usage.monthly.resetsAt"
                ),
            ]
        )
    }

    static func localOpenCodeKey() -> String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/auth.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/auth.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = root["opencode"] as? [String: Any],
                  let key = entry["key"] as? String else { continue }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// 请求一次接口，把里面的数字字段摊平成「路径 → 数值」，让用户直接选。
enum SubscriptionProbe {
    static func fetch(_ source: SubscriptionSource, completion: @escaping ([(String, Double)], String?) -> Void) {
        guard let url = URL(string: source.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            completion([], L.t("地址无效", "Invalid URL"))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppUserAgent.value, forHTTPHeaderField: "User-Agent")
        switch source.auth {
        case .bearer:
            if !source.token.isEmpty { request.setValue("Bearer \(source.token)", forHTTPHeaderField: "Authorization") }
        case .header:
            if !source.headerName.isEmpty { request.setValue(source.token, forHTTPHeaderField: source.headerName) }
        case .none:
            break
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion([], error.localizedDescription)
                return
            }
            guard let data, let root = try? JSONSerialization.jsonObject(with: data) else {
                completion([], L.t("返回内容不是 JSON", "Response is not JSON"))
                return
            }
            var found: [(String, Double)] = []
            flatten(root, prefix: "", depth: 0, into: &found)
            completion(found.sorted { $0.0 < $1.0 }, nil)
        }.resume()
    }

    private static func flatten(_ node: Any, prefix: String, depth: Int, into out: inout [(String, Double)]) {
        guard depth < 5, out.count < 60 else { return }
        if let dict = node as? [String: Any] {
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                flatten(value, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", depth: depth + 1, into: &out)
            }
        } else if let array = node as? [Any] {
            for (index, value) in array.enumerated().prefix(5) {
                flatten(value, prefix: "\(prefix).\(index)", depth: depth + 1, into: &out)
            }
        } else if let number = node as? NSNumber {
            out.append((prefix, number.doubleValue))
        }
    }
}

enum SubscriptionStyle: String, CaseIterable, Identifiable {
    /// 一行胶囊
    case capsule
    /// 横向柱状图（每个指标一行）
    case bars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capsule: return L.t("胶囊", "Capsule")
        case .bars: return L.t("柱状图", "Bars")
        }
    }

    /// 兼容旧值：overview / inline 都归到胶囊
    static func stored(_ raw: String?) -> SubscriptionStyle {
        switch raw {
        case "bars": return .bars
        default: return .capsule
        }
    }
}

enum SubscriptionMode: String, CaseIterable, Identifiable {
    case remaining
    case used

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remaining: return L.t("剩余", "Left")
        case .used: return L.t("已使用", "Used")
        }
    }
}

final class SubscriptionSettings: ObservableObject {
    static let shared = SubscriptionSettings()

    @Published var mode: SubscriptionMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "subscriptionMode") }
    }
    @Published var style: SubscriptionStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "subscriptionStyle") }
    }

    init() {
        let defaults = UserDefaults.standard
        mode = SubscriptionMode(rawValue: defaults.string(forKey: "subscriptionMode") ?? "") ?? .remaining
        style = SubscriptionStyle.stored(defaults.string(forKey: "subscriptionStyle"))
    }
}

struct ContentView: View {
    let onQuit: () -> Void

    @AppStorage("tier") private var tierRaw = Tier.flash.rawValue
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.zh.rawValue
    @AppStorage("currencyMode") private var currencyRaw = DisplayCurrency.cny.rawValue
    @AppStorage("usdRate") private var usdRate = 7.2
    @AppStorage("panelOpacity") private var panelOpacity = 1.0
    @AppStorage("showHeaderSection") private var showHeaderSection = true
    @AppStorage("showPriceSection") private var showPriceSection = true
    @AppStorage("showUsageSection") private var showUsageSection = true
    @AppStorage("showSubscriptions") private var showSubscriptions = true
    @ObservedObject private var subscriptionPrefs = SubscriptionSettings.shared
    @AppStorage("showBalanceSection") private var showBalanceSection = true
    @AppStorage("showFooterSection") private var showFooterSection = true
    @StateObject private var period = PeriodModel()
    @StateObject private var usage = UsageStore()
    @StateObject private var official = OfficialStore()
    @StateObject private var custom = CustomStore()
    @StateObject private var pricing = PricingStore()
    @StateObject private var balance = BalanceStore.shared
    @StateObject private var accounts = OfficialAccountsStore()
    @StateObject private var localSources = LocalSourcesStore()
    @StateObject private var localUsage = LocalUsageStore()
    @StateObject private var manualCosts = ManualCostStore.shared
    @StateObject private var officialTotals = OfficialTotalsStore()
    @StateObject private var subscriptions = SubscriptionStore.shared
    @State private var showSources = ProcessInfo.processInfo.arguments.contains("--sources")
    @State private var hoveringBalance = false
    @State private var pricingRevision = 0
    @AppStorage("usageDisplayMode") private var usageDisplayModeRaw = UsageDisplayMode.numbers.rawValue

    private var tier: Tier { Tier(rawValue: tierRaw) ?? .flash }
    private var peak: Bool { period.peak }

    var body: some View {
        let _ = languageRaw
        let _ = currencyRaw
        let _ = usdRate
        let _ = pricingRevision
        VStack(alignment: .leading, spacing: 0) {
            if showHeaderSection {
                header
                Divider()
            }
            if showPriceSection {
                priceSection
                Divider()
            }
            if showUsageSection {
                usageSection
                Divider()
            }
            if showSubscriptions, !subscriptions.activeSources.isEmpty {
                subscriptionSection
            }
            if showBalanceSection {
                balanceRow
                Divider()
            }
            if showFooterSection {
                footer
            }
        }
        .frame(width: panelWidth)
        .tint(Theme.accent)
        .background(PanelGlassBackground())
        .background(WindowAlphaConfigurator(alpha: panelOpacity))
        .onAppear {
            period.start()
            pricing.refreshIfNeeded()
            localSources.reload()
            normalizeSourceSelection()
            officialTotals.refresh(accounts: accounts.accounts)
            usage.refresh(force: true)
            subscriptions.refresh()
            refreshActiveSource(force: true, runLocal: false)
            UserDefaults.standard.set(Double(panelWidth), forKey: "panelWidth")
            resizeSoon()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dsUsageRefresh)) { _ in
            refreshActiveSource(force: true, runLocal: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dsPricingChanged)) { _ in
            pricingRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .dsDataRestored)) { _ in
            accounts.reload()
            localSources.reload()
            manualCosts.reload()
            custom.refresh(force: true)
            usage.refresh(force: true)
            subscriptions.reload()
            subscriptions.refresh(force: true)
            normalizeSourceSelection()
            official.configure(account: selectedAccount)
            official.refresh(period: usage.selectedPeriod, force: true)
            balance.refresh(token: balanceAccount?.token, force: true)
            officialTotals.refresh(accounts: accounts.accounts, force: true)
            Pricing.loadUserTables()
            AppearanceStore.apply(AppearanceStore.current)
            AppIconStore.apply()
            pricingRevision += 1
            resizeSoon()
        }
        .onChange(of: usage.selectedPeriod) { newPeriod in
            usage.showAllRanking = false
            official.expandedKeyID = nil
            if isOfficialSource {
                official.refresh(period: newPeriod, force: true)
            }
            resizeSoon()
        }
        .onChange(of: usage.selectedSource) { source in
            usage.showAllRanking = false
            official.expandedKeyID = nil
            if isOfficialSource {
                official.configure(account: selectedAccount)
                official.refresh(period: usage.selectedPeriod, force: true)
                balance.refresh(token: selectedAccount?.token, force: true)
            } else {
                if source == "custom" {
                    custom.refresh(force: true)
                } else if let local = selectedLocalSource {
                    localUsage.refresh(local, run: true)
                } else {
                    usage.refresh(force: true)
                }
                balance.refresh(token: balanceAccount?.token, force: true)
            }
            resizeSoon()
        }
        .onChange(of: usage.loadCount) { _ in
            resizeSoon()
        }
        .onChange(of: custom.loadCount) { _ in
            resizeSoon()
        }
        .onChange(of: localUsage.loadCount) { _ in
            resizeSoon()
        }
        .onChange(of: panelWidth) { width in
            UserDefaults.standard.set(Double(width), forKey: "panelWidth")
            resizeSoon()
        }
        .onChange(of: official.state) { _ in
            resizeSoon()
        }
        .onChange(of: accounts.accounts) { _ in
            normalizeSourceSelection()
            officialTotals.refresh(accounts: accounts.accounts, force: true)
            if isOfficialSource {
                official.configure(account: selectedAccount)
                official.refresh(period: usage.selectedPeriod, force: true)
                balance.refresh(token: selectedAccount?.token, force: true)
            }
            resizeSoon()
        }
        .onChange(of: usage.selectedOfficialAccountID) { _ in
            usage.showAllRanking = false
            official.expandedKeyID = nil
            if isOfficialSource {
                official.configure(account: selectedAccount)
                official.refresh(period: usage.selectedPeriod, force: true)
                balance.refresh(token: selectedAccount?.token, force: true)
            }
            resizeSoon()
        }
        .onChange(of: balance.snapshot?.totalCost) { value in
            if let id = selectedAccount?.id, let value {
                officialTotals.set(id: id, value: value)
            }
        }
        .onChange(of: localSources.sources) { _ in
            normalizeSourceSelection()
            resizeSoon()
        }
        .sheet(isPresented: $showSources) {
            SourcesManagerView(
                accounts: accounts,
                localSources: localSources,
                selectedSource: usage.selectedSource,
                selectedOfficialAccountID: usage.selectedOfficialAccountID,
                onSelectSource: { sourceID in
                    if sourceID.hasPrefix("official:") {
                        usage.selectedOfficialAccountID = String(sourceID.dropFirst("official:".count))
                        usage.selectedSource = "official"
                    } else {
                        usage.selectedSource = sourceID
                    }
                    showSources = false
                },
                onClose: { showSources = false }
            )
        }
    }

    // MARK: - 数据源选择

    private var isOfficialSource: Bool {
        usage.selectedSource == "official" || usage.selectedSource.hasPrefix("official:")
    }

    private var selectedAccount: OfficialAccount? {
        accounts.account(id: usage.selectedOfficialAccountID) ?? accounts.first
    }

    private var selectedLocalSource: LocalSource? {
        localSources.source(forSourceID: usage.selectedSource)
    }

    private var balanceAccount: OfficialAccount? {
        selectedAccount ?? accounts.first
    }

    private func normalizeSourceSelection() {
        if usage.selectedSource.hasPrefix("official:") {
            let id = String(usage.selectedSource.dropFirst("official:".count))
            if id != "none", !id.isEmpty, accounts.account(id: id) != nil {
                usage.selectedOfficialAccountID = id
            }
            usage.selectedSource = "official"
        }

        if accounts.accounts.isEmpty {
            if isOfficialSource {
                usage.selectedSource = "official:none"
            }
        } else {
            if usage.selectedSource == "official:none" {
                usage.selectedSource = "official"
            }
            if accounts.account(id: usage.selectedOfficialAccountID) == nil {
                usage.selectedOfficialAccountID = accounts.first?.id ?? ""
            }
        }

        let ids = Set(sourceOptions.map { $0.id })
        if !ids.contains(usage.selectedSource), !isOfficialSource {
            usage.selectedSource = accounts.accounts.isEmpty ? "all" : "official"
        }
    }

    private func refreshActiveSource(force: Bool, runLocal: Bool) {
        if isOfficialSource {
            official.configure(account: selectedAccount)
            official.refresh(period: usage.selectedPeriod, force: force)
            balance.refresh(token: selectedAccount?.token, force: force)
            officialTotals.refresh(accounts: accounts.accounts, force: force)
        } else if usage.selectedSource == "custom" {
            custom.refresh(force: force)
            balance.refresh(token: balanceAccount?.token, force: force)
        } else if let local = selectedLocalSource {
            localUsage.refresh(local, run: runLocal)
            balance.refresh(token: balanceAccount?.token, force: force)
        } else {
            usage.refresh(force: force)
            balance.refresh(token: balanceAccount?.token, force: force)
        }
    }

    private func resizeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: .dsResizePopover, object: nil)
        }
    }

    private var panelWidth: CGFloat {
        let visible = [
            showHeaderSection,
            showPriceSection,
            showUsageSection,
            showSubscriptions,
            showBalanceSection,
            showFooterSection,
        ].filter { $0 }.count
        let base: CGFloat = showPriceSection ? 305 : (showUsageSection ? 310 : 250)
        switch visible {
        case 0, 1, 2: return base
        case 3: return base + 10
        case 4: return 345
        default: return 380
        }
    }

    private func spendSlices() -> (slices: [SpendSlice], note: String?) {
        struct Item {
            var name: String
            var amount: Double
            var manual: Bool
        }

        var items: [Item] = []

        func add(_ name: String, _ amount: Double, manual: Bool = false) {
            guard amount > 0.0001 else { return }
            if let index = items.firstIndex(where: { $0.name == name }) {
                if manual && !items[index].manual {
                    items[index].amount = amount
                    items[index].manual = true
                } else if !manual && items[index].manual {
                    return
                } else {
                    items[index].amount += amount
                }
            } else {
                items.append(Item(name: name, amount: amount, manual: manual))
            }
        }

        let officialAccounts = accounts.accounts.filter {
            !$0.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasOfficial = !officialAccounts.isEmpty

        for account in officialAccounts {
            let amount = officialTotals.totals[account.id]
                ?? (account.id == selectedAccount?.id ? balance.snapshot?.totalCost : nil)
                ?? 0
            add(account.name, amount)
        }

        if case .ready = usage.state {
            var openCodeCost = usage.allTime.bucket(source: "all").cost
            if hasOfficial {
                openCodeCost -= usage.allTime.bucket(source: "deepseek").cost
            }
            add("OpenCode", openCodeCost)
        }
        if case .ready = custom.state {
            add(L.t("自定义 App", "Custom app"), custom.all.all.cost)
        }
        for source in localSources.sources {
            if let snapshot = localUsage.snapshot(for: source.id) {
                add(source.name, snapshot.all.all.cost)
            }
        }

        for cost in manualCosts.costs {
            let name = cost.name.trimmingCharacters(in: .whitespacesAndNewlines)
            add(name.isEmpty ? L.t("手动记录", "Manual record") : name, cost.total, manual: true)
        }

        let slices = items.enumerated().map { index, item in
            SpendSlice(
                id: "\(index)-\(item.name)",
                name: item.name,
                amount: item.amount,
                color: SpendBreakdown.palette[index % SpendBreakdown.palette.count]
            )
        }

        let note = hasOfficial
            ? L.t(
                "OpenCode 的 DeepSeek 部分已排除，避免与 DeepSeek 账号重复计算",
                "OpenCode DeepSeek usage is excluded to avoid double counting with official accounts"
            )
            : nil

        return (slices, note)
    }

    private func openSpendBreakdown() {
        let data = spendSlices()
        SpendChartWindowController.shared.show(slices: data.slices, note: data.note)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(peak ? Color.orange : Color.green)
                    Text(peak ? L.t("高峰时段", "Peak hours") : L.t("空闲时段", "Off-peak"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(peak ? L.t("标准价", "Standard") : L.t("5 折", "50% off"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((peak ? Color.orange : Color.green).opacity(0.15)))
                        .foregroundStyle(peak ? Color.orange : Color.green)
                }
                ClockLine()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var priceSection: some View {
        let off = Pricing.price(tier, peak: false)
        let pk = Pricing.price(tier, peak: true)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("DeepSeek 模型价格", "DeepSeek pricing"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $tierRaw) {
                    ForEach(Tier.allCases) { item in
                        Text(item.name).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)
            }

            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    Text(Money.currency.priceUnit)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.leading)
                    Text(L.t("空闲", "Off-peak"))
                        .font(.system(size: 11, weight: peak ? .regular : .bold))
                        .foregroundStyle(peak ? Color.secondary : Color.green)
                        .frame(width: 66, alignment: .trailing)
                    Text(L.t("高峰", "Peak"))
                        .font(.system(size: 11, weight: peak ? .bold : .regular))
                        .foregroundStyle(peak ? Color.orange : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
                GridRow {
                    Text(L.t("缓存命中", "Cache hit")).font(.system(size: 12)).gridColumnAlignment(.leading)
                    Text(Money.price(off.hit))
                        .font(.system(size: 12, weight: peak ? .regular : .semibold, design: .monospaced))
                        .foregroundStyle(peak ? Color.secondary : Color.primary)
                        .frame(width: 66, alignment: .trailing)
                    Text(Money.price(pk.hit))
                        .font(.system(size: 12, weight: peak ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(peak ? Color.primary : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
                GridRow {
                    Text(L.t("缓存未命中", "Cache miss")).font(.system(size: 12)).gridColumnAlignment(.leading)
                    Text(Money.price(off.miss))
                        .font(.system(size: 12, weight: peak ? .regular : .semibold, design: .monospaced))
                        .foregroundStyle(peak ? Color.secondary : Color.primary)
                        .frame(width: 66, alignment: .trailing)
                    Text(Money.price(pk.miss))
                        .font(.system(size: 12, weight: peak ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(peak ? Color.primary : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
                GridRow {
                    Text(L.t("输出", "Output")).font(.system(size: 12)).gridColumnAlignment(.leading)
                    Text(Money.price(off.output))
                        .font(.system(size: 12, weight: peak ? .regular : .semibold, design: .monospaced))
                        .foregroundStyle(peak ? Color.secondary : Color.primary)
                        .frame(width: 66, alignment: .trailing)
                    Text(Money.price(pk.output))
                        .font(.system(size: 12, weight: peak ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(peak ? Color.primary : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
            }

            HStack(spacing: 5) {
                Text("\(tier.modelID) · " + Money.currency.name)
                Spacer()

                if pricing.updating {
                    ProgressView()
                        .controlSize(.mini)
                } else if pricing.updateFailed {
                    Text(L.t("更新失败", "Update failed"))
                        .foregroundStyle(.red)
                }

                Button {
                    pricing.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("立即检查官方定价")

                if Pricing.hasUserTables {
                    Text(L.t("自定义", "Custom"))
                        .foregroundStyle(Theme.accent)
                        .help(L.t("当前使用设置里的自定义价格", "Using custom prices from Settings"))
                }

                Text(priceUpdatedText)
                    .help("每月自动检查官方定价页")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var priceUpdatedText: String {
        guard let date = pricing.lastUpdated else { return "内置价格" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return L.t("价格", "Price") + " \(formatter.string(from: date))"
    }

    private var selectedUsage: UsageSet {
        switch usage.selectedPeriod {
        case .all: return usage.allTime
        case .today: return usage.today
        case .week: return usage.week
        case .month: return usage.month
        }
    }

    private func localBucket(_ period: UsagePeriod) -> UsageBucket {
        let set: UsageSet
        switch period {
        case .all: set = usage.allTime
        case .today: set = usage.today
        case .week: set = usage.week
        case .month: set = usage.month
        }
        return set.bucket(source: usage.selectedSource)
    }

    private func periodTitle(_ period: UsagePeriod) -> String {
        // 官方接口单次最多约 31 天，这里的「全部」只能覆盖最近 30 天
        if isOfficialSource, period == .all {
            return L.t("近 30 天", "Last 30 days")
        }
        return period.title
    }

    private var sourceAllTimeSpend: Double? {
        if isOfficialSource {
            let officialAccounts = accounts.accounts.filter {
                !$0.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if officialAccounts.isEmpty { return 0 }
            var total = 0.0
            var found = false
            for account in officialAccounts {
                if let value = officialTotals.totals[account.id] {
                    total += value
                    found = true
                } else if account.id == selectedAccount?.id, let snapshot = balance.snapshot {
                    total += snapshot.totalCost
                    found = true
                }
            }
            return found ? total : nil
        }
        if usage.selectedSource == "custom" {
            guard case .ready = custom.state else { return nil }
            return custom.all.all.cost
        }
        if let local = selectedLocalSource {
            guard case .ready = localUsage.state(for: local.id),
                  let snapshot = localUsage.snapshot(for: local.id) else { return nil }
            return snapshot.all.all.cost
        }
        guard case .ready = usage.state else { return nil }
        return usage.allTime.bucket(source: usage.selectedSource).cost
    }

    private var allTimeSpendText: String? {
        let manual = manualCosts.total
        if let base = sourceAllTimeSpend {
            return UsageFormat.money(base + manual)
        }
        if manual > 0 {
            return UsageFormat.money(manual)
        }
        return nil
    }

    private var sourceOptions: [(id: String, title: String)] {
        var options: [(id: String, title: String)] = []

        if customAvailable {
            options.append(("custom", L.t("自定义 App", "Custom app")))
        }
        for source in localSources.sources {
            options.append((source.sourceID, L.t("本地", "Local") + " · " + source.name))
        }

        options.append(("all", L.t("OpenCode · 全部", "OpenCode · All")))
        for provider in usage.providers {
            options.append((provider, "OpenCode · \(providerName(provider))"))
        }
        return options
    }

    private var periodOptions: [(id: String, title: String)] {
        UsagePeriod.allCases.map { (id: $0.rawValue, title: periodTitle($0)) }
    }

    private var subscriptionStyle: SubscriptionStyle { subscriptionPrefs.style }

    private var subscriptionMode: SubscriptionMode { subscriptionPrefs.mode }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(subscriptions.activeSources) { source in
                subscriptionRow(source)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .frame(minHeight: subscriptionStyle == .bars ? 54 : 20, alignment: .leading)
    }

    private func subscriptionRow(_ source: SubscriptionSource) -> some View {
        let result = subscriptions.results[source.id]
        let values = result?.values ?? []
        let title = source.name.isEmpty ? L.t("订阅", "Plan") : source.name
        let isFirst = subscriptions.activeSources.first?.id == source.id
        let refreshButton = Button {
            balance.refresh(token: balanceAccount?.token, force: true)
            subscriptions.refresh(force: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L.t("刷新余额与订阅", "Refresh balance and plans"))

        return Group {
            if subscriptionStyle == .bars {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if isFirst {
                            refreshButton
                        }
                    }

                    if values.isEmpty {
                        Text(result?.error ?? L.t("读取中…", "Loading…"))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        subscriptionBars(values)
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, 8)

                    if values.isEmpty {
                        Text(result?.error ?? L.t("读取中…", "Loading…"))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        ForEach(values) { value in
                            subscriptionCapsule(value.label, value, ghost: false)
                        }
                    }

                    Spacer(minLength: 2)
                    if isFirst {
                        refreshButton
                    }
                }
            }
        }
    }

    private func subscriptionBars(_ values: [SubscriptionMetricValue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values) { value in
                let percent = subscriptionMode == .used ? value.used : value.remainingPercent
                HStack(spacing: 6) {
                    Text(value.label)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(subscriptionColor(percent).opacity(0.45))
                                .frame(width: max(2, geometry.size.width * CGFloat(percent ?? 0) / 100))
                        }
                    }
                    .frame(height: 4)

                    Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
    }

    private func subscriptionCapsule(_ label: String, _ value: SubscriptionMetricValue, ghost: Bool) -> some View {
        let percent = subscriptionMode == .used ? value.used : value.remainingPercent
        let rounded = percent.map { Int($0.rounded()) }
        let color = subscriptionColor(percent)

        return HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .opacity(0.8)
            Text(rounded.map { "\($0)%" } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(ghost ? Color.primary.opacity(0.05) : color.opacity(0.10), in: Capsule())
        .foregroundStyle(ghost ? Color.secondary : color.opacity(0.88))
    }

    private func subscriptionColor(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        if subscriptionMode == .used {
            if percent >= 90 { return .red }
            if percent >= 70 { return .orange }
            return Theme.accent
        }
        if percent <= 10 { return .red }
        if percent <= 30 { return .orange }
        return Theme.accent
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L.t("我的用量", "My usage"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                MenuButton(
                    selection: Binding(
                        get: { isOfficialSource ? "official" : usage.selectedSource },
                        set: { id in
                            if id == "official:none" {
                                showSources = true
                                return
                            }
                            if id.hasPrefix("official:") {
                                usage.selectedOfficialAccountID = String(id.dropFirst("official:".count))
                                usage.selectedSource = "official"
                            } else {
                                usage.selectedSource = id
                            }
                        }
                    ),
                    options: sourceOptions,
                    footer: nil,
                    actions: [
                        ("管理账号与来源", { showSources = true }),
                        ("让 AI 帮我接入新来源", { LocalSourceAI.present() })
                    ],
                    submenu: MenuSubmenu(
                        id: "official",
                        title: "DeepSeek",
                        options: accounts.accounts.isEmpty
                            ? [("official:none", L.t("＋ 添加账号", "＋ Add account"))]
                            : accounts.accounts.map { ($0.sourceID, $0.name) }
                    ),
                    displayTitle: isOfficialSource
                        ? (selectedAccount?.name ?? "DeepSeek")
                        : nil,
                    help: "DeepSeek：每个账号单独统计；本地来源：读取 sources 文件夹里的 jsonl；OpenCode：本机 OpenCode 记录"
                )
                .fixedSize()

                MenuButton(
                    selection: Binding(
                        get: { usage.selectedPeriod.rawValue },
                        set: { raw in
                            if let period = UsagePeriod(rawValue: raw) {
                                usage.selectedPeriod = period
                            }
                        }
                    ),
                    options: periodOptions,
                    footer: allTimeSpendText.map { L.t("总花费", "Total spent") + "    \($0)" },
                    footerAction: { openSpendBreakdown() },
                    footerHelp: L.t("点击查看花费构成", "Click to view the spending breakdown"),
                    help: "统计区间：今日 / 近 7 天 / 本月（自然月，月初重置）/ 全部。下方「总花费」为有史以来的累计花费"
                )
                .fixedSize()

                Spacer()
                Button {
                    refreshActiveSource(force: true, runLocal: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新用量")
            }

            if isOfficialSource {
                officialSection
            } else if usage.selectedSource == "custom" {
                customSection
            } else if let local = selectedLocalSource {
                localSection(local)
            } else {
                switch usage.state {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L.t("读取中…", "Loading…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                case .ready:
                    if usageDisplayMode == .bars {
                        summaryBars(showCost: sourceHasCost) { localBucket($0) }
                    } else {
                        ForEach([UsagePeriod.today, .week, .month, .all]) { period in
                            usageRow(
                                period.title,
                                localBucket(period),
                                showCost: sourceHasCost,
                                saved: savedAmount(localBucket(period))
                            )
                        }
                    }

                    if sourceHasCost {
                        HStack(spacing: 4) {
                            Text(L.t("本地模型已省", "Saved on local models"))
                                .foregroundStyle(.secondary)
                            Text(UsageFormat.money(totalSaved))
                                .fontWeight(.semibold)
                                .foregroundStyle(totalSaved > 0 ? .green : .secondary)
                            Text(L.t("按 \(tier.name) 价", "at \(tier.name) pricing"))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .font(.system(size: 10))
                        .monospacedDigit()
                    }

                    if !sourceEntries.isEmpty {
                        Text(L.t("API 用量", "API usage") + " · \(periodTitle(usage.selectedPeriod))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)

                        ForEach(Array(displayedSourceEntries.enumerated()), id: \.element.id) { index, api in
                            rankingRow(index + 1, api)
                        }

                        rankingToggle(sourceEntries.count)
                        trendBlock
                    } else if !hasAnyUsage {
                        usageEmptyCard(
                            title: L.t("还没有接入用量数据", "No usage data yet"),
                            detail: L.t("先在 OpenCode 里对话几轮，或接入一个来源", "Have a few turns in OpenCode, or connect a source")
                        )
                    } else {
                        Text(L.t("该时段还没有用量", "No usage in this period"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    hitRateBlock
                case .unavailable:
                    usageZeroState(
                        L.t("还没有接入用量数据", "No usage data yet"),
                        L.t("先在 OpenCode 里对话几轮，或接入一个来源", "Have a few turns in OpenCode, or connect a source")
                    )
                case .failed:
                    usageZeroState(
                        L.t("用量读取失败", "Failed to read usage"),
                        L.t("点右上角刷新重试，或先接入一个来源", "Refresh to retry, or connect a source first")
                    )
                }
            }

            HStack(spacing: 6) {
                Text(sourceNote)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isOfficialSource {
                    Button(L.t("管理账号", "Manage accounts")) { showSources = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 空状态

    /// 该来源在所有区间都没有用量。
    private var hasAnyUsage: Bool {
        [UsagePeriod.today, .week, .month, .all].contains { localBucket($0).tokens > 0 }
    }

    private func usageEmptyCard(title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L.t("接入来源", "Add source")) { showSources = true }
                Button(L.t("刷新", "Refresh")) { refreshActiveSource(force: true, runLocal: true) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
        }
        .frame(maxWidth: .infinity, minHeight: 172)
    }

    /// 完全读不到数据时：保留完整行结构，避免面板塌缩。
    private func usageZeroState(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach([UsagePeriod.today, .week, .month, .all]) { period in
                usageRow(period.title, UsageBucket(), showCost: sourceHasCost)
            }

            if sourceHasCost {
                HStack(spacing: 4) {
                    Text(L.t("本地模型已省", "Saved on local models"))
                        .foregroundStyle(.secondary)
                    Text("—")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                    Text(L.t("按 \(tier.name) 价", "at \(tier.name) pricing"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.system(size: 10))
                .monospacedDigit()
            }

            usageEmptyCard(title: title, detail: detail)
            hitRateBlock
        }
    }

    private var sourceEntries: [ApiUsage] {
        selectedUsage.entries(source: usage.selectedSource)
    }

    private var displayedSourceEntries: [ApiUsage] {
        usage.showAllRanking ? sourceEntries : Array(sourceEntries.prefix(3))
    }

    private var officialEntries: [OfficialKeyUsage] {
        official.usage.ranked
    }

    private var displayedOfficialEntries: [OfficialKeyUsage] {
        usage.showAllRanking ? officialEntries : Array(officialEntries.prefix(3))
    }

    private var displayedCustomEntries: [CustomAppUsage] {
        usage.showAllRanking ? customEntries : Array(customEntries.prefix(3))
    }

    private var sourceBucket: UsageBucket {
        selectedUsage.bucket(source: usage.selectedSource)
    }

    private var sourceHasCost: Bool {
        usage.selectedSource == "all" || usage.selectedSource == "deepseek"
    }

    private var usageDisplayMode: UsageDisplayMode {
        UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .numbers
    }

    private var trendAccent: Color {
        Color(red: 0.60, green: 0.67, blue: 0.84)
    }

    private func summaryBars(showCost: Bool, _ bucket: (UsagePeriod) -> UsageBucket) -> some View {
        let periods = UsagePeriod.allCases
        let buckets = periods.map(bucket)
        let values = buckets.map { showCost ? $0.cost : Double($0.tokens) }
        let maxValue = max(values.max() ?? 1, 1)

        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(periods.indices, id: \.self) { index in
                VStack(spacing: 3) {
                    Text(showCost
                         ? UsageFormat.money(buckets[index].cost)
                         : UsageFormat.tokens(buckets[index].tokens))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(trendAccent.opacity(index == periods.count - 1 ? 0.42 : 0.22))
                        .frame(height: max(2, 26 * values[index] / maxValue))

                    Text(periods[index].title)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 54)
        .padding(.vertical, 2)
    }

    private var sourceNote: String {
        if isOfficialSource {
            var note = L.t(
                "数据来自 DeepSeek 网页接口，按 API Key 排名；Token 只存本机文件（600 权限）",
                "Data comes from the official web API, ranked by API key; the token is stored locally only (mode 600)"
            )
            if usage.selectedPeriod == .all {
                note += L.t(
                    " 接口单次最多约 31 天，故「全部」为近 30 天",
                    " The API allows about 31 days per request, so \"All\" means the last 30 days"
                )
            }
            return note
        }
        if usage.selectedSource == "custom" {
            return L.t(
                "自定义 App：读取本地 custom-usage.jsonl，用 --report 或脚本写入",
                "Custom app: reads local custom-usage.jsonl, written by --report or a script"
            )
        }
        if let local = selectedLocalSource {
            return L.t(
                "本地来源「\(local.name)」：读取 sources/\(local.id).jsonl；点右上角刷新会先运行命令",
                "Local source \"\(local.name)\": reads sources/\(local.id).jsonl; Refresh runs the command first"
            )
        }
        return L.t(
            "费用只统计 DeepSeek；Ollama 等本地模型按 DeepSeek 同档价格折算「已省」，仅供参考",
            "Cost only counts DeepSeek; local models such as Ollama are priced at the same tier to estimate savings"
        )
    }

    private var customAvailable: Bool {
        FileManager.default.fileExists(atPath: CustomUsageFile.fileURL.path)
    }

    private func savedAmount(_ bucket: UsageBucket) -> Double {
        tier == .pro ? bucket.savedPro : bucket.savedFlash
    }

    private var totalSaved: Double {
        tier == .pro ? selectedUsage.all.savedPro : selectedUsage.all.savedFlash
    }

    private func providerName(_ provider: String) -> String {
        switch provider {
        case "deepseek": return "DeepSeek"
        case "ollama": return "Ollama"
        case "opencode": return "免费模型"
        default: return provider.capitalized
        }
    }

    private func usageRow(
        _ label: String,
        _ bucket: UsageBucket,
        showCost: Bool = true,
        saved: Double = 0
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 112, alignment: .leading)
            Text(showCost ? UsageFormat.money(bucket.cost) : (saved > 0 ? "省 \(UsageFormat.money(saved))" : "—"))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Spacer()
            Text("\(UsageFormat.tokens(bucket.tokens)) tokens")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func rankingToggle(_ count: Int) -> some View {
        if count > 3 {
            Button(usage.showAllRanking ? L.t("收起", "Collapse") : L.t("展开全部 \(count) 个", "Show all \(count)")) {
                usage.showAllRanking.toggle()
                resizeSoon()
            }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundStyle(Color.accentColor)
            .padding(.top, 1)
        }
    }

    private func rankingRow(_ rank: Int, _ api: ApiUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(rank == 1 ? Color.orange : Color.secondary)
                .frame(width: 12)
            Text(api.model)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(api.model)
            if usage.selectedSource == "all" {
                Text("·")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(providerName(api.provider))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(api.provider == "deepseek"
                 ? UsageFormat.money(api.bucket.cost)
                 : (savedAmount(api.bucket) > 0 ? "省 \(UsageFormat.money(savedAmount(api.bucket)))" : "—"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text(UsageFormat.tokens(api.bucket.tokens))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch custom.state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("读取自定义用量…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .empty:
                Text("还没有自定义 App 用量")
                    .font(.system(size: 11, weight: .semibold))
                Text("用 --report 上报，或写入 custom-usage.jsonl")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(L.t("打开文件夹", "Open folder")) {
                        try? FileManager.default.createDirectory(
                            at: CustomUsageFile.folderURL,
                            withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(CustomUsageFile.folderURL)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button("刷新") { custom.refresh(force: true) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            case .failed:
                Text("读取失败，可点右上角刷新")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .ready:
                if usageDisplayMode == .bars {
                    summaryBars(showCost: true) { customBucket(for: $0) }
                } else {
                    ForEach([UsagePeriod.today, .week, .month, .all]) { period in
                        usageRow(period.title, customBucket(for: period))
                    }
                }

                if !customEntries.isEmpty {
                    Text("App 用量 · \(periodTitle(usage.selectedPeriod))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)

                    ForEach(Array(displayedCustomEntries.enumerated()), id: \.element.id) { index, app in
                        customAppRow(index + 1, app)
                    }

                    rankingToggle(customEntries.count)
                    trendBlock
                } else {
                    Text("该时段没有自定义用量")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                hitRateBlock
            }
        }
    }

    private func customAppRow(_ rank: Int, _ app: CustomAppUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(rank == 1 ? Color.orange : Color.secondary)
                .frame(width: 12)
            Text(app.app)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(UsageFormat.money(app.bucket.cost))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text(UsageFormat.tokens(app.bucket.tokens))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func localSection(_ source: LocalSource) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch localUsage.state(for: source.id) {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.t("读取本地来源…", "Loading local source…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .empty:
                Text("「\(source.name)」还没有数据")
                    .font(.system(size: 11, weight: .semibold))
                Text(source.command.isEmpty
                     ? "把一个 .jsonl 放进 sources 文件夹，或让 AI 帮你写接入脚本"
                     : "点右上角刷新会运行命令并读取 sources/\(source.id).jsonl")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(L.t("刷新并运行", "Refresh & run")) {
                        localUsage.refresh(source, run: true)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button(L.t("打开文件夹", "Open folder")) {
                        LocalSourcesFile.ensureFolder()
                        NSWorkspace.shared.open(LocalSourcesFile.folderURL)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button(L.t("AI 帮我接入", "Add with AI")) {
                        LocalSourceAI.openChatGPT(sourceName: source.name)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            case .failed(let message):
                Text(L.t("读取失败", "Failed") + "：\(message)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L.t("重试", "Retry")) { localUsage.refresh(source, run: true) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Button(L.t("打开文件夹", "Open folder")) {
                        LocalSourcesFile.ensureFolder()
                        NSWorkspace.shared.open(LocalSourcesFile.folderURL)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            case .ready:
                if usageDisplayMode == .bars {
                    summaryBars(showCost: true) { localBucket(source.id, period: $0) }
                } else {
                    ForEach([UsagePeriod.today, .week, .month, .all]) { period in
                        usageRow(period.title, localBucket(source.id, period: period))
                    }
                }

                let entries = localUsageSet(source.id, period: usage.selectedPeriod).ranked
                if !entries.isEmpty {
                    Text(L.t("来源明细", "Details") + " · \(periodTitle(usage.selectedPeriod))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)

                    ForEach(Array(entries.prefix(usage.showAllRanking ? entries.count : 3).enumerated()), id: \.element.id) { index, app in
                        customAppRow(index + 1, app)
                    }

                    rankingToggle(entries.count)
                    trendBlock
                } else {
                    Text(L.t("该时段没有本地用量", "No local usage in this period"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                hitRateBlock
            }
        }
    }

    private var officialSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch official.state {
            case .needsToken:
                tokenSetup(invalid: false)
            case .invalidToken:
                tokenSetup(invalid: true)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.t("读取 DeepSeek 用量…", "Loading DeepSeek usage…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(L.t("读取失败", "Failed") + "：\(message)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L.t("重试", "Retry")) {
                        official.refresh(period: usage.selectedPeriod, force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(L.t("管理账号", "Manage accounts")) { showSources = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            case .ready:
                usageRow(periodTitle(usage.selectedPeriod), official.usage.all)

                if !officialEntries.isEmpty {
                    Text(L.t("API Key 用量", "API key usage") + " · \(periodTitle(usage.selectedPeriod))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)

                    ForEach(Array(displayedOfficialEntries.enumerated()), id: \.element.id) { index, key in
                        officialKeyRow(index + 1, key)
                    }

                    rankingToggle(officialEntries.count)
                    trendBlock
                } else {
                    Text(L.t("该时段没有 DeepSeek 用量", "No DeepSeek usage in this period"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                hitRateBlock
            }
        }
    }

    private func hitRate(_ bucket: UsageBucket) -> Double? {
        let total = bucket.hit + bucket.miss
        guard total > 0 else { return nil }
        return Double(bucket.hit) / Double(total)
    }

    private func officialKeyRow(_ rank: Int, _ key: OfficialKeyUsage) -> some View {
        let rate = hitRate(key.bucket)
        let expanded = official.expandedKeyID == key.id

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rank)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(rank == 1 ? Color.orange : Color.secondary)
                    .frame(width: 12)
                Text(key.name)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(key.name)
                Spacer(minLength: 3)
                Text(rateText(rate))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(rateColor(rate))
                    .frame(width: 38, alignment: .trailing)
                    .help(L.t("命中率 = 命中 ÷（命中 + 未命中）", "Hit rate = hits ÷ (hits + misses)"))

                Text(UsageFormat.money(key.bucket.cost))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)

                Text(UsageFormat.tokens(key.bucket.tokens))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 54, alignment: .trailing)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                official.expandedKeyID = expanded ? nil : key.id
                resizeSoon()
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text("命中 \(UsageFormat.tokens(key.bucket.hit))")
                        Text("未命中 \(UsageFormat.tokens(key.bucket.miss))")
                    }
                    HStack(spacing: 10) {
                        Text("输出 \(UsageFormat.tokens(key.bucket.output))")
                        Text("请求 \(key.requests) 次")
                    }
                }
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.leading, 19)
                .padding(.bottom, 2)
            }
        }
    }

    private func tokenSetup(invalid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(invalid
                 ? "账号登录已过期"
                 : (selectedAccount == nil ? "还没有 DeepSeek 账号" : "这个账号还没有 Token"))
                .font(.system(size: 11, weight: .semibold))

            Text("在「管理账号与来源」里添加 DeepSeek 账号，支持多个账号分别统计。Token 只存本机文件（600 权限），App 不会保存密码")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(selectedAccount == nil ? "添加 DeepSeek 账号…" : "重新登录 / 更换 Token…") {
                showSources = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var activeBucket: UsageBucket {
        if isOfficialSource { return official.usage.all }
        if let local = selectedLocalSource {
            return localBucket(local.id, period: usage.selectedPeriod)
        }
        if usage.selectedSource == "custom" { return customBucket }
        return sourceBucket
    }

    private var activeDaily: [DailyRate] {
        if isOfficialSource { return official.usage.daily }
        if let local = selectedLocalSource {
            return localUsage.snapshot(for: local.id)?.daily ?? []
        }
        if usage.selectedSource == "custom" { return custom.daily }
        return dailyRates
    }

    private func localUsageSet(_ id: String, period: UsagePeriod) -> CustomUsage {
        let snapshot = localUsage.snapshot(for: id) ?? CustomSnapshot()
        switch period {
        case .all: return snapshot.all
        case .today: return snapshot.today
        case .week: return snapshot.week
        case .month: return snapshot.month
        }
    }

    private func localBucket(_ id: String, period: UsagePeriod) -> UsageBucket {
        localUsageSet(id, period: period).all
    }

    private func localBucket(for period: UsagePeriod) -> UsageBucket {
        guard let local = selectedLocalSource else { return UsageBucket() }
        return localBucket(local.id, period: period)
    }

    private var customUsage: CustomUsage {
        switch usage.selectedPeriod {
        case .all: return custom.all
        case .today: return custom.today
        case .week: return custom.week
        case .month: return custom.month
        }
    }

    private var customBucket: UsageBucket {
        customUsage.all
    }

    private func customBucket(for period: UsagePeriod) -> UsageBucket {
        switch period {
        case .all: return custom.all.all
        case .today: return custom.today.all
        case .week: return custom.week.all
        case .month: return custom.month.all
        }
    }

    private var customEntries: [CustomAppUsage] {
        customUsage.ranked
    }

    private var selectedRate: Double? {
        let bucket = activeBucket
        let total = bucket.hit + bucket.miss
        guard total > 0 else { return nil }
        return Double(bucket.hit) / Double(total)
    }

    /// 按当前命中率和当前时段价格，估算每百万输入 token 的均价。
    private var predictedInputPrice: Double? {
        guard let rate = selectedRate else { return nil }
        let price = Pricing.price(tier, peak: peak)
        return price.hit * rate + price.miss * (1 - rate)
    }

    private var predictedPriceHelp: String {
        let price = Pricing.price(tier, peak: peak)
        let window = peak ? L.t("高峰", "peak") : L.t("空闲", "off-peak")
        return L.t(
            "按当前命中率估算的输入均价（\(Money.currency.name)/百万 tokens）：命中 \(Money.price(price.hit)) × 命中率 + 未命中 \(Money.price(price.miss)) × 未命中率。\(window) · \(tier.name)",
            "Estimated average input price (\(Money.currency.code) / 1M tokens): hit \(Money.price(price.hit)) × hit rate + miss \(Money.price(price.miss)) × miss rate. \(window) · \(tier.name)"
        )
    }

    private var dailyRates: [DailyRate] {
        let source = usage.selectedSource
        let filtered = usage.daily.filter { source == "all" || $0.provider == source }
        let cal = Pricing.calendar

        var byDay: [Date: (hit: Int64, miss: Int64, output: Int64)] = [:]
        for item in filtered {
            let day = cal.startOfDay(for: item.date)
            var aggregate = byDay[day] ?? (hit: 0, miss: 0, output: 0)
            aggregate.hit += item.hit
            aggregate.miss += item.miss
            aggregate.output += item.output
            byDay[day] = aggregate
        }

        let today = cal.startOfDay(for: Date())
        var result: [DailyRate] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let aggregate = byDay[date] ?? (hit: 0, miss: 0, output: 0)
            result.append(
                DailyRate(date: date, provider: source, hit: aggregate.hit, miss: aggregate.miss, output: aggregate.output)
            )
        }
        return result
    }

    private var trendDays: [Date] {
        let cal = Pricing.calendar
        let today = cal.startOfDay(for: Date())
        switch usage.selectedPeriod {
        case .today:
            return []
        case .week:
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0 - 6, to: today) }
        case .month:
            guard let start = cal.date(from: cal.dateComponents([.year, .month], from: today)) else {
                return []
            }
            let count = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
            return (0..<max(count, 1)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        case .all:
            return (0..<30).compactMap { cal.date(byAdding: .day, value: $0 - 29, to: today) }
        }
    }

    private var trendTitle: String {
        switch usage.selectedPeriod {
        case .today: return L.t("今日趋势", "Today")
        case .week: return L.t("近 7 天趋势", "7-day trend")
        case .month: return L.t("本月趋势", "This month")
        case .all: return L.t("近 30 天趋势", "30-day trend")
        }
    }

    private var trendDailyRecords: [(date: Date, model: String, tokens: Int64)] {
        var records: [(Date, String, Int64)] = []

        if usage.selectedSource == "custom" {
            records = custom.daily.map {
                ($0.date, L.t("自定义 App", "Custom"), $0.hit + $0.miss + $0.output)
            }
        } else if let local = selectedLocalSource {
            if let snapshot = localUsage.snapshot(for: local.id) {
                records = snapshot.daily.map {
                    ($0.date, local.name, $0.hit + $0.miss + $0.output)
                }
            }
        } else if isOfficialSource {
            let name = selectedAccount?.name ?? "DeepSeek"
            records = official.usage.daily.map {
                ($0.date, name, $0.hit + $0.miss + $0.output)
            }
        } else {
            records = usage.daily
                .filter { usage.selectedSource == "all" || $0.provider == usage.selectedSource }
                .map {
                    ($0.date, $0.model ?? $0.provider, $0.hit + $0.miss + $0.output)
                }
        }

        return records.map { (date: $0.0, model: $0.1, tokens: $0.2) }
    }

    private var trendValues: [Double] {
        dailyTokenValues(for: trendDays)
    }

    private var trendLabels: [String] {
        let days = trendDays
        guard !days.isEmpty else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = Pricing.timeZone

        if days.count <= 7 {
            formatter.dateFormat = "EEEEE"
            return days.enumerated().map { index, date in
                index == days.count - 1 ? L.t("今", "Now") : formatter.string(from: date)
            }
        }

        formatter.dateFormat = "d"
        return days.enumerated().map { index, date in
            if index == days.count - 1 { return L.t("今", "Now") }
            return index % 5 == 0 ? formatter.string(from: date) : ""
        }
    }

    @ViewBuilder
    private var trendBlock: some View {
        if usage.selectedPeriod != .today {
            let values = trendValues
            if values.contains(where: { $0 > 0 }) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(trendTitle)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    UsageTrendChart(values: values, labels: trendLabels)
                }
                .padding(.top, 4)
            }
        }
    }

    private func dailyTokenValues(for days: [Date]) -> [Double] {
        let cal = Pricing.calendar
        var values = Array(repeating: 0.0, count: days.count)
        for record in trendDailyRecords {
            guard let index = days.firstIndex(where: { cal.isDate($0, inSameDayAs: record.date) }) else {
                continue
            }
            values[index] += Double(record.tokens)
        }
        return values
    }

    private var hitRateBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .padding(.vertical, 1)

            HStack(alignment: .firstTextBaseline) {
                Text(L.t("缓存命中率", "Cache hit rate"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let predicted = predictedInputPrice {
                    Text("（" + L.t("预测", "est") + " \(UsageFormat.money(predicted))/" + L.t("百万", "1M") + "）")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .help(predictedPriceHelp)
                }
                Spacer()
                Text(rateText(selectedRate))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(rateColor(selectedRate))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(rateColor(selectedRate))
                        .frame(width: geo.size.width * CGFloat(selectedRate ?? 0))
                }
            }
            .frame(height: 5)

            Text(adviceText(for: selectedRate))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 3)
    }

    private func dailyBar(_ day: DailyRate) -> some View {
        let isToday = Pricing.calendar.isDateInToday(day.date)
        return VStack(spacing: 3) {
            Text(day.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            RoundedRectangle(cornerRadius: 2)
                .fill(day.rate == nil ? Color.secondary.opacity(0.12) : rateColor(day.rate))
                .frame(height: CGFloat(max(3.0, 30.0 * (day.rate ?? 0))))
            Text(dayLabel(day.date))
                .font(.system(size: 8, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Color.primary : Color.secondary.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func rateText(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.1f%%", rate * 100)
    }

    private func rateColor(_ rate: Double?) -> Color {
        guard let rate else { return Color.secondary.opacity(0.3) }
        if rate < 0.5 { return Color(nsColor: .systemOrange) }
        return .green
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = Pricing.timeZone
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date)
    }

    private func adviceText(for rate: Double?) -> String {
        guard let rate else {
            return L.t(
                "还没有输入数据；先在 OpenCode 里正常对话几轮再来看",
                "No input data yet. Have a few normal turns in OpenCode first"
            )
        }
        let pct = String(format: "%.1f", rate * 100)
        if rate >= 0.8 {
            return L.t(
                "命中率 \(pct)%：缓存利用良好。继续在同一会话追问，尽量别改动开头的大段上下文",
                "Hit rate \(pct)%: cache use is healthy. Keep asking in the same session and avoid changing the opening context"
            )
        }
        if rate >= 0.5 {
            return L.t(
                "命中率 \(pct)%：还有提升空间。保持会话连续，把稳定内容放前面、变化内容放后面",
                "Hit rate \(pct)%: room to improve. Keep sessions continuous; put stable content first and changing content last"
            )
        }
        return L.t(
            "命中率 \(pct)%：偏低。少频繁新建会话或修改开头提示词，重复的大文件尽量复用同一份上下文",
            "Hit rate \(pct)%: low. Avoid creating sessions too often or editing the opening prompt; reuse the same context for large files"
        )
    }

    private var balanceRow: some View {
        HStack(spacing: 6) {
            Text(L.t("余额", "Balance"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if let snapshot = balance.snapshot {
                Text(balanceText(snapshot))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(snapshot.total < 5 ? Color.red : Color.primary)
                    .help("充值余额 \(balanceMoney(snapshot.normal, currency: snapshot.currency)) · 赠送 \(balanceMoney(snapshot.bonus, currency: snapshot.currency))")
            } else if balance.state == .loading {
                ProgressView()
                    .controlSize(.mini)
            } else if balance.state == .needsLogin {
                Text(L.t("登录后查看", "Sign in to view"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if subscriptions.activeSources.isEmpty {
                Button {
                    balance.refresh(token: balanceAccount?.token, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新余额")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            if hoveringBalance {
                Button(L.t("充值", "Top up")) {
                    NSWorkspace.shared.open(OfficialLinks.topUp)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.trailing, 16)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveringBalance = hovering
            }
        }
    }

    private func balanceText(_ snapshot: BalanceSnapshot) -> String {
        balanceMoney(snapshot.total, currency: snapshot.currency)
    }

    private func balanceMoney(_ value: Double, currency: String) -> String {
        switch currency.uppercased() {
        case "USD":
            return Money.display(value * Money.usdRate)
        case "CNY":
            return Money.display(value)
        default:
            return Money.display(value)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t("高峰：周一至周五 9:00–12:00、14:00–18:00（北京时间，法定节假日除外）", "Peak: Mon–Fri 9:00–12:00 and 14:00–18:00 (Beijing time, public holidays excluded)"))
            Text(L.t("工作日其余时段、周六周日及法定节假日全天为空闲，价格为高峰的 5 折；缓存写入按未命中计", "Other weekday hours, weekends and public holidays are off-peak at 50% of peak price; cache writes count as misses"))
            HStack {
                Button {
                    if let url = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(L.t("价格来源：DeepSeek 官方文档", "Pricing source: DeepSeek docs"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
                Text(Money.currency.name).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

}

struct SettingsView: View {
    let onDockChanged: (Bool) -> Void

    @AppStorage("appLanguage") private var languageRaw = AppLanguage.zh.rawValue
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("currencyMode") private var currencyRaw = DisplayCurrency.cny.rawValue
    @AppStorage("usdRate") private var usdRate = 7.2
    @AppStorage("panelOpacity") private var panelOpacity = 1.0
    @AppStorage("showHeaderSection") private var showHeaderSection = true
    @AppStorage("showPriceSection") private var showPriceSection = true
    @AppStorage("showUsageSection") private var showUsageSection = true
    @AppStorage("showSubscriptions") private var showSubscriptions = true
    @ObservedObject private var subscriptionPrefs = SubscriptionSettings.shared
    @AppStorage("showBalanceSection") private var showBalanceSection = true
    @AppStorage("showFooterSection") private var showFooterSection = true
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("appIcon") private var appIconRaw = AppIconChoice.retro.rawValue
    @AppStorage("statusRingStyle") private var ringStyleRaw = StatusRingStyle.soft.rawValue
    @AppStorage("autoICloudBackup") private var autoICloudBackup = false

    @State private var backupMessage: String?
    @State private var lastBackupDate: Date?
    @State private var showRestoreConfirm = false

    @ObservedObject private var manualCosts = ManualCostStore.shared
    @ObservedObject private var subscriptions = SubscriptionStore.shared
    @State private var costName = ""
    @State private var costAmount = ""
    @State private var costDate = Date()
    @State private var costRecurring = false
    @State private var costError: String?

    @State private var launchAtLogin = LoginItem.isOn
    @State private var showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false

    @State private var probeResults: [UUID: [(String, Double)]] = [:]
    @State private var probeErrors: [UUID: String] = [:]
    @State private var probing: UUID?

    @State private var priceTierRaw = Tier.flash.rawValue
    @State private var priceDraft: [String: String] = [:]
    @State private var priceMessage: String?
    @State private var priceSourceURL = PricingSource.urlString
    @State private var importingPrices = false

    private func subscriptionEditor(_ source: Binding<SubscriptionSource>) -> some View {
        let value = source.wrappedValue
        let detected = probeResults[value.id] ?? []
        let probeError = probeErrors[value.id]

        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                TextField(L.t("名称，例如 Claude Pro", "Name, e.g. Claude Pro"), text: source.name)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 6) {
                    TextField(L.t("接口地址（https）", "Endpoint (https)"), text: source.url)
                        .textFieldStyle(.roundedBorder)

                    Button(probing == value.id ? L.t("识别中…", "Reading…") : L.t("识别字段", "Detect")) {
                        probe(source)
                    }
                    .controlSize(.small)
                    .disabled(probing == value.id)
                }

                if let probeError {
                    Text(probeError)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }

                HStack(spacing: 6) {
                    Picker("", selection: source.auth) {
                        ForEach(SubscriptionAuth.allCases) { auth in
                            Text(auth.title).tag(auth)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if value.auth != .none {
                        SecureField(L.t("Key", "Key"), text: source.token)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if value.auth == .header {
                    TextField(L.t("Header 名称", "Header name"), text: source.headerName)
                        .textFieldStyle(.roundedBorder)
                }

                ForEach(source.metrics) { $metric in
                    metricEditor($metric, source: source, detected: detected)
                }

                HStack(spacing: 8) {
                    Button(L.t("＋ 指标", "＋ Metric")) {
                        source.wrappedValue.metrics.append(SubscriptionMetric(label: ""))
                    }
                    .controlSize(.small)

                    Button(L.t("刷新", "Refresh")) {
                        subscriptions.refresh(sourceID: value.id, force: true)
                    }
                    .controlSize(.small)

                    Spacer()

                    Button {
                        subscriptions.remove(value.id)
                    } label: {
                        Text(L.t("删除", "Delete"))
                    }
                    .controlSize(.small)
                }

                Text(statusText(for: value.id))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(value.name.isEmpty ? L.t("未命名订阅", "Untitled plan") : value.name)
                    .font(.system(size: 11, weight: .medium))
                if !value.enabled {
                    Text(L.t("已关闭", "off"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: source.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .font(.system(size: 11))
    }

    private func metricEditor(
        _ metric: Binding<SubscriptionMetric>,
        source: Binding<SubscriptionSource>,
        detected: [(String, Double)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(L.t("标签", "Label"), text: metric.label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)

                if detected.isEmpty {
                    TextField(L.t("数值路径", "Value path"), text: metric.path)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Menu {
                        ForEach(detected.indices, id: \.self) { index in
                            Button("\(detected[index].0) = \(formatProbe(detected[index].1))") {
                                metric.wrappedValue.path = detected[index].0
                            }
                        }
                    } label: {
                        Text(metric.wrappedValue.path.isEmpty ? L.t("选择字段", "Pick a field") : metric.wrappedValue.path)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)
                }

                Picker("", selection: metric.kind) {
                    ForEach(SubscriptionMetric.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 92)

                Button {
                    let id = metric.wrappedValue.id
                    source.wrappedValue.metrics.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            if metric.wrappedValue.kind == .ratio {
                TextField(L.t("总量路径", "Total path"), text: metric.totalPath)
                    .textFieldStyle(.roundedBorder)
            }

            TextField(L.t("重置时间路径（可选）", "Reset path (optional)"), text: metric.resetPath)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
        }
    }

    private func formatProbe(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.4g", value)
    }

    private func probe(_ source: Binding<SubscriptionSource>) {
        let value = source.wrappedValue
        probing = value.id
        probeErrors[value.id] = nil
        SubscriptionProbe.fetch(value) { paths, error in
            DispatchQueue.main.async {
                probing = nil
                if let error {
                    probeErrors[value.id] = error
                } else if paths.isEmpty {
                    probeErrors[value.id] = L.t("接口里没找到数字字段", "No numeric fields found")
                } else {
                    probeResults[value.id] = paths
                }
            }
        }
    }

    private func statusText(for id: UUID) -> String {
        guard let result = subscriptions.results[id] else {
            return L.t("还没有请求过", "Not fetched yet")
        }
        if let error = result.error {
            return L.t("读取失败：\(error)", "Failed: \(error)")
        }
        let values = result.values.compactMap { value -> String? in
            guard let percent = value.remainingPercent else { return nil }
            return "\(value.label) 剩 \(Int(percent.rounded()))%"
        }
        let time = result.fetchedAt.formatted(date: .omitted, time: .shortened)
        return values.isEmpty
            ? L.t("更新于 \(time)", "Updated \(time)")
            : "\(values.joined(separator: " · "))  ·  \(time)"
    }

    private var ringStyle: StatusRingStyle {
        StatusRingStyle(rawValue: ringStyleRaw) ?? .soft
    }

    private func ringPreviewItem(_ title: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Circle()
                .strokeBorder(color, lineWidth: 2)
                .frame(width: 13, height: 13)
                .frame(width: 18, height: 22)
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        let _ = languageRaw
        let _ = appearanceRaw
        let _ = currencyRaw
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.t("设置", "Settings"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("", selection: $languageRaw) {
                    Text("中文").tag(AppLanguage.zh.rawValue)
                    Text("English").tag(AppLanguage.en.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle(L.t("外观", "Appearance"))

                    VStack(alignment: .leading, spacing: 5) {
                        Picker("", selection: $appearanceRaw) {
                            ForEach(AppAppearance.allCases) { item in
                                Text(L.t(item.zh, item.en)).tag(item.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: appearanceRaw) { raw in
                            AppearanceStore.apply(AppAppearance(rawValue: raw) ?? .system)
                        }
                    }
                    .font(.system(size: 11))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L.t("窗口不透明度", "Window opacity"))
                            Spacer()
                            Text("\(Int((panelOpacity * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $panelOpacity, in: 0.8...1.0, step: 0.01)
                    }
                    .font(.system(size: 11))

                    sectionTitle(L.t("状态圆环", "Status ring"))

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $ringStyleRaw) {
                            ForEach(StatusRingStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: ringStyleRaw) { _ in
                            NotificationCenter.default.post(name: .dsRingStyleChanged, object: nil)
                        }

                        HStack(spacing: 18) {
                            ringPreviewItem(L.t("空闲", "Idle"), ringStyle.idleColor)
                            ringPreviewItem(L.t("高峰", "Peak"), ringStyle.peakColor)
                            ringPreviewItem(L.t("低余额", "Low"), ringStyle.lowColor)
                            Spacer(minLength: 8)
                            Text(ringStyle.detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .font(.system(size: 11))

                    sectionTitle(L.t("应用图标", "App icon"))

                    Picker("", selection: $appIconRaw) {
                        ForEach(AppIconChoice.allCases, id: \.rawValue) { item in
                            Text(L.t(item.zh, item.en)).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: appIconRaw) { raw in
                        if let choice = AppIconChoice(rawValue: raw) {
                            AppIconStore.set(choice)
                        }
                    }

                    Text(L.t("Dock 图标会立即切换；Finder 里的包图标固定为复古版画",
                             "The Dock icon changes immediately; the bundle icon in Finder stays Retro"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    sectionTitle(L.t("计价货币", "Currency"))

                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $currencyRaw) {
                            Text(L.t("人民币", "CNY")).tag(DisplayCurrency.cny.rawValue)
                            Text(L.t("美元", "USD")).tag(DisplayCurrency.usd.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)

                        if currencyRaw == DisplayCurrency.usd.rawValue {
                            HStack(spacing: 6) {
                                Text("1 USD =")
                                TextField("7.20", value: $usdRate, format: .number.precision(.fractionLength(2)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                                Text("CNY")
                            }
                            Text(L.t("只影响显示，内部仍按人民币保存", "Display only; values are stored in CNY"))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11))

                    sectionTitle(L.t("DeepSeek 模型价格", "DeepSeek pricing"))

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Picker("", selection: $priceTierRaw) {
                                ForEach(Tier.allCases) { item in
                                    Text(item.name).tag(item.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 130)

                            Spacer()

                            Text(Money.currency.priceUnit)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }

                        HStack(spacing: 6) {
                            TextField(L.t("价格页网址", "Pricing page URL"), text: $priceSourceURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 9))
                                .onSubmit { importPrices() }

                            if importingPrices {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Button(L.t("识别", "Detect")) { importPrices() }
                                    .controlSize(.small)
                                    .disabled(priceSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }

                        Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 6) {
                            GridRow {
                                Text("")
                                Text(L.t("空闲", "Off-peak"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(L.t("高峰", "Peak"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(priceRows.indices, id: \.self) { index in
                                let row = priceRows[index]
                                GridRow {
                                    Text(L.t(row.zh, row.en))
                                        .font(.system(size: 10))
                                        .gridColumnAlignment(.leading)
                                    priceField("\(priceTierRaw)-\(row.key)Off")
                                    priceField("\(priceTierRaw)-\(row.key)Peak")
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button(L.t("保存价格", "Save prices")) { savePrices() }
                                .controlSize(.small)

                            if Pricing.hasUserTables {
                                Button(L.t("恢复官方价格", "Reset to official")) { resetPrices() }
                                    .controlSize(.small)
                            }

                            Spacer()

                            Button {
                                if let url = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(L.t("价格来源", "Price source"))
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9))
                        }

                        if let priceMessage {
                            Text(priceMessage)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                    .onAppear {
                        priceSourceURL = PricingSource.urlString
                        loadPriceDraft()
                    }
                    .onChange(of: currencyRaw) { _ in loadPriceDraft() }
                    .onChange(of: usdRate) { _ in loadPriceDraft() }
                    .onReceive(NotificationCenter.default.publisher(for: .dsDataRestored)) { _ in
                        loadPriceDraft()
                    }

                    sectionTitle(L.t("显示模块", "Visible sections"))

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L.t("时段与倒计时", "Session & countdown"), isOn: $showHeaderSection)
                        Toggle(L.t("模型价格", "Model pricing"), isOn: $showPriceSection)
                        Toggle(L.t("我的用量", "My usage"), isOn: $showUsageSection)
                        Toggle(L.t("订阅与花费", "Plans & costs"), isOn: $showSubscriptions)
                        Toggle(L.t("余额", "Balance"), isOn: $showBalanceSection)
                        Toggle(L.t("底部说明", "Footer notes"), isOn: $showFooterSection)
                    }
                    .font(.system(size: 11))
                    .onChange(of: showHeaderSection) { _ in notifyResize() }
                    .onChange(of: showPriceSection) { _ in notifyResize() }
                    .onChange(of: showUsageSection) { _ in notifyResize() }
                    .onChange(of: showSubscriptions) { _ in notifyResize() }
                    .onChange(of: showBalanceSection) { _ in notifyResize() }
                    .onChange(of: showFooterSection) { _ in notifyResize() }

                    sectionTitle(L.t("订阅与花费", "Plans & costs"))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Picker("", selection: $subscriptionPrefs.mode) {
                                ForEach(SubscriptionMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Picker("", selection: $subscriptionPrefs.style) {
                                ForEach(SubscriptionStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        .font(.system(size: 11))

                        ForEach($subscriptions.sources) { $source in
                            subscriptionEditor($source)
                        }

                        Menu {
                            Button(L.t("OpenCode Go（已填好）", "OpenCode Go (prefilled)")) {
                                subscriptions.add(SubscriptionPreset.opencodeGo())
                            }
                            Button(L.t("其他服务", "Other service")) {
                                subscriptions.add(
                                    SubscriptionSource(
                                        name: L.t("新订阅", "New plan"),
                                        url: "",
                                        auth: .bearer,
                                        metrics: [
                                            SubscriptionMetric(label: L.t("剩余", "Left"), kind: .remainingPercent)
                                        ]
                                    )
                                )
                            }
                        } label: {
                            Text(L.t("＋ 添加订阅", "＋ Add plan"))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Text(L.t(
                            "订阅只需要一个返回 JSON 的接口。路径按点分层级填写，例如 usage.rolling.percent；数组用数字下标，例如 data.0.left。只做 GET 请求，数据不外传。",
                            "A plan needs any JSON endpoint. Paths are dot separated, e.g. usage.rolling.percent; arrays use indexes, e.g. data.0.left. GET only, nothing is uploaded."
                        ))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Divider().padding(.vertical, 2)

                        Text(L.t("手动花费", "Manual costs"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)


                        VStack(alignment: .leading, spacing: 7) {
                            Text(L.t("订阅费按开始月份累计，一次性花费只计一次；两者都会加入「总花费」",
                                     "Subscriptions accumulate from the start month; one-time costs count once. Both are added to Total spent"))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(manualCosts.costs) { cost in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cost.name)
                                            .font(.system(size: 10.5, weight: .medium))
                                        Text(manualCostDetail(cost))
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(UsageFormat.money(cost.total))
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .monospacedDigit()
                                    Button {
                                        manualCosts.remove(id: cost.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tertiary)
                                    .help(L.t("删除这条花费", "Delete this cost"))
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
                            }

                            if manualCosts.total > 0 {
                                HStack {
                                    Text(L.t("手动合计", "Manual total"))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(UsageFormat.money(manualCosts.total))
                                        .fontWeight(.semibold)
                                        .monospacedDigit()
                                }
                                .font(.system(size: 10))
                            }

                            TextField(L.t("名称，例如 ChatGPT Plus", "Name, e.g. ChatGPT Plus"), text: $costName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))

                            HStack(spacing: 8) {
                                TextField(L.t("金额 (\(Money.symbol))", "Amount (\(Money.symbol))"), text: $costAmount)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10))
                                    .frame(width: 80)
                                DatePicker("", selection: $costDate, in: ...Date(), displayedComponents: .date)
                                    .labelsHidden()
                                    .controlSize(.small)
                                Toggle(L.t("每月订阅", "Monthly"), isOn: $costRecurring)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 10))
                            }

                            if let costError {
                                Text(costError)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                            }

                            Button(L.t("添加花费", "Add cost")) {
                                addManualCost()
                            }
                            .controlSize(.small)
                            .disabled(costName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                    }
                    .font(.system(size: 11))

                    sectionTitle(L.t("启动", "Startup"))

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L.t("开机自动启动", "Launch at login"), isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { enabled in
                                LoginItem.set(enabled)
                            }
                        Toggle(L.t("在程序坞显示", "Show in Dock"), isOn: $showDockIcon)
                            .onChange(of: showDockIcon) { enabled in
                                onDockChanged(enabled)
                            }
                        Toggle(L.t("启动时检查更新", "Check for updates at launch"), isOn: $autoCheckUpdates)

                        Button(L.t("检查更新", "Check for updates")) {
                            NotificationCenter.default.post(name: .dsCheckUpdates, object: nil)
                        }
                        .controlSize(.small)
                    }
                    .font(.system(size: 11))

                    sectionTitle(L.t("iCloud 备份", "iCloud backup"))

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 5) {
                            Image(systemName: BackupManager.isAvailable ? "icloud.fill" : "icloud.slash")
                            Text(BackupManager.isAvailable
                                 ? L.t("iCloud Drive 可用", "iCloud Drive available")
                                 : L.t("没有找到 iCloud Drive", "iCloud Drive not found"))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10))

                        HStack(spacing: 8) {
                            Button(L.t("立即备份", "Back up now")) {
                                runBackup()
                            }
                            .controlSize(.small)

                            Button(L.t("从最近备份恢复", "Restore latest")) {
                                showRestoreConfirm = true
                            }
                            .controlSize(.small)
                            .disabled(BackupManager.listBackups().isEmpty)

                            Button(L.t("打开备份文件夹", "Open backups")) {
                                try? FileManager.default.createDirectory(
                                    at: BackupManager.backupsFolder,
                                    withIntermediateDirectories: true
                                )
                                NSWorkspace.shared.open(BackupManager.backupsFolder)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9))
                        }

                        Toggle(L.t("每天自动备份到 iCloud Drive", "Daily automatic backup to iCloud Drive"),
                               isOn: $autoICloudBackup)
                            .font(.system(size: 10))

                        if let lastBackupDate {
                            let formatter = DateFormatter()
                            let _ = formatter.locale = Locale(identifier: "zh_CN")
                            let _ = formatter.dateFormat = "yyyy-MM-dd HH:mm"
                            Text(L.t("最近备份", "Last backup") + "  " + formatter.string(from: lastBackupDate))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }

                        Text(L.t("备份中的官方 Token 已加密；换机恢复需要重新登录；恢复会覆盖当前数据",
                                 "Official tokens are encrypted in backups; a new Mac needs a fresh login; restoring overwrites current data"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let backupMessage {
                            Text(backupMessage)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }

                }
                .padding(.trailing, 4)
            }
            .frame(height: 500)
        }
        .padding(20)
        .frame(width: 360)
        .tint(Theme.accent)
        .onAppear { refreshBackupState() }
        .alert(L.t("从最近备份恢复？", "Restore latest backup?"), isPresented: $showRestoreConfirm) {
            Button(L.t("恢复", "Restore"), role: .destructive) { restoreLatestBackup() }
            Button(L.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("会覆盖当前账号、手动花费和本地来源", "This overwrites accounts, manual costs and local sources"))
        }
    }

    private func runBackup() {
        switch BackupManager.backup() {
        case .success(let url):
            lastBackupDate = Date()
            backupMessage = L.t("已备份到 \(url.lastPathComponent)", "Backed up to \(url.lastPathComponent)")
        case .failure(let error):
            backupMessage = error.message
        }
    }

    private func restoreLatestBackup() {
        guard let latest = BackupManager.listBackups().first else {
            backupMessage = L.t("没有可用备份", "No backups found")
            return
        }
        switch BackupManager.restore(latest) {
        case .success:
            lastBackupDate = latest.date
            backupMessage = L.t("已恢复，建议重启 App", "Restored; restart the app to be safe")
            AppIconStore.apply()
        case .failure(let error):
            backupMessage = error.message
        }
    }

    private func refreshBackupState() {
        lastBackupDate = BackupManager.listBackups().first?.date
    }

    private func manualCostDetail(_ cost: ManualCost) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.isEnglish ? "en_US_POSIX" : "zh_CN")
        formatter.timeZone = Pricing.timeZone

        if cost.recurring {
            formatter.dateFormat = L.isEnglish ? "MMM yyyy" : "yyyy-MM"
            let start = formatter.string(from: cost.dateValue)
            return L.t(
                "\(start) 起 · 每月 \(UsageFormat.money(cost.amount)) · 已累计 \(cost.chargedMonths) 个月",
                "since \(start) · \(UsageFormat.money(cost.amount))/mo · \(cost.chargedMonths) months"
            )
        }

        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: cost.dateValue)
    }

    private func addManualCost() {
        let text = costAmount
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = Double(text), amount > 0 else {
            costError = L.t("请输入大于 0 的金额", "Enter an amount greater than 0")
            return
        }
        guard manualCosts.add(name: costName, amount: Money.toCNY(amount), date: costDate, recurring: costRecurring) else {
            costError = L.t("名称不能为空", "Name cannot be empty")
            return
        }
        costName = ""
        costAmount = ""
        costDate = Date()
        costRecurring = false
        costError = nil
    }

    private var priceRows: [(key: String, zh: String, en: String)] {
        [
            ("hit", "缓存命中", "Cache hit"),
            ("miss", "缓存未命中", "Cache miss"),
            ("output", "输出", "Output"),
        ]
    }

    private func priceField(_ key: String) -> some View {
        TextField("", text: Binding(
            get: { priceDraft[key] ?? "" },
            set: { priceDraft[key] = $0 }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 10, design: .monospaced))
        .multilineTextAlignment(.trailing)
        .frame(width: 70)
    }

    private func loadPriceDraft() {
        let tables = Pricing.currentTables
        var draft: [String: String] = [:]

        for tier in Tier.allCases {
            let table = tier == .flash ? tables.flash : tables.pro
            let prefix = tier.rawValue
            draft["\(prefix)-hitOff"] = priceText(table.hitOff)
            draft["\(prefix)-hitPeak"] = priceText(table.hitPeak)
            draft["\(prefix)-missOff"] = priceText(table.missOff)
            draft["\(prefix)-missPeak"] = priceText(table.missPeak)
            draft["\(prefix)-outputOff"] = priceText(table.outputOff)
            draft["\(prefix)-outputPeak"] = priceText(table.outputPeak)
        }

        priceDraft = draft
        priceMessage = nil
    }

    private func priceText(_ cny: Double) -> String {
        var text = String(format: "%.4f", Money.fromCNY(cny))
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    private func priceValue(_ key: String) -> Double? {
        let text = (priceDraft[key] ?? "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Double(text), raw > 0 else { return nil }
        return Money.toCNY(raw)
    }

    private func draftTable(_ tier: Tier) -> PriceTable? {
        let prefix = tier.rawValue
        guard let hitOff = priceValue("\(prefix)-hitOff"),
              let hitPeak = priceValue("\(prefix)-hitPeak"),
              let missOff = priceValue("\(prefix)-missOff"),
              let missPeak = priceValue("\(prefix)-missPeak"),
              let outputOff = priceValue("\(prefix)-outputOff"),
              let outputPeak = priceValue("\(prefix)-outputPeak") else {
            return nil
        }

        guard hitOff <= hitPeak, missOff <= missPeak, outputOff <= outputPeak else {
            return nil
        }

        return PriceTable(
            hitOff: hitOff, hitPeak: hitPeak,
            missOff: missOff, missPeak: missPeak,
            outputOff: outputOff, outputPeak: outputPeak
        )
    }

    private func importPrices() {
        let url = priceSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        importingPrices = true
        priceMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = PricingSourceImporter.fetch(urlString: url)
            DispatchQueue.main.async {
                importingPrices = false
                switch result {
                case .success(let fetched):
                    PricingSource.save(url)
                    Pricing.setUserTables(flash: fetched.flash, pro: fetched.pro)
                    loadPriceDraft()
                    priceSourceURL = PricingSource.urlString
                    NotificationCenter.default.post(name: .dsPricingChanged, object: nil)
                    priceMessage = L.t("已识别并应用价格", "Prices detected and applied")
                case .failure(let failure):
                    priceMessage = failure.message
                }
            }
        }
    }

    private func savePrices() {
        guard let flash = draftTable(.flash), let pro = draftTable(.pro) else {
            priceMessage = L.t(
                "请填写大于 0 的价格，空闲价不能高于高峰价",
                "Enter prices above 0; off-peak cannot exceed peak"
            )
            return
        }

        Pricing.setUserTables(flash: flash, pro: pro)
        NotificationCenter.default.post(name: .dsPricingChanged, object: nil)
        priceMessage = L.t("已保存", "Saved")
    }

    private func resetPrices() {
        Pricing.clearUserTables()
        PricingSource.reset()
        priceSourceURL = PricingSource.urlString
        loadPriceDraft()
        NotificationCenter.default.post(name: .dsPricingChanged, object: nil)
        priceMessage = L.t("已恢复官方价格", "Reset to official prices")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func notifyResize() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .dsResizePopover, object: nil)
        }
    }
}

private struct DonationQRCode: View {
    let size: CGFloat

    private static var cache: NSImage?

    static var centeredImage: NSImage? {
        if let cache { return cache }
        guard let original = loadOriginal(),
              let cg = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let w = cg.width
        let h = cg.height
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return original }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 用深色像素找二维码本体的包围盒；金色徽章不参与，避免把视觉重心带偏。
        var minX = w, maxX = 0, minY = h, maxY = 0
        var found = false
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bytesPerRow + x * 4
                guard data[i + 3] > 16 else { continue }
                if max(data[i], data[i + 1], data[i + 2]) < 160 {
                    found = true
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard found else { return original }

        let centerX = CGFloat(minX + maxX) / 2
        let centerY = CGFloat(minY + maxY) / 2
        let contentSide = CGFloat(max(maxX - minX, maxY - minY) + 1)
        let margin = max(16, contentSide / 12)
        let side = min(CGFloat(min(w, h)), contentSide + margin * 2)

        var rect = CGRect(
            x: centerX - side / 2,
            y: centerY - side / 2,
            width: side,
            height: side
        )
        rect.origin.x = max(0, min(rect.origin.x, CGFloat(w) - side))
        rect.origin.y = max(0, min(rect.origin.y, CGFloat(h) - side))

        guard let cropped = cg.cropping(to: rect) else { return original }
        let result = NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
        cache = result
        return result
    }

    static var hasImage: Bool { centeredImage != nil }

    private static func loadOriginal() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "donation-qr", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        if let image = Self.centeredImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

enum CelebrationSound {
    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?

    static func play() {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate * 1.6)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = buffer.frameCapacity
        let frames = Int(buffer.frameLength)
        let notes: [(onset: Double, frequency: Double)] = [
            (0.00, 523.25),
            (0.10, 659.25),
            (0.20, 783.99),
            (0.30, 1046.50),
        ]

        for index in 0..<frames {
            let time = Double(index) / sampleRate
            var sample = 0.0

            for note in notes {
                let delta = time - note.onset
                guard delta >= 0, delta < 0.5 else { continue }
                let attack = min(1.0, delta * 80)
                let decay = exp(-delta * 7)
                sample += sin(2 * .pi * note.frequency * delta) * attack * decay * 0.16
            }

            if time >= 0.42, time < 1.5 {
                let delta = time - 0.42
                let attack = min(1.0, delta * 50)
                let decay = exp(-delta * 3.2)
                let chord = (
                    sin(2 * .pi * 523.25 * delta)
                    + sin(2 * .pi * 659.25 * delta)
                    + sin(2 * .pi * 783.99 * delta)
                ) / 3
                sample += chord * attack * decay * 0.09
            }

            channel[index] = Float(max(-0.35, min(0.35, sample)))
        }

        let audioEngine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 0.4

        do {
            try audioEngine.start()
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            node.play()
        } catch {
            NSSound(named: "Glass")?.play()
        }

        engine = audioEngine
        player = node

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            node.stop()
            audioEngine.stop()
            if player === node { player = nil }
            if engine === audioEngine { engine = nil }
        }
    }
}

private struct GlassBackground: NSViewRepresentable {
    var alpha: CGFloat = 0.52

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = alpha
    }
}

/// 面板的「液态玻璃」底：系统模糊材质 + 随深浅色变化的乳白 / 烟灰渐变。
private struct PanelGlassBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            PanelVisualEffect()
            LinearGradient(
                colors: scheme == .light
                    ? [Color.white.opacity(0.66), Color.white.opacity(0.50)]
                    : [Color.black.opacity(0.54), Color.black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct PanelVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct DonationView: View {
    private static let compliments: [(zh: String, en: String)] = [
        ("你真好看", "You look great"),
        ("今天的你，比昨天更好看", "You look even better today than yesterday"),
        ("你的品味，真的很在线", "Your taste is impeccable"),
        ("你一笑，天气都变好了", "Your smile makes the weather better"),
        ("你认真生活的样子，很迷人", "The way you live is charming"),
        ("你值得所有温柔和好运", "You deserve all the kindness and luck"),
        ("你一来，整个房间都亮了", "The room lights up when you walk in"),
        ("你的眼光，从来不会让人失望", "Your taste never disappoints"),
        ("你不仅好看，还很有眼光", "You're not just good-looking; you have great taste"),
        ("有你在，平凡的一天也会发光", "With you around, an ordinary day shines"),
    ]

    @State private var complimentIndex = Int.random(in: 0..<10)
    @State private var celebrationTask: DispatchWorkItem?
    @State private var nudgeTask: DispatchWorkItem?
    @State private var activeMessage: String?
    @State private var didScheduleCelebration = false
    @State private var didScheduleNudge = false

    var body: some View {
        VStack(spacing: 10) {
            Text(L.t(Self.compliments[complimentIndex].zh, Self.compliments[complimentIndex].en))
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
                .padding(.top, 2)

            Button {
                if let url = URL(string: "https://afdian.com/a/tack123") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "heart.fill")
                    Text(L.t("去爱发电支持", "Support on Afdian"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            if DonationQRCode.hasImage {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 0.5)
                    Text(L.t("或 微信扫码", "or scan WeChat"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 0.5)
                }

                DonationQRCode(size: 120)
            }

            ZStack {
                if let message = activeMessage {
                    HStack(spacing: 8) {
                        Text("💖")
                            .font(.system(size: 14))
                        Text(message)
                            .font(.system(size: 10, weight: .medium))
                        Text("✨")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        GlassBackground(alpha: 0.5)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: 26)
            .padding(.top, DonationQRCode.hasImage ? -24 : 0)

            Text(L.t(
                "自愿赞赏 · 不换取任何功能或服务 · 不支持退款",
                "Voluntary tip · No features or services in return · Non-refundable"
            ))
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button(L.t("关闭", "Close")) { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 340)
        .onAppear {
            complimentIndex = Int.random(in: 0..<Self.compliments.count)
            scheduleCelebrationOnce()
            scheduleNudgeOnce()
        }
        .onDisappear {
            celebrationTask?.cancel()
            celebrationTask = nil
            nudgeTask?.cancel()
            nudgeTask = nil
        }
    }

    private func scheduleCelebrationOnce() {
        guard !didScheduleCelebration else { return }
        didScheduleCelebration = true

        let task = DispatchWorkItem {
            CelebrationSound.play()
            showMessage(L.t("天气从未如此明媚", "The weather has never been so bright"), duration: 3.0)
        }
        celebrationTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    private func scheduleNudgeOnce() {
        guard !didScheduleNudge else { return }
        didScheduleNudge = true

        let task = DispatchWorkItem {
            showMessage(L.t("你这么好看，在犹豫什么", "You look so great. What are you waiting for?"), duration: 4.0)
        }
        nudgeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: task)
    }

    private func showMessage(_ text: String, duration: TimeInterval) {
        withAnimation(.easeOut(duration: 0.25)) {
            activeMessage = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if activeMessage == text {
                withAnimation(.easeOut(duration: 0.3)) {
                    activeMessage = nil
                }
            }
        }
    }

}

struct SpendSlice: Identifiable {
    let id: String
    let name: String
    let amount: Double
    let color: Color
}

enum SpendBreakdown {
    static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .brown,
    ]
}

struct DonutChart: View {
    let slices: [SpendSlice]

    private var total: Double {
        slices.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        Canvas { context, size in
            guard total > 0 else { return }
            let lineWidth = min(size.width, size.height) * 0.24
            let radius = (min(size.width, size.height) - lineWidth) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var start = Angle(degrees: -90)

            for slice in slices {
                let sweep = Angle(degrees: slice.amount / total * 360)
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: start,
                    endAngle: start + sweep,
                    clockwise: false
                )
                context.stroke(
                    path,
                    with: .color(slice.color),
                    style: StrokeStyle(lineWidth: lineWidth)
                )
                start = start + sweep
            }
        }
    }
}

struct SpendChartView: View {
    let slices: [SpendSlice]
    let note: String?

    private var total: Double {
        slices.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(L.t("花费构成", "Spending breakdown"))
                .font(.system(size: 16, weight: .semibold))

            Text(L.t("各来源历史累计花费占比", "All-time share by source"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            if let note {
                Text(note)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }

            if slices.isEmpty || total <= 0 {
                Text(L.t("还没有可统计的花费", "No spend to show yet"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        DonutChart(slices: slices)
                            .frame(width: 140, height: 140)
                        VStack(spacing: 2) {
                            Text(L.t("合计", "Total"))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(UsageFormat.money(total))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(slices) { slice in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 8, height: 8)
                                Text(slice.name)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text("\(Int((slice.amount / total * 100).rounded()))%")
                                    .font(.system(size: 9))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .trailing)
                                Text(UsageFormat.money(slice.amount))
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                    .frame(maxWidth: 260)
                }
            }

            Button(L.t("关闭", "Close")) { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 430)
    }
}

final class SpendChartWindowController {
    static let shared = SpendChartWindowController()

    private var window: NSWindow?

    func show(slices: [SpendSlice], note: String? = nil) {
        let host = NSHostingController(rootView: ThemedRoot {
            SpendChartView(slices: slices, note: note)
        })
        let window: NSWindow

        if let existing = self.window {
            existing.contentViewController = host
            window = existing
        } else {
            window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        host.view.layoutSubtreeIfNeeded()
        window.title = L.t("花费构成", "Spending breakdown")
        window.setContentSize(host.view.fittingSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class LoginBridge: ObservableObject {
    private var controller: OfficialLoginWindowController?

    func start(onToken: @escaping (String) -> Void) {
        controller?.close()
        let current = OfficialLoginWindowController(
            onToken: { [weak self] token in
                self?.controller = nil
                onToken(OfficialAccountsFile.cleanToken(token))
            },
            onClose: { [weak self] in
                self?.controller = nil
            }
        )
        controller = current
        current.show()
    }
}

struct SourcesManagerView: View {
    @ObservedObject var accounts: OfficialAccountsStore
    @ObservedObject var localSources: LocalSourcesStore
    let selectedSource: String
    let selectedOfficialAccountID: String
    let onSelectSource: (String) -> Void
    let onClose: () -> Void

    @StateObject private var login = LoginBridge()

    @State private var showAccountForm = false
    @State private var editingAccountID: String?
    @State private var accountName = ""
    @State private var accountToken = ""
    @State private var accountError: String?

    @State private var showLocalForm = false
    @State private var editingLocalID: String?
    @State private var localName = ""
    @State private var localCommand = ""
    @State private var localMessage: String?
    @State private var runningLocalID: String?

    @State private var pendingAccountDelete: OfficialAccount?
    @State private var pendingLocalDelete: LocalSource?
    @State private var renamingAccountID: String?
    @State private var renameDraft = ""

    private var activeAccountID: String? {
        guard selectedSource == "official" || selectedSource.hasPrefix("official:") else { return nil }
        return selectedOfficialAccountID.isEmpty ? nil : selectedOfficialAccountID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.t("账号与来源", "Accounts & sources"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(L.t("完成", "Done")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    officialSection
                    Divider()
                    localSection
                }
                .padding(.trailing, 4)
            }
        }
        .padding(20)
        .frame(width: 520, height: 620)
        .tint(Theme.accent)
        .alert(L.t("删除 DeepSeek 账号？", "Delete DeepSeek account?"), isPresented: Binding(
            get: { pendingAccountDelete != nil },
            set: { if !$0 { pendingAccountDelete = nil } }
        )) {
            Button(L.t("删除", "Delete"), role: .destructive) {
                if let account = pendingAccountDelete {
                    accounts.remove(id: account.id)
                }
                pendingAccountDelete = nil
            }
            Button(L.t("取消", "Cancel"), role: .cancel) { pendingAccountDelete = nil }
        } message: {
            Text(L.t("这个账号的 Token 也会一起删除", "The token for this account will be deleted too"))
        }
        .alert(L.t("删除本地来源？", "Delete local source?"), isPresented: Binding(
            get: { pendingLocalDelete != nil },
            set: { if !$0 { pendingLocalDelete = nil } }
        )) {
            Button(L.t("删除", "Delete"), role: .destructive) {
                if let source = pendingLocalDelete {
                    localSources.remove(source)
                }
                pendingLocalDelete = nil
            }
            Button(L.t("取消", "Cancel"), role: .cancel) { pendingLocalDelete = nil }
        } message: {
            Text(L.t("sources 里对应的 .jsonl 文件也会删除", "The matching .jsonl file in sources will be deleted too"))
        }
    }

    // MARK: 官方账号

    private var officialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("DeepSeek", "DeepSeek"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(accounts.accounts.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L.t("＋ 添加账号", "＋ Add account")) {
                    editingAccountID = nil
                    accountName = "DeepSeek \(accounts.accounts.count + 1)"
                    accountToken = ""
                    accountError = nil
                    showAccountForm = true
                }
                .controlSize(.small)
            }

            if accounts.accounts.isEmpty && !showAccountForm {
                Text(L.t("添加多个 DeepSeek 账号后，可以在「我的用量」里分别查看每个账号的 Key、余额和总花费", "Add multiple DeepSeek accounts and switch between them in My usage; each account has its own keys, balance and total spend"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(accounts.accounts) { account in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if renamingAccountID == account.id {
                                TextField("", text: $renameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .frame(width: 130)
                                    .onSubmit { commitRename(account) }

                                Button { commitRename(account) } label: {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.plain)

                                Button { renamingAccountID = nil } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                            } else {
                                Text(account.name)
                                    .font(.system(size: 11, weight: .medium))

                                Button { startRename(account) } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                                .help(L.t("重命名", "Rename"))
                            }
                        }
                        HStack(spacing: 7) {
                            Text(account.token.isEmpty ? L.t("没有 Token", "No token") : L.t("Token 已保存", "Token saved"))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if activeAccountID == account.id {
                        Text(L.t("使用中", "In use"))
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                    Button(L.t("使用", "Use")) { onSelectSource(account.sourceID) }
                        .controlSize(.mini)
                    Button(L.t("编辑", "Edit")) {
                        editingAccountID = account.id
                        accountName = account.name
                        accountToken = account.token
                        accountError = nil
                        showAccountForm = true
                    }
                    .controlSize(.mini)
                    Button(L.t("删除", "Delete")) { pendingAccountDelete = account }
                        .controlSize(.mini)
                        .foregroundStyle(.red)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.06)))
            }

            if showAccountForm {
                VStack(alignment: .leading, spacing: 7) {
                    Text(editingAccountID == nil ? L.t("添加 DeepSeek", "Add DeepSeek") : L.t("编辑 DeepSeek", "Edit DeepSeek"))
                        .font(.system(size: 11, weight: .semibold))

                    TextField(L.t("账号名称", "Account name"), text: $accountName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    SecureField(L.t("网页 Token（不是 sk- API Key）", "Web token (not an sk- API key)"), text: $accountToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    HStack(spacing: 8) {
                        Button(L.t("登录 DeepSeek 网页获取 Token", "Sign in to get token")) {
                            login.start { token in
                                accountToken = token
                                if accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    accountName = "DeepSeek \(accounts.accounts.count + 1)"
                                }
                            }
                        }
                        .controlSize(.small)

                        Button(L.t("打开 DeepSeek 用量页", "Open DeepSeek usage page")) {
                            if let url = URL(string: "https://platform.deepseek.com/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                    }

                    Text(L.t("Token 只存本机 \(OfficialAccountsFile.fileURL.deletingLastPathComponent().path)（600 权限）。API Key 不能读用量", "Token is stored locally in \(OfficialAccountsFile.fileURL.deletingLastPathComponent().path) (mode 600). API keys cannot read usage"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let accountError {
                        Text(accountError)
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 8) {
                        Button(editingAccountID == nil ? L.t("添加并刷新", "Add & refresh") : L.t("保存", "Save")) {
                            saveAccount()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(accountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(L.t("取消", "Cancel")) {
                            showAccountForm = false
                            accountError = nil
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))
            }
        }
    }

    private func startRename(_ account: OfficialAccount) {
        renamingAccountID = account.id
        renameDraft = account.name
    }

    private func commitRename(_ account: OfficialAccount) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renamingAccountID = nil
            return
        }
        accounts.rename(id: account.id, name: name)
        renamingAccountID = nil
    }

    private func saveAccount() {
        let clean = OfficialAccountsFile.cleanToken(accountToken)
        if accounts.accounts.contains(where: { $0.id != editingAccountID && $0.token == clean }) {
            accountError = L.t(
                "这个账号已经添加过，请换一个账号登录",
                "This account is already added; sign in with another account"
            )
            return
        }

        if let id = editingAccountID {
            let before = accounts.account(id: id)
            accounts.update(id: id, name: accountName, token: accountToken)
            guard let after = accounts.account(id: id), after != before else {
                accountError = L.t("Token 不能为空，也不能是 sk- API Key", "Token cannot be empty or an sk- API key")
                return
            }
            showAccountForm = false
            accountError = nil
            onSelectSource(after.sourceID)
        } else if let account = accounts.add(name: accountName, token: accountToken) {
            showAccountForm = false
            accountError = nil
            onSelectSource(account.sourceID)
        } else {
            accountError = L.t("Token 不能为空，也不能是 sk- API Key", "Token cannot be empty or an sk- API key")
        }
    }

    // MARK: 本地来源

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("本地来源", "Local sources"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(localSources.sources.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L.t("打开文件夹", "Open folder")) {
                    LocalSourcesFile.ensureFolder()
                    NSWorkspace.shared.open(LocalSourcesFile.folderURL)
                }
                .controlSize(.small)
                Button(L.t("＋ 添加来源", "＋ Add source")) {
                    editingLocalID = nil
                    localName = ""
                    localCommand = ""
                    localMessage = nil
                    showLocalForm = true
                }
                .controlSize(.small)
            }

            Text(L.t("每个 .jsonl 文件就是一个来源；也可以配置一条命令，刷新时自动生成数据。让 AI 写脚本时，它会把文件直接放进这个文件夹", "Each .jsonl file is a source. You can also attach a command that regenerates the file on refresh. An AI can write the file directly into this folder"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(localSources.sources) { source in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(source.command.isEmpty ? L.t("读取 sources/", "Reads sources/") + "\(source.id).jsonl" : L.t("命令已配置", "Command configured"))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if selectedSource == source.sourceID {
                            Text(L.t("使用中", "In use"))
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        }
                        Button(L.t("使用", "Use")) { onSelectSource(source.sourceID) }
                            .controlSize(.mini)
                        Button(L.t("运行", "Run")) { runLocal(source) }
                            .controlSize(.mini)
                            .disabled(runningLocalID == source.id)
                        Button(L.t("编辑", "Edit")) {
                            editingLocalID = source.id
                            localName = source.name
                            localCommand = source.command
                            localMessage = nil
                            showLocalForm = true
                        }
                        .controlSize(.mini)
                        Button(L.t("删除", "Delete")) { pendingLocalDelete = source }
                            .controlSize(.mini)
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.06)))
            }

            if showLocalForm {
                VStack(alignment: .leading, spacing: 7) {
                    Text(editingLocalID == nil ? L.t("添加本地来源", "Add local source") : L.t("编辑本地来源", "Edit local source"))
                        .font(.system(size: 11, weight: .semibold))

                    TextField(L.t("来源名称，例如 Claude Code", "Source name, e.g. Claude Code"), text: $localName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    Text(L.t("命令（可留空）。命令需要输出 JSONL，或写入 $DS_SOURCE_FILE", "Command (optional). It must print JSONL or write to $DS_SOURCE_FILE"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $localCommand)
                        .font(.system(size: 9.5, design: .monospaced))
                        .frame(height: 64)
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.06)))

                    HStack(spacing: 8) {
                        Button(L.t("让 AI 帮我写", "Ask AI to write it")) {
                            LocalSourceAI.present(sourceName: localName)
                        }
                        .controlSize(.small)
                        Button(L.t("复制 AI 提示词", "Copy AI prompt")) {
                            LocalSourceAI.copyPrompt(sourceName: localName)
                            localMessage = L.t("已复制提示词", "Prompt copied")
                        }
                        .controlSize(.small)
                        Button(L.t("打开文件夹", "Open folder")) {
                            LocalSourcesFile.ensureFolder()
                            NSWorkspace.shared.open(LocalSourcesFile.folderURL)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                    }

                    if let localMessage {
                        Text(localMessage)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button(editingLocalID == nil ? L.t("添加", "Add") : L.t("保存", "Save")) {
                            saveLocalSource()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(L.t("取消", "Cancel")) {
                            showLocalForm = false
                            localMessage = nil
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))
            }
        }
    }

    private func saveLocalSource() {
        let name = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if let id = editingLocalID {
            localSources.update(id: id, name: name, command: localCommand)
            showLocalForm = false
            localMessage = nil
            onSelectSource("local:\(id)")
        } else if let source = localSources.add(name: name, command: localCommand) {
            showLocalForm = false
            localMessage = nil
            onSelectSource(source.sourceID)
        }
    }

    private func runLocal(_ source: LocalSource) {
        guard !source.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localMessage = L.t("这个来源没有命令，直接把 jsonl 放进文件夹即可", "No command for this source; just put a .jsonl file in the folder")
            return
        }
        runningLocalID = source.id
        localMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LocalSourcesFile.run(source)
            DispatchQueue.main.async {
                runningLocalID = nil
                switch result {
                case .success:
                    localMessage = L.t("命令已运行", "Command finished")
                    NotificationCenter.default.post(name: .dsUsageRefresh, object: nil)
                case .failure(let error):
                    localMessage = error.message
                }
            }
        }
    }
}

private final class AlphaWindowView: NSView {
    var alpha: CGFloat = 1 {
        didSet { window?.alphaValue = alpha }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.alphaValue = alpha
    }
}

private struct WindowAlphaConfigurator: NSViewRepresentable {
    let alpha: Double

    func makeNSView(context: Context) -> AlphaWindowView {
        let view = AlphaWindowView()
        view.alpha = CGFloat(alpha)
        return view
    }

    func updateNSView(_ view: AlphaWindowView, context: Context) {
        view.alpha = CGFloat(alpha)
    }
}

// MARK: - 菜单栏

enum StatusRingStyle: String, CaseIterable, Identifiable {
    case classic
    case soft
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return L.t("经典", "Classic")
        case .soft: return L.t("柔和", "Soft")
        case .light: return L.t("浅色", "Light")
        }
    }

    var detail: String {
        switch self {
        case .classic: return L.t("系统绿 / 橙 / 红", "System green / orange / red")
        case .soft: return L.t("降低饱和度，保留辨识度", "Softer, still easy to read")
        case .light: return L.t("更接近系统浅色图标", "Closest to light system icons")
        }
    }

    var idle: NSColor {
        switch self {
        case .classic: return .systemGreen
        case .soft: return NSColor(srgbRed: 0.36, green: 0.72, blue: 0.49, alpha: 1)
        case .light: return NSColor(srgbRed: 0.45, green: 0.78, blue: 0.58, alpha: 1)
        }
    }

    var peak: NSColor {
        switch self {
        case .classic: return .systemOrange
        case .soft: return NSColor(srgbRed: 0.93, green: 0.62, blue: 0.32, alpha: 1)
        case .light: return NSColor(srgbRed: 0.96, green: 0.72, blue: 0.45, alpha: 1)
        }
    }

    var low: NSColor {
        switch self {
        case .classic: return .systemRed
        case .soft: return NSColor(srgbRed: 0.89, green: 0.44, blue: 0.42, alpha: 1)
        case .light: return NSColor(srgbRed: 0.93, green: 0.55, blue: 0.52, alpha: 1)
        }
    }

    var idleColor: Color { Color(nsColor: idle) }
    var peakColor: Color { Color(nsColor: peak) }
    var lowColor: Color { Color(nsColor: low) }
}

final class StatusCircleView: NSView {
    var ringColor: NSColor = StatusRingStyle.soft.idle {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("TokenPeek")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.invalidateShadow()
    }

    override func draw(_ dirtyRect: NSRect) {
        ringColor.setStroke()
        let diameter = min(bounds.width, bounds.height) - 5
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

struct StatusMenuView: View {
    let launchAtLogin: Bool
    let showDock: Bool
    let onToggleLogin: () -> Void
    let onOpenWindow: () -> Void
    let onToggleDock: () -> Void
    let onSettings: () -> Void
    let onCheckUpdates: () -> Void
    let onDonation: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(
                title: L.t("开机自动启动", "Launch at login"),
                checked: launchAtLogin,
                action: onToggleLogin
            )
            Divider().padding(.vertical, 4)
            MenuRow(title: L.t("打开主窗口", "Open window"), action: onOpenWindow)
            MenuRow(
                title: L.t("在程序坞显示", "Show in Dock"),
                checked: showDock,
                action: onToggleDock
            )
            MenuRow(title: L.t("设置", "Settings"), shortcut: "⌘,", action: onSettings)
            MenuRow(title: L.t("检查更新", "Check for updates"), action: onCheckUpdates)
            MenuRow(
                title: L.t("有你真好", "So glad to have you"),
                emoji: "👏",
                action: onDonation
            )
            Divider().padding(.vertical, 4)
            MenuRow(title: L.t("退出", "Quit"), shortcut: "⌘Q", action: onQuit)
        }
        .padding(6)
        .frame(width: 212)
        .background(MenuVisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MenuVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct MenuRow: View {
    let title: String
    var checked = false
    var shortcut: String?
    var emoji: String?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: 14)

            if let emoji {
                Text(emoji)
                    .font(.system(size: 12))
            }

            Text(title)
                .font(.system(size: 12.5))

            Spacer(minLength: 12)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { action() }
    }
}

private final class StatusMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var statusView: StatusCircleView?
    private let popover = NSPopover()
    private var statusMenuPanel: NSPanel?
    private var statusMenuLocalMonitor: Any?
    private var statusMenuDismissObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var donationWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceStore.apply(AppearanceStore.current)
        AppIconStore.apply()
        Pricing.loadUserTables()

        statusItem = NSStatusBar.system.statusItem(withLength: 18)
        statusItem.autosaveName = "local.deepseekcost.item"

        let view = StatusCircleView(frame: NSRect(x: 0, y: 0, width: 18, height: 22))
        view.onClick = { [weak self] in self?.togglePopover() }
        view.onRightClick = { [weak self] in self?.showMenu() }
        statusItem.view = view
        statusView = view

        BalanceStore.shared.refresh(token: OfficialAccountsFile.load().first?.token, force: true)

        NotificationCenter.default.addObserver(
            forName: .dsBalanceUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }

        NotificationCenter.default.addObserver(
            forName: .dsRingStyleChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }

        refreshStatus()

        let host = NSHostingController(rootView: ThemedRoot {
            ContentView(onQuit: { [weak self] in
                self?.popover.performClose(nil)
            })
        })
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        NotificationCenter.default.addObserver(
            forName: .dsResizePopover,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resizePopover()
        }

        NotificationCenter.default.addObserver(
            forName: .dsCheckUpdates,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.runUpdateCheck(silent: false)
        }

        if ProcessInfo.processInfo.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.showPopover()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.showSettings()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--donation") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.showDonation()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.showMainWindow()
            }
        }

        if UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.runUpdateCheck(silent: true)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            BackupManager.autoBackupIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let host = NSHostingController(
                rootView: ThemedRoot {
                    ContentView(onQuit: { [weak self] in
                        self?.mainWindow?.orderOut(nil)
                    })
                }
            )
            let window = NSWindow(contentViewController: host)
            window.title = "TokenPeek"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.appearance = NSApp.appearance
            window.center()

            host.view.layoutSubtreeIfNeeded()
            window.setContentSize(desiredPanelSize(host.view.fittingSize))
            mainWindow = window
        }

        mainWindow?.title = "TokenPeek"
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func toggleDockIcon() {
        let current = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
        setDockIcon(!current, showWindow: true)
    }

    private func setDockIcon(_ enabled: Bool, showWindow: Bool = false) {
        UserDefaults.standard.set(enabled, forKey: "showDockIcon")
        NSApp.setActivationPolicy(enabled ? .regular : .accessory)
        if !enabled {
            mainWindow?.orderOut(nil)
        } else if showWindow {
            showMainWindow()
        }
    }

    private func showSettings() {
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let host = NSHostingController(
                rootView: ThemedRoot {
                    SettingsView(
                        onDockChanged: { [weak self] enabled in
                            self?.setDockIcon(enabled)
                        }
                    )
                }
            )
            let created = NSWindow(contentViewController: host)
            created.title = L.t("TokenPeek 设置", "TokenPeek Settings")
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.appearance = NSApp.appearance

            // 先按最终内容尺寸定好窗口大小，再居中；否则窗口会以旧尺寸居中后向右下长。
            host.view.layoutSubtreeIfNeeded()
            created.setContentSize(host.view.fittingSize)
            centerWindow(created)
            settingsWindow = created
            window = created
        }

        window.title = L.t("TokenPeek 设置", "TokenPeek Settings")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 在鼠标所在屏幕的可视区域居中，避免多显示器时跑到另一块屏或超出边缘。
    private func centerWindow(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    @objc func openSettings() {
        showSettings()
    }

    private func showDonation() {
        let host = NSHostingController(rootView: ThemedRoot { DonationView() })
        let window: NSWindow

        if let existing = donationWindow {
            existing.contentViewController = host
            window = existing
        } else {
            let created = NSWindow(contentViewController: host)
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            donationWindow = created
            window = created
        }

        host.view.layoutSubtreeIfNeeded()
        window.title = L.t("有你真好", "So glad to have you")
        window.setContentSize(host.view.fittingSize)
        if !window.isVisible {
            centerWindow(window)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDonation() {
        showDonation()
    }

    private func togglePopover() {
        if statusMenuPanel != nil {
            closeStatusMenu()
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func desiredPanelSize(_ fitting: NSSize) -> NSSize {
        var size = fitting
        let width = UserDefaults.standard.double(forKey: "panelWidth")
        if width > 0 { size.width = width }
        return size
    }

    private func showPopover() {
        guard let statusView else { return }
        if statusMenuPanel != nil {
            closeStatusMenu()
        }
        refreshStatus()
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = desiredPanelSize(view.fittingSize)
        }
        popover.show(relativeTo: statusView.bounds, of: statusView, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        NotificationCenter.default.post(name: .dsUsageRefresh, object: nil)
    }

    func popoverDidClose(_ notification: Notification) {
    }

    private func resizePopover() {
        if popover.isShown, let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = desiredPanelSize(view.fittingSize)
            if size.width > 0, size.height > 0, popover.contentSize != size {
                popover.contentSize = size
            }
        }

        if let window = mainWindow, let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = desiredPanelSize(view.fittingSize)
            if size.width > 0, size.height > 0 {
                window.setContentSize(size)
            }
        }
    }

    private func refreshStatus() {
        guard let view = statusView else { return }
        let peak = Pricing.isPeak()
        let lowBalance = (BalanceStore.shared.snapshot?.total ?? .infinity) < 5

        let style = StatusRingStyle(
            rawValue: UserDefaults.standard.string(forKey: "statusRingStyle") ?? ""
        ) ?? .soft
        view.ringColor = lowBalance
            ? style.low
            : (peak ? style.peak : style.idle)
        view.needsDisplay = true

        let price = Pricing.price(.flash, peak: peak)
        let balanceLine = lowBalance
            ? "\n余额不足 \(Money.display(5))，请充值"
            : ""
        view.toolTip = """
        TokenPeek · \(peak ? "高峰时段" : "空闲时段")
        Flash 输入 \(Money.price(price.miss)) / 输出 \(Money.price(price.output))（\(Money.currency.priceUnit)）
        左键查看价格与用量，右键更多选项\(balanceLine)
        """
    }

    private func emojiIcon(_ emoji: String, size: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size - 1)
        ]
        let text = emoji as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: (size - textSize.width) / 2,
                y: (size - textSize.height) / 2
            ),
            withAttributes: attributes
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func menuIcon(_ symbol: String, color: NSColor, size: CGFloat = 14) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let baseSize = base.size
        let rect = NSRect(
            x: (size - baseSize.width) / 2,
            y: (size - baseSize.height) / 2,
            width: baseSize.width,
            height: baseSize.height
        )
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func showMenu() {
        guard let statusView else { return }

        if statusMenuPanel != nil {
            closeStatusMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        }

        let view = StatusMenuView(
            launchAtLogin: LoginItem.isOn,
            showDock: UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false,
            onToggleLogin: { [weak self] in
                self?.closeStatusMenu()
                self?.toggleLogin()
            },
            onOpenWindow: { [weak self] in
                self?.closeStatusMenu()
                self?.showMainWindow()
            },
            onToggleDock: { [weak self] in
                self?.closeStatusMenu()
                self?.toggleDockIcon()
            },
            onSettings: { [weak self] in
                self?.closeStatusMenu()
                self?.showSettings()
            },
            onCheckUpdates: { [weak self] in
                self?.closeStatusMenu()
                self?.checkForUpdates()
            },
            onDonation: { [weak self] in
                self?.closeStatusMenu()
                self?.showDonation()
            },
            onQuit: { [weak self] in
                self?.closeStatusMenu()
                self?.quit()
            }
        )

        let systemAppearance = NSApp.effectiveAppearance
        let systemScheme: ColorScheme = systemAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let host = NSHostingView(
            rootView: ThemedRoot(scheme: systemScheme) { view }
        )
        host.frame = NSRect(x: 0, y: 0, width: 212, height: 320)
        host.layoutSubtreeIfNeeded()
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true

        let size = host.fittingSize
        let panel = StatusMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = systemAppearance
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        let anchorWindow = statusView.window
        var anchor = anchorWindow?.convertToScreen(statusView.convert(statusView.bounds, to: nil)) ?? .zero
        if anchor.width < 1 || anchor.maxX <= 0 {
            let mouse = NSEvent.mouseLocation
            anchor = NSRect(x: mouse.x, y: mouse.y, width: 18, height: 22)
        }
        let visible = (anchorWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 和系统菜单一致：左边缘比图标再向左溢出约 12pt，往右展开；
        // 右边放不下时整体左移，保证不超出屏幕。
        var x = anchor.minX - 12
        if x + size.width > visible.maxX - 8 {
            x = visible.maxX - size.width - 8
        }
        x = max(x, visible.minX + 8)
        let y = anchor.minY - size.height - 4

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        statusMenuPanel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        statusMenuDismissObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closeStatusMenu()
        }

        statusMenuLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window === panel || event.window === self.statusView?.window {
                return event
            }
            self.closeStatusMenu()
            return event
        }
    }

    private func closeStatusMenu() {
        if let monitor = statusMenuLocalMonitor {
            NSEvent.removeMonitor(monitor)
            statusMenuLocalMonitor = nil
        }
        if let observer = statusMenuDismissObserver {
            NotificationCenter.default.removeObserver(observer)
            statusMenuDismissObserver = nil
        }
        if let panel = statusMenuPanel {
            statusMenuPanel = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func checkForUpdates() {
        runUpdateCheck(silent: false)
    }

    private func runUpdateCheck(silent: Bool) {
        if silent {
            let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
            if Date().timeIntervalSince1970 - last < 86_400 {
                return
            }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

        UpdateChecker.check { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let info):
                    guard let info else {
                        if !silent {
                            self.showUpdateAlert(
                                title: L.t("已是最新版本", "You're up to date"),
                                message: L.t(
                                    "当前版本 \(UpdateChecker.currentVersion)",
                                    "Current version \(UpdateChecker.currentVersion)"
                                )
                            )
                        }
                        return
                    }
                    self.showUpdateAlert(
                        title: L.t("发现新版本 \(info.version)", "New version \(info.version)"),
                        message: L.t(
                            "当前版本 \(UpdateChecker.currentVersion)。是否打开下载页面",
                            "Current version \(UpdateChecker.currentVersion). Open the download page"
                        ),
                        downloadURL: info.pageURL
                    )
                case .failure(let error):
                    if !silent {
                        self.showUpdateAlert(
                            title: L.t("检查更新失败", "Update check failed"),
                            message: error.message
                        )
                    }
                }
            }
        }
    }

    private func showUpdateAlert(title: String, message: String, downloadURL: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let downloadURL {
            alert.addButton(withTitle: L.t("下载", "Download"))
            alert.addButton(withTitle: L.t("稍后", "Later"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(downloadURL)
            }
        } else {
            alert.addButton(withTitle: L.t("好", "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func toggleLogin() {
        LoginItem.toggle()
    }

    @objc private func openDocs() {
        if let url = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openBilling() {
        NSWorkspace.shared.open(OfficialLinks.billing)
    }

    @objc private func openTopUp() {
        NSWorkspace.shared.open(OfficialLinks.topUp)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 启动

if CommandLine.arguments.contains("--backup") {
    switch BackupManager.backup() {
    case .success(let url):
        print("已备份：\(url.path)")
        exit(0)
    case .failure(let error):
        print("备份失败：\(error.message)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--restore-latest") {
    guard let latest = BackupManager.listBackups().first else {
        print("没有备份")
        exit(1)
    }
    switch BackupManager.restore(latest) {
    case .success:
        print("已恢复：\(latest.id)")
        exit(0)
    case .failure(let error):
        print("恢复失败：\(error.message)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--backup-list") {
    let backups = BackupManager.listBackups()
    if backups.isEmpty {
        print("没有备份")
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for backup in backups {
            print("\(formatter.string(from: backup.date))  \(backup.id)")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--pricing-check") {
    switch PricingUpdater.fetch() {
    case .success(let pricing):
        func printTable(_ name: String, _ table: PriceTable) {
            print("\(name)：命中 \(table.hitOff)/\(table.hitPeak) · 未命中 \(table.missOff)/\(table.missPeak) · 输出 \(table.outputOff)/\(table.outputPeak)（空闲/高峰，元/百万 tokens）")
        }
        printTable("Flash", pricing.flash)
        printTable("Pro", pricing.pro)
    case .failure:
        print("价格抓取失败，继续使用本地缓存或内置价格")
    }
    exit(0)
}

if CommandLine.arguments.contains("--report") {
    exit(CustomUsageFile.report(arguments: CommandLine.arguments) ? 0 : 1)
}

if CommandLine.arguments.contains("--usage") {
    func rateText(_ bucket: UsageBucket) -> String {
        let total = bucket.hit + bucket.miss
        guard total > 0 else { return "—" }
        return String(format: "%.1f%%", Double(bucket.hit) / Double(total) * 100)
    }

    func rateText(_ set: UsageSet) -> String {
        rateText(set.all)
    }

    func printUsage(_ title: String, _ set: UsageSet) {
        let all = set.bucket(source: "all")
        print("\(title)：全部 \(UsageFormat.money(all.cost)) · \(UsageFormat.tokens(all.tokens)) tokens · 命中率 \(rateText(all))")
        if all.savedFlash > 0 || all.savedPro > 0 {
            print("  本地模型已省：按 Flash \(UsageFormat.money(all.savedFlash)) · 按 Pro \(UsageFormat.money(all.savedPro))")
        }
        for entry in set.entries(source: "all").prefix(3) {
            let money: String
            if entry.provider == "deepseek" {
                money = UsageFormat.money(entry.bucket.cost)
            } else if entry.bucket.savedFlash > 0 {
                money = "省 \(UsageFormat.money(entry.bucket.savedFlash))"
            } else {
                money = "—"
            }
            print("  \(entry.model) [\(entry.provider)]  \(money) · \(UsageFormat.tokens(entry.bucket.tokens)) tokens")
        }
    }

    switch UsageLoader.load() {
    case .success(let today, let week, let month, _, _):
        printUsage("今日", today)
        printUsage("近 7 天", week)
        printUsage("本月", month)
    case .unavailable:
        print("未找到 OpenCode 用量数据库")
    case .failed:
        print("读取用量失败")
    }
    exit(0)
}

if CommandLine.arguments.contains("--custom-usage") {
    if let snapshot = CustomUsageLoader.load() {
        func printUsage(_ title: String, _ usage: CustomUsage) {
            let all = usage.all
            print("\(title)：\(UsageFormat.money(all.cost)) · \(UsageFormat.tokens(all.tokens)) tokens")
            for app in usage.ranked.prefix(3) {
                print("  \(app.app)  \(UsageFormat.money(app.bucket.cost)) · \(UsageFormat.tokens(app.bucket.tokens)) tokens")
            }
        }
        printUsage("全部", snapshot.all)
        printUsage("今日", snapshot.today)
        printUsage("近 7 天", snapshot.week)
        printUsage("本月", snapshot.month)
    } else {
        print("未找到自定义用量文件：\(CustomUsageFile.fileURL.path)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--subscriptions") {
    SubscriptionStore.shared.reload()
    let sources = SubscriptionStore.shared.activeSources
    guard !sources.isEmpty else {
        print("还没有配置订阅。打开设置 → 订阅监控 添加。")
        exit(0)
    }
    let group = DispatchGroup()
    for source in sources {
        group.enter()
        SubscriptionLoader.fetch(source) { result in
            let title = source.name.isEmpty ? source.url : source.name
            if let error = result.error {
                print("\(title)：读取失败（\(error)）")
            } else {
                print(title + "：")
                for value in result.values {
                    let left = value.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
                    let used = value.used.map { "\(Int($0.rounded()))%" } ?? "—"
                    print("  \(value.label)：剩 \(left) · 已用 \(used)")
                }
            }
            group.leave()
        }
    }
    group.wait()
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = Pricing.timeZone
    parser.dateFormat = "yyyy-MM-dd HH:mm"

    let cases: [(String, Bool)] = [
        ("2026-10-30 10:00", true),   // 周五上午
        ("2026-10-30 12:00", false),  // 午休
        ("2026-10-30 14:30", true),   // 周五下午
        ("2026-10-30 18:00", false),  // 下班
        ("2026-10-31 10:00", false),  // 周六
        ("2026-10-01 10:00", false),  // 国庆
        ("2026-11-02 09:00", true),   // 周一
        ("2026-11-02 08:59", false),
    ]

    var failed = 0
    for (text, expected) in cases {
        guard let date = parser.date(from: text) else { continue }
        let actual = Pricing.isPeak(date)
        if actual != expected { failed += 1 }
        print("\(text) 期望 \(expected ? "高峰" : "空闲") 实际 \(actual ? "高峰" : "空闲")")
    }
    print(failed == 0 ? "全部通过" : "失败 \(failed) 项")
    exit(failed == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--check") {
    let peak = Pricing.isPeak()
    print("当前：\(peak ? "高峰时段" : "空闲时段")")
    print("北京时间：\(Pricing.timeText(Date()))")
    print("Flash 百万未命中输入费用：\(Money.display(Pricing.cost(tier: .flash, peak: peak, hit: 0, miss: 1_000_000, output: 0)))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let showDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
app.setActivationPolicy(showDock ? .regular : .accessory)

let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
let settingsItem = NSMenuItem(
    title: L.t("设置", "Settings"),
    action: #selector(AppDelegate.openSettings),
    keyEquivalent: ","
)
settingsItem.target = delegate
settingsItem.image = NSImage(size: NSSize(width: 0.1, height: 0.1))
appMenu.addItem(settingsItem)
appMenu.addItem(.separator())
appMenu.addItem(NSMenuItem(
    title: L.t("退出", "Quit"),
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
))
appItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
