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

-- TW3: the model may omit `path` (or arguments may fail to decode — parse_args
-- returns {} on bad JSON). A nil/empty path must surface as a tool error the
-- model can correct, not a Lua crash ("attempt to index a nil value") that
-- kills the turn.
local function require_path(args)
    local p = args and args.path
    if type(p) == "string" and p ~= "" then return p end
    return nil, "missing path argument"
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

-- Design §7: symlinks are resolved; path traversal via ".." is rejected.
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

function M.read(args, cfg)
    local path, perr = require_path(args)
    if not path then return nil, perr end
    path = resolve(path, cfg)
    local f = io.open(path, "rb")
    if not f then
        return nil, string.format("cannot open %s", to_rel(args.path, cfg))
    end
    local data = f:read(1024 * 1024)
    f:close()
    if not data then
        return nil, "read failed"
    end
    if data:sub(1, 8192):find("\0", 1, true) then
        return nil, string.format("%s is binary", to_rel(args.path, cfg))
    end
    -- 3.3: split without emitting a phantom trailing line for \n-terminated files
    local body = data
    if body:sub(-1) == "\n" then body = body:sub(1, -2) end
    local lines = {}
    if body ~= "" then
        for line in body:gmatch("[^\n]*") do
            lines[#lines + 1] = line
            if #lines > 200000 then break end
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

local function is_dir(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    -- 2.4: a directory's realpath with a trailing "/" is the directory itself;
    -- for a file that path cannot resolve (ENOTDIR) so realpath returns nil.
    local rp = tether.realpath and tether.realpath(path .. "/") or nil
    if not rp then return false end
    local norm = (path:gsub("/+$", ""))
    return rp == norm
end

local function dir_entries(path)
    -- 1.4: in-process listing via the C host; readdir already returns the
    -- entry names sorted and without `.`/`..` (no `ls -1A` shell-out).
    local names = tether.readdir(path)
    if not names then return {} end
    return names
end

function M.list(args, cfg)
    local path = args.path and resolve(args.path, cfg) or current_workspace(cfg)
    local entries = dir_entries(path)
    return { entries = entries, count = #entries }
end

-- 4.1/4.4: path completion primitive. Takes a user-typed token (may start
-- with @, may be relative), returns a list of matching candidates.
--   prefix = "/abs/path"          → list entries under that absolute dir
--   prefix = "src"                 → workspace-relative candidates matching prefix
--   prefix = "src/"                → list entries inside src/
--   prefix = "@src"               → same as "src", leading @ preserved in UI
-- Absolute tokens starting with "/" or containing ".." are refused (return {}).
-- Results capped at 200 with a truncation flag.
function M.path_complete(token, cfg)
    local ws = current_workspace(cfg)
    -- refuse absolute and traversal tokens
    if token:sub(1, 1) == "/" then return { candidates = {}, truncated = false } end
    if token:find("%.%./") or token:find("^%.%./") or token:find("/%.%./")
        or token:find("^%.%./") then
        return { candidates = {}, truncated = false }
    end
    -- strip leading @
    local clean = token:gsub("^@", "")
    -- split into dir part and file prefix
    local dir, filepfx
    local slash = clean:match("^(.*)/")
    if slash then
        dir = slash
        filepfx = clean:sub(#slash + 2)
    else
        dir = ""
        filepfx = clean
    end
    local abs_dir = (dir == "") and ws or (ws .. "/" .. dir)
    -- check we are still inside the workspace
    if not within_workspace(abs_dir, cfg) then
        return { candidates = {}, truncated = false }
    end
    local entries = dir_entries(abs_dir)
    local candidates = {}
    local limit = 200
    local truncated = false
    for _, e in ipairs(entries) do
        if e:sub(1, #filepfx) == filepfx then
            -- 4.4: directories get a trailing / so a second completion lists inside them
            local base = is_dir(abs_dir .. "/" .. e) and (e .. "/") or e
            -- The candidate carries the typed directory: completing replaces the
            -- whole token, so a bare name would drop it (spec tui: Path
            -- completion — the token becomes `src/tether/agent.lua`).
            local label = (dir == "") and base or (dir .. "/" .. base)
            candidates[#candidates + 1] = label
            if #candidates >= limit then truncated = true break end
        end
    end
    return { candidates = candidates, truncated = truncated }
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

function M.glob(args, cfg)
    local base = args.path and resolve(args.path, cfg) or current_workspace(cfg)
    local pattern = args.pattern or ""
    local all_files = {}
    -- 1.5: recursive in-process walk (no `find` shell-out). tether.stat is
    -- lstat-based, matching `find -type f`: symlinks are not followed.
    local function walk(dir)
        local names = tether.readdir(dir)
        if not names then return end
        for _, name in ipairs(names) do
            local full = dir .. "/" .. name
            local st = tether.stat(full)
            if st and st.is_dir then
                walk(full)
            elseif st then
                all_files[#all_files + 1] = full
            end
        end
    end
    local ok = pcall(walk, base)
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
            files[#files + 1] = to_rel(f, cfg)
            if #files >= 500 then break end -- design §7: limit 500
        end
    end
    table.sort(files)
    return { files = files, count = #files }
end

function M.grep(args, cfg)
    local base = args.path and resolve(args.path, cfg) or current_workspace(cfg)
    local max = args.max_results or 100
    local pattern = args.pattern or ""

    -- 2.2: one in-process krep invocation replaces the rg -> grep shell
    -- fallback. krep honors .gitignore/.ignore and the optional glob filter on
    -- its own; records come back as {path, line, column, text} (column is 1
    -- because krep's printed form carries no column).
    local records = tether.krep_search(base, pattern, args.glob,
        args.ignore_case == true, true, max)
    if not records then return { matches = {}, count = 0 } end

    local matches = {}
    for _, rec in ipairs(records) do
        matches[#matches + 1] = {
            path = to_rel(rec.path, cfg),
            line = rec.line,
            column = rec.column or 1,
            text = rec.text,
        }
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
    local path, perr = require_path(args)
    if not path then return nil, perr end
    path = resolve(path, cfg)
    if not within_workspace(path, cfg) then
        return nil, "write outside workspace requires confirmation"
    end
    local content = args.content or ""
    local ok, err = atomic_write(path, content)
    if not ok then
        return nil, string.format("cannot write %s", to_rel(args.path, cfg))
    end
    return { bytes = #content, path = to_rel(args.path, cfg) }
end

function M.patch(patch_str, cfg)
    local c = cfg
    local file_patches = {}
    local current_file = nil
    local current_hunk = nil

    -- (pre-existing) gmatch returns an iterator; wrapping it in ipairs raised
    -- "attempt to index a function value" — the patch tool could never run.
    -- The `a/`/`b/` component that `diff -u` / git add to a header is not part
    -- of the real path; strip one leading component and treat /dev/null as
    -- "no such side" (new/deleted file). Applies to both header styles.
    local function diff_path(p)
        if not p or p == "/dev/null" then return nil end
        return p:match("^[ab]/(.+)$") or p
    end

    for line in patch_str:gmatch("[^\n]*") do
        if line:match("^%-%-%-%s+%S+") then
            current_file = diff_path(line:match("^%-%-%-%s+([^%s]+)"))
            current_hunk = nil
            if current_file and not file_patches[current_file] then
                file_patches[current_file] = { hunks = {} }
            end
        elseif line:match("^%+%+%+%s+%S+") then
            -- take the +++ path (stripped of a//b/); a new file has --- /dev/null
            local bpath = diff_path(line:match("^%+%+%+%s+([^%s]+)"))
            if bpath then
                if current_file then
                    file_patches[bpath] = file_patches[current_file]
                    if bpath ~= current_file then file_patches[current_file] = nil end
                elseif not file_patches[bpath] then
                    file_patches[bpath] = { hunks = {} }
                end
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
            return nil, string.format("%s outside workspace requires confirmation", fname)
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
            return nil, string.format("patch conflict in %s — re-read the file", fname)
        end
    end

    return { files = files_applied, add = total_add, del = total_del, applied = applied_files }
end

function M.run(args, cfg)
    local c = cfg
    local command = args.command or ""
    -- 3.7: the model may send a string/float timeout; coerce before %d.
    local timeout_val = tonumber(args.timeout)
        or (c and c.tools and c.tools.run_shell and tonumber(c.tools.run_shell.timeout))
        or 120
    if timeout_val < 1 then timeout_val = 1 end
    timeout_val = math.floor(timeout_val)
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
