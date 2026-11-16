// 대시보드 — 왼쪽: 검색 + 메모 목록, 오른쪽: 메모 내용 보기/편집

import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject private var store: MemoStore
    @State private var query = ""

    private var filteredMemos: [Memo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.memos }
        return store.memos.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("검색", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if let memo = store.create("") { store.selection = memo.id }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("새 메모")
                }
                .padding(8)

                List(filteredMemos, selection: $store.selection) { memo in
                    MemoRow(memo: memo)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } detail: {
            if let id = store.selection, let memo = store.memos.first(where: { $0.id == id }) {
                MemoDetail(memo: memo)
                    .id(memo.id) // 다른 메모를 고르면 편집 상태를 새로 만듦
            } else {
                ContentUnavailableView(
                    "메모를 선택하세요",
                    systemImage: "note.text",
                    description: Text("메모 \(store.memos.count)개")
                )
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

private struct MemoRow: View {
    let memo: Memo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(memo.title)
                .lineLimit(1)
            Text(memo.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct MemoDetail: View {
    @EnvironmentObject private var store: MemoStore
    let memo: Memo

    @State private var text: String
    @State private var isConfirmingDelete = false

    init(memo: Memo) {
        self.memo = memo
        _text = State(initialValue: memo.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(memo.date.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("복사")
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("삭제")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
        }
        // 고칠 때마다 바로 파일에 저장 (저장 버튼 없음)
        .onChange(of: text) { _, newValue in
            store.update(memo.id, text: newValue)
        }
        .confirmationDialog("이 메모를 삭제할까요?", isPresented: $isConfirmingDelete) {
            Button("삭제", role: .destructive) { store.delete(memo.id) }
        } message: {
            Text("삭제한 메모는 되돌릴 수 없어요.")
        }
    }
}
