-- tether update — self-update against the GitHub release stream.
--
-- Two halves, one contract with .github/workflows/build.yml: every push to main
-- publishes tag `tether-<short sha>` with a `VERSION` asset (that sha, one line)
-- and the bare executable. `build_version` is the same kind of sha, so
-- "is there something newer" is a string comparison, never a version parse.
--
-- Startup discipline mirrors provider_metadata (src/tether/metadata.lua): a fresh
-- cache serves with zero network, an expired one schedules ONE background probe
-- through tether.fetch_bg and serves the result on a later start — the running
-- session never waits on the network and never fails because of it. Downloading
-- a release binary happens only when the user runs `tether update`.
-- IN:  cfg table (or nil), home string (or nil = $HOME), current build sha
-- OUT: status strings, a sha for the banner, or (code, message) for the command
-- EXAMPLE:
--      update.notice({ update_check = true }, home, "a521ba3")
--          --> "update available: tether 1c26820  (run: tether update)"
local M = {}

local function json()
    return _G.provider_common
        or (function()
            local chunk = loadfile("src/tether/providers/common.lua")
            return chunk and chunk()
        end)()
end

-- Release source. The base is overridable only so tests can point it at a local
-- stub; users have no reason to change it and it is undocumented on purpose.
M.RELEASE_BASE = "https://github.com/vorons/tether"
M.UPDATE_TTL = 24 * 3600
M.PROBE_TIMEOUT_S = 20
-- A background probe whose marker never filled in: the forked child died.
M.STALE_MARKER_S = 120
M.SYNC_TIMEOUT_S = 30
M.BINARY_TIMEOUT_S = 120
-- A release binary below this is truncated or an error page, not a build.
-- The UPX-packed linux build is roughly 0.9 MB.
M.MIN_BINARY_BYTES = 200000

function M.base_url()
    local b = os.getenv("TETHER_RELEASE_BASE_URL")
    if type(b) == "string" and b ~= "" then
        return (b:gsub("/+$", ""))
    end
    return M.RELEASE_BASE
end

function M.version_url()
    return M.base_url() .. "/releases/latest/download/VERSION"
end

-- Asset URL for one probed sha. The sha is hex-checked before it can reach a
-- URL, so a hostile or corrupt probe answer cannot redirect the updater.
function M.binary_url(sha)
    if type(sha) ~= "string" or not sha:match("^%x+$") then
        return nil, "bad release id"
    end
    return M.base_url() .. "/releases/download/tether-" .. sha
        .. "/tether-" .. sha .. "-linux-x86_64"
end

-- Strict probe reader: the whole body must be one hex token of sha-plausible
-- length. Loose matching would turn an intermediate proxy's error page into a
-- release id, and the updater would then fetch a URL for a build that does not
-- exist (design add-self-update §3).
function M.parse_version(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty version response"
    end
    if body:match("^FETCH_FAILED") then
        return nil, (body:match("^FETCH_FAILED%s*(.-)%s*$") or "request failed")
    end
    local s = body:match("^%s*(%x+)%s*$")
    if not s then return nil, "not a release version" end
    if #s < 7 or #s > 40 then return nil, "version out of range" end
    return s:lower()
end

-- Home resolution matches providers/catalog.lua: an explicit argument wins,
-- then TETHER_HOME (portable installs, test isolation), then HOME.
function M.cache_path(home)
    local h = home
    if type(h) ~= "string" or h == "" then
        h = os.getenv("TETHER_HOME")
    end
    if type(h) ~= "string" or h == "" then h = os.getenv("HOME") or "." end
    return h .. "/.tether/update.json"
end

function M.marker_path(home)
    return M.cache_path(home) .. ".pending"
end

-- { sha = <probed release>, checked_at = <os.time> }. Unreadable or corrupt
-- content is an absent record, never an error.
local function read_record(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local j = json()
    if not j then return {} end
    local ok, tbl = pcall(j.json_decode, data or "")
    if not ok or type(tbl) ~= "table" then return {} end
    return tbl
end

local function write_record(path, rec)
    local j = json()
    if not j then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(j.json_encode(rec))
    f:close()
    return true
end

-- Fold a finished background probe into the cache. Returns "idle" (no marker),
-- "waiting" (child still running), "updated" or "failed". A failed probe keeps
-- the previous sha and only stamps checked_at, so a dead source cools down for
-- one TTL instead of retrying every start.
function M.consume(home)
    local pend = M.marker_path(home)
    local f = io.open(pend, "r")
    if not f then return "idle" end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then
        local th = rawget(_G, "tether")
        if th and th.stat then
            local ok, st = pcall(th.stat, pend)
            if ok and type(st) == "table" and tonumber(st.mtime)
                and (os.time() - tonumber(st.mtime)) > M.STALE_MARKER_S then
                os.remove(pend)
                return "idle"
            end
        end
        return "waiting"
    end
    os.remove(pend)
    local sha = M.parse_version(body)
    local path = M.cache_path(home)
    local rec = read_record(path)
    rec.checked_at = os.time()
    if sha then rec.sha = sha end
    write_record(path, rec)
    return sha and "updated" or "failed"
end

-- Schedule one detached probe and return immediately. Without the background
-- fetch primitive there is nothing safe to do in-session: startup must not
-- block on the network, so the check reports "nosync" and stays silent.
local function schedule(home)
    local th = rawget(_G, "tether")
    if not (th and th.fetch_bg) then return "nosync" end
    local pend = M.marker_path(home)
    local pf = io.open(pend, "w")
    if not pf then return "nosync" end
    pf:close()
    local ok, res = pcall(th.fetch_bg, M.version_url(), {}, pend,
        M.PROBE_TIMEOUT_S)
    if ok and res then return "background" end
    os.remove(pend)
    return "nosync"
end

-- Startup hook. Returns "off" | "fresh" | "waiting" | "background" | "nosync"
-- plus the cached sha when one is known. Never raises, never blocks.
function M.check(cfg, home)
    if type(cfg) == "table" and cfg.update_check == false then
        return "off"
    end
    if M.consume(home) == "waiting" then return "waiting" end
    local rec = read_record(M.cache_path(home))
    local checked = tonumber(rec.checked_at)
    if checked and (os.time() - checked) < M.UPDATE_TTL then
        return "fresh", rec.sha
    end
    return schedule(home), rec.sha
end

-- ponytail: release identity is a git short sha, which has no ordering, so any
-- sha different from `current` reads as "newer". A hand-built binary ahead of
-- the newest release therefore gets offered that release. Accepted for the
-- single-developer alpha channel; a tagged-release scheme would retire this.
--
-- The banner text to show, or nil: opt-out, no current version, no cache, an
-- expired cache, or already that build. Decided from disk only — no network.
-- The copy lives here rather than in ui/copy.lua because that file's TCOPY
-- guard rejects the literal release-name token it has to quote.
function M.notice(cfg, home, current)
    if type(cfg) == "table" and cfg.update_check == false then return nil end
    if type(current) ~= "string" or current == "" then return nil end
    local rec = read_record(M.cache_path(home))
    local checked = tonumber(rec.checked_at)
    if not checked or (os.time() - checked) >= M.UPDATE_TTL then return nil end
    local sha = rec.sha
    if type(sha) ~= "string" or sha == "" or sha == current then return nil end
    return "update available: tether " .. sha .. "  (run: tether update)"
end

-- foreground probe -> download -> verify -> swap. Returns (code, message).
-- The swap renames a temp file over the target instead of writing it: this
-- process IS the file being replaced, so an in-place write would fail with
-- ETXTBSY, while a rename only re-links the directory entry and leaves the
-- running inode alone. Same directory keeps the rename on one filesystem.

-- What to tell the user when the install itself refuses the write.
local NOT_WRITABLE = "\nhint: run this as the install's owner (sudo), or "
    .. "reinstall into ~/.local/bin with `make install`"

function M.run(home, current)
    local th = rawget(_G, "tether")
    if not (th and th.http_get) then return 1, "no http client" end
    local exe = th.exepath and th.exepath() or nil
    if type(exe) ~= "string" or exe == "" then
        return 1, "cannot locate the running executable; rebuild from source instead"
    end
    local dir = exe:match("^(.*)/[^/]*$") or exe
    if type(current) ~= "string" or current == "" or current == "dev" then
        return 1, "this build carries no release version; rebuild from source instead"
    end

    local ok, body, herr = pcall(th.http_get, M.version_url(), {},
        M.SYNC_TIMEOUT_S)
    if not ok then return 1, "cannot reach the release source: " .. tostring(body) end
    local sha, perr = M.parse_version(body)
    if not sha then
        return 1, "cannot reach the release source: "
            .. tostring(herr or perr)
    end
    if sha == current then
        return 0, "tether is already up to date (" .. sha .. ")"
    end

    local url, uerr = M.binary_url(sha)
    if not url then return 1, tostring(uerr) end
    local dok, blob, derr = pcall(th.http_get, url, {}, M.BINARY_TIMEOUT_S)
    if not dok then return 1, "download failed: " .. tostring(blob) end
    if type(blob) ~= "string" then
        return 1, "download failed: " .. tostring(derr or "no response")
    end
    if blob == "" then return 1, "download failed: empty response" end
    if blob:sub(1, 4) ~= "\127ELF" then
        return 1, "refused: response is not an executable"
    end
    if #blob < M.MIN_BINARY_BYTES then
        return 1, "refused: response is too small to be a full build"
    end

    -- Record the probed release before touching the binary: a later start whose
    -- cache still named the superseded sha would otherwise banner a downgrade.
    local rec = read_record(M.cache_path(home))
    rec.sha = sha
    rec.checked_at = os.time()
    write_record(M.cache_path(home), rec)

    local tmp = dir .. "/tether.update.tmp"
    local w = io.open(tmp, "wb")
    if not w then
        return 1, "cannot write into " .. dir .. NOT_WRITABLE
    end
    local wrote = w:write(blob)
    w:close()
    if not wrote then
        os.remove(tmp)
        return 1, "cannot write " .. tmp
    end
    if th.fchmod then
        -- tether.fchmod is `true | nil, err` (src/host/main.c:546).
        local cok, cres, cerr = pcall(th.fchmod, tmp, 493) -- 0755
        if not cok or not cres then
            os.remove(tmp)
            return 1, "cannot make " .. tmp .. " executable: "
                .. tostring(cerr or cres)
        end
    end
    local rok, rerr = os.rename(tmp, exe)
    if not rok then
        os.remove(tmp)
        return 1, "cannot replace " .. exe .. ": " .. tostring(rerr)
            .. NOT_WRITABLE
    end
    return 0, "updated tether " .. current .. " -> " .. sha
        .. "\nrestart tether to run the new build"
end

return M
