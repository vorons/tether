# Lua-side JSON handling in tether

## Context

- `agent.lua` must parse tool_call arguments (JSON) that arrive as strings from the LLM.
- The single-binary constraint rules out external Lua C extensions (no `cjson`, no `lua-cjson` loadable lib).
- Design guidelines also warn against `load`-based JSON for untrusted/complex data.

## Choice

- Hand-rolled recursive-descent JSON parser in Lua (`agent.lua`), no C dependency.
  - Handles nested objects, arrays, numbers, booleans, null, escape sequences.
- `api.lua` keeps a *separate* minimal `load`-based `json_decode` for reading its own
  request construction (trusted, internal) and a `parse_json_str` gmatch parser for SSE
  deltas (shallow, fast path).

## Ruled out

- `cjson` / `lua-cjson` C extension — breaks single-binary target.
- `load("return "..s)` for LLM-provided tool args — untrusted input, injection surface.

## Gotchas learned

- **Lua patterns are not C regex**: `[[:space:]]` is NOT a valid Lua pattern — it is
  interpreted as a literal character class of the letters in "space". Use `[%s]` instead.
- **`s:match("^...")` anchors to string start, not offset**: when using a position
  argument, use `s:find(pat, pos)` or `s:match(pat, pos)` without `^`.
- **Scroll wheel SGR codes**: `64` = wheel up, `65` = wheel down (initially swapped).
