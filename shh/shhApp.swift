// shh — 기술 검증 스파이크
// 확인할 것: 투명 패널이 키보드 포커스를 가져가서 한글 입력을 받고, 화면에는 아무것도 안 보이는가?
// ⌃⌥; 전역 단축키로 몰래 입력 모드를 켜고 끕니다. (메뉴바 메뉴로도 가능)

import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct shhApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 창 없는 메뉴바 앱이라 빈 Settings 씬만 둠
        Settings { EmptyView() }
    }
}

// 키보드 포커스를 받을 수 있는 투명 패널
final class InvisiblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: InvisiblePanel!
    private var textView: NSTextView!
    private var isCapturing = false
    private var lastMemo = ""
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock에 안 뜨는 메뉴바 전용 앱으로
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        registerHotKey()
    }

    // MARK: - 전역 단축키 (⌃⌥;)

    // 단축키를 바꾸고 싶으면 이 두 줄만 고치면 됨
    private let hotKeyCode = UInt32(kVK_ANSI_Semicolon)
    private let hotKeyModifiers = UInt32(controlKey | optionKey)

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // 단축키가 눌리면 toggleCapture() 호출
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in delegate.toggleCapture() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x7368_6868), id: 1) // 'shhh'
        let status = RegisterEventHotKey(
            hotKeyCode, hotKeyModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        print(status == noErr ? "단축키 등록 완료" : "단축키 등록 실패: \(status) (다른 앱이나 시스템이 이미 쓰는 조합일 수 있음)")
    }

    func toggleCapture() {
        isCapturing ? stopCapture() : startCapture()
    }

    // MARK: - 메뉴바

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "shh"

        let menu = NSMenu()
        menu.addItem(withTitle: "몰래 입력 시작 (⌃⌥;)", action: #selector(startCapture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "마지막 메모 보기", action: #selector(showLastMemo), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // MARK: - 투명 패널

    private func setupPanel() {
        panel = InvisiblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], // 원래 앱을 비활성화하지 않고 포커스만 가져옴
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        textView = NSTextView(frame: panel.contentView!.bounds)
        textView.delegate = self
        textView.isRichText = false
        textView.drawsBackground = false

        // 글자, 커서, 조합 중인 글자 모두 투명하게
        textView.textColor = .clear
        textView.insertionPointColor = .clear
        textView.typingAttributes = [.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 13)]
        textView.markedTextAttributes = [.foregroundColor: NSColor.clear]

        // 자동 교정·추천 팝업이 뜨면 들키니까 전부 끔
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = .no
        }

        panel.contentView?.addSubview(textView)
    }

    // MARK: - 몰래 입력 모드

    @objc private func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        textView.string = ""
        statusItem.button?.title = "shh·" // 나만 알아챌 상태 표시

        // 메뉴가 완전히 닫힌 뒤에 포커스를 가져와야 안정적
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.orderFrontRegardless()
            self.panel.makeKey()
            self.panel.makeFirstResponder(self.textView)
        }
    }

    private func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false

        textView.unmarkText() // 조합 중이던 마지막 글자 확정
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)

        panel.orderOut(nil)
        statusItem.button?.title = "shh"

        guard !text.isEmpty else { return }
        lastMemo = text
        save(text)
    }

    // Esc는 종료, 백스페이스·엔터만 허용, 나머지(방향키, 선택 등)는 막음
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            stopCapture()
            return true
        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.insertNewline(_:)):
            return false
        default:
            return true
        }
    }

    // 다른 곳을 클릭해서 포커스를 잃으면 자동 종료 (안 그러면 입력이 다른 앱으로 새어 나감)
    func windowDidResignKey(_ notification: Notification) {
        stopCapture()
    }

    // MARK: - 저장

    private func save(_ text: String) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shh", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("memos.md")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let entry = "## \(formatter.string(from: Date()))\n\(text)\n\n"

        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: file, atomically: true, encoding: .utf8)
        }
        print("저장됨: \(file.path)")
    }

    // MARK: - 확인용

    @objc private func showLastMemo() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "마지막 메모"
        alert.informativeText = lastMemo.isEmpty ? "(아직 없음)" : lastMemo
        alert.runModal()
    }
}
