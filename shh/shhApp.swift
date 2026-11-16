// shh — 화면에 아무것도 안 보이게 타이핑만으로 메모하는 맥 메뉴바 앱
// ⌃⌥; 로 몰래 입력 모드를 켜고, 같은 단축키나 Esc로 끄면 메모 1개가 저장됩니다.
// 메뉴바의 shh → 대시보드 열기에서 메모를 보고, 검색하고, 고칠 수 있습니다.

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
    private let store = MemoStore()

    private var statusItem: NSStatusItem!
    private var panel: InvisiblePanel!
    private var textView: NSTextView!
    private var dashboardWindow: NSWindow?
    private var isCapturing = false
    private var hotKeyRef: EventHotKeyRef?
    private let recentCount = 5 // 메뉴에 보여줄 최근 메모 개수

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

    // 메뉴가 열리기 직전에 호출됨 → 폴더에서 최신 메모를 읽어 목록을 다시 만듦
    func menuNeedsUpdate(_ menu: NSMenu) {
        store.reload()
        menu.removeAllItems()

        menu.addItem(withTitle: "몰래 입력 시작 (⌃⌥;)", action: #selector(startCapture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "대시보드 열기", action: #selector(openDashboardFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let header = NSMenuItem(title: "최근 메모", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let recent = store.memos.prefix(recentCount)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "  (아직 메모 없음)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for memo in recent {
            let item = NSMenuItem(title: menuTitle(for: memo), action: #selector(openMemoFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = memo.id
            item.toolTip = memo.text // 마우스를 올리면 전체 내용
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "메모 폴더 열기", action: #selector(openMemoFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private static let menuDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    // "11-10 20:04  첫 줄 내용…" 형태로 짧게
    private func menuTitle(for memo: Memo) -> String {
        let maxLength = 24
        var preview = String(memo.title.prefix(maxLength))
        if memo.title.count > maxLength || memo.text.contains("\n") { preview += "…" }
        return "\(Self.menuDateFormatter.string(from: memo.date))  \(preview)"
    }

    // MARK: - 대시보드

    @objc private func openDashboardFromMenu() {
        // 메뉴가 완전히 닫힌 뒤에 창을 띄워야 안정적
        DispatchQueue.main.async { self.openDashboard(selecting: nil) }
    }

    @objc private func openMemoFromMenu(_ sender: NSMenuItem) {
        let id = sender.representedObject as? Memo.ID
        DispatchQueue.main.async { self.openDashboard(selecting: id) }
    }

    private func openDashboard(selecting id: Memo.ID?) {
        store.reload()
        if let id { store.selection = id }

        if dashboardWindow == nil {
            let hosting = NSHostingController(rootView: DashboardView().environmentObject(store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "shh"
            window.setContentSize(NSSize(width: 780, height: 500))
            window.isReleasedWhenClosed = false // 닫아도 다시 열 수 있게
            window.center()
            window.setFrameAutosaveName("shhDashboard") // 창 크기·위치 기억
            dashboardWindow = window
        }

        NSApp.activate()
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openMemoFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.folderURL])
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
        textView.inlinePredictionType = .no

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
        store.create(text)
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
        guard (notification.object as? NSWindow) === panel else { return }
        stopCapture()
    }
}
