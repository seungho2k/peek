# peek

화면 가장자리에 숨어 있는 단 하나의 노트 (macOS 27+). 스펙은 [SPEC.md](SPEC.md).

## 빌드 / 실행

Xcode 없이 Command Line Tools만으로 빌드된다.

```sh
scripts/run.sh            # debug 빌드 후 build/peek.app 재실행
scripts/build.sh release  # build/peek.app 생성 (ad-hoc 서명)
```

설치해서 쓰려면:

```sh
scripts/install.sh        # release 빌드 → /Applications/peek.app 설치 후 실행
```

그다음 ⌥Space로 노트를 열고 ⌘, 로 설정을 열어 `launch-at-login: on`으로 바꾸면 재부팅 후에도 자동으로 뜬다.

## 사용

- ⌥Space로 노트를 열고 닫는다(전역). 노트는 화면 오른쪽 끝(설정에서 왼쪽/아래로 변경)에 붙는다. 입력하려면 노트를 클릭.
- 설정: 노트에서 ⌘, 또는 peek를 한 번 더 실행 → 노트 옆에 텍스트 설정이 뜬다(`key: value`를 고치면 바로 반영).
- 단축키(기본): ⌘B 굵게, ⌘⇧X 취소선, ⌘L 수평선, ⌘↩ 화면 가득 토글, ⌥Space 열기/닫기(전역), Ctrl+H/J/K/L 방향키.
- 데이터: `~/Library/Application Support/peek/note.md`, `images/`.

## 개발

```sh
swift build && .build/debug/Peek --selftest   # 헤드리스 에디터 테스트
```

`Theme.swift`의 색상(애플 메모)과 여백은 추정값이다. Digital Color Meter로 재서 조정하면 된다.

## 폰트

[Pretendard](https://github.com/orioncactus/pretendard) v1.3.9 (Regular, Black)를 `Support/Fonts`에 포함한다. SIL Open Font License 1.1 — `Support/Fonts/LICENSE.txt`.
