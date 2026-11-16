// 메모 저장소 — 메모 하나 = 마크다운 파일 하나
// 위치: Application Support/shh/memos/2026-11-10 20-04-12.md

import Foundation
import Combine

struct Memo: Identifiable, Hashable {
    let id: URL      // 메모 파일 경로가 곧 ID
    let date: Date
    var text: String

    // 목록에 보일 제목: 첫 번째 줄
    var title: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "(빈 메모)" : trimmed
    }
}

@MainActor
final class MemoStore: ObservableObject {
    @Published private(set) var memos: [Memo] = []         // 최신 순
    @Published private(set) var trashedMemos: [Memo] = []  // 휴지통, 최신 순
    @Published var selection: Memo.ID?                     // 대시보드에서 선택된 메모

    let folderURL: URL       // Application Support/shh/memos
    let trashFolderURL: URL  // Application Support/shh/trash

    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss" // 파일 이름엔 ':'를 못 써서 '-'
        return f
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shh", isDirectory: true)
        folderURL = base.appendingPathComponent("memos", isDirectory: true)
        trashFolderURL = base.appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: trashFolderURL, withIntermediateDirectories: true)

        migrateLegacyFile(at: base.appendingPathComponent("memos.md"))
        reload()
    }

    // MARK: - 읽기

    // 폴더의 .md 파일을 전부 다시 읽음 (Finder에서 직접 고쳐도 반영되게)
    func reload() {
        memos = loadMemos(in: folderURL)
        trashedMemos = loadMemos(in: trashFolderURL)

        if let current = selection, memo(for: current) == nil {
            selection = nil
        }
    }

    // 메모 목록과 휴지통 양쪽에서 찾음
    func memo(for id: Memo.ID) -> Memo? {
        memos.first { $0.id == id } ?? trashedMemos.first { $0.id == id }
    }

    func isTrashed(_ id: Memo.ID) -> Bool {
        trashedMemos.contains { $0.id == id }
    }

    private func loadMemos(in folder: URL) -> [Memo] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "md" }
            .map { url in
                Memo(id: url, date: date(for: url), text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - 쓰기

    @discardableResult
    func create(_ text: String, date: Date = Date()) -> Memo? {
        let url = uniqueURL(for: date)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("저장 실패: \(error)")
            return nil
        }
        let memo = Memo(id: url, date: date, text: text)
        memos.append(memo)
        memos.sort { $0.date > $1.date }
        return memo
    }

    func update(_ id: Memo.ID, text: String) {
        guard let index = memos.firstIndex(where: { $0.id == id }), memos[index].text != text else { return }
        memos[index].text = text
        try? text.write(to: id, atomically: true, encoding: .utf8)
    }

    // MARK: - 휴지통

    // 삭제 = 휴지통 폴더로 옮기기 (파일 이름은 그대로 → 작성 시각 유지)
    func moveToTrash(_ id: Memo.ID) {
        guard let memo = memos.first(where: { $0.id == id }) else { return }
        let destination = uniqueURL(named: id.deletingPathExtension().lastPathComponent, in: trashFolderURL)
        do {
            try FileManager.default.moveItem(at: id, to: destination)
        } catch {
            print("휴지통 이동 실패: \(error)")
            return
        }
        memos.removeAll { $0.id == id }
        trashedMemos.append(Memo(id: destination, date: memo.date, text: memo.text))
        trashedMemos.sort { $0.date > $1.date }
        if selection == id { selection = nil }
    }

    // 복구 = 메모 폴더로 다시 옮기기. 복구된 메모를 선택해줌
    func restore(_ id: Memo.ID) {
        guard let memo = trashedMemos.first(where: { $0.id == id }) else { return }
        let destination = uniqueURL(named: id.deletingPathExtension().lastPathComponent, in: folderURL)
        do {
            try FileManager.default.moveItem(at: id, to: destination)
        } catch {
            print("복구 실패: \(error)")
            return
        }
        trashedMemos.removeAll { $0.id == id }
        memos.append(Memo(id: destination, date: memo.date, text: memo.text))
        memos.sort { $0.date > $1.date }
        selection = destination
    }

    // 영구 삭제 = 파일을 완전히 지움 (되돌릴 수 없음)
    func deletePermanently(_ id: Memo.ID) {
        try? FileManager.default.removeItem(at: id)
        trashedMemos.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func emptyTrash() {
        for memo in trashedMemos {
            try? FileManager.default.removeItem(at: memo.id)
        }
        if let current = selection, isTrashed(current) { selection = nil }
        trashedMemos = []
    }

    // MARK: - 파일 이름 ↔ 날짜

    private func date(for url: URL) -> Date {
        // "2026-11-10 20-04-12 (2)" 같은 이름도 앞 19글자로 날짜를 읽음
        let stem = String(url.deletingPathExtension().lastPathComponent.prefix(19))
        if let date = Self.fileNameFormatter.date(from: stem) { return date }
        // 직접 만든 파일처럼 이름이 형식에 안 맞으면 파일 생성 시각 사용
        return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    // 같은 초에 메모가 두 개 생겨도 덮어쓰지 않게 " (2)"를 붙임
    private func uniqueURL(for date: Date) -> URL {
        uniqueURL(named: Self.fileNameFormatter.string(from: date), in: folderURL)
    }

    private func uniqueURL(named base: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).md")
            n += 1
        }
        return url
    }

    // MARK: - 예전 형식 옮기기

    // 예전엔 memos.md 한 파일에 "## yyyy-MM-dd HH:mm" + 내용으로 쌓았음.
    // 처음 실행할 때 한 번만 메모별 파일로 쪼개고, 원본은 memos.md.bak으로 남겨둠.
    private func migrateLegacyFile(at legacyURL: URL) {
        guard let content = try? String(contentsOf: legacyURL, encoding: .utf8) else { return }

        let headerFormatter = DateFormatter()
        headerFormatter.locale = Locale(identifier: "en_US_POSIX")
        headerFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var entries: [(date: Date, text: String)] = []
        var currentDate: Date?
        var bodyLines: [String] = []

        func flush() {
            guard let date = currentDate else { return }
            let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { entries.append((date, text)) }
        }

        for line in content.components(separatedBy: "\n") {
            if line.range(of: #"^## \d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil {
                flush()
                currentDate = headerFormatter.date(from: String(line.dropFirst(3)))
                bodyLines = []
            } else {
                bodyLines.append(line)
            }
        }
        flush()

        for entry in entries {
            create(entry.text, date: entry.date)
        }

        // 다음 실행 때 또 옮기지 않도록 원본 이름을 바꿔둠
        let backupURL = legacyURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: legacyURL, to: backupURL)
        print("예전 메모 \(entries.count)개를 옮김. 원본: \(backupURL.path)")
    }
}
