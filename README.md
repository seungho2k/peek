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

그다음 화면 끝으로 마우스 → ⌘, 로 설정을 열어 "Launch at Login"을 켜면 재부팅 후에도 자동으로 뜬다.

## 사용

- 화면 오른쪽 끝(설정에서 왼쪽/아래로 변경)에 마우스를 대면 노트가 나오고, 벗어나면 들어간다. 입력하려면 노트를 클릭.
- 설정: 노트에서 ⌘, 또는 peek를 한 번 더 실행.
- 단축키(기본): ⌘0 문서 맨 앞, ⌘B 굵게, ⌘L 수평선, ⌘↩ 화면 가득 토글, ⌥Space 열고 pin(전역), Ctrl+H/J/K/L 방향키.
- 데이터: `~/Library/Application Support/peek/note.md`, `images/`.

## 개발

```sh
swift build && .build/debug/Peek --selftest   # 헤드리스 에디터 테스트
```

`Theme.swift`의 색상(애플 메모)과 여백은 추정값이다. Digital Color Meter로 재서 조정하면 된다.
