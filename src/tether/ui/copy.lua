-- src/tether/ui/copy.lua — SAFE-EDIT ZONE for human copy changes.
--
-- IN:  nothing (this file takes no arguments, reads no globals, no S).
-- OUT: returns the `ui_copy` table: sectioned UI strings (splash, hints,
--      footer labels, slash-command list, confirm/ask texts, secret-mode
--      templates, error texts). Data only — no functions, no logic.
-- EXAMPLE (plain Lua, no host binary needed):
--      local copy = ui._copy  -- same table the ui facade reads
--      assert(copy.confirm.options[1] == "[once]     allow once")
--
-- RULES (enforced by the TCOPY guard test in tests/lua_tests.lua):
--   1. Only string / string-list / {key,act}-pair values. No functions.
--   2. No globals, no file access, no host calls, no loading of other files.
--   3. Editing a string here must never change control flow: call sites
--      read these values, they never branch on them.
-- Rendered output is byte-identical to the literals this table replaces
-- (verified by tests/golden_snapshot.lua diffs + `make test`).
local M = {}

-- Startup splash block.
M.splash = {
    wordmark = {
        " ▀█▀ █▀▀ ▀█▀ █░█ █▀▀ █▀█",
        " ░█░ ██▄ ░█░ █▀█ ██▄ █▀▄",
    },
    narrow_title = " Tether",
    context_header = "[Context]",
    skills_header = "[Skills]",
    extensions_header = "[Extensions]",
}

-- Out-of-workspace confirmation menu.
M.confirm = {
    digits = { "allow", "session", "always", "deny", "cancel" },
    questions = {
        run = "Allow command execution?",
        write = "Allow writing this file?",
        patch = "Allow applying this patch?",
    },
    question_fallback = "Allow this action?",
    hint = {
        { key = "↑↓", act = "select" },
        { key = "enter", act = "submit" },
        { key = "esc", act = "dismiss" },
    },
    options = {
        "[once]     allow once",
        "[session]  allow until the session ends",
        "[always]   save to auto_approve",
        "[deny]     decline",
    },
    danger_warning = "⚠ potentially dangerous command",
}

-- Per-mode dock hint rows ({key, act} pairs; key tokens dim, acts muted).
M.palette_hints = {
    command = { { key = "type", act = "filter" }, { key = "↑↓", act = "select" },
                { key = "enter", act = "run" }, { key = "tab", act = "insert" },
                { key = "esc", act = "close" } },
    path = { { key = "tab", act = "cycle" }, { key = "esc", act = "restore" } },
    mention = { { key = "type", act = "filter" }, { key = "↑↓", act = "move" },
                { key = "enter/tab", act = "insert" }, { key = "esc", act = "close" } },
    copy = { { key = "↑↓", act = "select" }, { key = "enter", act = "copy" },
             { key = "esc", act = "close" } },
    resume = { { key = "↑↓", act = "select" }, { key = "enter", act = "resume" },
               { key = "esc", act = "dismiss" } },
    model = { { key = "type", act = "filter" }, { key = "↑↓", act = "select" },
              { key = "enter", act = "pick" }, { key = "esc", act = "close" } },
    login = { { key = "type", act = "filter" }, { key = "↑↓", act = "select" },
              { key = "enter", act = "connect" }, { key = "esc", act = "close" } },
    logout = { { key = "type", act = "filter" }, { key = "↑↓", act = "select" },
               { key = "enter", act = "confirm" }, { key = "esc", act = "close" } },
    ["logout-confirm"] = { { key = "↑↓", act = "select" },
                           { key = "enter", act = "delete" },
                           { key = "y/n", act = "choose" }, { key = "esc", act = "back" } },
    think = { { key = "↑↓", act = "select" }, { key = "enter", act = "set" },
              { key = "esc", act = "close" } },
}

-- Built-in slash commands (declared order = palette order).
M.commands = {
    { label = "/clear",   desc = "clear the transcript",            cmd = "clear" },
    { label = "/compact", desc = "compact context (summarize)",       cmd = "compact" },
    { label = "/model",   desc = "switch model",                      cmd = "model" },
    { label = "/resume",  desc = "resume session for workspace",      cmd = "resume" },
    { label = "/new",     desc = "start a new session",               cmd = "new" },
    { label = "/quit",    desc = "exit",                              cmd = "quit" },
    { label = "/copy",    desc = "copy from the transcript",          cmd = "copy" },
    { label = "/login",   desc = "log in with a provider (API key/OAuth)", cmd = "login" },
    { label = "/logout",  desc = "log out from a provider (drop the key)",  cmd = "logout" },
    { label = "/think",   desc = "thinking level",                    cmd = "think" },
}

-- Documented keyboard bindings (help/keymap surface, no behavior).
M.keys = {
    map = {
        ["enter"]      = "send",
        ["ctrl+j"]     = "newline",
        ["ctrl+c"]     = "abort/quit",
        ["ctrl+q"]     = "quit",
        ["ctrl+r"]     = "resume picker",
        ["ctrl+n"]     = "new session",
        ["ctrl+o"]     = "toggle newest tool result",
        ["ctrl+shift+o"] = "expand/collapse all tool results",
        ["ctrl+t"]     = "toggle thinking",
        ["ctrl+l"]     = "clear screen",
        ["ctrl+a"]     = "line start",
        ["ctrl+e"]     = "line end",
        ["ctrl+u"]     = "kill to start",
        ["ctrl+w"]     = "kill word",
        ["ctrl+k"]     = "kill to end",
        ["ctrl+up"]    = "history prev",
        ["ctrl+down"]  = "history next",
        ["up"]         = "history prev / cursor up (multi-line, Shift+)",
        ["down"]       = "history next / cursor down (multi-line, Shift+)",
        ["pgup"]       = "scroll up",
        ["pgdn"]       = "scroll down",
        ["home"]       = "jump to top (input empty)",
        ["end"]        = "jump to bottom (input empty)",
        ["esc"]        = "cancel/confirmation deny",
        ["1"]          = "confirm allow",
        ["2"]          = "confirm session",
        ["3"]          = "confirm always",
        ["4"]          = "confirm deny",
        ["5"]          = "confirm cancel",
        ["y"]          = "confirm allow",
        ["a"]          = "confirm session",
        ["A"]          = "confirm always",
        ["n"]          = "confirm deny",
    },
    ask = {
        ["up"]        = "previous option",
        ["down"]      = "next option",
        ["enter"]     = "submit / accept the question",
        ["1"]         = "pick option 1",
        ["space"]     = "pick the highlighted option (toggle on a multi question)",
        ["tab"]       = "edit the highlighted option's note / the freeform answer",
        ["left"]      = "previous question",
        ["right"]     = "next question",
        ["esc"]       = "cancel the question set",
        ["backspace"] = "edit the open note / freeform editor",
    },
}

-- Structured-question (ask) block view strings.
M.ask = {
    confirm_tab = "Confirm",
    hints = {
        confirm = { { key = "⇆", act = "tab" }, { key = "enter", act = "submit" },
                    { key = "esc", act = "dismiss" } },
        note = { { key = "type", act = "note" }, { key = "Enter", act = "save" },
                 { key = "Esc", act = "discard" } },
        other = { { key = "type", act = "answer" }, { key = "Enter", act = "save" },
                  { key = "Esc", act = "discard" } },
        multi = { { key = "↑↓", act = "move" }, { key = "Space", act = "toggle" },
                  { key = "Enter", act = "accept" }, { key = "Tab", act = "note" },
                  { key = "Esc", act = "cancel" } },
        multiset = { { key = "⇆", act = "tab" }, { key = "↑↓", act = "select" },
                     { key = "enter", act = "confirm" }, { key = "esc", act = "dismiss" } },
        -- ask-block-redesign: named only past the first question (qidx > 1);
        -- ask_hint splices it after the navigation pairs of the list hints.
        back = { key = "←", act = "back" },
        single = { { key = "↑↓", act = "select" }, { key = "enter", act = "submit" },
                   { key = "esc", act = "dismiss" } },
    },
}

-- Login secret-mode line templates (dynamic parts appended by ui.lua).
M.secret = {
    paste_key = "paste API key",
    or_auth_code = " or auth code",
    open_prefix = "open ",
    and_enter = " and enter ",
    waiting_suffix = " — waiting (Esc cancels)",
    paste_token_suffix = ", paste token",
    login_prefix = "login ",
}

-- Palette query/indicator row formats.
M.palette = {
    query_prefix = "> ",
    no_matches = " (no matches)",
    sel_total_fmt = " (%d/%d)",
    count_fmt = " %d/%d%s",
    cut_marker = "+",
}

-- Static error-banner texts (dynamic suffixes appended by ui.lua).
M.errors = {
    login_interactive_only = "login is interactive only",
    device_expired = "device login expired — run /login again",
    device_failed_prefix = "device login failed: ",
    device_request_failed = "device request failed",
    login_store_failed = "login store failed",
    oauth_exchange_failed = "oauth exchange failed",
    oauth_state_mismatch = "oauth callback state mismatch — paste the code manually",
    unknown_provider_prefix = "unknown provider: ",
    no_provider_logged_in = "no provider is logged in",
    no_stored_credential_prefix = "no stored credential for ",
    unknown_thinking_level_prefix = "unknown thinking level: ",
}

-- Session/system-row echoes.
M.session = {
    resumed_prefix = "↻ session ",
    resumed_suffix = " resumed",
    thinking_prefix = "→ thinking: ",
    compact_separator = "summary",
    copy_bytes_suffix = " bytes",
    think_current = "current",
}

-- Busy spinner frames.
M.spinner = {
    frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    ascii = { "|", "/", "-", "\\" },
}

-- Input-box rule glyph + hidden-rows labels.
M.rules = {
    glyph = "─",
    label_up_fmt = "↑ %d more",
    label_down_fmt = "↓ %d more",
}

-- Footer cell separator.
M.footer = {
    sep = " · ",
}

return M
