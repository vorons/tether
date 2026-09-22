-- tether context-injection: system prompt assembly
-- Composition: base (config.get_system_prompt or built-in tool prompt)
--   + home AGENTS.md + workspace AGENTS.md
--   + agents files (cfg.agents_files, then CLI --agents-file, in order)
--   + skills index (discovered dirs: default set or cfg.skills_dirs)
-- Skill content is NOT auto-injected — only the index; the agent reads
-- SKILL.md via the `read` tool on demand.

local M = {}

local AGENTS_CAP_BYTES = 16 * 1024

local BUILTIN_PROMPT = [==[
You are tether, a code assistant running inside a terminal.

Available tools:
- read(path, offset?, limit?) — read file contents
- write(path, content) — create/overwrite file
- list(path?) — list directory entries
- glob(pattern, path?) — find files by glob
- grep(pattern, path?, glob?, ignore_case?, max_results?) — search text in files
- run(command, cwd?, timeout?) — run shell command via /bin/sh -c
- patch(patch) — apply unified diff, strictly
- ask(questions) — ask the user to choose: [{question, options:[{label, description?}], id?, description?, multi?, recommended?}]

When a decision belongs to the user (which option, which scope, which
constraint), ask instead of guessing. When the user asks you to inspect or edit
code, use these tools.
Work in the current directory.
Outside workspace, write/patch/run require user confirmation.
]==]

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Does the path exist (file or dir)?
local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- List immediate subdirectories of `dir` that hold a SKILL.md, using the
-- in-process `tether.readdir` primitive (fix: no `ls -1A` shell-out).
-- Returns a sorted list, or nil when the directory cannot be listed.
local function ls_subdirs(dir)
    if not tether or not tether.readdir then return nil end
    local names = tether.readdir(dir)
    if not names then return nil end
    local entries = {}
    for _, name in ipairs(names) do
        if name ~= "." and name ~= ".." and name:find("/") == nil then
            local probe = io.open(dir .. "/" .. name .. "/SKILL.md", "r")
            if probe then
                probe:close()
                entries[#entries + 1] = name
            end
        end
    end
    table.sort(entries)
    return entries
end

-- Parse name/description from a leading ---...--- frontmatter block.
-- Falls back to the directory name when frontmatter or a field is missing.
function M.parse_skill_frontmatter(text, dir_name)
    local result = { name = dir_name, description = "" }
    if not text or not text:match("^%-%-%-\n") then
        return result
    end
    local block = text:match("^%-%-%-\n(.-)\n%-%-%-")
    if not block then
        return result
    end
    for line in block:gmatch("[^\n]+") do
        local key, val = line:match("^(%w[%w_-]*)%s*:%s*(.*)$")
        if key and val then
            val = val:match("^['\"]?(.-)['\"]$") or val
            val = val:gsub("%s+$", "")
            if key == "name" and result.name == dir_name then
                result.name = val
            elseif key == "description" and result.description == "" then
                result.description = val
            end
        end
    end
    return result
end

-- Default discovery order: user-global first, then workspace-local,
-- first-wins on name collision.
local function default_skill_dirs(workspace, home)
    local dirs = {}
    local function add(d)
        if d ~= nil then dirs[#dirs + 1] = d end
    end
    add(home and (home .. "/.tether/skills"))
    add(workspace and (workspace .. "/.tether/skills"))
    add(home and (home .. "/.agents/skills"))
    add(workspace and (workspace .. "/.agents/skills"))
    return dirs
end

function M.discover_skills(cfg, workspace)
    local cfg = cfg or {}
    local home = os.getenv("HOME") or ""
    local dirs
    if type(cfg.skills_dirs) == "table" and next(cfg.skills_dirs) then
        dirs = {}
        for _, d in ipairs(cfg.skills_dirs) do
            if type(d) == "string" and d ~= "" then dirs[#dirs + 1] = d end
        end
    else
        dirs = default_skill_dirs(workspace, home)
    end

    local seen = {}
    local skills = {}
    for _, dir in ipairs(dirs) do
        local entries = ls_subdirs(dir)
        if entries then
            for _, name in ipairs(entries) do
                if not seen[name] then
                    seen[name] = true
                    local skill_md = dir .. "/" .. name .. "/SKILL.md"
                    local text = read_file(skill_md)
                    local fm = M.parse_skill_frontmatter(text, name)
                    skills[#skills + 1] = {
                        name = fm.name,
                        description = fm.description,
                        path = skill_md,
                    }
                end
            end
        end
    end
    return skills
end

-- Auto-discovered AGENTS.md: home first, then workspace. A file that exists
-- but cannot be read is skipped with a stderr warning; missing files are
-- silently ignored.
function M.load_agents_files(workspace)
    local home = os.getenv("HOME") or ""
    local sections = {}
    local candidates = {
        { label = "home", path = home ~= "" and (home .. "/AGENTS.md") or nil },
        { label = "workspace", path = workspace and (workspace .. "/AGENTS.md") or nil },
    }
    for _, c in ipairs(candidates) do
        if c.path then
            local data = read_file(c.path)
            if data == nil then
                if exists(c.path) then
                    io.stderr:write("tether: cannot read AGENTS.md: " .. c.path .. "\n")
                end
            elseif data ~= "" then
                sections[#sections + 1] = { label = c.label, content = data }
            end
        end
    end
    return sections
end

-- Explicit agents files (cfg.agents_files + CLI --agents-file). An
-- unreadable path yields a stderr warning and is skipped.
function M.load_agents_paths(paths)
    local sections = {}
    for _, path in ipairs(paths or {}) do
        if exists(path) then
            local data = read_file(path)
            if data ~= nil and data ~= "" then
                sections[#sections + 1] = { path = path, content = data }
            else
                io.stderr:write("tether: cannot read agents file: " .. path .. "\n")
            end
        else
            io.stderr:write("tether: cannot read agents file: " .. path .. "\n")
        end
    end
    return sections
end

local function render_agents_sections(sections)
    local parts = {}
    for _, s in ipairs(sections) do
        local content = s.content
        if #content > AGENTS_CAP_BYTES then
            content = content:sub(1, AGENTS_CAP_BYTES) .. "…(truncated)"
        end
        local header
        if s.path then
            header = "## agents file: " .. s.path
        else
            header = "## AGENTS.md (" .. s.label .. ")"
        end
        parts[#parts + 1] = header .. "\n" .. content
    end
    return table.concat(parts, "\n\n")
end

local function render_skills_index(skills)
    if #skills == 0 then return nil end
    local parts = {}
    parts[#parts + 1] = "## Skills"
    parts[#parts + 1] = "Skills are markdown instruction files. When a task matches a skill's description, read the full file with the `read` tool before acting."
    for _, sk in ipairs(skills) do
        parts[#parts + 1] = string.format(
            "- name: %s\n  description: %s\n  file: %s",
            sk.name, sk.description, sk.path)
    end
    return table.concat(parts, "\n")
end

-- Compose the full system prompt.
-- opts: { agents_files = { path, ... }, workspace = string }
function M.compose(cfg, opts)
    local cfg = cfg or {}
    local opts = opts or {}
    local base = BUILTIN_PROMPT
    if config and config.get_system_prompt then
        base = config.get_system_prompt(cfg) or BUILTIN_PROMPT
    end

    local out = { base }

    local auto = M.load_agents_files(opts.workspace)
    if #auto > 0 then
        out[#out + 1] = render_agents_sections(auto)
    end

    local flag_paths = {}
    for _, p in ipairs(cfg.agents_files or {}) do
        if type(p) == "string" and p ~= "" then flag_paths[#flag_paths + 1] = p end
    end
    for _, p in ipairs(opts.agents_files or {}) do
        if type(p) == "string" and p ~= "" then flag_paths[#flag_paths + 1] = p end
    end
    if #flag_paths > 0 then
        local flag_secs = M.load_agents_paths(flag_paths)
        if #flag_secs > 0 then
            out[#out + 1] = render_agents_sections(flag_secs)
        end
    end

    local index = render_skills_index(M.discover_skills(cfg, opts.workspace))
    if index then
        out[#out + 1] = index
    end

    return table.concat(out, "\n\n")
end

-- Exposed for tests and for agent.lua to keep the built-in prompt in one place.
M.builtin_prompt = BUILTIN_PROMPT
M.default_skill_dirs = default_skill_dirs
M.AGENTS_CAP_BYTES = AGENTS_CAP_BYTES

return M
