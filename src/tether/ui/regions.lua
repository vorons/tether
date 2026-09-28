-- src/tether/ui/regions.lua — dock region renderers: input, footer, banner.
--
-- IN:  every renderer takes (slice, L, P):
--        slice: plain state snapshot built by the facade per paint. Fields:
--          w, content_width, gutter, pad, side, content_w (geometry),
--          input, cursor (editing), busy, busy_started_at_ms (turn status),
--          error_banner, toast (banner/flags),
--          tokens_used, tokens_max, tokens_in, tokens_out,
--          model_name, cfg_provider, cfg_reasoning, cfg_summarize_at,
--          cfg_providers, ws_tilde, home (footer/session cells),
--          login (nil or { buf, provider, flow }) (secret box),
--          catalog (provider catalog or nil — read fresh per paint).
--        L: layout rows (rule/input/palette/footer row indices + heights).
--        P: painter/capability table built once by the facade:
--          dim, muted, red, green, yellow, cyan, rev (role painters),
--          trunc, vlen, to_ascii, cells (string ops),
--          copy (ui_copy table),
--          now_ms() (wall clock), ascii_none() bool, caret_reverse() bool,
--          spinner_interval_ms (80).
--      The provider catalog travels in the slice (it can be re-pointed at
--      runtime by tests/host, so a build-once snapshot would go stale).
--      Pure cells (scroll_indicator, scroll_shift_seq, token_pct,
--      token_usage, format_count, footer_stats, tail_cols, drop_cols,
--      take_cols, input_lines, cursor_line_col) take values only.
-- OUT: renderers return an ORDERED rowmap: array of {row, text} applied by
--      the facade via set_row (terminal I/O stays in the facade). Pure
--      cells return values. No S, no globals, no mutation.
-- EXAMPLE:
--      local rows = regions.render_footer(slice, L, P)  -- {{row, text}}
--      for _, r in ipairs(rows) do set_row(r[1], r[2]) end
local M = {}

local ESC = "\27"

local function scroll_indicator(total, scroll, visible_h)
    if scroll <= 0 then return nil end
    local bottom = total - scroll
    if bottom >= total then return nil end
    local hidden_below = total - bottom
    if hidden_below <= 0 then return nil end
    return hidden_below
end
M.scroll_indicator = scroll_indicator

-- M10: hardware scroll-region shift, adapted from terminal.lua's
-- terminal.scroll approach. Returns an escape sequence that sets DECSTBM
-- (top..bottom inclusive, 1-based screen rows), scrolls the region by
-- |shift| lines with SU (up) / SD (down), then resets the region.
-- Guard rails: zero/nil shift, shift >= region size or an invalid region
-- return "" — the caller then falls back to per-row repaint.
local function scroll_shift_seq(h, top, bottom, shift)
    if not shift or shift == 0 then return "" end
    if not h or not top or not bottom then return "" end
    if top < 1 or bottom > h or top > bottom then return "" end
    local region = bottom - top + 1
    local amount = shift > 0 and shift or -shift
    if amount >= region then return "" end
    local move = (shift > 0)
        and (ESC .. "[" .. amount .. "S")
        or  (ESC .. "[" .. amount .. "T")
    return ESC .. "[" .. top .. ";" .. bottom .. "r" .. move .. ESC .. "[r"
end
M.scroll_shift_seq = scroll_shift_seq

local function token_pct(pct, summarize_at, P)
    summarize_at = summarize_at or 0.7
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    local color = pct >= 0.9 and P.red or (pct >= summarize_at and P.yellow or P.green)
    return color(string.format("%d%%", math.floor(pct * 100)))
end
M.token_pct = token_pct

-- T47: "4.1k/32k (13%)" — used over budget (KiB-style /1024, so the default
-- 32768 budget reads as "32k"), colored by the same thresholds.
local function token_usage(used, max_tokens, summarize_at, P)
    if type(used) ~= "number" or used < 0 then used = 0 end
    if type(max_tokens) ~= "number" or max_tokens <= 0 then max_tokens = 1024 end
    local pct = math.min(used / max_tokens, 1)
    -- the cell reads dim like the rest of the footer; the thresholds only
    -- tint it — nested SGR composes faint with the color (dim yellow/red).
    local tint = nil
    if pct >= 0.9 then tint = P.red
    elseif pct >= (summarize_at or 0.7) then tint = P.yellow end
    local k = function(n)
        local s = string.format("%.1fk", n / 1024)
        return (s:gsub("%.0k$", "k"))
    end
    local s = string.format("%s/%s (%d%%)", k(used), k(max_tokens),
        math.floor(pct * 100 + 0.5))
    if tint then return P.dim(tint(s)) end
    return P.dim(s)
end
M.token_usage = token_usage

-- pi-style-input-and-footer: compact token counts for the footer, mirrored
-- from pi's footer formatter (plain below 1000, one decimal k, rounded k, M).
local function format_count(n)
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    n = math.floor(n)
    if n < 1000 then return tostring(n) end
    if n < 10000 then return string.format("%.1fk", n / 1000) end
    if n < 1000000 then return string.format("%dk", math.floor(n / 1000 + 0.5)) end
    if n < 10000000 then return string.format("%.1fM", n / 1000000) end
    return string.format("%dM", math.floor(n / 1000000 + 0.5))
end
M.format_count = format_count

-- The tail of `s`, at most `maxw` display columns. The footer keeps the model
-- name readable from its end, where the model id actually lives.
local function tail_cols(s, maxw, P)
    if maxw <= 0 then return "" end
    if P.vlen(s) <= maxw then return s end
    local cs = P.cells(s)
    local out, col = {}, 0
    for i = #cs, 1, -1 do
        local c = cs[i]
        if col + c.w > maxw then break end
        table.insert(out, 1, c.t)
        col = col + c.w
    end
    return table.concat(out)
end
M.tail_cols = tail_cols

-- Display-column slicing of a row body: drop `n` columns from the start, and
-- keep at most `width` columns from the start. Both are SGR- and wide-char
-- aware (they walk cells(), not bytes).
local function drop_cols(s, n, P)
    if not s or s == "" or n <= 0 then return s or "" end
    local out, col = {}, 0
    for _, c in ipairs(P.cells(s)) do
        col = col + c.w
        if col > n then out[#out + 1] = c.t end
    end
    return table.concat(out)
end
M.drop_cols = drop_cols

local function take_cols(s, width, P)
    local out, col = {}, 0
    if width <= 0 then return "", 0 end
    for _, c in ipairs(P.cells(s)) do
        if col + c.w > width then break end
        out[#out + 1] = c.t
        col = col + c.w
    end
    return table.concat(out), col
end
M.take_cols = take_cols
-- The footer row composition: `left` at the start, `right` right-aligned and kept
-- at least two columns away. Both sides may carry SGR; widths are display
-- columns. When they cannot both fit, the right side loses its start (so its
-- tail survives) and is dropped only when nothing of it fits; the left side is
-- truncated only when it alone exceeds the row.
local function footer_stats(left, right, width, P)
    if width <= 0 then return "" end
    left, right = left or "", right or ""
    local lw = P.vlen(left)
    if lw >= width then return P.to_ascii(P.trunc(left, width)) end
    local room = width - lw - 2 -- the two columns the model must stay clear of
    local rw = P.vlen(right)
    if rw == 0 or room <= 0 then
        return left .. string.rep(" ", width - lw)
    end
    local kept = rw <= room and right or tail_cols(right, room, P)
    local kw = P.vlen(kept)
    return left .. string.rep(" ", width - lw - kw) .. kept
end
M.footer_stats = footer_stats


local function input_lines(input)
    local out = {}
    local pos = 1
    while true do
        local nl = input:find("\n", pos, true)
        if not nl then
            out[#out + 1] = { text = input:sub(pos), from = pos - 1 }
            break
        end
        out[#out + 1] = { text = input:sub(pos, nl - 1), from = pos - 1 }
        pos = nl + 1
    end
    return out
end
M.input_lines = input_lines

local function cursor_line_col(input, cursor)
    local lines = input_lines(input)
    for i, ln in ipairs(lines) do
        if cursor >= ln.from and cursor <= ln.from + #ln.text then
            return i, cursor - ln.from
        end
    end
    local last = lines[#lines]
    return #lines, #last.text
end
M.cursor_line_col = cursor_line_col

-- Spinner frame from elapsed wall-clock time (TW2: time-based, not
-- paint-count-based). P.now_ms() is the wall clock, P.copy.spinner the
-- frames, P.ascii_none() selects the ASCII set.
local function spinner_glyph(slice, P)
    local frames = P.ascii_none() and P.copy.spinner.ascii or P.copy.spinner.frames
    local ms = 0
    if slice.busy_started_at_ms then
        ms = P.now_ms() - slice.busy_started_at_ms
    end
    return frames[(math.floor(ms / P.spinner_interval_ms) % #frames) + 1]
end
M.spinner_glyph = spinner_glyph

-- TW2 test seam: glyph for a given elapsed-ms (pure, no slice dependency).
local function spinner_glyph_at(ms, P)
    local frames = P.ascii_none() and P.copy.spinner.ascii or P.copy.spinner.frames
    return frames[(math.floor(ms / P.spinner_interval_ms) % #frames) + 1]
end
M.spinner_glyph_at = spinner_glyph_at

-- One input row's body: the line windowed to `width` display columns with the
-- caret inside the window, padded out so every input row and both rules share
-- one display width. `caret_off` is the cursor's byte offset inside `text`, or
-- nil on the rows the cursor is not on.
local function input_row_text(text, caret_off, width, P)
    text = text or ""
    local before, caret, after
    if caret_off then
        before = text:sub(1, caret_off)
        local rest = text:sub(caret_off + 1)
        local ch = rest:match("^" .. utf8.charpattern) or ""
        if P.caret_reverse() then
            -- pi's caret: the cell under the cursor painted in reverse video,
            -- or a reverse-video space at the end of the row
            caret = P.rev(ch ~= "" and ch or " ")
            after = ch ~= "" and rest:sub(#ch + 1) or ""
        else
            caret = "|"
            after = rest
        end
    else
        before, caret, after = text, "", ""
    end
    local caret_col = P.vlen(before)
    local caret_w = P.vlen(caret)
    local total_w = caret_col + caret_w + P.vlen(after)
    local from = 0
    if total_w > width then
        -- scroll right just far enough to bring the caret's own cell inside
        from = math.min(math.max(0, total_w - width),
                        math.max(0, caret_col + caret_w - width))
    end
    local shown = take_cols(drop_cols(before .. caret .. after, from, P), width, P)
    local w = P.vlen(shown)
    if w < width then shown = shown .. string.rep(" ", width - w) end
    return shown
end
M.input_row_text = input_row_text

-- A rule row: the box's top and bottom rules. It can carry the turn's status at
-- the left (pi's "── status ────") and a centered "N more" label naming the
-- input rows the window hides. Always exactly `width` columns, muted in every
-- theme; the ASCII rules come from GLYPH_MAP through muted().
local function rule_row(width, status, label, P)
    if width <= 0 then return "" end
    local glyph = P.copy.rules.glyph
    local function fill(n) return string.rep(glyph, math.max(0, n)) end
    local sw = status and P.vlen(status) or 0
    if status and sw > 0 and sw + 4 <= width then
        local rest = width - 3 - sw - 1
        if label then
            local lw = P.vlen(label)
            local start = math.floor((width - lw) / 2)
            local left_block = 3 + sw + 1
            -- the label survives only when it clears the status by a column
            if lw + 2 <= width and start - left_block >= 1 then
                return P.muted(fill(3)) .. status ..
                    P.muted(" " .. fill(start - left_block) .. label ..
                        fill(width - start - lw))
            end
        end
        return P.muted(fill(3)) .. status .. P.muted(" " .. fill(rest))
    end
    if status and sw > 0 then
        -- too narrow for the "── " head: the status alone, truncated to fit
        return P.trunc(status, width)
    end
    if label then
        local lw = P.vlen(label)
        if lw + 2 <= width then
            local start = math.floor((width - lw) / 2)
            return P.muted(fill(start) .. label .. fill(width - start - lw))
        end
    end
    return P.muted(fill(width))
end
M.rule_row = rule_row

-- The turn's status for the box's top rule: the spinner with Working... while
-- busy. Leading space separates the indicator from the rule's left edge.
local function turn_status(slice, P)
    if slice.busy then
        return " " .. P.cyan(spinner_glyph(slice, P)) .. P.dim(" Working...")
    end
    return nil
end
M.turn_status = turn_status

-- slim-footer-indicators: transient flags only (the one-shot toast);
-- mouse/keyboard mode icons are gone. Everything lives on the single footer row.
local function static_flags(slice, P)
    local out = {}
    if slice.toast then out[#out + 1] = P.green(slice.toast) end
    return out
end
M.static_flags = static_flags

local function render_error_banner(slice, L, P)
    if not slice.error_banner then return {} end
    return { { L.error_row,
        slice.gutter .. P.rev(P.red(" ! ")) .. " " .. P.red(P.trunc(slice.error_banner, slice.content_width - 4)) } }
end
M.render_error_banner = render_error_banner

-- slim-footer-indicators: one dim footer row below the box — path ($HOME → ~),
-- session token stats + context cell, transient flags (toast), and the
-- model right-aligned. Truncation when over width (spec tui Footer): path
-- right-truncate first, then toast dropped, then stats
-- right-truncate; model is handled separately by footer_stats. No reverse
-- video, no mode icons.
local function footer_join(path_s, s_str, f_str, P)
    local SEP = P.dim(" · ")
    local parts = {}
    if path_s ~= "" then parts[#parts + 1] = path_s end
    if s_str ~= "" then parts[#parts + 1] = s_str end
    if f_str ~= "" then parts[#parts + 1] = f_str end
    return table.concat(parts, SEP)
end

local function footer_fit_path(f_str, s_str, slice, P)
    -- separators widen the row by 3 columns per join; reserve room for
    -- them so the truncated path still fits alongside the other blocks
    local rest = 0
    if s_str ~= "" then rest = rest + 3 + P.vlen(s_str) end
    if f_str ~= "" then rest = rest + 3 + P.vlen(f_str) end
    local room = slice.content_width - rest
    if room < 1 then return "" end
    return P.to_ascii(P.trunc(P.dim(slice.ws_tilde), room))
end

local function render_footer(slice, L, P)
    local stats = {}
    if (slice.tokens_in or 0) > 0 then
        stats[#stats + 1] = P.dim("↑" .. format_count(slice.tokens_in))
    end
    if (slice.tokens_out or 0) > 0 then
        stats[#stats + 1] = P.dim("↓" .. format_count(slice.tokens_out))
    end
    if slice.tokens_max and slice.tokens_max > 0 then
        local summarize_at = slice.cfg_summarize_at or 0.7
        -- no estimated prefix: the ≈/· marker in front of the context cell
        -- was dropped (the cell itself already reads as an estimate)
        stats[#stats + 1] = token_usage(slice.tokens_used, slice.tokens_max, summarize_at, P)
    end
    -- blocks joined by `·` separators: path · stats · flags (user request)
    local stats_str = table.concat(stats, P.dim(" · "))

    local flags = static_flags(slice, P)
    local flags_str = #flags > 0 and P.to_ascii(table.concat(flags, " ")) or ""

    -- Visual order: path, stats, flags — joined with ` · ` separators.
    -- Truncation order (spec): path first (to_ascii so ASCII mode gets
    -- "..." not "…"), then toast, then stats — each step
    -- re-fits the path into the room that opened up.
    local f_str, s_str = flags_str, stats_str
    local path_s = footer_fit_path(f_str, s_str, slice, P)
    local left = footer_join(path_s, s_str, f_str, P)

    if P.vlen(left) > slice.content_width then
        -- Drop the toast when over width.
        if slice.toast and f_str:find(P.to_ascii(P.green(slice.toast)), 1, true) then
            f_str = ""
            path_s = footer_fit_path(f_str, s_str, slice, P)
            left = footer_join(path_s, s_str, f_str, P)
        end
    end
    if P.vlen(left) > slice.content_width and f_str ~= "" then
        f_str = ""
        path_s = footer_fit_path(f_str, s_str, slice, P)
        left = footer_join(path_s, s_str, f_str, P)
    end
    if P.vlen(left) > slice.content_width then
        local stats_room = slice.content_width - (path_s ~= "" and P.vlen(path_s) + 3 or 0)
        if stats_room >= 1 then
            s_str = P.to_ascii(P.trunc(s_str, stats_room))
        else
            s_str = ""
        end
        path_s = footer_fit_path(f_str, s_str, slice, P)
        left = footer_join(path_s, s_str, f_str, P)
        if P.vlen(left) > slice.content_width then
            left = P.to_ascii(P.trunc(left, slice.content_width))
        end
    end

    -- right-aligned cell: provider/model · <level> (provider omitted when
    -- unknown; the level always shows, `off` included — spec tui: Footer).
    -- No model chosen drops the slash with it: `llama-cpp · off`, never
    -- a dangling `llama-cpp/`.
    local provider = slice.cfg_provider or nil
    local level = slice.cfg_reasoning or "off"
    local model_cell = provider
        and ((slice.model_name and (provider .. "/" .. slice.model_name) or provider) .. P.copy.footer.sep .. level)
        or ((slice.model_name or "?") .. P.copy.footer.sep .. level)
    return { { L.footer_row, slice.gutter .. footer_stats(left, P.dim(model_cell), slice.content_width, P) } }
end
M.render_footer = render_footer

local function render_input(slice, L, P)
    -- palette-only R5: secret mode paints a masked line in the input box —
    -- never the plaintext, never S.input.
    if slice.login then
        local content_w = slice.content_w
        local side = slice.side
        -- the secret line names what to paste: env var when the provider
        -- takes an API key, device URL for device flows, auth code otherwise.
        -- Templates live in ui_copy (safe-edit zone); dynamic parts appended here.
        local hint = P.copy.secret.paste_key
        local env_name
        local catalog = slice.catalog
        local prov_cfg = slice.cfg_providers and slice.cfg_providers[slice.login.provider]
        if prov_cfg and prov_cfg.api_key_env then
            env_name = prov_cfg.api_key_env
        elseif catalog and catalog.get then
            local entry = catalog.get(slice.login.provider or "")
            if entry then env_name = entry.api_key_env end
        end
        -- dynamic-provider-catalog: api_key_env is a list of vars ("first
        -- set wins") for pipeline presets like opencode — resolve to one
        -- name before concatenating. Nil/"" stays keyless (OAuth/store).
        if catalog and catalog.env_name then
            env_name = catalog.env_name(env_name)
        elseif type(env_name) == "table" then
            env_name = type(env_name[1]) == "string" and env_name[1] or nil
        end
        if env_name and env_name ~= "" then
            hint = hint .. " (" .. env_name .. ")"
        end
        local flow = slice.login.flow
        if flow and flow.device and flow.device_code then
            -- full device flow: the TUI polls; the user just authorizes
            hint = P.copy.secret.open_prefix .. tostring(flow.verification_uri
                or flow.device_url)
                .. P.copy.secret.and_enter .. tostring(flow.user_code or "")
                .. P.copy.secret.waiting_suffix
        elseif flow and flow.device and flow.device_url then
            hint = P.copy.secret.open_prefix .. flow.device_url .. P.copy.secret.paste_token_suffix
        elseif flow and flow.authorize_url then
            hint = hint .. P.copy.secret.or_auth_code
        end
        local label = P.copy.secret.login_prefix .. tostring(slice.login.provider or "") .. ": " .. hint
        local mask = string.rep("*", #(slice.login.buf or ""))
        local text = label .. ": " .. mask
        local out = {
            { L.rule_top_row, slice.gutter .. rule_row(slice.content_width, turn_status(slice, P), nil, P) },
            { L.input_row, slice.gutter .. side .. input_row_text(text, #text, content_w, P) .. side },
        }
        for i = 2, L.input_h do
            out[#out + 1] = { L.input_row + i - 1, slice.gutter .. side .. string.rep(" ", content_w) .. side }
        end
        out[#out + 1] = { L.rule_bottom_row, slice.gutter .. rule_row(slice.content_width, nil, nil, P) }
        return out
    end
    local lines = input_lines(slice.input)
    local total = #lines
    local shown = L.input_h
    local start = 1
    if total > shown then
        local li = cursor_line_col(slice.input, slice.cursor)
        start = li - math.floor(shown / 2)
        if start < 1 then start = 1 end
        if start > total - shown + 1 then start = total - shown + 1 end
    end
    local content_w = slice.content_w
    local side = slice.side
    local cursor_li = cursor_line_col(slice.input, slice.cursor)

    -- pi-style-input-and-footer: the box. The top rule carries the turn's
    -- status and, like the bottom rule, names the input rows the window hides.
    local hidden_above = start - 1
    local hidden_below = total - (start + shown - 1)
    local out = {
        { L.rule_top_row, slice.gutter .. rule_row(slice.content_width, turn_status(slice, P),
            hidden_above > 0 and string.format(P.copy.rules.label_up_fmt, hidden_above) or nil, P) },
    }
    for i = 1, shown do
        local li = start + i - 1
        local ln = lines[li]
        if not ln then
            out[#out + 1] = { L.input_row + i - 1,
                slice.gutter .. side .. string.rep(" ", content_w) .. side }
        else
            local caret_off = (li == cursor_li) and (slice.cursor - ln.from) or nil
            out[#out + 1] = { L.input_row + i - 1,
                slice.gutter .. side .. input_row_text(ln.text, caret_off, content_w, P) .. side }
        end
    end
    out[#out + 1] = { L.rule_bottom_row, slice.gutter .. rule_row(slice.content_width, nil,
        hidden_below > 0 and string.format(P.copy.rules.label_down_fmt, hidden_below) or nil, P) }
    return out
end
M.render_input = render_input

return M
