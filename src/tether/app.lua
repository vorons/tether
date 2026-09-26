-- tether M5: app entry — CLI parsing, session resume, TUI/print modes
local M = {}

local version = false

-- commands: embedded global (main.c mods[]); loadfile fallback for tests.
local commands = _G.commands
if type(commands) ~= "table" then
    local chunk = loadfile("src/tether/commands.lua")
    commands = (chunk and chunk()) or {}
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
            opts.resume = true
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

local function run_inner()
    local opts = parse_args()
    if version then print("tether 0.1.0"); os.exit(0) end

    if opts.print_mode then
        -- Non-interactive: run a single agent turn, print final text to stdout
        local cfg = config.load()
        do
            local ok, perr = commands.boot_providers(cfg)
            if not ok then
                io.stderr:write(tostring(perr) .. "\n")
                os.exit(1)
            end
        end
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

        local sid = commands.new(cfg.workspace, cfg.model)
        cfg._session_id = sid

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
            io.stderr:write("tether: agent error: " .. tostring(err) .. "\n")
            os.exit(1)
        end
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

    -- Resume logic (design §10): only with -r
    local resume_id = nil
    if opts.resume then
        local sid, messages = commands.resume(nil, cfg.workspace, cfg)
        if sid then
            resume_id = sid
            -- the transcript seeds from these, not from the agent history:
            -- history carries no thinking blocks (the model must not see
            -- them) while the seed needs the journal's display fields
            cfg._resume_messages = messages
        else
            io.stderr:write("tether: no previous session for this workspace; starting a new one\n")
        end
    end

    -- Reuse the resumed session, if any. A fresh session is minted lazily
    -- by the first turn (ui.ensure_session) — opening tether just to look
    -- must not leave empty session files behind.
    local id = resume_id
    if id then cfg._session_id = id end

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
        io.stderr:write("tether: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

return M
