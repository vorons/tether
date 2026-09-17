-- tether M5: app entry — CLI parsing, session resume, TUI/print modes
local M = {}

local version = false

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
        elseif a == "--version" or a == "-v" then
            version = true
            return opts
        end
        i = i + 1
    end
    return opts
end

local function run_inner()
    local opts = parse_args()
    if version then print("tether 0.1.0"); os.exit(0) end

    if opts.print_mode then
        -- Non-interactive: run a single agent turn, print final text to stdout
        local cfg = config.load()
        if opts.workspace then cfg.workspace = opts.workspace end
        if opts.model then cfg.model = opts.model end
        cfg.debug = opts.debug
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

        local sid = session.new_session(cfg.workspace, cfg.model)
        cfg._session_id = sid

        agent.add_user(prompt)
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
    if opts.workspace then
        cfg.workspace = opts.workspace
    end
    if opts.model then
        cfg.model = opts.model
    end
    cfg.debug = opts.debug
    -- Design §7: workspace = cwd unless -w; realpath with symlinks expanded
    if not cfg.workspace then cfg.workspace = tether.getcwd() end
    local rp = tether.realpath(cfg.workspace)
    if rp then cfg.workspace = rp end

    -- Resume logic (design §10): only with -r
    local resume_id = nil
    if opts.resume then
        local id = session.latest(cfg.workspace)
        if id then
            resume_id = id
            local messages = session.resume(id)
            if messages then
                agent.clear()
                for _, msg in ipairs(messages) do
                    if msg.role == "user" then
                        agent.add_user(msg.content)
                    elseif msg.role == "assistant" then
                        if msg.tool_calls then
                            agent.add_assistant({ tool_calls = msg.tool_calls })
                        else
                            agent.add_assistant(msg.content)
                        end
                    elseif msg.role == "tool" then
                        -- M7/D4: without tool results the API rejects the
                        -- first turn after resume (400: tool_call without
                        -- tool response).
                        agent.add_tool_result(msg.tool_call_id, msg.content or "")
                    end
                end
            end
        else
            io.stderr:write("tether: no previous session for this workspace; starting a new one\n")
        end
    end

    -- Start new session or reuse resumed one
    local id = resume_id or session.new_session(cfg.workspace, cfg.model)
    cfg._session_id = id

    -- Run TUI
    ui.run()

    -- End session
    session.append(id, {
        ts = os.date(),
        type = "session_end",
        meta = { workspace = cfg.workspace, model = cfg.model },
    })
end

function M.run()
    local ok, err = pcall(run_inner)
    if not ok then
        io.stderr:write("tether: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

return M
