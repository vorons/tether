# Input model: bracketed paste, mouse SGR, keyboard protocol

## Context

- TUI must work across terminals with very different input capabilities:
  kitty (rich keyboard protocol), VTE/Alacritty (modifyOtherKeys), xterm (SGR mouse),
  plain dumb terminals.
- No shared C-side event loop; all key parsing happens in Lua via `read_char`/`read_char_nb`.

## Choice

- **Bracketed paste** (`ESC[200~…ESC[201~`): enabled in non-ASCII mode, parsed in
  `read_key` and returned as `{kind="paste", text=...}`. Multi-line text inserted as-is.
- **Mouse SGR** (`[?1006h`): enabled when `ui.mouse` is not "off". Wheel codes 64/65
  scroll the transcript; press (code 32) on a palette or confirmation row selects the
  clicked item.
- **Keyboard protocol detection**: C `detect_kb_protocol` reads `TERM_PROGRAM`/`TERM`
  → 0 (plain), 1 (kitty → send `ESC[?u`), 2 (modifyOtherKeys/VTE/X11). Status line
  shows `⌨ kitty` when proto==1.
- **Ctrl+J fallback**: in plain terminals, `Ctrl+J` (code 10) inserts a newline,
  since `Enter` submits. Shown in the hint line.
- **OSC 52 clipboard**: `Ctrl+Shift+C` (kitty `ESC[4:53;96C`, X11 `ESC[1;2C` fallback)
  emits `ESC]52;c;<base64>` to copy the last assistant message; base64 encoded in Lua.

## Ruled out

- C-side SGR/mouse parser — would require a C event loop rewrite; Lua is the right layer.
- Clipboard via `pbcopy`/`xclip` as primary — terminal-dependent; OSC 52 is terminal-native.
  Shell fallback added only as a last resort.
