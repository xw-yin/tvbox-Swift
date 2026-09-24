import Foundation

/// 远程 EPG 节目单服务。
///
/// 直播配置中的 `epg` 字段通常是一个带 `{name}` 占位符的 URL 模板，例如
/// `http://epg.51zmt.top:8000/api/diyp/?ch={name}`。本服务负责：
/// - 按频道名替换占位符并请求节目单；
/// - 兼容 diyp 风格 JSON（`{"epg_data":[...]}`）与裸数组 JSON；
/// - 兼容 `yyyyMMddHHmmss` / `yyyy-MM-dd HH:mm:ss` / `HH:mm` 三种时间格式；
/// - 按频道+日期做内存缓存，避免切台时反复请求。
final class EpgService {
    static let shared = EpgService()

    /// 缓存条目：频道名 ->（缓存日期，节目单）。
    private var cache: [String: (day: String, programs: [Epginfo])] = [:]
    private let lock = NSLock()
    /// 内存缓存有效期（秒）。EPG 按天更新，12 小时足够。
    private let cacheTTL: TimeInterval = 12 * 3600

    private init() {}

    /// 获取指定频道的今日节目单。
    /// - Parameter channelName: 频道名，用于替换 URL 模板中的 `{name}`。
    /// - Returns: 按开始时间排序的节目单；无 EPG 配置或请求失败时返回空数组。
    func programs(for channelName: String) async -> [Epginfo] {
        let name = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let template = await MainActor.run { ApiConfig.shared.liveEpgUrlTemplate }
        guard !template.isEmpty else { return [] }

        let today = Self.dayString(for: Date())
        lock.lock()
        if let entry = cache[name], entry.day == today {
            let programs = entry.programs
            lock.unlock()
            return programs
        }
        lock.unlock()

        guard let url = Self.buildURL(template: template, channelName: name) else { return [] }
        do {
            let data = try await NetworkManager.shared.getData(from: url, timeout: 10)
            let programs = Self.parse(data: data).sorted { $0.sortKey < $1.sortKey }
            lock.lock()
            cache[name] = (day: today, programs: programs)
            lock.unlock()
            return programs
        } catch {
            print("EPG 获取失败: \(name), error: \(error)")
            return []
        }
    }

    /// 清除全部 EPG 缓存（用于源切换后刷新）。
    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - URL 构建

    static func buildURL(template: String, channelName: String) -> URL? {
        let encoded = channelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelName
        var urlString = template
            .replacingOccurrences(of: "{name}", with: encoded)
            .replacingOccurrences(of: "{chn}", with: encoded)
        // 部分模板用 %s 风格占位
        if urlString.contains("%s") {
            urlString = urlString.replacingOccurrences(of: "%s", with: encoded)
        }
        return URL(string: urlString)
    }

    // MARK: - 解析

    private static func parse(data: Data) -> [Epginfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawList: [[String: Any]]
        if let dict = json as? [String: Any],
           let epgData = dict["epg_data"] as? [[String: Any]] {
            // diyp 风格
            rawList = epgData
        } else if let array = json as? [[String: Any]] {
            rawList = array
        } else {
            return []
        }

        var result: [Epginfo] = []
        for (index, item) in rawList.enumerated() {
            let title = (item["title"] as? String) ?? (item["name"] as? String) ?? ""
            guard !title.isEmpty else { continue }
            let startRaw = stringValue(item["start"]) ?? ""
            let endRaw = stringValue(item["end"]) ?? ""
            guard let start = parseTime(startRaw), let end = parseTime(endRaw) else { continue }
            var info = Epginfo()
            info.title = title
            info.startTime = formatHM(start)
            info.endTime = formatHM(end)
            info.index = index
            result.append(info)
        }
        return result
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// 解析三种常见时间格式，返回当日 Date。
    private static func parseTime(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formats = ["yyyyMMddHHmmss", "yyyy-MM-dd HH:mm:ss", "yyyyMMddHHmm", "HH:mm"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            formatter.dateFormat = f
            if let date = formatter.date(from: trimmed) {
                // "HH:mm" 只有时间，补到今天。
                if f == "HH:mm" {
                    return mergeTimeIntoToday(date)
                }
                return date
            }
        }
        return nil
    }

    private static func mergeTimeIntoToday(_ time: Date) -> Date? {
        let cal = Calendar.current
        let timeParts = cal.dateComponents([.hour, .minute], from: time)
        var todayParts = cal.dateComponents([.year, .month, .day], from: Date())
        todayParts.hour = timeParts.hour
        todayParts.minute = timeParts.minute
        return cal.date(from: todayParts)
    }

    private static func formatHM(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Epginfo 排序辅助

private extension Epginfo {
    /// "HH:mm" 转分钟数，用于排序。
    var sortKey: Int {
        let parts = startTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}

// MARK: - NetworkManager 扩展

private extension NetworkManager {
    /// 带超时的原始数据请求。
    func getData(from url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
