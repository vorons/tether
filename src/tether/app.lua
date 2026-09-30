-- tether M5: app entry — CLI parsing, session resume, TUI/print modes
local M = {}

local version = false

-- commands: embedded global (main.c mods[]); loadfile fallback for tests.
local commands = _G.commands
if type(commands) ~= "table" then
    local chunk = loadfile("src/tether/commands.lua")
    commands = (chunk and chunk()) or {}
end

-- extension-system: same idiom as context.lua — the embedded global is read
-- at call time (loadfile fallback for dev/test runs).
local function ext_mod()
    if type(_G.extensions) == "table" then return _G.extensions end
    local chunk = loadfile("src/tether/extensions.lua")
    return chunk and chunk() or nil
end

-- extension-system: discover + register once at startup, after cfg is final
-- (the disabled list comes from cfg, design §1). Returns the registry; a
-- missing extensions module or dir yields an empty one, so extension-less
-- runs behave exactly as before.
function M.boot_extensions(cfg, home)
    local ext = ext_mod()
    if not ext or type(ext.load) ~= "function" then return nil end
    local h = home or os.getenv("HOME")
    if type(h) ~= "string" or h == "" then return nil end
    local ok, reg = pcall(ext.load, h, cfg)
    if not ok or type(reg) ~= "table" then return nil end
    if type(commands.register_extension_commands) == "function" then
        pcall(commands.register_extension_commands, reg)
    end
    return reg
end

-- extension-system: fire on_session_start once per session start, new or
-- resumed (task 3.3). The once-per-process guard lives in
-- extensions.fire_start; app only routes the two call points (resume here,
-- lazy mint via cfg._on_session_start from ui). Never blocks the session:
-- handler errors are the module's own stderr warnings.
function M.fire_session_start(cfg)
    local ext = ext_mod()
    if not ext or type(ext.fire_start) ~= "function" then return end
    pcall(ext.fire_start, cfg, type(cfg) == "table" and cfg.workspace or nil)
end

-- tui-stderr-guard: pre-TUI stderr capture. Installed on the interactive
-- path after provider/config fatals (those must keep the terminal — the
-- TUI never starts there) and before boot_extensions, so load warnings and
-- the resume fire_start land in the session log instead of scrollback.
-- Extension lines are additionally collected into cfg._startup_warnings
-- for the TUI error banner; everything else is file-only. The sink opens
-- and closes the file per line (few lines ever flow here), so restoring is
-- just a global swap — ui.run installs its own persistent sink on top.
local early_saved_stderr = nil
-- Canonical path lives in extensions.session_log_dir (single source of
-- truth); same delegate-then-fallback shape as ui.lua.
local function early_log_path(cfg)
    local ext = ext_mod()
    if ext and ext.session_log_dir then
        local ok, dir = pcall(ext.session_log_dir, cfg)
        if ok and type(dir) == "string" and dir ~= "" then return dir end
    end
    if type(cfg) == "table" and type(cfg._log_dir) == "string"
        and cfg._log_dir ~= "" then
        return cfg._log_dir
    end
    return (os.getenv("HOME") or "/tmp") .. "/.tether/log"
end
function M._early_stderr_sink(cfg)
    if early_saved_stderr ~= nil then return end
    local dir = early_log_path(cfg)
    pcall(function()
        local th = rawget(_G, "tether")
        if th and th.mkdirp then th.mkdirp(dir) end
    end)
    local path = dir .. "/tether.log"
    if type(cfg) == "table" and type(cfg._startup_warnings) ~= "table" then
        cfg._startup_warnings = {}
    end
    early_saved_stderr = io.stderr
    io.stderr = { write = function(_, ...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        local line = table.concat(parts):gsub("\n$", "")
        pcall(function()
            local fh = io.open(path, "a")
            if fh then fh:write(line .. "\n") fh:close() end
        end)
        if type(cfg) == "table" and cfg._startup_warnings
            and line:find("^tether: extension") == 1 then
            cfg._startup_warnings[#cfg._startup_warnings + 1] = line
        end
        return io.stderr
    end }
end
function M._restore_early_stderr_sink()
    if early_saved_stderr ~= nil then
        io.stderr = early_saved_stderr
        early_saved_stderr = nil
    end
end

local function parse_args()
    local args = arg or {}
    local opts = {
        interactive = true,
        workspace = nil,
        model = nil,
        resume = nil,
        print_mode = false,
        print_prompt = nil,
        debug = false,
        agents_files = {},
        tools_allowlist = {},
    }
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--resume" or a == "-r" then
            -- sequel: an explicit session id continues it; bare -r keeps
            -- latest-for-workspace behavior.
            if args[i + 1] and not args[i + 1]:match("^%-") then
                opts.resume = args[i + 1]
                i = i + 1
            else
                opts.resume = true
            end
        elseif a == "--workspace" or a == "-w" then
            opts.workspace = args[i + 1]
            i = i + 1
        elseif a == "--model" or a == "-m" then
            opts.model = args[i + 1]
            i = i + 1
        elseif a == "--print" or a == "-p" then
            opts.print_mode = true
            opts.interactive = false
            if args[i + 1] and not args[i + 1]:match("^%-") then
                opts.print_prompt = args[i + 1]
                i = i + 1
            end
        elseif a == "--debug" then
            opts.debug = true
        elseif a == "--agents-file" then
            local path = args[i + 1]
            if path and not path:match("^%-") then
                opts.agents_files[#opts.agents_files + 1] = path
                i = i + 1
            end
        elseif a == "--tools" then
            -- subagent allowlist: comma-separated tool names for this run.
            -- Only honored in --print (child) runs; interactive use ignores it.
            local csv = args[i + 1]
            if csv and not csv:match("^%-") then
                for name in csv:gmatch("[^,%s]+") do
                    opts.tools_allowlist[#opts.tools_allowlist + 1] = name
                end
                i = i + 1
            end
        elseif a == "--version" or a == "-v" then
            version = true
            return opts
        end
        i = i + 1
    end
    return opts
end

-- add-provider-login: --print cannot run interactive slash flows. Returns an
-- error string for /login /logout prompts, nil otherwise (T161).
function M._print_prompt_error(prompt)
    if type(prompt) ~= "string" then return nil end
    local head = prompt:match("^%s*(%S+)")
    if head == "/login" or head == "/logout" then
        return (head:sub(2)) .. " is interactive only"
    end
    return nil
end

-- Test seam for the CLI parser (T240): parse a given argv instead of the
-- process-global `arg` (mirrors the M._print_prompt_error precedent).
function M._parse_args(argv)
    local keep = arg
    arg = argv
    local ok, opts = pcall(parse_args)
    arg = keep
    if ok then return opts end
    return nil
end

-- extension-system: top-level management verbs (design §7, flat per user
-- decision). Returns the process exit code so tests drive the handler
-- without os.exit; the caller exits only when a verb was matched.
function M._run_ext_cli(argv, home)
    local verb = argv[1]
    local ext = ext_mod()
    local function die(msg)
        io.stderr:write("tether: " .. tostring(msg) .. "\n")
        return 1
    end
    local function yes(...)
        for _, a in ipairs({ ... }) do
            if a == "--yes" or a == "-y" then return true end
        end
        return false
    end
    if not ext then return die("extensions module unavailable") end
    local h = home or os.getenv("HOME")
    if type(h) ~= "string" or h == "" then return die("cannot resolve the home directory") end
    if verb == "install" then
        local source = argv[2]
        if type(source) ~= "string" or source == "" then
            return die("tether install needs a source path or URL")
        end
        local name, err = ext.install(source, h)
        if not name then return die(err) end
        print("installed " .. name)
        return 0
    elseif verb == "list" then
        for _, n in ipairs(ext.list_names(h)) do print(n) end
        return 0
    elseif verb == "remove" then
        local name = argv[2]
        if type(name) ~= "string" or name == "" then
            return die("tether remove needs an extension name")
        end
        if not yes(argv[3], argv[4]) then
            io.stderr:write("remove " .. name .. "? [y/N] ")
            local line = io.read and io.read("*l")
            if not (type(line) == "string"
                and (line == "y" or line == "Y" or line:lower() == "yes")) then
                print("cancelled")
                return 0
            end
        end
        local ok, err = ext.remove(name, h)
        if not ok then return die(err) end
        print("removed " .. name)
        return 0
    end
    return nil
end

-- add-self-update: seams for the update paths, so tests drive the behaviour
-- without os.exit, a TTY or the network. _update_verb returns (code, message);
-- _startup_update schedules the background probe and returns its status, never
-- raising and never blocking. Both tolerate a missing `update` module (plain
-- Lua test/dev runtime).
function M._update_verb(home)
    if not (update and update.run) then
        return 1, "update module unavailable"
    end
    local ok, code, text = pcall(update.run, home, build_version)
    if not ok then return 1, tostring(code) end
    return tonumber(code) or 1, text or "no result"
end

function M._startup_update(cfg, opts, home)
    -- a one-shot run has no banner to show and no user waiting on it, so it
    -- performs no release probe at all (spec: one-shot runs do not check).
    if opts and opts.print_mode then return nil end
    -- a piped stdin is the same case without the flag: nobody is reading a
    -- banner, so leave no marker behind. Absent primitive (plain-Lua runtime)
    -- counts as interactive.
    if tether and tether.is_tty and not tether.is_tty() then return nil end
    if not (update and update.check) then return nil end
    local ok, res = pcall(update.check, cfg, home)
    if not ok then return nil end
    return res
end

local function run_inner()
    -- extension-system: management verbs run before the flag parser, which
    -- would otherwise ignore them and open a session.
    local argv = arg or {}
    if argv[1] == "install" or argv[1] == "list" or argv[1] == "remove" then
        os.exit(M._run_ext_cli(argv) or 0)
    end
    -- add-self-update: the update verb is trimmed here for the same reason the
    -- extension verbs are — the flag parser would ignore it and open a session.
    if argv[1] == "update" then
        local code, text = M._update_verb()
        if code ~= 0 then
            io.stderr:write("tether: " .. tostring(text) .. "\n")
        else
            io.stdout:write(tostring(text) .. "\n")
        end
        os.exit(code)
    end
    local opts = parse_args()
    if version then print("tether " .. tostring(build_version or "dev")); os.exit(0) end

    -- Stage log for --print children (and the parent when debugged):
    -- open/append/close per line, safe across forked processes sharing
    -- the file. Stages show exactly where a silent child stops.
    local log_on = opts.debug or false
    local function dlog(msg)
        if not log_on then return end
        pcall(function()
            local th = rawget(_G, "tether")
            local dir = (os.getenv("HOME") or "/tmp") .. "/.tether/log"
            if th and th.mkdirp then th.mkdirp(dir) end
            local f = io.open(dir .. "/tether.log", "a")
            if f then
                f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
                f:close()
            end
        end)
    end

    if opts.print_mode then
        dlog("print: start")
        -- Non-interactive: run a single agent turn, print final text to stdout
        local cfg = config.load()
        dlog("print: config loaded")
        do
            local ok, perr = commands.boot_providers(cfg)
            if not ok then
                io.stderr:write(tostring(perr) .. "\n")
                os.exit(1)
            end
        end
        dlog("print: providers booted")
        if opts.workspace then cfg.workspace = opts.workspace end
        if opts.model then cfg.model = opts.model end
        -- context-injection: CLI agents files feed the composed prompt (merged
        -- after cfg.agents_files by context.compose).
        if #opts.agents_files > 0 then
            cfg._cli_agents_files = opts.agents_files
        end
        -- subagent depth + allowlist composition (2.3): depth travels in
        -- TETHER_SUBAGENT_DEPTH (0 top, ++ per fork); at the limit the
        -- child schema omits `subagent`. Unknown/deep values behave as
        -- at-limit, never as deeper. Provider payload builders take no
        -- cfg, so the composed filter rides module state (see
        -- set_tools_filter); the dispatch guard reads cfg directly.
        local depth = tonumber(os.getenv("TETHER_SUBAGENT_DEPTH")) or 0
        if depth < 0 then depth = 0 end
        cfg._subagent_depth = depth
        local max_depth = (cfg.subagents and tonumber(cfg.subagents.max_depth)) or 1
        if #opts.tools_allowlist > 0 then
            cfg._tools_allowlist = opts.tools_allowlist
        end
        if cfg._tools_allowlist ~= nil or depth >= max_depth then
            local common = rawget(_G, "provider_common")
            if not common then
                local chunk = loadfile("src/tether/providers/common.lua")
                common = chunk and chunk()
            end
            if common then
                local keep = {}
                if cfg._tools_allowlist then
                    for _, n in ipairs(cfg._tools_allowlist) do
                        if type(n) == "string" and n ~= "" then keep[n] = true end
                    end
                else
                    for _, t in ipairs(common.tools_schema()) do
                        if type(t.name) == "string" then keep[t.name] = true end
                    end
                end
                if depth >= max_depth then keep["subagent"] = nil end
                local list = {}
                for n in pairs(keep) do list[#list + 1] = n end
                if common.set_tools_filter then
                    common.set_tools_filter(list)
                end
            end
        end
        cfg.debug = opts.debug
        -- add-ask-tool: a print run has nobody to answer `ask`, so the agent
        -- degrades such a call to an error tool result instead of parking.
        cfg.non_interactive = true
        -- Design §14: workspace defaults to cwd; -w overrides (tools read cfg.workspace)
        if not cfg.workspace then cfg.workspace = tether.getcwd() end
        local rp = tether.realpath(cfg.workspace)
        if rp then cfg.workspace = rp end
        -- extension-system: tools/commands/prompt/hooks must be registered
        -- before the turn composes its prompt and dispatches tool calls.
        M.boot_extensions(cfg)

        local api_key = config.api_key(cfg) or ""
        local prompt = opts.print_prompt
        if not prompt then
            -- read prompt from stdin only when piped (audit #4: no TTY hang)
            if tether.is_tty() then
                io.stderr:write("tether: --print requires a prompt argument or piped stdin\n")
                os.exit(1)
            end
            prompt = io.read("*a")
        end
        if not prompt or prompt:match("^%s*$") then
            io.stderr:write("tether: --print requires a prompt argument or stdin input\n")
            os.exit(1)
        end
        local interactive_err = M._print_prompt_error(prompt)
        if interactive_err then
            io.stderr:write("tether: " .. interactive_err .. "\n")
            os.exit(1)
        end

        local sid = nil
        if opts.resume then
            -- sequel: continue a child session instead of minting a fresh
            -- one. An explicit id must resolve to a real journal (messages
            -- nil means the file is missing/empty); bare -r falls back to
            -- latest for the workspace, then to a fresh session.
            local rid = (type(opts.resume) == "string") and opts.resume or nil
            local rsid, rmsgs = commands.resume(rid, cfg.workspace, cfg)
            if rsid and (not rid or rmsgs) then
                sid = rsid
            elseif rid then
                io.stderr:write("tether: no such session: " .. rid .. "\n")
                os.exit(1)
            end
        end
        if not sid then sid = commands.new(cfg.workspace, cfg.model) end
        cfg._session_id = sid
        -- extension-system: session start fires once the session exists
        -- (new or resumed), before the first turn.
        M.fire_session_start(cfg)
        dlog("print: session " .. tostring(sid))

        -- 1.5: agent.turn adds (and journals) the user message; adding it here
        -- too would send the prompt twice.
        local text_chunks = {}
        local had_error = false
        local function on_event(ev)
            if ev.type == "text_delta" then
                text_chunks[#text_chunks + 1] = ev.text
            elseif ev.type == "error" then
                had_error = true
                io.stderr:write("tether: " .. (ev.message or "") .. "\n")
            end
        end
        local ok, err = pcall(agent.turn, cfg, api_key, prompt, on_event)
        if not ok then
            dlog("print: turn raised: " .. tostring(err))
            io.stderr:write("tether: agent error: " .. tostring(err) .. "\n")
            os.exit(1)
        end
        dlog("print: turn done")
        -- collect the last assistant text from agent history
        local history = agent.get_history()
        local last_text = ""
        for i = #history, 1, -1 do
            if history[i].role == "assistant" and type(history[i].content) == "string" then
                last_text = history[i].content
                break
            end
        end
        if last_text == "" then
            for _, c in ipairs(text_chunks) do last_text = last_text .. c end
        end
        session.append(sid, {
            ts = os.date(), type = "session_end",
            meta = { workspace = cfg.workspace, model = cfg.model },
        })
        -- M7/D5: tech-spec contract — exit 1 on error OR empty response
        if last_text == "" then
            io.stderr:write("tether: no response text\n")
            os.exit(1)
        end
        io.write(last_text)
        io.write("\n")
        return
    end

    local cfg = config.load()
    do
        local ok, perr = commands.boot_providers(cfg)
        if not ok then
            io.stderr:write(tostring(perr) .. "\n")
            os.exit(1)
        end
    end
    if opts.workspace then
        cfg.workspace = opts.workspace
    end
    if opts.model then
        cfg.model = opts.model
    end
    if #opts.agents_files > 0 then
        cfg._cli_agents_files = opts.agents_files
    end
    cfg.debug = opts.debug
    -- Design §7: workspace = cwd unless -w; realpath with symlinks expanded
    if not cfg.workspace then cfg.workspace = tether.getcwd() end
    local rp = tether.realpath(cfg.workspace)
    if rp then cfg.workspace = rp end
    -- tui-stderr-guard: from here until the TUI owns the screen, pre-TUI
    -- diagnostics go to the session log (banner-bound ones collected).
    M._early_stderr_sink(cfg)
    -- extension-system: registry (tools/prompt/hooks) + slash commands,
    -- composed before the resume seed and the first turn.
    M.boot_extensions(cfg)
    -- add-self-update: probe for a newer release (or reuse a fresh cache)
    -- before the TUI paints. Never blocks, never raises, never runs in a
    -- one-shot pass — see M._startup_update.
    M._startup_update(cfg, opts)

    -- Resume logic (design §10): only with -r
    local resume_id = nil
    if opts.resume then
        local rid = (type(opts.resume) == "string") and opts.resume or nil
        local sid, messages = commands.resume(rid, cfg.workspace, cfg)
        if sid and (not rid or messages) then
            resume_id = sid
            -- the transcript seeds from these, not from the agent history:
            -- history carries no thinking blocks (the model must not see
            -- them) while the seed needs the journal's display fields
            cfg._resume_messages = messages
        elseif rid then
            io.stderr:write("tether: no such session: " .. rid .. "\n")
            os.exit(1)
        else
            io.stderr:write("tether: no previous session for this workspace; starting a new one\n")
        end
    end

    -- Reuse the resumed session, if any. A fresh session is minted lazily
    -- by the first turn (ui.ensure_session) — opening tether just to look
    -- must not leave empty session files behind.
    local id = resume_id
    if id then
        cfg._session_id = id
        -- extension-system: a resumed session starts now, not at first turn
        -- (fire_start is once-per-process, so the lazy path can't double up).
        M.fire_session_start(cfg)
    end
    -- extension-system: a lazily minted session fires from ui._ensure_session.
    cfg._on_session_start = function() M.fire_session_start(cfg) end
    -- extension-command-execution: extension code that runs a command is
    -- journaled, and a journal needs a session. The TUI mints one at the first
    -- turn, so hand the ctx path the same entry point: a slash command typed
    -- before any prompt still gets its execution recorded.
    cfg._ensure_session = function()
        if type(ui) == "table" and type(ui._ensure_session) == "function" then
            pcall(ui._ensure_session)
        end
    end

    -- Run TUI with this same cfg: ui.run used to load a second copy, so it
    -- never saw _session_id and minted its own session every launch (two
    -- session files per run, -r ambiguity on top).
    ui.run(cfg)

    -- End session (only when one exists: a look-around run has no file)
    if cfg._session_id then
        session.append(cfg._session_id, {
            ts = os.date(),
            type = "session_end",
            meta = { workspace = cfg.workspace, model = cfg.model },
        })
    end
end

function M.run()
    local ok, err = pcall(run_inner)
    if not ok then
        -- tui-stderr-guard: a raise inside the guarded window must not
        -- swallow the fatal into the log — hand the terminal back first.
        -- Every restore here is idempotent and safe with no guard active.
        pcall(function()
            if type(ui) == "table" and ui._stderr_guard_restore then
                ui._stderr_guard_restore()
            end
        end)
        pcall(M._restore_early_stderr_sink)
        local th = rawget(_G, "tether")
        if th and th.stderr_restore then pcall(th.stderr_restore) end
        io.stderr:write("tether: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

return M
