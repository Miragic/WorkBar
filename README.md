# WorkBar

![WorkBar 在 Touch Bar 上的工作态显示](docs/images/scene-working-detail-crop.png)

**在 Touch Bar 上常驻显示 WorkBuddy 的任务状态——不用切回窗口，就知道它在做什么、做到哪一步、有没有需要你确认。**

WorkBar 是一款 macOS 原生小工具（Swift / AppKit），面向带 Touch Bar 的 MacBook Pro。第一版以 WorkBuddy 为数据源，状态归约与展示层已分层，便于日后接入其他 AI 应用。

> **设计原则**：所有信息无感呈现。不弹窗、不抢焦点、不为了读一个数值打断你的操作。

---

## 功能一览

### 状态显示

Touch Bar 随 WorkBuddy 的状态自动切换：

![空闲态](docs/images/scene-idle-crop.png)

*空闲：今日完成数与积分消耗*

![工作态详情](docs/images/scene-working-detail-crop.png)

*工作态详情：任务标题 + 模型 / 积分 / 上下文 / 时长*

![多任务](docs/images/scene-multi-task-crop.png)

*多任务：标题带 `(1/2)` 序号，横滑切换，详情与序号一起跟着走*

![待确认态](docs/images/scene-pending-crop.png)

*待确认：🙋 举手脸 + 「N 待确认」+ 等你处理的任务条*

![紧凑态](docs/images/scene-compact-crop.png)

*紧凑态：一行标题 + 时长*

![已完成态](docs/images/scene-completed-crop.png)

*已完成态：🎉 完成脸 + 「N 待读」+ 已完成任务条*

| 状态   | 显示内容                    |
| ---- | ----------------------- |
| 空闲   | 「空闲」+ 今日完成数 / 积分消耗      |
| 工作中  | 「N 进行中」+ 聚焦任务标题 + 详情第二行 |
| 待确认  | 「N 待确认」+ 任务条            |
| 已完成  | 「N 待读」+ 🎉 完成脸 + 已完成任务条 |
| 选择弹层 | 弹层标题 + 最多 3 个选项按钮，直接点   |
| 权限弹窗 | 「标题 / 允许 / 取消」+ 勾选项两屏   |

> **关于「已完成」态**：该画面需要 WorkBuddy 在会话结束后写入未读标记（`sessions.unread`）。当前版本实测这个字段恒为 0，因此实际使用时任务完成会直接回到「空闲」，并在「今日 N 完成」里计数。上面这张是按该分支的渲染逻辑拍的前向兼容效果图。

详情第二行依次是：`状态 · 模型 · 本轮积分 · 上下文占用 · 时长`。

- **上下文占用**：环形图标四档 `◔ / ◑ / ◒ / ●`，达到 75% 变橙提醒你该新开会话：

  ![上下文占用 92% 的橙色警告态](docs/images/scene-context-warning-crop.png)
- **任务步骤**：开启后追加 `3/8 当前在做什么` 和一条细进度条：

  ![3/8 步骤进度条](docs/images/scene-task-steps-crop.png)
- **本轮积分**：与 WorkBuddy 界面的「已消耗 ◇ N」一致，不是会话累计。
- **时长**：照搬 WorkBuddy 的「已处理 Xm Ys」，不用数据库时间瞎算。

### 交互

| 操作                | 效果                                   |
| ----------------- | ------------------------------------ |
| 点摘要区              | 激活并跳转到 WorkBuddy                     |
| 点任务条              | 切换紧凑 / 详情视图                          |
| 横滑任务条             | 切换聚焦任务（多任务时标题带 `(1/2)` 序号，和详情一起切换）   |
| 在 WorkBuddy 里切换会话 | Touch Bar 标题与详情自动跟随                  |
| 点弹层 / 权限选项        | 等价于在 WorkBuddy 界面里按那个按钮，按下后摘要短暂变青绿确认 |
| 语音按钮              | 识别结果插入输入框（已实现，当前暂搁置）                 |

---

## 快速开始

### 环境要求

- 带 Touch Bar 的 MacBook Pro（2016–2022 款；没有 Touch Bar 的机型用不了）
- macOS 13 及以上（开发与实测环境是 macOS 15，13 / 14 未充分验证）
- WorkBuddy 安装在 `/Applications/WorkBuddy.app`——WorkBar 只读它的本地数据，没装 WorkBuddy 就没有内容可显示

### 下载安装（推荐，不用编译）

1. 到 **[Releases](https://github.com/Miragic/WorkBar/releases/latest)** 下载 `WorkBar-0.1.0-macos-universal.zip`
   （通用二进制，Apple Silicon 和 Intel 都能跑）
2. 解压，把 `WorkBar.app` 拖进 `/Applications`
3. 首次打开会被系统拦下（本项目没有 Apple 开发者账号、未做公证）。两种放行方式：
   - Finder 里**右键点 WorkBar.app → 打开 → 再点「打开」**
   - 或执行一次：`xattr -dr com.apple.quarantine /Applications/WorkBar.app`
4. 按下一节「首次授权」给辅助功能权限，然后点菜单栏那条胶囊图标

> 校验下载包：`shasum -a 256 WorkBar-0.1.0-macos-universal.zip`，值见对应 Release 说明。

### 从源码构建

```bash
git clone <repository-url> WorkBar
cd WorkBar
./Scripts/build-direct.sh
open build/WorkBar.app
```

> 本机不能用 SwiftPM（Command Line Tools 的编译器与 `libPackageDescription` 版本不一致），构建用 `build-direct.sh`：swiftc 直编 + 签名 + 组装 .app。测试用 `./Scripts/run-tests.sh`。

打发行包（通用二进制 + ad-hoc 签名 + zip，产物进 `dist/`）：

```bash
./Scripts/make-release.sh
```

### 首次授权

1. **辅助功能**（必需）：系统设置 → 隐私与安全性 → 辅助功能 → 打开 WorkBar。用于读取状态、点击选项、语音输入。
2. **语音识别 / 麦克风**（使用语音时）：首次点击语音按钮时系统弹出。

菜单栏那条胶囊图标提供：辅助功能授权入口、打开 WorkBuddy、开机自启、退出。重复启动会自动激活已有实例。

---

## 使用指南

### 设置面板

菜单栏打开设置，WorkBuddy 风格的三栏窗口：

- **常规**：极简模式、默认详情模式、任务步骤、图形上下文图标、常驻显示、空闲统计口径。
  - 空闲统计口径可切换「今日各轮之和」与「本轮消耗」。
- **布局**：DIY 显示 / 隐藏与排序四个 item（状态摘要 / 任务条 / 今日统计 / 语音按钮），带实时预览。宽度固定不可调。
- **关于**：版本、作者、源码地址。

### 常驻行为

Touch Bar 跨 App 切换始终显示 WorkBar（用私有 API 常驻）。切回本工具时自动恢复。

### 数据读取

全部无感只读本地数据，不写 WorkBuddy 任何文件：

- `~/.workbuddy/workbuddy.db`：会话状态、上下文占用、统计
- `~/.workbuddy/tasks/<session_id>/*.json`：待办步骤
- macOS 辅助功能 API：弹层选项、轮次耗时、积分、当前选中会话

### 演示脚本

```bash
./Scripts/demo-context-warning.sh          # 演示 92% 上下文橙色警告
./Scripts/demo-context-warning.sh --restore

./Scripts/demo-task-steps.sh               # 演示 3/8 步骤进度条
./Scripts/demo-task-steps.sh --restore
```

脚本只改 `.verify/` 下的副本，不碰你的真实数据。

## 已知限制

- **语音输入暂搁置**：功能已实现（本地识别 + 注入 + 回读校验），但 Touch Bar 上长按手势与点击会打架，当前不开放「按住说话」。
- **余额 / 成长计划 / 模型倍率**：WorkBuddy 本地无可用接口，不做弹窗读界面的替代方案，因此不显示。
- **Control Strip 宽度**：系统不允许程序化收缩，留给本工具约 290pt。
- **未做公证**：没有 Apple 开发者账号，发行包是 ad-hoc 签名，首次打开需要右键「打开」或清一次 quarantine 属性（见上文安装步骤）。
- **常驻依赖私有 API**：`presentSystemModalTouchBar` 在 macOS 升级后可能失效。
- **常驻显示的代价**：开启后有任务运行时屏幕不会自动熄灭（Touch Bar 亮灭跟随屏幕，系统没有只让 Touch Bar 常亮的公开接口）。

---

## 许可证

个人项目，仅供学习交流。
