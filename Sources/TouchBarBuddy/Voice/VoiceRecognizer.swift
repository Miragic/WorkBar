import Foundation
import Speech
import AVFoundation
import AppKit

/// 语音识别封装：授权、录音、本地识别（zh-CN）、停止，以及「剪贴板 + ⌘V」填入输入框。
///
/// 线程模型：录音启动/停止均在主线程调用；SFSpeechRecognizer 的结果回调统一切回主线程处理，
/// 避免跨线程触碰 AVAudioEngine / UI。
final class VoiceRecognizer: NSObject {

    /// 语音状态（驱动 Touch Bar 语音按钮反馈）。
    enum VoiceState: Equatable {
        case idle
        case listening
        case finished(String)
        case denied
        case failed(String)
    }

    /// 语音识别器不可用。
    enum VoiceError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            "语音识别器不可用（可能未启用 Siri / 无网络 / 语言不支持）"
        }
    }

    private let localeIdentifier: String
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var isRecording = false
    private var didEmitFinal = false
    private var latestTranscript = ""

    /// 状态变化回调（驱动 Touch Bar 语音按钮文案）。
    var onStateChange: ((VoiceState) -> Void)?
    /// 识别完成文本回调（→ 填入输入框）。
    var onTranscript: ((String) -> Void)?
    /// 注入结束回调（成功 true / 失败 false）。
    ///
    /// 为什么需要：语音回显要先上屏、又不能在注入的 ⌘V 前后重建 Touch Bar
    /// （dismiss+present 会抢走 WorkBuddy 的键盘焦点，导致粘贴落空）。
    /// 于是回显先只记数据不重建，等这里回调到达再上屏 —— 零竞态。
    /// - Note: 回调在主线程执行，调用方可直接更新 UI。
    var onInjectionFinished: ((Bool) -> Void)?

    /// - Parameter localeIdentifier: 识别语言，默认 zh-CN（日常开发中文场景）。
    init(localeIdentifier: String = "zh-CN") {
        self.localeIdentifier = localeIdentifier
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        super.init()
    }

    // MARK: - 授权

    /// 申请语音识别 + 麦克风授权。
    /// - Parameter completion: 主线程回调是否全部授权成功。
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async { completion(micGranted) }
            }
        }
    }

    // MARK: - 录音开关

    /// 切换录音：未在录音则开始，正在录音则停止。
    func toggleRecording() {
        if isRecording {
            stop()
        } else {
            begin()
        }
    }

    private func begin() {
        requestAuthorization { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.onStateChange?(.denied)
                tbLog("[WorkBar] 语音/麦克风未授权，请到「系统设置 → 隐私与安全性」开启。")
                return
            }
            do {
                try self.startRecognition()
            } catch {
                self.onStateChange?(.failed(error.localizedDescription))
                tbLog("[WorkBar] 启动语音识别失败: \(error)")
            }
        }
    }

    private func startRecognition() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw VoiceError.unavailable
        }
        cancelExisting()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 优先本地识别（隐私优先）；仅在设备支持时开启，避免不可用时直接失败。
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        latestTranscript = ""
        didEmitFinal = false

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            // 统一切回主线程，避免跨线程触碰音频引擎 / UI。
            DispatchQueue.main.async {
                if let result = result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.handleFinal()
                    }
                }
                if let error = error, self.isRecording {
                    self.handleError(error)
                }
            }
        }

        recognitionRequest = request
        isRecording = true
        onStateChange?(.listening)
    }

    /// 停止录音，产出最终文本（若无 final 回调则 0.8s 后用部分结果兜底）。
    ///
    /// - Important: 这里是曾经的一处**静默失败**。原实现的兜底分支在
    ///   `latestTranscript` 为空时直接 `return`，既不回调文本也不报错 ——
    ///   表现就是「点了结束，然后什么都没发生，也没有任何提示」。
    ///   现在改成：超时仍无文本就明确报「没听清，请再说一次」。
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()

        // 0.8s 是「等 final 回调」与「别让用户干等」的折中：本地识别收尾通常 <0.5s。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, !self.isRecording, !self.didEmitFinal else { return }
            let text = self.latestTranscript
            self.finishCleanup()
            self.didEmitFinal = true
            guard !text.isEmpty else {
                tbLog("[WorkBar] 语音结束但没有识别到文本（可能没说清 / 麦克风没收到声音）")
                self.onStateChange?(.failed("没听清，请再说一次"))
                return
            }
            self.onStateChange?(.finished(text))
            self.onTranscript?(text)
        }
    }

    // MARK: - 填入输入框

    /// 将识别结果填进 WorkBuddy 的输入框。
    ///
    /// 实现全部委托给 `TextInjector`：**先激活 WorkBuddy 并确认它在前台**，再聚焦输入框，
    /// 最后用剪贴板 + ⌘V 写入。这里不再自己发键盘事件 —— 旧实现直接 ⌘V，
    /// 点 Touch Bar 时前台若还是终端/访达，文字就粘到别的 app 里去了。
    ///
    /// - Note: `TextInjector.insert` 是阻塞的（含前台等待 + 粘贴后回读校验，最长约 4s），
    ///   所以放到后台队列跑；结果回主线程再更新 UI，避免 Touch Bar 冻住。
    /// - Note: 失败一律通过 `onStateChange(.failed(_:))` 报给 Touch Bar（红色提示），
    ///   不允许静默吞掉 —— 静默失败用户只会看到「说了话但什么都没发生」。
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        tbLog("[WorkBar] 语音识别完成：\(text.count) 字，开始填入")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TextInjector.insert(text)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if result.ok {
                    if let reason = result.reason {
                        tbLog("[WorkBar] 文字已填入，但有降级情况：\(reason)")
                    } else {
                        tbLog("[WorkBar] 文字已填入 WorkBuddy 输入框。")
                    }
                    // 注入已落盘，此刻重建 Touch Bar 显示回显不会再抢 ⌘V 的焦点。
                    self.onInjectionFinished?(true)
                    return
                }
                let reason = result.reason ?? "填入 WorkBuddy 输入框失败"
                tbLog("[WorkBar] 填入失败：\(reason)")
                self.onInjectionFinished?(false)
                self.onStateChange?(.failed(reason))
            }
        }
    }

    // MARK: - 内部状态处理

    private func handleFinal() {
        guard !didEmitFinal else { return }
        let text = latestTranscript
        finishCleanup()
        didEmitFinal = true
        onStateChange?(.finished(text))
        onTranscript?(text)
    }

    private func handleError(_ error: Error) {
        finishCleanup()
        onStateChange?(.failed(error.localizedDescription))
    }

    /// 清理音频引擎与识别任务（可重复调用，保证幂等）。
    private func finishCleanup() {
        isRecording = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func cancelExisting() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }
}
