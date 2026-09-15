-- tether M2: app entry — runs the Lua TUI loop
local M = {}

function M.run()
    local ui = assert(ui, "ui module not loaded by C host")
    ui.run()
end

return M
