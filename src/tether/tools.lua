-- tether M4: tools — read, list, glob, grep, write, patch, run
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

local function within_workspace(path, cfg)
    if cfg and cfg.allow_outside_workspace then return true end
    local rel = to_rel(path)
    return rel ~= path
end

local function now_ms()
    return math.floor(os.clock() * 1000)
end

function M._workspace() return WS end
function M._resolve(path) return resolve(path) end
function M._to_rel(path) return to_rel(path) end

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

local function dir_entries(path)
    local entries = {}
    local ok, dir = pcall(function()
        local f = io.popen("ls -1A " .. sq(path) .. " 2>/dev/null")
        local result = f:read("*a")
        f:close()
        return result
    end)
    if not ok then return entries end
    for entry in dir:gmatch("[^\n]+") do
        if entry ~= "." and entry ~= ".." then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries)
    return entries
end

function M.list(args)
    local path = args.path and resolve(args.path) or WS
    local entries = dir_entries(path)
    return { entries = entries, count = #entries }
end

local function dir_files(base)
    local files = {}
    local ok, result = pcall(function()
        local f = io.popen("find " .. sq(base) .. " -type f 2>/dev/null")
        local r = f:read("*a")
        f:close()
        return r
    end)
    if not ok then return files end
    for file in result:gmatch("[^\n]+") do
        files[#files + 1] = to_rel(file)
    end
    return files
end

function M.glob(args)
    local base = args.path and resolve(args.path) or WS
    local pattern = args.pattern or ""
    local all_files = dir_files(base)
    local files = {}
    local lp = pattern:gsub("%.", "%%."):gsub("%.%.", ".*"):gsub("%*", ".*")
    for _, f in ipairs(all_files) do
        local basename = f:match("([^/]+)$") or f
        if basename:match(lp) then
            files[#files + 1] = f
        end
    end
    table.sort(files)
    return { files = files, count = #files }
end

function M.grep(args)
    local base = args.path and resolve(args.path) or WS
    local max = args.max_results or 100
    local ic = args.ignore_case and "-i " or ""
    local pattern = args.pattern or ""

    local data = ""
    local ok = pcall(function()
        local f = io.popen("rg -n --no-heading " .. ic .. sq(pattern) .. " " .. sq(base) .. " 2>/dev/null | head " .. max)
        data = f:read("*a")
        f:close()
    end)
    if not ok or data == "" then
        ok = pcall(function()
            local f = io.popen("grep -rn" .. ic .. " " .. sq(pattern) .. " " .. sq(base) .. " 2>/dev/null | head " .. max)
            data = f:read("*a")
            f:close()
        end)
    end

    local matches = {}
    for line in data:gmatch("[^\n]+") do
        local p, num, text = line:match("^(.-):(%d+):(.*)$")
        if p and num then
            matches[#matches + 1] = {
                path = to_rel(p),
                line = tonumber(num),
                text = text,
            }
        end
    end
    return { matches = matches, count = #matches }
end

local function atomic_write(path, content)
    local tmp = path .. ".tmp." .. math.random(100000, 999999)
    local f = io.open(tmp, "w")
    if not f then return nil, "cannot open temp file" end
    f:write(content)
    f:close()
    os.rename(tmp, path)
    return true
end

function M.write(args, cfg)
    local path = resolve(args.path)
    if not within_workspace(path, cfg) then
        return nil, "write outside workspace requires confirmation"
    end
    local content = args.content or ""
    local ok, err = atomic_write(path, content)
    if not ok then
        return nil, string.format("cannot write %s", to_rel(args.path))
    end
    return { bytes = #content, path = to_rel(args.path) }
end

function M.patch(patch_str, cfg)
    local file_patches = {}
    local current_file = nil
    local current_hunk = nil

    for _, line in ipairs(patch_str:gmatch("[^\n]*")) do
        if line:match("^%-%-%-%s+%S+") then
            current_file = line:match("^%-%-%-%s+([^%s]+)")
            current_hunk = nil
            if not file_patches[current_file] then
                file_patches[current_file] = { hunks = {} }
            end
        elseif line:match("^@@%-(%d+),?(%d*)%+%(%d+),?(%d*)@@") then
            local ns = tonumber(line:match("@@%-(%d+)")) or 1
            local ne = tonumber(line:match("%+(%d+)") or 1)
            current_hunk = { old_start = ns, new_start = ne, old_lines = {}, new_lines = {} }
            if file_patches[current_file] then
                file_patches[current_file].hunks[#file_patches[current_file].hunks + 1] = current_hunk
            end
        elseif current_hunk then
            local prefix = line:sub(1, 1)
            local content = line:sub(2)
            if prefix == " " then
                current_hunk.old_lines[#current_hunk.old_lines + 1] = content
                current_hunk.new_lines[#current_hunk.new_lines + 1] = content
            elseif prefix == "+" then
                current_hunk.new_lines[#current_hunk.new_lines + 1] = content
            elseif prefix == "-" then
                current_hunk.old_lines[#current_hunk.old_lines + 1] = content
            end
        end
    end

    local total_add, total_del, files_applied = 0, 0, 0
    local applied_files = {}

    for fname, fdata in pairs(file_patches) do
        local full_path = resolve(fname)
        if not within_workspace(full_path, cfg) then
            return nil, string.format("patch outside workspace: %s", fname)
        end
        local f = io.open(full_path, "r")
        local content = f and f:read("*a") or ""
        if f then f:close() end
        local content_lines = {}
        for line in content:gmatch("[^\n]*") do
            content_lines[#content_lines + 1] = line
        end
        if content_lines[#content_lines] == "" then content_lines[#content_lines] = nil end

        local ok = true
        local add_count, del_count = 0, 0

        for i = #fdata.hunks, 1, -1 do
            local hunk = fdata.hunks[i]
            for j, old_line in ipairs(hunk.old_lines) do
                if hunk.old_start + j - 1 > #content_lines or content_lines[hunk.old_start + j - 1] ~= old_line then
                    ok = false
                    break
                end
            end
            if not ok then break end

            local before = {}
            for i = 1, hunk.old_start - 1 do before[i] = content_lines[i] end
            local after = {}
            local after_start = hunk.old_start + #hunk.old_lines
            for i = after_start, #content_lines do after[#after + 1] = content_lines[i] end

            add_count = add_count + #hunk.new_lines
            del_count = del_count + #hunk.old_lines
            files_applied = files_applied + 1

            local new_content = {}
            for i = 1, #before do new_content[i] = before[i] end
            for i = 1, #hunk.new_lines do new_content[#before + i] = hunk.new_lines[i] end
            for i = 1, #after do new_content[#before + #hunk.new_lines + i] = after[i] end
            content_lines = new_content
        end

        if ok then
            local tmp = full_path .. ".tmp." .. math.random(100000, 999999)
            local f2 = io.open(tmp, "w")
            if f2 then
                f2:write(table.concat(content_lines, "\n"))
                if #content_lines > 0 then f2:write("\n") end
                f2:close()
                os.rename(tmp, full_path)
            end
            total_add = total_add + add_count
            total_del = total_del + del_count
            table.insert(applied_files, { file = fname, add = add_count, del = del_count })
        else
            return nil, string.format("patch conflict in %s", fname)
        end
    end

    return { files = files_applied, add = total_add, del = total_del }
end

function M.run(args, cfg)
    local command = args.command or ""
    local timeout_val = (args.timeout or (cfg and cfg.tools and cfg.tools.run_shell and cfg.tools.run_shell.timeout)) or 120
    local cwd = args.cwd and resolve(args.cwd) or WS
    if not within_workspace(cwd, cfg) then
        return nil, "run outside workspace requires confirmation"
    end

    local cmd = string.format("timeout %d env TETHER_WORKSPACE=%s sh -c %s 2>&1",
                              timeout_val, sq(cwd), sq(command))
    local start_ms = now_ms()
    local outfile = "/tmp/tether_run_out.txt"
    tether.exec(cmd .. " > " .. outfile)
    local elapsed = now_ms() - start_ms

    local f = io.open(outfile, "r")
    local output = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(outfile)

    return { output = output, elapsed_ms = elapsed }
end

return M
