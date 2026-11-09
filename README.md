# peek

A note at the edge of your screen. macOS 27+.

## Install

```sh
scripts/make-signing-cert.sh   # once: keeps the Accessibility permission across installs
scripts/install.sh             # builds, installs to /Applications, launches
```

Allow peek in System Settings › Privacy & Security › Accessibility so it can move other windows out of its way.

## Use

- `opt+space` show / hide
- `ctrl+opt+enter` fill the focused window (beside peek when it's open)
- `cmd+b` bold
- `cmd+d` strikethrough
- `cmd+enter` rule
- `cmd+h/j/k/l` arrow keys
- `cmd+0`–`cmd+9` jump to section
- `cmd+,` settings (plain text, applies as you type)

Your note is at `~/Library/Application Support/peek/note.md`.
