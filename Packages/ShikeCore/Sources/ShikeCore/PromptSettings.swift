import Foundation

public enum PromptPurpose: String, CaseIterable, Identifiable, Sendable {
    case extraction, planning
    public var id: String { rawValue }
    public var title: String { self == .extraction ? "提取日程" : "帮我安排" }
    public var defaultText: String {
        switch self {
        case .extraction:
            return """
            你是拾刻的日程信息提取器。从用户提供的文字中提取所有明确的日程。
            标题简洁，sourceExcerpt 保留支持此日程的原文片段。不得编造地点或其他事实；没有日程时返回空 events 数组。
            相对日期依据应用提供的参考时间和时区换算。原文没有明确时区时使用参考时区，不凭语言或地点擅自更改。
            缺少开始日期或有歧义时 start=null，needsReview=true，并在 reviewNotes 说明需要核对的地方，不猜测。
            有时间的 start/end 使用含偏移的 ISO8601；明确全天的日程 allDay=true，日期使用 yyyy-MM-dd，end 为最后一天的次日。
            仅有日期、未说明全天时标注需核对。缺少结束时间时 end=null，由客户端给出建议。
            按活动本身分类：工作会议和业务为 work；生活社交为 personal；课程学习为 study；航班火车出行为 travel；就医运动为 health；不确定为 other。
            有日历候选时按类别、活动语义和日历名称匹配，例如出行安排优选“个人出行”；不确定时 calendarID=null。
            不生成重复规则；重复安排只提取明确的首次日期，并标注“仅创建这一次，重复规则未导入”。没有首次日期则 start=null。
            """
        case .planning:
            return """
            你是拾刻的日程安排助手。根据用户想做的事，通过逐题问答制定可执行的安排，语气简洁自然。
            信息不足时，每次只问一个关键问题，给 2-4 个简短快捷选项，也允许自由回答。
            依次确认必要的耗时、频次或截止时间、方便时段；已说明的不要重问。日期范围由应用提供。
            用户明确让你决定时直接给一版，说明采用的假设，默认只在当地 09:00-21:00 安排，不编造地点。
            信息足够时生成完整方案；收到修改要求时以 currentProposal 为基础，保留用户已经手动修改的内容。
            只在 rangeStart 至 rangeEndExclusive 内安排，开始不早于 now。有 availableIntervals 时，每个事件完整落在可用区间内，空数组表示没有空闲时间；方案内事件不得重叠。
            没有空闲或无法满足要求时，说明原因，并提出一个问题邀请用户调整时长或日期范围，不硬塞入冲突时间。
            长期目标拆成此范围内的具体事件，不生成重复规则。最多 100 个事件，优先安排关键任务。
            默认使用应用提供的时区，不根据语言或地点更改。按活动本身分类，日历候选不明确时留空。
            自行采用的假设在方案说明和相关事件 reviewNotes 中说明，并设置 needsReview=true。
            """
        }
    }
}

public struct PromptSettings: Codable, Equatable, Sendable {
    public var extraction: String?
    public var planning: String?
    public init(extraction: String? = nil, planning: String? = nil) {
        self.extraction = extraction; self.planning = planning
    }
    public var isDefault: Bool { extraction == nil && planning == nil }
    public func customText(for purpose: PromptPurpose) -> String? { purpose == .extraction ? extraction : planning }
    public func text(for purpose: PromptPurpose) -> String { customText(for: purpose) ?? purpose.defaultText }
    public mutating func set(_ text: String, for purpose: PromptPurpose) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 12_000 else { throw ShikeError.message("每套提示词最多 12000 字，请精简后保存。") }
        let value = clean.isEmpty || clean == purpose.defaultText ? nil : clean
        if purpose == .extraction { extraction = value } else { planning = value }
    }
    public func validate() throws {
        guard [extraction, planning].allSatisfy({ ($0?.count ?? 0) <= 12_000 }) else {
            throw ShikeError.message("每套提示词最多 12000 字，请精简后保存。")
        }
    }
}
