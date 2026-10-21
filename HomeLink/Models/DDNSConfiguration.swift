import Foundation

nonisolated struct CheckTime: Codable, Equatable, Identifiable, Sendable {
    var hour: Int
    var minute: Int
    var id: Int { hour * 60 + minute }
    var label: String { String(format: "%02d:%02d", hour, minute) }
}

nonisolated struct DDNSPlan: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case interval, scheduled }
    enum Repetition: String, Codable, CaseIterable, Sendable { case daily, weekdays, weekly }
    var mode = Mode.interval
    var intervalMinutes = 5
    var repetition = Repetition.daily
    var weekdays = Set([2, 3, 4, 5, 6])
    var times = [CheckTime(hour: 8, minute: 0)]
    var catchUp = true

    func validate() throws {
        if mode == .interval {
            guard (1...10_080).contains(intervalMinutes) else { throw HomeLinkError.message("间隔应为 1 分钟到 7 天。") }
        } else {
            guard !times.isEmpty, times.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else {
                throw HomeLinkError.message("请添加至少一个有效时间。")
            }
            guard Set(times.map(\.id)).count == times.count else { throw HomeLinkError.message("请移除重复的时间。") }
            if repetition == .weekly && (weekdays.isEmpty || !weekdays.isSubset(of: Set(1...7))) {
                throw HomeLinkError.message("请选择至少一个星期。")
            }
        }
    }

    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard (try? validate()) != nil else { return nil }
        if mode == .interval { return date.addingTimeInterval(Double(intervalMinutes) * 60) }
        let days: [Int?] = repetition == .daily ? [nil] :
            (repetition == .weekdays ? Array(2...6) : weekdays.sorted()).map(Optional.some)
        return times.flatMap { time in
            days.compactMap { day in
                calendar.nextDate(after: date, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0, weekday: day),
                                  matchingPolicy: .nextTime, repeatedTimePolicy: .first)
            }
        }.min()
    }

    var summary: String {
        if mode == .interval { return intervalMinutes % 60 == 0 ? "每 \(intervalMinutes / 60) 小时" : "每 \(intervalMinutes) 分钟" }
        let prefix: String
        switch repetition {
        case .daily: prefix = "每天"
        case .weekdays: prefix = "工作日"
        case .weekly:
            let names = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]
            prefix = "每周" + weekdays.sorted().compactMap { names[$0] }.joined(separator: "、")
        }
        return prefix + " " + times.sorted { $0.id < $1.id }.map(\.label).joined(separator: "、")
    }
}

nonisolated struct DDNSConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var domain = ""
    var zoneID = ""
    var recordID = ""
    var trustedNetwork = ""
    var plan = DDNSPlan()
    var nextCheck: Date?
    var lastCheck: Date?
    var lastUpdate: Date?
    var lastIP: String?
    var timeZoneIdentifier: String?

    static func normalizedDomain(_ input: String) throws -> String {
        let domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.utf8.count <= 253, parts.count >= 2,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.utf8.count <= 63 && part.first != "-" && part.last != "-" &&
                  part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }), parts.last!.contains(where: \.isLetter) else {
            throw HomeLinkError.message("请填写完整域名，例如 home.example.com，不包含 https:// 或端口。")
        }
        return domain
    }
}
