-- tether M3: tools — read, list, glob, grep
local M = {}

local WS = tether.getcwd()

local function sq(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function resolve(path)
    if path:find("^/") then return path end
    return WS .. "/" .. path
end

local function to_rel(path)
    local prefix = WS .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

local function run_to_file(cmd, outfile)
    tether.exec(cmd .. " > " .. outfile)
    local f = io.open(outfile, "r")
    local data = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(outfile)
    return data
end

function M.read(args)
    local path = resolve(args.path)
    local f = io.open(path, "rb")
    if not f then
        return nil, string.format("cannot open %s", to_rel(args.path))
    end
    local data = f:read(1024 * 1024)
    f:close()
    if not data then
        return nil, "read failed"
    end
    if data:sub(1, 8192):find("\0") then
        return nil, string.format("%s is binary", to_rel(args.path))
    end
    local lines = {}
    for line in data:gmatch("([^\n]*)\n?") do
        if #line > 8192 then
            lines[#lines + 1] = line:sub(1, 8192) .. " (truncated)"
        else
            lines[#lines + 1] = line
        end
    end
    local offset = args.offset or 1
    local limit = args.limit or 10000
    local out = {}
    for i = offset, math.min(#lines, offset + limit - 1) do
        out[#out + 1] = string.format("%d\t%s", i, lines[i])
    end
    return { content = table.concat(out, "\n"), line_count = #lines }
end

function M.list(args)
    local path = args.path and resolve(args.path) or WS
    local data = run_to_file(
        string.format("ls -1A %s 2>/dev/null", sq(path)),
        "/tmp/tether_list.txt")
    local entries = {}
    for entry in data:gmatch("([^\n]+)") do
        if entry ~= "." and entry ~= ".." then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries)
    return { entries = entries, count = #entries }
end

function M.glob(args)
    local base = args.path and resolve(args.path) or WS
    local data = run_to_file(
        string.format("find %s -name %s -type f 2>/dev/null | head -500",
                      sq(base), sq(args.pattern)),
        "/tmp/tether_glob.txt")
    local files = {}
    for file in data:gmatch("([^\n]+)") do
        files[#files + 1] = to_rel(file)
    end
    table.sort(files)
    return { files = files, count = #files }
end

function M.grep(args)
    local base = args.path and resolve(args.path) or WS
    local max = args.max_results or 100
    local ic = args.ignore_case and "-i " or ""

    local data = run_to_file(
        string.format("rg -n --no-heading %s%s %s %s 2>/dev/null | head %d",
                      ic, sq(args.pattern), sq(base), "0", max),
        "/tmp/tether_grep.txt")

    if data == "" then
        data = run_to_file(
            string.format("grep -rn%s %s %s 2>/dev/null | head %d",
                         ic, sq(args.pattern), sq(base), max),
            "/tmp/tether_grep.txt")
    end

    local matches = {}
    for line in data:gmatch("([^\n]+)") do
        local path, num, text = line:match("^(.-):(%d+):(.*)$")
        if path and num then
            matches[#matches + 1] = {
                path = to_rel(path),
                line = tonumber(num),
                text = text,
            }
        end
    end
    return { matches = matches, count = #matches }
end

M._ws = WS
return M
