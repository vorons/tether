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
        local api_key = config.api_key(cfg) or ""
        local prompt = opts.print_prompt
        if not prompt then
            -- read prompt from stdin (piped)
            prompt = io.read("*a")
        end
        if not prompt or prompt:match("^%s*$") then
            io.stderr:write("tether: --print requires a prompt argument or stdin input\n")
            os.exit(1)
        end
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
        local ok, err = pcall(agent.turn, cfg, api_key, "", on_event, true)
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
        if last_text == "" and had_error then
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

    -- Resume logic
    local resume_id = nil
    if opts.resume or not cfg.workspace then
        local ws = opts.workspace or cfg.workspace or tether.getcwd()
        local id = session.latest(ws)
        if id and not opts.workspace then
            resume_id = id
            local messages = session.resume(id)
            if messages then
                agent.clear()
                for _, msg in ipairs(messages) do
                    if msg.role == "user" then
                        agent.add_user(msg.content)
                    elseif msg.role == "assistant" then
                        agent.add_assistant(msg.content)
                    end
                end
            end
        end
    end

    -- Start new session or reuse resumed one
    local ws = opts.workspace or cfg.workspace or tether.getcwd()
    local id = resume_id or session.new_session(ws, cfg.model)

    cfg._session_id = id

    -- Run TUI
    ui.run()

    -- End session
    session.append(id, {
        ts = os.date("*t"),
        type = "session_end",
        meta = { workspace = ws, model = cfg.model },
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
