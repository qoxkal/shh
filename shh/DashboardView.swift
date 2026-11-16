// 대시보드 — 왼쪽: 메모/휴지통 탭 + 검색 + 목록, 오른쪽: 메모 내용 보기/편집

import SwiftUI
import AppKit

private enum DashboardTab: Hashable {
    case memos, trash
}

struct DashboardView: View {
    @EnvironmentObject private var store: MemoStore
    @State private var tab: DashboardTab = .memos
    @State private var query = ""
    @State private var isConfirmingEmptyTrash = false

    private var filteredMemos: [Memo] {
        let source = tab == .memos ? store.memos : store.trashedMemos
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return source }
        return source.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("메모 \(store.memos.count)").tag(DashboardTab.memos)
                    Text("휴지통 \(store.trashedMemos.count)").tag(DashboardTab.trash)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 8)

                HStack(spacing: 6) {
                    TextField("검색", text: $query)
                        .textFieldStyle(.roundedBorder)

                    if tab == .memos {
                        Button {
                            if let memo = store.create("") { store.selection = memo.id }
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("새 메모")
                    } else {
                        Button {
                            isConfirmingEmptyTrash = true
                        } label: {
                            Image(systemName: "trash.slash")
                        }
                        .help("휴지통 비우기")
                        .disabled(store.trashedMemos.isEmpty)
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)

                List(filteredMemos, selection: $store.selection) { memo in
                    MemoRow(memo: memo)
                        .contextMenu {
                            if tab == .memos {
                                Button("휴지통으로 이동") { store.moveToTrash(memo.id) }
                            } else {
                                Button("복구") { store.restore(memo.id) }
                            }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = store.selection, let memo = store.memo(for: id) {
                Group {
                    if store.isTrashed(id) {
                        TrashedMemoDetail(memo: memo)
                    } else {
                        MemoDetail(memo: memo)
                    }
                }
                .id(memo.id) // 다른 메모를 고르면 상태를 새로 만듦
            } else {
                ContentUnavailableView(
                    tab == .memos ? "메모를 선택하세요" : "휴지통",
                    systemImage: tab == .memos ? "note.text" : "trash",
                    description: Text(tab == .memos
                        ? "메모 \(store.memos.count)개"
                        : "삭제한 메모는 여기서 복구하거나 영구 삭제할 수 있어요")
                )
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        // 탭을 바꾸면, 선택된 메모가 그 탭에 없을 때만 선택 해제
        .onChange(of: tab) { _, newTab in
            if let id = store.selection, store.isTrashed(id) != (newTab == .trash) {
                store.selection = nil
            }
        }
        // 메뉴바에서 메모를 눌러 열었을 때 등, 선택된 메모가 있는 탭으로 자동 이동
        .onChange(of: store.selection) { _, id in
            guard let id else { return }
            tab = store.isTrashed(id) ? .trash : .memos
        }
        .confirmationDialog("휴지통을 비울까요?", isPresented: $isConfirmingEmptyTrash) {
            Button("휴지통 비우기", role: .destructive) { store.emptyTrash() }
        } message: {
            Text("휴지통의 메모 \(store.trashedMemos.count)개가 완전히 삭제되고, 되돌릴 수 없어요.")
        }
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

// 일반 메모: 바로 편집 가능
private struct MemoDetail: View {
    @EnvironmentObject private var store: MemoStore
    let memo: Memo

    @State private var text: String

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
                Button {
                    store.moveToTrash(memo.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("휴지통으로 이동")
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
    }
}

// 휴지통 메모: 읽기만 가능, 복구 또는 영구 삭제
private struct TrashedMemoDetail: View {
    @EnvironmentObject private var store: MemoStore
    let memo: Memo

    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("휴지통에 있는 메모", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("복구", systemImage: "arrow.uturn.backward") {
                    store.restore(memo.id)
                }
                Button("영구 삭제", systemImage: "xmark.bin", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Text(memo.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
            }
        }
        .confirmationDialog("이 메모를 영구 삭제할까요?", isPresented: $isConfirmingDelete) {
            Button("영구 삭제", role: .destructive) { store.deletePermanently(memo.id) }
        } message: {
            Text("영구 삭제한 메모는 되돌릴 수 없어요.")
        }
    }
}
