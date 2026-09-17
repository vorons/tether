-- tether M4: tools — read, list, glob, grep, write, patch, run
local M = {}

-- Design §7: workspace defaults to cwd; override comes from cfg.workspace
-- (-w / config), resolved via realpath with symlinks expanded.
local function current_workspace(cfg)
    local ws = cfg and cfg.workspace or os.getenv("TETHER_WORKSPACE")
    if ws and ws ~= "" then
        local rp = tether.realpath and tether.realpath(ws) or nil
        if rp then return rp end
        return ws
    end
    return tether.getcwd()
end

local function sq(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function resolve(path, cfg)
    if path:find("^/") then return path end
    return current_workspace(cfg) .. "/" .. path
end

local function to_rel(path, cfg)
    local prefix = current_workspace(cfg) .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

-- Design §7: symlink-и раскрываются; path traversal через ".." не проходит.
local function within_workspace(path, cfg)
    if cfg and cfg.allow_outside_workspace == true then return true end
    local rp = tether.realpath and tether.realpath(path) or nil
    if not rp then return false end
    local ws = current_workspace(cfg)
    return rp == ws or rp:sub(1, #ws + 1) == ws .. "/"
end

local function now_ms()
    return math.floor(os.clock() * 1000)
end

function M._workspace(cfg) return current_workspace(cfg) end
function M._resolve(path, cfg) return resolve(path, cfg) end
function M._to_rel(path, cfg) return to_rel(path, cfg) end
function M._within(path, cfg) return within_workspace(path, cfg) end

function M.read(args)
    local path = resolve(args.path, args._cfg)
    local f = io.open(path, "rb")
    if not f then
        return nil, string.format("cannot open %s", to_rel(args.path, args._cfg))
    end
    local data = f:read(1024 * 1024)
    f:close()
    if not data then
        return nil, "read failed"
    end
    if data:sub(1, 8192):find("\0", 1, true) then
        return nil, string.format("%s is binary", to_rel(args.path, args._cfg))
    end
    local lines = {}
    for line in data:gmatch("([^\n]*)\n?") do
        lines[#lines + 1] = line
        if #lines > 200000 then break end
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
        entries[#entries + 1] = entry
    end
    table.sort(entries)
    return entries
end

function M.list(args)
    local path = args.path and resolve(args.path, args._cfg) or current_workspace(args._cfg)
    local entries = dir_entries(path)
    return { entries = entries, count = #entries }
end

-- Design §7 glob: *, **, ?, [abc], [!abc]; sort by path; limit 500.
local function glob_to_pattern(p)
    local out = {}
    local i = 1
    while i <= #p do
        local c = p:sub(i, i)
        if c == "*" then
            if p:sub(i + 1, i + 1) == "*" then
                out[#out + 1] = ".*"
                i = i + 2
            else
                out[#out + 1] = "[^/]*"
                i = i + 1
            end
        elseif c == "?" then
            out[#out + 1] = "[^/]"
            i = i + 1
        elseif c == "[" then
            local close = p:find("]", i + 1, true)
            if close then
                local cls = p:sub(i + 1, close - 1)
                local neg = false
                if cls:sub(1, 1) == "!" then neg = true; cls = cls:sub(2) end
                cls = cls:gsub("%%", "%%%%"):gsub("^%^", "%%^")
                out[#out + 1] = neg and ("[^" .. cls .. "]") or ("[" .. cls .. "]")
                i = close + 1
            else
                out[#out + 1] = "%["
                i = i + 1
            end
        else
            out[#out + 1] = c:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

function M.glob(args)
    local base = args.path and resolve(args.path, args._cfg) or current_workspace(args._cfg)
    local pattern = args.pattern or ""
    local all_files = {}
    local ok = pcall(function()
        local f = io.popen("find " .. sq(base) .. " -type f 2>/dev/null")
        local r = f:read("*a")
        f:close()
        for file in r:gmatch("[^\n]+") do
            all_files[#all_files + 1] = file
        end
    end)
    if not ok then return { files = {}, count = 0 } end
    -- strip base prefix for matching
    local prefix = base
    if not prefix:find("/$") then prefix = prefix .. "/" end
    local files = {}
    local lp = glob_to_pattern(pattern)
    for _, f in ipairs(all_files) do
        local rel = f
        if f:sub(1, #prefix) == prefix then rel = f:sub(#prefix + 1) end
        -- match against the whole relative path (** may span dirs) or basename
        local name = rel:match("([^/]+)$") or rel
        if rel:match(lp) or name:match(lp) then
            files[#files + 1] = to_rel(f, args._cfg)
            if #files >= 500 then break end -- design §7: limit 500
        end
    end
    table.sort(files)
    return { files = files, count = #files }
end

function M.grep(args)
    local base = args.path and resolve(args.path, args._cfg) or current_workspace(args._cfg)
    local max = args.max_results or 100
    local ic = args.ignore_case and "-i " or ""
    local pattern = args.pattern or ""
    local glob_flag = ""
    if args.glob then
        glob_flag = "--glob " .. sq(args.glob) .. " "
    end

    local data = ""
    local ok = pcall(function()
        -- design §7: prefer rg, then grep -R, then (omitted) Lua fallback
        local f = io.popen("rg -n --no-heading " .. glob_flag .. ic .. sq(pattern) .. " " .. sq(base) .. " 2>/dev/null | head -" .. max)
        data = f:read("*a")
        f:close()
    end)
    if not ok or data == "" then
        ok = pcall(function()
            local f = io.popen("grep -rn" .. ic .. " " .. sq(pattern) .. " " .. sq(base) .. " 2>/dev/null | head -" .. max)
            data = f:read("*a")
            f:close()
        end)
    end

    local matches = {}
    for line in data:gmatch("[^\n]+") do
        -- design §7 format: {path, line, column, text}
        local p, num, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if not p then
            p, num, text = line:match("^(.-):(%d+):(.*)$")
            col = "1"
        end
        if p and num then
            matches[#matches + 1] = {
                path = to_rel(p, args._cfg),
                line = tonumber(num),
                column = tonumber(col) or 1,
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
    local path = resolve(args.path, args._cfg or cfg)
    if not within_workspace(path, args._cfg or cfg) then
        return nil, "write outside workspace requires confirmation"
    end
    local content = args.content or ""
    local ok, err = atomic_write(path, content)
    if not ok then
        return nil, string.format("cannot write %s", to_rel(args.path, args._cfg or cfg))
    end
    return { bytes = #content, path = to_rel(args.path, args._cfg or cfg) }
end

function M.patch(patch_str, cfg)
    local c = cfg
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
        elseif line:match("^%+%+%+%s+%S+") then
            -- take the b/ path if present (prefer it over a/)
            local bpath = line:match("^%+%+%+%s+([^%s]+)")
            if bpath and current_file then
                file_patches[bpath] = file_patches[current_file]
                if bpath ~= current_file then file_patches[current_file] = nil end
                current_file = bpath
            end
        elseif line:match("^@@") then
            local ns = tonumber(line:match("@@%-(%d+)") or line:match("@@%+(%d+)")) or 1
            current_hunk = { old_start = ns, new_start = ns, old_lines = {}, new_lines = {} }
            if file_patches[current_file] then
                local fp = file_patches[current_file]
                fp.hunks[#fp.hunks + 1] = current_hunk
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
        local full_path = resolve(fname, c)
        if not within_workspace(full_path, c) then
            return nil, string.format("patch outside workspace: %s", fname)
        end
        local f = io.open(full_path, "r")
        local content = f and f:read("*a") or ""
        if f then f:close() end
        local content_lines = {}
        for line in content:gmatch("([^\n]*)\n?") do
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
            files_applied = files_applied + 1
            applied_files[#applied_files + 1] = { file = fname, add = add_count, del = del_count }
        else
            return nil, string.format("patch conflict in %s — перечитайте файл", fname)
        end
    end

    return { files = files_applied, add = total_add, del = total_del, applied = applied_files }
end

function M.run(args, cfg)
    local c = args._cfg or cfg
    local command = args.command or ""
    local timeout_val = (args.timeout or (c and c.tools and c.tools.run_shell and c.tools.run_shell.timeout)) or 120
    local cwd = args.cwd and resolve(args.cwd, c) or current_workspace(c)
    if not within_workspace(cwd, c) then
        return nil, "run outside workspace requires confirmation"
    end

    local start_ms = now_ms()
    -- unique temp file per invocation: no cross-run races / leaks (audit #6)
    local outfile = ("/tmp/tether_run_%d_%d.out"):format(os.time(), math.random(100000, 999999))
    local cmd = string.format("cd %s && timeout %d env TETHER_WORKSPACE=%s sh -c %s > %s 2>&1",
                              sq(cwd), timeout_val, sq(cwd), sq(command), sq(outfile))
    local ok, exit_code = tether.exec(cmd)
    local elapsed = now_ms() - start_ms

    local f = io.open(outfile, "r")
    local output = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(outfile)

    return { output = output, exit_code = exit_code or (ok and 0 or 1), elapsed_ms = elapsed }
end

return M
