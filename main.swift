import AppKit
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

    static func price(_ tier: Tier, peak: Bool) -> Price {
        priceLock.lock()
        defer { priceLock.unlock() }
        let table = tables[tier] ?? (tier == .pro ? .proDefault : .flashDefault)
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
        return (tables[.flash] ?? .flashDefault, tables[.pro] ?? .proDefault)
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
            day = "今天"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
                  cal.isDate(date, inSameDayAs: tomorrow) {
            day = "明天"
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
        if d > 0 { return m == 0 ? "\(d) 天 \(h) 小时" : "\(d) 天 \(h) 小时 \(m) 分" }
        if h > 0 { return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分 \(s) 秒" }
        return "\(s) 秒"
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

    private static func table(from values: [String: Double]) -> PriceTable? {
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
    }

    struct Wallet: Decodable {
        let currency: String?
        let balance: FlexString?
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

            outcome = .success(BalanceSnapshot(currency: currency, normal: normal, bonus: bonus))
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

    private var loading = false
    private var lastLoaded = Date.distantPast

    func refresh(force: Bool = false) {
        if loading { return }
        if !force, Date().timeIntervalSince(lastLoaded) < 60 { return }

        guard let token = TokenFile.load() else {
            state = .needsLogin
            return
        }

        loading = true
        state = .loading

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = BalanceLoader.load(token: token)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
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
    var hit: Int64 = 0
    var miss: Int64 = 0

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
        case .all: return "全部"
        case .today: return "今日"
        case .week: return "近 7 天"
        case .month: return "本月"
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

            if date >= startWeek {
                let day = cal.startOfDay(for: date)
                let key = "\(provider)|\(day.timeIntervalSince1970)"
                if var entry = dailyMap[key] {
                    entry.hit += hit
                    entry.miss += miss
                    dailyMap[key] = entry
                } else {
                    dailyMap[key] = DailyRate(date: day, provider: provider, hit: hit, miss: miss)
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
    @Published var selectedSource: String = "official"
    @Published var showAllRanking = false

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
                    if self.selectedSource != "all",
                       self.selectedSource != "official",
                       self.selectedSource != "custom",
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
        if value <= 0 { return Pricing.money(0, digits: 2) }
        return Pricing.money(value, digits: value >= 0.01 ? 2 : 4)
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
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: startToday),
              let dailyStart = cal.date(byAdding: .day, value: -6, to: startToday) else {
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
            periodStart = dailyStart
            periodEnd = tomorrow
        case .month:
            guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
                  let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else {
                return .failure(.failed("无法读取官方数据"))
            }
            periodStart = monthStart
            periodEnd = monthEnd
        }

        let queryStart = min(periodStart, dailyStart)
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
        var dailyMap: [Date: (hit: Int64, miss: Int64)] = [:]

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
                var dayValue = dailyMap[day] ?? (hit: 0, miss: 0)
                dayValue.hit += hit
                dayValue.miss += miss
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
        for offset in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: offset, to: dailyStart) else { continue }
            let day = cal.startOfDay(for: date)
            let value = dailyMap[day] ?? (hit: 0, miss: 0)
            daily.append(
                DailyRate(date: day, provider: "official", hit: value.hit, miss: value.miss)
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
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        window.title = "登录 DeepSeek 官方（登录后自动获取 Token）"
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
    @Published var tokenDraft = ""
    @Published private(set) var hasToken = false
    @Published var copiedCommand = false
    @Published var showManualToken = false

    private var token: String?
    private var loading = false
    private var lastLoaded = Date.distantPast
    private var lastPeriod: UsagePeriod?
    private var loginWindow: OfficialLoginWindowController?

    init() {
        if let loaded = TokenFile.load() {
            let clean = normalizedToken(loaded)
            if clean.lowercased().hasPrefix("sk-") {
                token = nil
                state = .failed("保存的是 API Key，不是网页 Token")
            } else {
                token = clean
                hasToken = true
                state = .loading
            }
        } else {
            state = .needsToken
        }
    }

    private func normalizedToken(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst(7))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refresh(period: UsagePeriod, force: Bool = false) {
        guard let token else {
            state = .needsToken
            return
        }
        if loading { return }
        if !force, lastPeriod == period, Date().timeIntervalSince(lastLoaded) < 60 {
            return
        }

        loading = true
        if state != .ready { state = .loading }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OfficialUsageLoader.load(period: period, token: token)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
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

    func saveToken(period: UsagePeriod) {
        let trimmed = normalizedToken(tokenDraft)
        guard !trimmed.isEmpty else { return }
        if trimmed.lowercased().hasPrefix("sk-") {
            state = .failed("这是 API Key，不是网页 Token")
            return
        }
        guard TokenFile.save(trimmed) else {
            state = .failed("无法保存 Token 文件")
            return
        }

        token = trimmed
        hasToken = true
        tokenDraft = ""
        state = .loading
        refresh(period: period, force: true)
    }

    func startWebLogin(period: UsagePeriod) {
        loginWindow?.close()
        loginWindow = nil

        let controller = OfficialLoginWindowController(
            onToken: { [weak self] token in
                guard let self else { return }
                let clean = self.normalizedToken(token)
                if clean.lowercased().hasPrefix("sk-") {
                    self.state = .failed("读取到的是 API Key，不是网页 Token")
                } else if TokenFile.save(clean) {
                    self.token = clean
                    self.hasToken = true
                    self.tokenDraft = ""
                    self.state = .loading
                    self.refresh(period: period, force: true)
                } else {
                    self.state = .failed("无法保存 Token 文件")
                }
                self.loginWindow = nil
            },
            onClose: { [weak self] in
                self?.loginWindow = nil
            }
        )
        loginWindow = controller
        controller.show()
    }

    func clearToken() {
        TokenFile.delete()
        token = nil
        hasToken = false
        usage = OfficialUsage()
        expandedKeyID = nil
        state = .needsToken
    }

    func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            "JSON.parse(localStorage.getItem('userToken')).value",
            forType: .string
        )
        copiedCommand = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedCommand = false
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

        let calendar = Pricing.calendar
        let startToday = calendar.startOfDay(for: now)
        guard let startWeek = calendar.date(byAdding: .day, value: -6, to: startToday),
              let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) else {
            return nil
        }

        var snapshot = CustomSnapshot()
        var dailyMap: [Date: (hit: Int64, miss: Int64)] = [:]
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

                let day = calendar.startOfDay(for: date)
                if day < tomorrow {
                    var daily = dailyMap[day] ?? (hit: 0, miss: 0)
                    daily.hit += hit
                    daily.miss += miss
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

        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: startWeek) else { continue }
            let day = calendar.startOfDay(for: date)
            let daily = dailyMap[day] ?? (hit: 0, miss: 0)
            snapshot.daily.append(
                DailyRate(date: day, provider: "custom", hit: daily.hit, miss: daily.miss)
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
                Text(peak ? "距空闲" : "距高峰")
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

final class DonationModel: ObservableObject {
    @Published var show = false
}

struct ContentView: View {
    let onQuit: () -> Void

    @AppStorage("tier") private var tierRaw = Tier.flash.rawValue
    @StateObject private var period = PeriodModel()
    @StateObject private var usage = UsageStore()
    @StateObject private var official = OfficialStore()
    @StateObject private var custom = CustomStore()
    @StateObject private var pricing = PricingStore()
    @StateObject private var balance = BalanceStore.shared
    @StateObject private var donation = DonationModel()

    private var tier: Tier { Tier(rawValue: tierRaw) ?? .flash }
    private var peak: Bool { period.peak }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            priceSection
            Divider()
            usageSection
            Divider()
            balanceRow
            Divider()
            footer
            supportFooter
        }
        .frame(width: 380)
        .sheet(isPresented: $donation.show) { donationSheet }
        .onAppear {
            period.start()
            pricing.refreshIfNeeded()
            balance.refresh(force: true)
            usage.refresh(force: true)
            if usage.selectedSource == "official" {
                official.refresh(period: usage.selectedPeriod, force: true)
            } else if usage.selectedSource == "custom" {
                custom.refresh(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dsUsageRefresh)) { _ in
            if usage.selectedSource == "official" {
                official.refresh(period: usage.selectedPeriod, force: true)
            } else if usage.selectedSource == "custom" {
                custom.refresh(force: true)
            } else {
                usage.refresh(force: true)
            }
        }
        .onChange(of: usage.selectedPeriod) { newPeriod in
            usage.showAllRanking = false
            official.expandedKeyID = nil
            if usage.selectedSource == "official" {
                official.refresh(period: newPeriod, force: true)
            }
            resizeSoon()
        }
        .onChange(of: usage.selectedSource) { source in
            usage.showAllRanking = false
            official.expandedKeyID = nil
            if source == "official" {
                official.refresh(period: usage.selectedPeriod, force: true)
            } else if source == "custom" {
                custom.refresh(force: true)
            }
            resizeSoon()
        }
        .onChange(of: usage.loadCount) { _ in
            resizeSoon()
        }
        .onChange(of: custom.loadCount) { _ in
            resizeSoon()
        }
        .onChange(of: official.hasToken) { _ in
            balance.refresh(force: true)
        }
        .onChange(of: official.state) { _ in
            resizeSoon()
        }
        .onChange(of: official.showManualToken) { _ in
            resizeSoon()
        }
    }

    private func resizeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: .dsResizePopover, object: nil)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(peak ? Color.orange : Color.green)
                    Text(peak ? "高峰时段" : "空闲时段")
                        .font(.system(size: 17, weight: .semibold))
                    Text(peak ? "标准价" : "5 折")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((peak ? Color.orange : Color.green).opacity(0.15)))
                        .foregroundStyle(peak ? Color.orange : Color.green)
                }
                ClockLine()
            }
            Spacer(minLength: 0)
            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭面板")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var priceSection: some View {
        let off = Pricing.price(tier, peak: false)
        let pk = Pricing.price(tier, peak: true)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型价格")
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
                    Text("元 / 百万 tokens")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.leading)
                    Text("空闲")
                        .font(.system(size: 11, weight: peak ? .regular : .bold))
                        .foregroundStyle(peak ? Color.secondary : Color.green)
                        .frame(width: 66, alignment: .trailing)
                    Text("高峰")
                        .font(.system(size: 11, weight: peak ? .bold : .regular))
                        .foregroundStyle(peak ? Color.orange : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
                GridRow {
                    Text("缓存命中").font(.system(size: 12)).gridColumnAlignment(.leading)
                    Text(Pricing.money(off.hit, digits: 2))
                        .font(.system(size: 12, weight: peak ? .regular : .semibold, design: .monospaced))
                        .foregroundStyle(peak ? Color.secondary : Color.primary)
                        .frame(width: 66, alignment: .trailing)
                    Text(Pricing.money(pk.hit, digits: 2))
                        .font(.system(size: 12, weight: peak ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(peak ? Color.primary : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
                GridRow {
                    Text("缓存未命中").font(.system(size: 12)).gridColumnAlignment(.leading)
                    Text(Pricing.money(off.miss, digits: 2))
                        .font(.system(size: 12, weight: peak ? .regular : .semibold, design: .monospaced))
                        .foregroundStyle(peak ? Color.secondary : Color.primary)
                        .frame(width: 66, alignment: .trailing)
                    Text(Pricing.money(pk.miss, digits: 2))
                        .font(.system(size: 12, weight: peak ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(peak ? Color.primary : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
                GridRow {
                    Text("输出").font(.system(size: 12)).gridColumnAlignment(.leading)
                    Text(Pricing.money(off.output, digits: 2))
                        .font(.system(size: 12, weight: peak ? .regular : .semibold, design: .monospaced))
                        .foregroundStyle(peak ? Color.secondary : Color.primary)
                        .frame(width: 66, alignment: .trailing)
                    Text(Pricing.money(pk.output, digits: 2))
                        .font(.system(size: 12, weight: peak ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(peak ? Color.primary : Color.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
            }

            HStack(spacing: 5) {
                Text("\(tier.modelID) · 人民币")
                Spacer()

                if pricing.updating {
                    ProgressView()
                        .controlSize(.mini)
                } else if pricing.updateFailed {
                    Text("更新失败")
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
        return "价格 \(formatter.string(from: date))"
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
        if usage.selectedSource == "official", period == .all {
            return "近 30 天"
        }
        return period.title
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("我的用量")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: $usage.selectedSource) {
                    Text("官方 · 按 Key").tag("official")
                    if customAvailable {
                        Text("自定义 App").tag("custom")
                    }
                    Text("OpenCode · 全部").tag("all")
                    ForEach(usage.providers, id: \.self) { provider in
                        Text("OpenCode · \(providerName(provider))").tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("官方 · 按 Key：DeepSeek 官方账户（所有客户端）；OpenCode · DeepSeek：仅本机 OpenCode 的 DeepSeek 调用；OpenCode · 全部：本机 OpenCode 的所有模型")

                Picker("", selection: $usage.selectedPeriod) {
                    ForEach(UsagePeriod.allCases) { item in
                        Text(periodTitle(item)).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("统计区间：今日 / 近 7 天 / 本月（自然月，月初重置）/ 全部。排行与命中率跟随此区间。")

                Spacer()
                Button {
                    if usage.selectedSource == "official" {
                        official.refresh(period: usage.selectedPeriod, force: true)
                    } else if usage.selectedSource == "custom" {
                        custom.refresh(force: true)
                    } else {
                        usage.refresh(force: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新用量")
            }

            if usage.selectedSource == "official" {
                officialSection
            } else if usage.selectedSource == "custom" {
                customSection
            } else {
                switch usage.state {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("读取中…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                case .ready:
                    ForEach([UsagePeriod.today, .week, .month, .all]) { period in
                        usageRow(
                            period.title,
                            localBucket(period),
                            showCost: sourceHasCost,
                            saved: savedAmount(localBucket(period))
                        )
                    }

                    if sourceHasCost {
                        HStack(spacing: 4) {
                            Text("本地模型已省")
                                .foregroundStyle(.secondary)
                            Text(UsageFormat.money(totalSaved))
                                .fontWeight(.semibold)
                                .foregroundStyle(totalSaved > 0 ? .green : .secondary)
                            Text("按 \(tier.name) 价")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .font(.system(size: 10))
                        .monospacedDigit()
                    }

                    if !sourceEntries.isEmpty {
                        Text("API 用量 · \(periodTitle(usage.selectedPeriod))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)

                        ForEach(Array(displayedSourceEntries.enumerated()), id: \.element.id) { index, api in
                            rankingRow(index + 1, api)
                        }

                        rankingToggle(sourceEntries.count)
                    } else {
                        Text("该时段还没有用量")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    hitRateBlock
                case .unavailable:
                    Text("未找到本机 OpenCode 用量记录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .failed:
                    Text("读取失败，可点右上角刷新")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text(usage.selectedSource == "official"
                     ? "数据来自官方网页接口，按 API Key 排名；Token 只存本机文件（600 权限）。"
                       + (usage.selectedPeriod == .all ? " 接口单次最多约 31 天，故「全部」为近 30 天。" : "")
                     : usage.selectedSource == "custom"
                     ? "自定义 App：读取本地 custom-usage.jsonl，用 --report 或脚本写入。"
                     : "费用只统计 DeepSeek；Ollama 等本地模型按 DeepSeek 同档价格折算「已省」，仅供参考。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if usage.selectedSource == "official", official.hasToken {
                    Button("更换 Token") { official.clearToken() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            Button(usage.showAllRanking ? "收起" : "展开全部 \(count) 个") {
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
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(rank == 1 ? Color.orange : Color.secondary)
                .frame(width: 12)
            Text(api.model)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
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
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
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
                Text("用 --report 上报，或写入 custom-usage.jsonl。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("打开文件夹") {
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
                ForEach([UsagePeriod.today, .week, .month, .all]) { period in
                    usageRow(period.title, customBucket(for: period))
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
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
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
                    Text("读取官方用量…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text("读取失败：\(message)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重试") {
                        official.refresh(period: usage.selectedPeriod, force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("重新登录") { official.startWebLogin(period: usage.selectedPeriod) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Button("更换 Token") { official.clearToken() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            case .ready:
                usageRow(periodTitle(usage.selectedPeriod), official.usage.all)

                if !officialEntries.isEmpty {
                    Text("API Key 用量 · \(periodTitle(usage.selectedPeriod))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)

                    ForEach(Array(displayedOfficialEntries.enumerated()), id: \.element.id) { index, key in
                        officialKeyRow(index + 1, key)
                    }

                    rankingToggle(officialEntries.count)
                } else {
                    Text("该时段没有官方用量")
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
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(rank)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(rank == 1 ? Color.orange : Color.secondary)
                    .frame(width: 12)
                Text(key.name)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(rateText(rate))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(rateColor(rate))
                    .frame(width: 42, alignment: .trailing)
                    .help("命中率 = 命中 ÷（命中 + 未命中）")

                Text(UsageFormat.money(key.bucket.cost))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 66, alignment: .trailing)

                Text(UsageFormat.tokens(key.bucket.tokens))
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .trailing)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 8)
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
            Text(invalid ? "Token 已过期，请重新登录" : "按 API Key 排名需要登录 DeepSeek 官方")
                .font(.system(size: 11, weight: .semibold))

            Text("登录官方页面后自动读取 Token；App 不会保存你的密码。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("登录官方账户（自动获取 Token）") {
                official.startWebLogin(period: usage.selectedPeriod)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Text("它不是 sk- API Key；API Key 只能调用模型和查余额，读不了用量。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $official.showManualToken) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. 登录官方用量页")
                        Text("2. 按 ⌥⌘I 打开开发者工具 → Console")
                        Text("3. 点「复制命令」粘贴并回车")
                        Text("4. 把输出的 Token 粘贴到下面")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Text("JSON.parse(localStorage.getItem('userToken')).value")
                            .font(.system(size: 8.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))

                    SecureField("粘贴 userToken", text: $official.tokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    HStack(spacing: 8) {
                        Button("保存并刷新") {
                            official.saveToken(period: usage.selectedPeriod)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(official.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("打开官方用量页") {
                            if let url = URL(string: "https://platform.deepseek.com/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Button(official.copiedCommand ? "已复制" : "复制命令") {
                            official.copyCommand()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("或手动粘贴 Token")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeBucket: UsageBucket {
        switch usage.selectedSource {
        case "official": return official.usage.all
        case "custom": return customBucket
        default: return sourceBucket
        }
    }

    private var activeDaily: [DailyRate] {
        switch usage.selectedSource {
        case "official": return official.usage.daily
        case "custom": return custom.daily
        default: return dailyRates
        }
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

    private var dailyRates: [DailyRate] {
        let source = usage.selectedSource
        let filtered = usage.daily.filter { source == "all" || $0.provider == source }
        let cal = Pricing.calendar

        var byDay: [Date: (hit: Int64, miss: Int64)] = [:]
        for item in filtered {
            let day = cal.startOfDay(for: item.date)
            var aggregate = byDay[day] ?? (hit: 0, miss: 0)
            aggregate.hit += item.hit
            aggregate.miss += item.miss
            byDay[day] = aggregate
        }

        let today = cal.startOfDay(for: Date())
        var result: [DailyRate] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let aggregate = byDay[date] ?? (hit: 0, miss: 0)
            result.append(
                DailyRate(date: date, provider: source, hit: aggregate.hit, miss: aggregate.miss)
            )
        }
        return result
    }

    private var hitRateBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .padding(.vertical, 1)

            HStack(alignment: .firstTextBaseline) {
                Text("缓存命中率")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
            return "还没有输入数据；先在 OpenCode 里正常对话几轮再来看。"
        }
        let pct = String(format: "%.1f", rate * 100)
        if rate >= 0.8 {
            return "命中率 \(pct)%：缓存利用良好。继续在同一会话追问，尽量别改动开头的大段上下文。"
        }
        if rate >= 0.5 {
            return "命中率 \(pct)%：还有提升空间。保持会话连续，把稳定内容放前面、变化内容放后面。"
        }
        return "命中率 \(pct)%：偏低。少频繁新建会话或修改开头提示词，重复的大文件尽量复用同一份上下文。"
    }

    private var balanceRow: some View {
        HStack(spacing: 6) {
            Text("余额")
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
                Text("登录后查看")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("充值") {
                NSWorkspace.shared.open(OfficialLinks.topUp)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                balance.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("刷新余额")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func balanceText(_ snapshot: BalanceSnapshot) -> String {
        balanceMoney(snapshot.total, currency: snapshot.currency)
    }

    private func balanceMoney(_ value: Double, currency: String) -> String {
        let symbol: String
        switch currency.uppercased() {
        case "CNY": symbol = "¥"
        case "USD": symbol = "$"
        default: symbol = currency + " "
        }
        return symbol + String(format: "%.2f", value)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("高峰：周一至周五 9:00–12:00、14:00–18:00（北京时间，法定节假日除外）")
            Text("工作日其余时段、周六周日及法定节假日全天为空闲，价格为高峰的 5 折；缓存写入按未命中计。")
            HStack {
                Button("价格来源：DeepSeek 官方文档") {
                    if let url = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
                Text("人民币").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var supportFooter: some View {
        if donationImage != nil {
            Divider()
            supportButton
        }
    }

    private var supportButton: some View {
        Button {
            donation.show = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cup.and.saucer")
                    .font(.system(size: 9, weight: .semibold))
                Text("请我喝杯咖啡")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看微信赞赏码")
    }

    private var donationSheet: some View {
        VStack(spacing: 12) {
            Text("请我喝杯咖啡")
                .font(.system(size: 16, weight: .semibold))

            if let image = donationImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 280, height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("赞赏码未找到")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("微信扫码 · 感谢支持")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("微信赞赏码")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Button("关闭") { donation.show = false }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 340)
    }

    private var donationImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "donation-qr", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

}

// MARK: - 菜单栏

final class StatusCircleView: NSView {
    var ringColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("DeepSeek 仪表盘")
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var statusView: StatusCircleView?
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = icon
        }

        statusItem = NSStatusBar.system.statusItem(withLength: 18)
        statusItem.autosaveName = "local.deepseekcost.item"

        let view = StatusCircleView(frame: NSRect(x: 0, y: 0, width: 18, height: 22))
        view.onClick = { [weak self] in self?.togglePopover() }
        view.onRightClick = { [weak self] in self?.showMenu() }
        statusItem.view = view
        statusView = view

        BalanceStore.shared.refresh(force: true)

        NotificationCenter.default.addObserver(
            forName: .dsBalanceUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }

        refreshStatus()

        let host = NSHostingController(rootView: ContentView(onQuit: { [weak self] in
            self?.popover.performClose(nil)
        }))
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

        if ProcessInfo.processInfo.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.showPopover()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.showMainWindow()
            }
        } else if !ProcessInfo.processInfo.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showMainWindow()
            }
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
                rootView: ContentView(onQuit: { [weak self] in
                    self?.mainWindow?.orderOut(nil)
                })
            )
            let window = NSWindow(contentViewController: host)
            window.title = "DeepSeek 仪表盘"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()

            host.view.layoutSubtreeIfNeeded()
            window.setContentSize(host.view.fittingSize)
            mainWindow = window
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func toggleDockIcon() {
        let current = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
        let enabled = !current
        UserDefaults.standard.set(enabled, forKey: "showDockIcon")
        NSApp.setActivationPolicy(enabled ? .regular : .accessory)
        if enabled {
            showMainWindow()
        } else {
            mainWindow?.orderOut(nil)
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let statusView else { return }
        refreshStatus()
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
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
            let size = view.fittingSize
            if size.width > 0, size.height > 0, popover.contentSize != size {
                popover.contentSize = size
            }
        }

        if let window = mainWindow, let view = window.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size.width > 0, size.height > 0 {
                window.setContentSize(size)
            }
        }
    }

    private func refreshStatus() {
        guard let view = statusView else { return }
        let peak = Pricing.isPeak()
        let lowBalance = (BalanceStore.shared.snapshot?.total ?? .infinity) < 5

        view.ringColor = lowBalance ? .systemRed : (peak ? .systemOrange : .systemGreen)
        view.needsDisplay = true

        let price = Pricing.price(.flash, peak: peak)
        let balanceLine = lowBalance
            ? "\n余额不足 ¥5，请充值"
            : ""
        view.toolTip = """
        DeepSeek 仪表盘 · \(peak ? "高峰时段" : "空闲时段")
        Flash 输入 \(Pricing.money(price.miss, digits: 2)) / 输出 \(Pricing.money(price.output, digits: 2))（元/百万 tokens）
        左键查看价格与用量，右键更多选项\(balanceLine)
        """
    }

    private func showMenu() {
        let menu = NSMenu()

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isOn ? .on : .off
        menu.addItem(login)

        let source = NSMenuItem(title: "价格来源", action: #selector(openDocs), keyEquivalent: "")
        source.target = self
        menu.addItem(source)

        let billing = NSMenuItem(title: "官方余额", action: #selector(openBilling), keyEquivalent: "")
        billing.target = self
        menu.addItem(billing)

        let topup = NSMenuItem(title: "充值", action: #selector(openTopUp), keyEquivalent: "")
        topup.target = self
        menu.addItem(topup)

        menu.addItem(.separator())

        let windowItem = NSMenuItem(title: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)

        let dockItem = NSMenuItem(title: "在程序坞显示", action: #selector(toggleDockIcon), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = (UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false) ? .on : .off
        menu.addItem(dockItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 DeepSeek 仪表盘", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        guard let statusView else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: statusView.bounds.height + 4),
            in: statusView
        )
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
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
    print("Flash 百万未命中输入费用：\(Pricing.money(Pricing.cost(tier: .flash, peak: peak, hit: 0, miss: 1_000_000, output: 0)))")
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
appMenu.addItem(NSMenuItem(
    title: "退出 DeepSeek 仪表盘",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
))
appItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
