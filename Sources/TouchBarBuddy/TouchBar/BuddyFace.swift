import AppKit

/// Buddy 的五个情绪脸，与 `TouchBarState` 一一对应（外加一个「失败」脸）。
///
/// 为什么用 emoji 而不是自绘矢量：
/// - 本文件渲染出来的图片只有 22×22pt（Touch Bar 高度仅约 30pt），这个尺寸下自绘的
///   眼睛/嘴巴细节会糊成一团，而 emoji 是系统彩色字体位图，同尺寸下清晰得多；
/// - 也省掉一整套 drawRect 里的坐标常数，改脸型只要改 `emoji` 一行。
///
/// - Note: 五张脸**全部**走这里产出的静态 emoji 图。曾经试过给 `.running` 单独自绘一双
///   会眨眼的眼睛（`BuddyEyesView`），用户真机看过效果后否掉了 —— 22pt 里手绘的眼睛不如
///   emoji 耐看。若要动效，方向是用户提供 GIF / 多帧图，届时只需让 `image(for:)`
///   产出多帧 `NSImage`（`SummaryBarView` 的 `NSImageView.animates` 已就绪）。
///   归档见 `archive/2026-11-18-blinking-eyes/`。
///
/// - Note: `.failed` **不由状态机产生** —— 状态机里没有失败态（`sessions` 表也没有失败列）。
///   这个脸只在「瞬时提示是失败语义」时出现，见 `resolve(state:hasFailure:)`。
enum BuddyFace: String, CaseIterable {
    case idle
    case running
    case waiting
    case done
    case failed

    /// 对应 emoji。
    var emoji: String {
        switch self {
        case .idle: return "🌙"     // 小憩
        case .running: return "👀"  // 盯着干活
        case .waiting: return "🙋"  // 举手等你决定
        case .done: return "🎉"     // 完成
        case .failed: return "😞"   // 出错
        }
    }

    /// 表情图片缓存（key 为 emoji 字符串）。
    ///
    /// - Important: 必须缓存。Touch Bar 每次状态变化都会**重建整条 bar**（identifier 内嵌
    ///   generation），不缓存就等于每次重建都重画 5 张位图；emoji 走 CoreText 排版，
    ///   单次成本不高但没必要每次都付。
    /// - Note: 只在主线程读写（所有 Touch Bar 操作都在主线程），故不加锁。
    private static var imageCache: [String: NSImage] = [:]

    /// 渲染成 Touch Bar 按钮用的图片（22×22，emoji 以 18pt 居中绘制）。
    ///
    /// - Parameter face: 目标情绪脸。
    /// - Returns: 可直接赋给 `NSButton.image` 的图片（非模板图，保持 emoji 原色）。
    static func image(for face: BuddyFace) -> NSImage {
        if let cached = imageCache[face.emoji] { return cached }

        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = face.emoji as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18)
            ]
            let textSize = text.size(withAttributes: attributes)
            let origin = NSPoint(x: rect.midX - textSize.width / 2,
                                 y: rect.midY - textSize.height / 2)
            text.draw(at: origin, withAttributes: attributes)
            return true
        }
        // 彩色 emoji 若被当成模板图，系统会把它染成单色（表情就废了）。
        image.isTemplate = false
        imageCache[face.emoji] = image
        return image
    }

    // MARK: - 由状态推导

    /// 结合「当前是否有失败提示」决定该显示哪张脸。
    ///
    /// 为什么失败要盖住状态：出错的瞬间用户最需要知道的是「这次没成」，而不是
    /// 「还有 2 个任务进行中」—— 后者 2 秒后还会在，前者只有这 2 秒能说。
    ///
    /// - Parameters:
    ///   - state: 状态机归约出的展示状态。
    ///   - hasFailure: 当前是否有失败语义的瞬时提示在显示。
    /// - Returns: 失败时固定 `.failed`，否则按状态映射。
    static func resolve(state: TouchBarState, hasFailure: Bool) -> BuddyFace {
        hasFailure ? .failed : state.buddyFace
    }

    /// 从 `previous` 变到当前脸时该播哪种过渡；不需要动效时返回 nil。
    ///
    /// - Note: 只有「完成」和「失败」值得打断用户 —— 空闲⇄进行中⇄待确认之间每几秒就可能
    ///   跳一次，全都加动效会变成噪音，还会和 3 秒轮询打架（看起来像在抽搐）。
    /// - Parameter previous: 上一次显示的脸。
    /// - Returns: `.celebrate` / `.console` / nil。
    func transition(from previous: BuddyFace) -> BuddyFaceTransition? {
        guard previous != self else { return nil }
        switch self {
        case .done: return .celebrate
        case .failed: return .console
        case .idle, .running, .waiting: return nil
        }
    }
}

/// 情绪过渡动效的种类。
///
/// - Note: 之所以要单独一个类型而不是两个 Bool：`makeItem` 的签名已经有 8 个参数了，
///   再塞 `isCelebration` / `isConsole` 两个互斥布尔必然被人同时传 true。
enum BuddyFaceTransition: Equatable {
    /// 完成：图片做一次 1.0 → 1.18 → 1.0 的缩放（总 200ms）。
    case celebrate
    /// 失败：摘要文字短暂变红，200ms 后恢复次要色。
    case console
    /// 确认：点了弹层选项 / 权限允许取消后，摘要文字短暂转成青绿，200ms 后恢复。
    ///
    /// - Note: 这不是「脸变了」带来的动效，而是对用户那一下点击的即时回应 ——
    ///   AXPress 成功后原本完全静默，用户不确定自己有没有点中。用颜色而不是新增
    ///   item：290pt 已铺满，新 item 会把 voice 整块挤掉。
    case acknowledge
}

extension TouchBarState {
    /// 状态 → 情绪脸的映射。
    ///
    /// 映射理由（三类「等」合并成两张脸）：
    /// - `.pending`（有任务待我确认）与 `.choice`（弹层正等我点选项）在用户视角是同一件事
    ///   ——「举手等你决定」，故都用 `.waiting`；
    /// - `.unread`（任务已完成但没看）语义是「干完了」，用 `.done`；
    /// - `.failed` 不在此列，见 `BuddyFace.resolve(state:hasFailure:)`。
    var buddyFace: BuddyFace {
        switch self {
        case .idle: return .idle
        case .working: return .running
        case .pending: return .waiting
        case .choice: return .waiting
        case .unread: return .done
        }
    }
}
