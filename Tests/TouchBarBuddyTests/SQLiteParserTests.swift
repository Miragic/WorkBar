import XCTest
import SQLite3
@testable import TouchBarBuddy

/// SQLite sessions 解析单元测试：用 `:memory:` 临时库造表，不依赖真实 workbuddy.db。
final class SQLiteParserTests: XCTestCase {

    private var db: OpaquePointer?

    override func setUp() {
        super.setUp()
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK, "无法打开内存数据库")
    }

    override func tearDown() {
        if let db = db {
            sqlite3_close(db)
        }
        db = nil
        super.tearDown()
    }

    /// 执行任意 SQL（建表 / 插入）。
    private func exec(_ sql: String) {
        guard let db = db else {
            return XCTFail("db 未打开")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            XCTFail("SQL 执行失败: \(message)")
        }
    }

    private func read() throws -> [TaskInfo] {
        guard let db = db else {
            XCTFail("db 未打开")
            return []
        }
        return try SQLiteSessionReader.readSessions(from: db)
    }

    func testMissingTableReturnsEmpty() throws {
        // 未建 sessions 表 => 应返回空，且不抛错。
        let tasks = try read()
        XCTAssertTrue(tasks.isEmpty)
    }

    func testEmptyTableReturnsEmpty() throws {
        exec("CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);")
        let tasks = try read()
        XCTAssertTrue(tasks.isEmpty)
    }

    func testParsesFullRowWithAllColumns() throws {
        exec("""
        CREATE TABLE sessions (
            id TEXT, title TEXT, custom_title TEXT, status TEXT,
            unread INTEGER, model TEXT, group_id TEXT, group_title TEXT, buddy_binding_json TEXT
        );
        INSERT INTO sessions VALUES
            ('s1','原始标题','自定义标题','working',1,'gpt-x','g1','组A','{"buddy_name":"小Buddy"}');
        INSERT INTO sessions VALUES
            ('s2','第二个',NULL,'pending',0,NULL,NULL,NULL,NULL);
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 2)

        let first = tasks[0]
        XCTAssertEqual(first.id, "s1")
        XCTAssertEqual(first.title, "自定义标题") // custom_title 优先于 title
        XCTAssertEqual(first.status, .working)
        XCTAssertTrue(first.unread)
        XCTAssertEqual(first.model, "gpt-x")
        XCTAssertEqual(first.groupID, "g1")
        XCTAssertEqual(first.groupTitle, "组A")
        XCTAssertEqual(first.buddyName, "小Buddy")

        let second = tasks[1]
        XCTAssertEqual(second.id, "s2")
        XCTAssertEqual(second.title, "第二个")
        XCTAssertEqual(second.status, .pending)
        XCTAssertFalse(second.unread)
        XCTAssertNil(second.model)
        XCTAssertNil(second.buddyName)
    }

    func testDynamicColumnsMissingUseDefaults() throws {
        // 只有 id/title/status：其余列缺失应优雅降级，不崩溃。
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('x1','只有标题','completed');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].title, "只有标题")
        XCTAssertEqual(tasks[0].status, .completed)
        XCTAssertFalse(tasks[0].unread)
        XCTAssertNil(tasks[0].groupID)
        XCTAssertNil(tasks[0].model)
    }

    func testUnknownStatusMapsToUnknown() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('u1','怪状态','something_new');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].status, .unknown)
    }

    func testEmptyTitleIsSkipped() throws {
        // title 与 custom_title 均为空的占位行会被跳过（实测 active 占位会话即属此类）。
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, custom_title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('e1', NULL, '', 'working');
        """)

        let tasks = try read()
        XCTAssertTrue(tasks.isEmpty)
    }

    func testNoIDColumnFallsBackToRowid() throws {
        // 无 id 列时退化为 rowid 作为主键。
        exec("""
        CREATE TABLE sessions (title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('无ID','working');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertFalse(tasks[0].id.isEmpty)
        XCTAssertEqual(tasks[0].title, "无ID")
        XCTAssertEqual(tasks[0].status, .working)
    }

    // MARK: - 距上次活动（V13 降级版）

    /// 列缺失 → `activityAge` 为 nil（不是崩、也不是 0）。
    func testMissingActivityColumnYieldsNilAge() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('a1','没有活动列','working');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].activityAge)
    }

    /// 秒级 `last_activity_at`：时长应约等于 30 秒。
    ///
    /// - Note: 放宽到区间断言（25~60）：reader 内部用的是真实 `Date()`，
    ///   测试执行本身会消耗时间，卡精确值必然变成偶发失败。
    func testActivityAgeFromSecondTimestamp() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, last_activity_at INTEGER);
        INSERT INTO sessions VALUES ('a2','刚活动过','working', CAST(strftime('%s','now') AS INTEGER) - 30);
        """)

        let age = try read()[0].activityAge
        guard let age = age else { return XCTFail("应解析出 activityAge") }
        XCTAssertTrue(age >= 25 && age <= 60, "activityAge=\(age) 不在 25~60 区间")
    }

    /// 毫秒级 `last_activity_at`：同样应换算成约 30 秒（单位判断走数量级归一）。
    func testActivityAgeFromMillisecondTimestamp() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, last_activity_at INTEGER);
        INSERT INTO sessions VALUES ('a3','毫秒时间戳','working',
            (CAST(strftime('%s','now') AS INTEGER) - 30) * 1000);
        """)

        let age = try read()[0].activityAge
        guard let age = age else { return XCTFail("毫秒级时间戳应被识别，实际为 nil") }
        XCTAssertTrue(age >= 25 && age <= 60, "activityAge=\(age) 不在 25~60 区间")
    }

    /// 值为 0 / NULL 视为无效（0 若当有效会算出「距今 56 年」）。
    func testZeroOrNullActivityYieldsNilAge() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, last_activity_at INTEGER);
        INSERT INTO sessions VALUES ('a4','零值','working', 0);
        INSERT INTO sessions VALUES ('a5','空值','pending', NULL);
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 2)
        XCTAssertNil(tasks[0].activityAge)
        XCTAssertNil(tasks[1].activityAge)
    }

    /// 两字段都有值且 `updated_at` 更新 → 取 `updated_at`。
    ///
    /// 这是真机的常态（全库 78 行里 `last_activity_at` 没有一次比 `updated_at` 新）：
    /// 若取落后那个，界面会把一条 20 秒前刚有进展的任务显示成「30m」并亮橙。
    ///
    /// - Note: 断言用区间（15~30）而非精确值 —— reader 内部用的是真实 `Date()`，
    ///   测试执行本身要花时间，卡 `== 20` 必然偶发失败。而只要选错字段，
    ///   结果会是 ~1800 秒，区间外判据照样能抓住。
    func testActivityAgePrefersNewerUpdatedAt() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT,
                               last_activity_at INTEGER, updated_at INTEGER);
        INSERT INTO sessions VALUES ('m1','last 落后','working',
            (CAST(strftime('%s','now') AS INTEGER) - 1800) * 1000,
            (CAST(strftime('%s','now') AS INTEGER) - 20) * 1000);
        """)

        let age = try read()[0].activityAge
        guard let age = age else { return XCTFail("应取 updated_at，实际为 nil") }
        XCTAssertTrue(age >= 15 && age <= 30, "activityAge=\(age) 应约为 20s（取 updated_at）")
    }

    /// 两字段都有值且 `last_activity_at` **更新** → 取 `last_activity_at`。
    ///
    /// - Note: 真机库里构造不出这种数据（前者恒落后），但这是 `max` 语义的另一半，
    ///   必须钉住 —— 否则将来 WorkBuddy 改了 `last_activity_at` 的写法，
    ///   这里会悄悄退化成「永远只信 updated_at」。
    func testActivityAgePrefersNewerLastActivity() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT,
                               last_activity_at INTEGER, updated_at INTEGER);
        INSERT INTO sessions VALUES ('m2','updated 落后','working',
            (CAST(strftime('%s','now') AS INTEGER) - 20) * 1000,
            (CAST(strftime('%s','now') AS INTEGER) - 1800) * 1000);
        """)

        let age = try read()[0].activityAge
        guard let age = age else { return XCTFail("应取 last_activity_at，实际为 nil") }
        XCTAssertTrue(age >= 15 && age <= 30, "activityAge=\(age) 应约为 20s（取 last_activity_at）")
    }

    /// 两字段都无效 → nil（不显示，而不是显示「56 年」）。
    func testActivityAgeNilWhenBothTimestampsInvalid() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT,
                               last_activity_at INTEGER, updated_at INTEGER);
        INSERT INTO sessions VALUES ('m3','两者皆无效','working', 0, NULL);
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].activityAge)
    }

    /// `updated_at` 是 ISO 文本时（`sqlite3_column_int64` 会读出 `2026` 这种垃圾数字）不能显示荒谬时长。
    func testTextUpdatedAtDoesNotProduceAbsurdAge() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, updated_at TEXT);
        INSERT INTO sessions VALUES ('m4','文本时间','working','2026-01-01T00:00:00Z');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].activityAge)
    }

    // MARK: - 数据层缺陷回归（基于 2026-11 真机实测）

    func testDeletedRowsAreExcluded() throws {
        // 含 deleted_at 列：已删除的 pending 行必须排除，否则会误报「1 待确认」。
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, deleted_at TEXT);
        INSERT INTO sessions VALUES ('d1','已删除待确认','pending','2026-01-01T00:00:00Z');
        INSERT INTO sessions VALUES ('w1','进行中','working',NULL);
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id, "w1")
        XCTAssertEqual(tasks[0].status, .working)
    }

    func testMissingDeletedAtColumnDegradesGracefully() throws {
        // 旧 schema 无 deleted_at 列：WHERE 自动降级（仅保留 status <> 'archived'），不报错、正常返回。
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('a','甲','working');
        INSERT INTO sessions VALUES ('b','乙','archived');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id, "a")
    }

    func testOrderByUpdatedAtDescending() throws {
        // 有 updated_at 时应按其降序返回（保证单任务/横滑顺序稳定）。
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, updated_at TEXT);
        INSERT INTO sessions VALUES ('old','旧','working','2026-01-01T00:00:00Z');
        INSERT INTO sessions VALUES ('new','新','working','2026-03-01T00:00:00Z');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.map { $0.id }, ["new", "old"])
    }

    func testRowWithEmptyTitleAndCustomTitleIsSkipped() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, custom_title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('x','','','working');
        INSERT INTO sessions VALUES ('y','有标题',NULL,'working');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id, "y")
    }

    func testModelCatalogFillsDisplayNameAndNilMultiplier() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, model TEXT);
        INSERT INTO sessions VALUES ('m1','模型会话','working','deepseek-v4.1-flash');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].model, "deepseek-v4.1-flash")
        XCTAssertEqual(tasks[0].modelDisplayName, "DeepSeek V4.1 Flash")
        XCTAssertNil(tasks[0].modelMultiplier)
    }

    func testUnknownModelRawValuePassesThrough() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT, model TEXT);
        INSERT INTO sessions VALUES ('m2','未知模型','working','gpt-x');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].modelDisplayName, "gpt-x")
        XCTAssertNil(tasks[0].modelMultiplier)
    }

    // MARK: - 上下文占用（session_usage）

    /// `session_usage.used/size` 应按 `session_id` 合并进对应任务。
    func testContextUsageJoinedFromSessionUsage() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('u1','用了一半','working');
        INSERT INTO sessions VALUES ('u2','没有用量行','working');
        CREATE TABLE session_usage (
            session_id TEXT PRIMARY KEY, used INTEGER NOT NULL,
            size INTEGER NOT NULL, updated_at INTEGER NOT NULL, credit_json TEXT
        );
        INSERT INTO session_usage VALUES ('u1', 5300, 10000, 1794990000000, NULL);
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 2)
        // ORDER BY 在无 updated_at 列时不生效，顺序不保证 → 按 id 找。
        let matched = tasks.first { $0.id == "u1" }
        guard let ratio = matched?.contextUsage else {
            return XCTFail("u1 应解析出 contextUsage")
        }
        XCTAssertTrue(abs(ratio - 0.53) < 0.0001, "ratio=\(ratio) 应约为 0.53")

        let missing = tasks.first { $0.id == "u2" }
        XCTAssertNil(missing?.contextUsage, "没有 usage 行的会话不该编一个比例出来")
    }

    /// 没有 `session_usage` 表时不能崩、也不能编数据（旧库 / 只拷贝了 sessions 的库）。
    func testContextUsageNilWhenUsageTableMissing() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('s1','旧库','working');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].contextUsage)
    }

    /// `session_usage` 缺列（例如只有 credit_json 的早期版本）时同样降级为 nil。
    func testContextUsageNilWhenUsageColumnsMissing() throws {
        exec("""
        CREATE TABLE sessions (id TEXT, title TEXT, status TEXT);
        INSERT INTO sessions VALUES ('s2','缺列','working');
        CREATE TABLE session_usage (session_id TEXT PRIMARY KEY, credit_json TEXT);
        INSERT INTO session_usage VALUES ('s2', '{"x":1}');
        """)

        let tasks = try read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].contextUsage)
    }
}
