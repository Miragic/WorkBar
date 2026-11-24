import Foundation

/// 纯函数状态机：把 sessions 列表归约为一个 Touch Bar 展示状态（无副作用，可单元测试）。
///
/// 归约优先级（从高到低）：
///   0. `choice`（弹层待选择）——界面卡在一个必须做的选择上，最高优先；
///   1. `pending`（待确认）——需要用户处理；
///   2. `working`（进行中）；
///   3. `completed` 且 `unread`（待读）；
///   4. 其余（含 `archived` / `unknown`）=> `idle`。
///
/// - Note: `sessions` 表暂无明确「失败」列（见 docs/FEASIBILITY.md §2.1），故 MVP 省略失败态。
///   若未来新增失败标记，可在此追加 `.failed` 分支并置于 pending 之后、working 之前。
enum TouchBarStateMachine {

    /// 归约入口。
    ///
    /// - Parameters:
    ///   - sessions: 从 Provider 读取的原始会话列表（顺序保留，供横滑展示）。
    ///   - dialog: 当前检测到的弹层（由 `DialogDetector` 提供）；非空即直接进入 `.choice`。
    /// - Returns: 单一 Touch Bar 展示状态。
    /// - Note: `dialog` 有默认值 `nil`，所以既有调用方 / 测试的行为完全不变。
    static func reduce(_ sessions: [TaskInfo], dialog: DialogSnapshot? = nil) -> TouchBarState {
        // 弹层优先：弹层是需要人立刻做选择的东西，比任何任务状态都紧急。
        if let dialog = dialog {
            return .choice(title: dialog.title, options: dialog.options)
        }

        // 归档会话不参与展示。
        let active = sessions.filter { $0.status != .archived }

        let pending = active.filter { $0.status == .pending }
        if !pending.isEmpty {
            return .pending(tasks: pending)
        }

        // `working` 与 `active` 同属「进行中」一类（`active` 实测为占位会话，但语义归此）。
        let working = active.filter { $0.status == .working || $0.status == .active }
        if !working.isEmpty {
            return .working(tasks: working)
        }

        // 前向兼容保留：实测 `unread` 全库恒为 0，本分支当前不会触发（保留以便将来 WorkBuddy 真正写未读标记）。
        let unread = active.filter { $0.status == .completed && $0.unread }
        if !unread.isEmpty {
            return .unread(tasks: unread)
        }

        return .idle
    }
}
