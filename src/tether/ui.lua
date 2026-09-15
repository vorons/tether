-- tether M2: ui — TUI loop, reads chars via tether.read_char()
local M = {}

local function drain_escape()
    local c = tether.read_char()
    if c ~= 91 and c ~= 79 then return end
    c = tether.read_char()
    while c and c >= 65 and c <= 90 do
        c = tether.read_char()
    end
end

function M.run()
    tether.write("tether\n")
    while true do
        local c = tether.read_char()
        if c == 0 or c == -1 then
            break -- EOF
        end
        c = c & 0xFF
        if c == 3 or c == 4 or c == 24 then
            break
        elseif c == 12 then
            tether.write("\x1b[2J\x1b[H")
        elseif c == 27 then
            drain_escape()
        elseif c == 127 or c == 8 then
            tether.write("\b \b")
        elseif c >= 32 and c <= 126 then
            tether.write(string.char(c))
        elseif c >= 1 and c <= 26 then
            tether.write(string.format("^%c", c + 64))
        end
    end
    tether.write("\x1b[?25h\n")
end

return M
