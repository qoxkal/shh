// shh — 화면에 아무것도 안 보이게 타이핑만으로 메모하는 맥 메뉴바 앱
// ⌃⌥; 로 몰래 입력 모드를 켜고, 같은 단축키나 Esc로 끄면 메모 1개가 저장됩니다.
// 메뉴바의 shh를 누르면 최근 메모 5개가 보입니다.

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: InvisiblePanel!
    private var textView: NSTextView!
    private var isCapturing = false
    private let recentCount = 5 // 메뉴에 보여줄 최근 메모 개수
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

        // 메뉴 내용은 열릴 때마다 menuNeedsUpdate에서 새로 채움
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // 메뉴가 열리기 직전에 호출됨 → 파일에서 최신 메모를 읽어 목록을 다시 만듦
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(withTitle: "몰래 입력 시작 (⌃⌥;)", action: #selector(startCapture), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let header = NSMenuItem(title: "최근 메모", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let recent = loadMemos().suffix(recentCount).reversed() // 최신이 위로
        if recent.isEmpty {
            let empty = NSMenuItem(title: "  (아직 메모 없음)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for memo in recent {
            let item = NSMenuItem(title: menuTitle(for: memo), action: #selector(showMemo(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = memo
            item.toolTip = memo.text // 마우스를 올리면 전체 내용
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "메모 파일 열기", action: #selector(openMemoFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // "10-30 01:12  첫 줄 내용…" 형태로 짧게
    private func menuTitle(for memo: Memo) -> String {
        let time = String(memo.date.dropFirst(5)) // "yyyy-" 제거
        let lines = memo.text.components(separatedBy: .newlines)
        let first = lines.first ?? ""
        let maxLength = 24
        var preview = String(first.prefix(maxLength))
        if first.count > maxLength || lines.count > 1 { preview += "…" }
        return "\(time)  \(preview)"
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

    // 메모는 ~/Library/Application Support/shh/memos.md 한 파일에 쌓임
    private var memoFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memos.md")
    }

    // memos.md를 읽어서 메모 목록으로 (오래된 순)
    // 파일 형식: "## yyyy-MM-dd HH:mm" 줄 다음에 내용, 그 다음 빈 줄
    private func loadMemos() -> [Memo] {
        guard let content = try? String(contentsOf: memoFileURL, encoding: .utf8) else { return [] }

        var memos: [Memo] = []
        var currentDate: String?
        var bodyLines: [String] = []

        func flush() {
            guard let date = currentDate else { return }
            let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { memos.append(Memo(date: date, text: text)) }
        }

        for line in content.components(separatedBy: "\n") {
            // 날짜 형식까지 정확히 맞는 줄만 제목으로 인식 (메모 안에 "## "를 써도 안 깨지게)
            if line.range(of: #"^## \d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil {
                flush()
                currentDate = String(line.dropFirst(3))
                bodyLines = []
            } else {
                bodyLines.append(line)
            }
        }
        flush()
        return memos
    }

    private func save(_ text: String) {
        let file = memoFileURL

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

    // MARK: - 메모 보기

    // 메뉴에서 메모를 누르면 전체 내용을 보여줌
    @objc private func showMemo(_ sender: NSMenuItem) {
        guard let memo = sender.representedObject as? Memo else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = memo.date
        alert.informativeText = memo.text
        alert.addButton(withTitle: "닫기")
        alert.addButton(withTitle: "복사")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(memo.text, forType: .string)
        }
    }

    // Finder에서 memos.md 위치를 열어줌
    @objc private func openMemoFile() {
        NSWorkspace.shared.activateFileViewerSelecting([memoFileURL])
    }
}

struct Memo {
    let date: String  // "yyyy-MM-dd HH:mm"
    let text: String
}
