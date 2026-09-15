-- tether M3: ui — TUI with input field, transcript, agent dispatch
local M = {}

local transcript = {}
local input_buf = ""
local busy = false
local cfg = nil

local function out(s) tether.write(s) end

local function draw_banner()
    out("\x1b[2J\x1b[H")
    out("tether\n")
    for _, msg in ipairs(transcript) do
        if msg.role == "user" then
            out("\x1b[36m›\x1b[0m " .. msg.text .. "\n")
        elseif msg.role == "assistant" then
            out("● " .. msg.text .. "\n")
        elseif msg.role == "error" then
            out("\x1b[31m! " .. msg.text .. "\x1b[0m\n")
        end
    end
    out("› " .. input_buf)
end

local function commit_input()
    local text = input_buf
    input_buf = ""
    text = text:match("^%s*(.-)%s*$")
    if text == "" then
        draw_banner()
        out("› ")
        return
    end

    transcript[#transcript + 1] = { role = "user", text = text }
    draw_banner()
    out("… ")

    busy = true
    local key = os.getenv(cfg.api_key_env or "OPENAI_API_KEY") or ""
    local ok, err = agent.turn(cfg, key, text, function(ev)
        if ev.type == "text_delta" then
            out(ev.text or "")
        elseif ev.type == "error" then
            out("\n")
            transcript[#transcript + 1] = { role = "error", text = ev.message or "error" }
        end
    end)
    busy = false
    out("\n")
    if not ok then
        draw_banner()
    else
        draw_banner()
    end
    out("› ")
end

local function drain_escape()
    local c = tether.read_char()
    if c ~= 91 and c ~= 79 then return end
    c = tether.read_char()
    while c and c >= 65 and c <= 90 do
        c = tether.read_char()
    end
end

function M.run()
    cfg = config.load()
    draw_banner()
    out("› ")

    while true do
        local c = tether.read_char()
        if c == 0 or c == -1 then break end
        c = c & 0xFF

        if c == 3 or c == 4 then
            break
        elseif c == 12 then
            draw_banner()
            out("› ")
        elseif c == 13 or c == 10 then
            if not busy then
                commit_input()
            end
        elseif c == 27 then
            drain_escape()
        elseif c == 127 or c == 8 then
            if #input_buf > 0 then
                input_buf = input_buf:sub(1, -2)
                out("\b \b")
            end
        elseif c >= 32 and c <= 126 then
            input_buf = input_buf .. string.char(c)
            out(string.char(c))
        elseif c >= 1 and c <= 26 then
            out(string.format("^%c", c + 64))
        end
    end
    out("\x1b[?25h\n")
end

return M
