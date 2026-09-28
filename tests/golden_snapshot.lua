#!/usr/bin/env lua
-- tests/golden_snapshot.lua — byte-exact render snapshots for the
-- ui-modular-split change (task 1.2 baseline, re-diffed after each cut).
--
-- Usage: lua tests/golden_snapshot.lua [write|check]   (default: write)
--   write: render via M._* seams and store tests/golden/<name>.txt
--   check: render again and fail on any byte difference vs stored files.
--
-- Only seams callable WITHOUT M.run()/S are snapshotted (pure functions +
-- stub-arg renders). Full confirm-menu / ask-block / palette frames need a
-- live S and are covered by tests/lua_tests.lua instead.
local mode = arg and arg[1] or "write"
local GOLDEN_DIR = "tests/golden"

local ui = assert(dofile("src/tether/ui.lua"))
-- Deterministic color depth: snapshots must not depend on the host terminal.
ui._color_depth = "truecolor"
-- Highlight renders through the module with the ui role painter (facade
-- M.highlight_line was removed in proxy-removal 2.4; same bytes).
local hl = assert(loadfile("src/tether/ui/highlight.lua"))()
local function paint(line, lang, state)
    return hl.highlight(line, lang, state, function(role, text) return ui.md_ansi(role, text) end)
end

local cases = {}
local function case(name, fn) cases[#cases + 1] = { name = name, fn = fn } end
local function rows(t) return table.concat(t, "\n") end

-- splash (stub res: fixed version/agents/skills, no filesystem reads)
case("splash_w80", function()
    return rows(ui._splash_rows(
        { version = "v9.9-test", agents = { "~/.tether/AGENTS.md" }, skills = { "review", "deploy" } }, 80, 1))
end)
case("splash_narrow", function()
    return rows(ui._splash_rows(
        { version = "v9.9-test", agents = { "~/.tether/AGENTS.md" }, skills = { "review", "deploy" } }, 20, 0))
end)
case("splash_empty", function() return rows(ui._splash_rows({}, 80, 0)) end)

-- hints: command-palette pairs + every ask-hint phase + ask tabs.
-- Ask view renders through ui_ask_view (M._ask_hint/_render_ask_tabs facades
-- were removed in proxy-removal 2.4/4.3; same bytes via the module).
local ask_view = assert(loadfile("src/tether/ui/ask_view.lua"))()
local ask_copy = assert(loadfile("src/tether/ui/copy.lua"))()
local CMD_PAIRS = {
    { key = "type", act = "filter" }, { key = "↑↓", act = "select" },
    { key = "enter", act = "run" }, { key = "tab", act = "insert" },
    { key = "esc", act = "close" },
}
case("hint_command", function()
    return ui.hint_plain(CMD_PAIRS) .. "\n" .. ui.hint_paint(CMD_PAIRS, 80)
end)
case("hint_ask_phases", function()
    local out = {}
    local function show(label, a, q)
        out[#out + 1] = label .. ": " .. ui.hint_plain(ask_view.ask_hint(a, q or {}, ask_copy))
    end
    show("confirm", { phase = "confirm" })
    show("note", { mode = "note" })
    show("other", { mode = "other" })
    show("multi", { questions = { {}, {} } }, { multi = true })
    show("multiset", { questions = { {}, {} } }, {})
    show("single", { questions = { {} } }, {})
    return table.concat(out, "\n")
end)
case("ask_tabs", function()
    local P = { copy = ask_copy,
        clip = function(s, w)
            if #s <= w then return s end
            return s:sub(1, math.max(w - 3, 0)) .. "..."
        end,
        role = function(kind, text) return ui.md_ansi(kind, text) end,
        muted = function(s) return ui.md_ansi("muted", s) end }
    local r = ask_view.render_tabs(
        { questions = { { question = "Pick one" }, { question = "Longer question two" } } }, 80, P)
    if type(r) == "table" then return table.concat(r, "\n") end
    return tostring(r)
end)

-- footer + token helpers
case("footer", function()
    local out = {
        ui.footer_stats("left-side", "right-side", 80),
        ui.footer_stats("left-side", "right-side", 20),
        ui._strip_sgr(ui.token_usage(4200, 32768)),
        ui._strip_sgr(ui.token_usage(32768, 32768)),
        ui._strip_sgr(ui.token_pct(0.42, 0.7)),
        ui._strip_sgr(ui.token_pct(0.95, 0.7)),
        ui.format_count(999) .. "|" .. ui.format_count(4200) .. "|" .. ui.format_count(1500000),
    }
    return table.concat(out, "\n")
end)

-- markdown roles + highlight samples
case("markdown_roles", function()
    local out = {}
    for _, role in ipairs({ "accent", "warn", "error", "success", "dim", "muted",
        "italic", "reverse", "bold", "comment", "string", "number", "keyword", "code", "heading" }) do
        out[#out + 1] = role .. "=" .. ui.md_ansi(role, "Ab")
    end
    return table.concat(out, "\n")
end)
case("highlight", function()
    local st = {}
    local out = {
        paint("local function f(x) -- comment", "lua", {}),
        paint('print("hi") -- comment', "lua", {}),
        paint("/* block */ int x = 42;", "c", {}),
        paint("def f(): # comment", "python", {}),
        paint("anything at all", "unknownlang", {}),
    }
    return table.concat(out, "\n")
end)

-- fuzzy + mouse + misc pure helpers
case("fuzzy", function()
    local pal = assert(loadfile("src/tether/ui/palette.lua"))()
    return table.concat(pal.fuzzy_rank("md", { "model", "command", "resume", "new" }), ",")
end)
case("mouse", function()
    local function esc(s) return (s:gsub("\27", "<ESC>")) end
    return esc(ui.mouse_tracking_seqs(true)) .. "\n" .. esc(ui.mouse_tracking_seqs(false))
end)
case("misc", function()
    local out = {
        ui.kb_protocol_from_config(nil) == nil and "kb:auto" or "kb:FAIL",
        ui.kb_protocol_from_config("kitty") == 1 and "kb:kitty" or "kb:FAIL",
        "strip:" .. ui._strip_sgr("\27[31mred\27[0m"),
        "ascii:" .. ui.to_ascii("↑↓→"),
        "tilde:" .. ui._tilde_path("/tmp/x"),
    }
    return table.concat(out, "\n")
end)

-- copy-zone coverage: values that live in ui_copy must move a golden
-- when edited (task 2.6 proof). Rendered through the ui facade.
case("copy_zone", function()
    local c = ui._copy
    local out = {
        ui.hint_paint(c.palette_hints.command, 80),
        ui.hint_paint(c.confirm.hint, 80),
        table.concat(c.confirm.options, " | "),
        table.concat(c.confirm.digits, ","),
        c.errors.login_interactive_only,
        c.session.thinking_prefix .. "medium",
    }
    return table.concat(out, "\n")
end)

-- ascii twins run (same splash/hint under ascii mode)
case("ascii_twins", function()
    ui._ascii_mode = true
    local out = {
        rows(ui._splash_rows({ version = "v9.9-test" }, 80, 0)),
        ui.hint_plain(CMD_PAIRS),
        ui.to_ascii("↑↓ → • ─ │"),
    }
    ui._ascii_mode = nil
    return table.concat(out, "\n")
end)

local failures = 0
for _, c in ipairs(cases) do
    local ok, rendered = pcall(c.fn)
    if not ok then
        io.stderr:write("SNAPSHOT ERROR " .. c.name .. ": " .. tostring(rendered) .. "\n")
        failures = failures + 1
    else
        local path = GOLDEN_DIR .. "/" .. c.name .. ".txt"
        if mode == "check" then
            local f = io.open(path, "rb")
            local stored = f and f:read("*a")
            if f then f:close() end
            if stored ~= rendered then
                io.stderr:write("SNAPSHOT DIFF " .. c.name .. "\n")
                failures = failures + 1
            end
        else
            local f = assert(io.open(path, "wb"))
            f:write(rendered)
            f:close()
        end
    end
end
if mode == "check" and failures == 0 then print("golden snapshots: all clean") end
if failures > 0 then os.exit(1) end
if mode == "write" then print("golden snapshots written: " .. #cases) end
