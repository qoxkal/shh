# shh

A macOS menu bar app for invisible note-taking.

단축키로 입력 모드를 켜면 화면에 아무것도 표시하지 않은 채 키보드 입력을 메모로 저장하는 macOS 메뉴바 앱.

## Features

- 전역 단축키 `⌃⌥;`로 입력 모드 토글
- 입력 내용 화면 비표시 (한글 IME 지원)
- 모드 종료 시 메모 1건으로 로컬 저장
- 메뉴바에서 최근 메모 5건 조회
- 대시보드: 메모 목록, 검색, 편집(자동 저장), 복사, 삭제
- Dock 아이콘 및 창 없음 (메뉴바 전용)

## Usage

| 동작 | 키 |
|---|---|
| 입력 모드 시작 | `⌃⌥;` |
| 입력 모드 종료 및 저장 | `⌃⌥;` 또는 `Esc` |
| 삭제 | `Backspace` |
| 최근 메모 조회 | 메뉴바 `shh` 클릭 |
| 대시보드 열기 | 메뉴바 `shh` → 대시보드 열기, 또는 최근 메모 항목 클릭 |

- 입력 모드 중 메뉴바 표시가 `shh` → `shh·`로 변경됨
- 입력 모드 중에는 문자 입력, `Backspace`, `Return`만 허용. 방향키 및 선택 등 커서 이동 동작은 비활성화됨
- 다른 창을 클릭해 포커스를 잃으면 입력 모드가 자동 종료되고 저장됨

## Requirements

- macOS 26.5+
- Xcode (소스 빌드 시)

## Installation

### Releases에서 받기

1. [Releases](https://github.com/qoxkal/shh/releases)에서 최신 버전의 `shh.zip` 다운로드
2. 압축을 풀고 `shh.app`을 `/Applications`로 이동
3. 처음 실행 시 "확인되지 않은 개발자" 경고가 뜨면 우클릭 → **열기** (또는 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**)

업데이트할 때는 메뉴바 `shh` → **종료** 후 새 `shh.app`으로 교체. 기존 메모는 유지됨.

### 소스에서 빌드

```bash
git clone https://github.com/qoxkal/shh.git
open shh/shh.xcodeproj
```

1. Xcode에서 **Product → Archive**
2. Organizer에서 **Distribute App → Custom → Copy App**
3. 생성된 `shh.app`을 `/Applications`로 이동 후 실행

로그인 시 자동 실행: **시스템 설정 → 일반 → 로그인 항목**에 `shh` 추가

## Storage

메모 1건당 마크다운 파일 1개로 저장

```
~/Library/Containers/com.hyeona.shh/Data/Library/Application Support/shh/memos/
├── 2026-11-10 20-04-12.md
├── 2026-11-10 20-31-05.md
└── 2026-11-11 09-15-40.md
```

- 앱 샌드박스 때문에 실제 경로는 `~/Library/Containers/` 아래. 메뉴바 `shh` → **메모 폴더 열기**로 바로 열 수 있음
- 파일 이름이 작성 시각, 파일 내용이 메모 본문. 별도 메타데이터 없음
- 폴더의 파일을 직접 추가·수정·삭제해도 앱에 반영됨
- 로컬에만 저장. 네트워크 통신 없음
- 이전 버전의 `memos.md`는 첫 실행 시 메모별 파일로 자동 변환되고, 원본은 `memos.md.bak`으로 보관됨

## How it works

전역 키 이벤트를 가로채는 방식(CGEventTap 등)을 사용하지 않음.

1. Carbon `RegisterEventHotKey`로 전역 단축키 등록
2. 단축키 입력 시 투명한 `NSPanel`(`.nonactivatingPanel`)이 키보드 포커스를 획득
3. 패널 내 `NSTextView`가 입력을 받음. 텍스트, 커서, 조합 중 문자를 모두 투명 처리
4. 입력 모드 종료 시 패널을 숨기고 내용을 새 마크다운 파일로 저장

이 방식의 특성:
- 손쉬운 사용, 입력 모니터링 등 추가 권한 불필요
- macOS 기본 입력기를 그대로 사용하므로 한글 조합이 정상 동작
- 입력 모드가 아닐 때는 키 입력에 관여하지 않음

## Roadmap

- [ ] 메뉴바 아이콘 변경 / 숨김 옵션
- [ ] 키를 누르고 있는 동안만 마지막 메모를 표시하는 미리보기
- [ ] Touch ID 잠금
- [ ] 단축키 설정
- [ ] 배포 (GitHub Releases, Homebrew)

## License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 qoxkal
