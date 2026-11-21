-- lib/bridge_async_http.lua
-- Non-blocking background HTTP runner using curl + UIManager:scheduleIn polling.
-- Prevents DNS (gethostbyname) and socket (poll) stalls from blocking KOReader's LuaJIT main thread.

local DataStorage = require("datastorage")
local logger = require("logger")

local M = {}

local _curl_bin = nil
local _curl_checked = false
local _seq = 0

local function getCurlBin()
    if _curl_checked then return _curl_bin end
    _curl_checked = true
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local candidates = { "/system/bin/curl", "/usr/bin/curl", "/bin/curl" }
    if ok_lfs and lfs and lfs.attributes then
        for _, p in ipairs(candidates) do
            if lfs.attributes(p, "mode") == "file" then
                _curl_bin = p
                return _curl_bin
            end
        end
    end
    return nil
end

function M.isAvailable()
    return getCurlBin() ~= nil
end

local function escapeCfgValue(val)
    local s = tostring(val or "")
    s = s:gsub("%z", ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "")
    return '"' .. s .. '"'
end

local function shellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function isAllowedHttpUrl(url)
    if type(url) ~= "string" or url == "" or url:find("[%z\r\n]") then return false end
    local scheme = url:match("^([%a][%w+.-]*)://")
    if not scheme then return false end
    scheme = scheme:lower()
    return scheme == "http" or scheme == "https"
end

local function ensureTempDir()
    local dir = DataStorage:getDataDir() .. "/cache/bridge_async_http"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.mkdir then
        pcall(lfs.mkdir, DataStorage:getDataDir() .. "/cache")
        pcall(lfs.mkdir, dir)
    end
    return dir
end

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

local function fileExists(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.attributes then
        return lfs.attributes(path, "mode") == "file"
    end
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function cleanup(paths)
    for _, p in ipairs(paths) do
        if p then pcall(os.remove, p) end
    end
end

local function reportHealth(code, err_msg, opts)
    local ok_h, Health = pcall(require, "lib/bridge_health")
    if not (ok_h and Health) then return end
    local num_code = tonumber(code) or 0
    if num_code >= 200 and num_code < 500 and num_code ~= 408 then
        if Health.reportSuccess then Health.reportSuccess() end
    else
        if Health.reportFailure then
            Health.reportFailure(err_msg or ("HTTP " .. tostring(code)), opts)
        end
    end
end

--- Execute an HTTP request asynchronously in a background curl subprocess.
-- opts = { url, method, headers, body, connect_timeout, max_time, skip_health, is_thumbnail }
-- callback(ok, http_code, response_body, err_msg)
function M.requestAsync(opts, callback)
    local curl_bin = getCurlBin()
    if not curl_bin then
        if callback then callback(false, 0, nil, "curl unavailable") end
        return false
    end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not (ok_ui and UIManager and UIManager.scheduleIn) then
        if callback then callback(false, 0, nil, "UIManager unavailable") end
        return false
    end

    if type(opts) ~= "table" or not isAllowedHttpUrl(opts.url) then
        if callback then callback(false, 0, nil, "Invalid URL") end
        return false
    end

    _seq = _seq + 1
    local dir = ensureTempDir()
    local rand_id = math.random(100000, 999999)
    local prefix = string.format("%s/req_%d_%d_%d", dir, os.time(), _seq, rand_id)
    local cfg_path = prefix .. ".cfg"
    local body_in_path = opts.body and (prefix .. ".in") or nil
    local out_path = opts.output_path or (prefix .. ".out")
    local meta_path = prefix .. ".meta"
    local done_path = prefix .. ".done"
    local pid_path = prefix .. ".pid"

    if body_in_path then
        local fin, err_in = io.open(body_in_path, "wb")
        if not fin then
            if callback then callback(false, 0, nil, "Failed to write request body: " .. tostring(err_in)) end
            return false
        end
        local ok_w, err_w = fin:write(tostring(opts.body))
        local ok_c, err_c = fin:close()
        if not ok_w or not ok_c then
            cleanup({ body_in_path })
            if callback then callback(false, 0, nil, "Failed to flush request body: " .. tostring(err_w or err_c)) end
            return false
        end
    end

    local connect_timeout = tonumber(opts.connect_timeout) or 2
    local max_time = tonumber(opts.max_time) or 5
    local method = string.upper(tostring(opts.method or "GET"))

    local cfg_lines = {
        "url = " .. escapeCfgValue(opts.url),
        method == "HEAD" and "head" or ("request = " .. escapeCfgValue(method)),
        "connect-timeout = " .. tostring(connect_timeout),
        "max-time = " .. tostring(max_time),
        "proto = " .. escapeCfgValue("=http,https"),
        "proto-redir = " .. escapeCfgValue("=http,https"),
        "silent",
        "show-error",
        "output = " .. escapeCfgValue(out_path),
        'write-out = "%{http_code}"',
    }

    if type(opts.headers) == "table" then
        for k, v in pairs(opts.headers) do
            if v ~= nil and tostring(v) ~= "" then
                cfg_lines[#cfg_lines + 1] = "header = " .. escapeCfgValue(tostring(k) .. ": " .. tostring(v))
            end
        end
    end

    if body_in_path then
        cfg_lines[#cfg_lines + 1] = "data-binary = " .. escapeCfgValue("@" .. body_in_path)
    end

    local fcfg, err_cfg = io.open(cfg_path, "wb")
    if not fcfg then
        cleanup({ body_in_path })
        if callback then callback(false, 0, nil, "Failed to write curl config: " .. tostring(err_cfg)) end
        return false
    end
    local ok_cw, err_cw = fcfg:write(table.concat(cfg_lines, "\n") .. "\n")
    local ok_cc, err_cc = fcfg:close()
    if not ok_cw or not ok_cc then
        cleanup({ cfg_path, body_in_path })
        if callback then callback(false, 0, nil, "Failed to flush curl config: " .. tostring(err_cw or err_cc)) end
        return false
    end

    local q_curl = shellQuote(curl_bin)
    local q_cfg = shellQuote(cfg_path)
    local q_meta = shellQuote(meta_path)
    local q_done = shellQuote(done_path)
    local q_pid = shellQuote(pid_path)
    local bg_rm = body_in_path
        and ("rm -f " .. q_cfg .. " " .. shellQuote(body_in_path))
        or ("rm -f " .. q_cfg)

    local cmd = string.format(
        '(echo $$ > %s; %s -K %s > %s 2>/dev/null; rc=$?; printf "\\nCURL_RC=%%d\\n" "$rc" >> %s; %s; mv %s %s) >/dev/null 2>&1 &',
        q_pid, q_curl, q_cfg, q_meta, q_meta, bg_rm, q_meta, q_done
    )
    local exec_res = os.execute(cmd)
    if exec_res == false or (type(exec_res) == "number" and exec_res ~= 0) then
        cleanup({ cfg_path, body_in_path, meta_path, done_path, pid_path })
        if callback then callback(false, 0, nil, "Failed to spawn curl") end
        return false
    end

    local deadline = os.time() + max_time + 3
    local to_clean = { cfg_path, body_in_path, meta_path, done_path, pid_path }
    if not opts.output_path then
        to_clean[#to_clean + 1] = out_path
    end
    local health_opts = { is_thumbnail = opts.is_thumbnail == true or (opts.url:find("/thumbnail", 1, true) ~= nil) }

    local function poll()
        if fileExists(done_path) then
            local meta_str = readFile(done_path) or "0\nCURL_RC=1"
            local code = tonumber(meta_str:match("^(%d+)")) or 0
            local curl_rc = tonumber(meta_str:match("CURL_RC=(%d+)")) or tonumber(meta_str:match("^%d+%s+(%d+)")) or 0
            local resp_body = nil
            if not opts.output_path then
                resp_body = readFile(out_path)
            end
            cleanup(to_clean)
            local ok = (curl_rc == 0) and (code >= 200 and code < 300)
            local err_msg = nil
            if not ok then
                if curl_rc == 28 then
                    err_msg = "Request timeout"
                elseif curl_rc ~= 0 then
                    err_msg = "curl exit " .. tostring(curl_rc) .. (code == 0 and " (network unreachable)" or (" (HTTP " .. tostring(code) .. ")"))
                else
                    err_msg = (code == 0) and "Network timeout" or ("HTTP " .. tostring(code))
                end
                logger.warn(string.format("[BridgeAsyncHttp] request failed: method=%s code=%s curl_rc=%s err=%s meta=%q",
                    tostring(method), tostring(code), tostring(curl_rc), tostring(err_msg), tostring(meta_str)))
            end
            if not opts.skip_health then
                reportHealth(ok and code or (curl_rc ~= 0 and 0 or code), err_msg, health_opts)
            end
            if callback then callback(ok, ok and code or (curl_rc ~= 0 and 0 or code), resp_body, err_msg) end
            return
        end

        if os.time() > deadline then
            local pid_str = readFile(pid_path)
            local pid_num = pid_str and tonumber(pid_str:match("(%d+)"))
            if pid_num and pid_num > 1 then
                pcall(os.execute, "kill -9 " .. tostring(pid_num) .. " >/dev/null 2>&1")
            end
            cleanup(to_clean)
            if opts.output_path then pcall(os.remove, opts.output_path) end
            local err_msg = "Async HTTP poll timeout"
            if not opts.skip_health then
                reportHealth(0, err_msg, health_opts)
            end
            logger.warn("[BridgeAsyncHttp] " .. err_msg)
            if callback then callback(false, 0, nil, err_msg) end
            return
        end

        UIManager:scheduleIn(0.15, poll)
    end

    UIManager:scheduleIn(0.15, poll)
    return true
end

--- Stream a remote URL to dest_path asynchronously via curl.
-- opts = { url, headers, tmp_path, dest_path, connect_timeout, max_time, skip_health, is_thumbnail }
-- callback(ok, http_code, dest_path_or_nil, err_msg)
function M.downloadAsync(opts, callback)
    if type(opts) ~= "table" or not opts.tmp_path or not opts.dest_path then
        if callback then callback(false, 0, nil, "Missing tmp_path or dest_path") end
        return false
    end

    _seq = _seq + 1
    local unique_tmp = opts.tmp_path .. "." .. tostring(os.time()) .. "_" .. tostring(_seq) .. "_" .. tostring(math.random(1000, 9999))

    return M.requestAsync({
        url = opts.url,
        method = "GET",
        headers = opts.headers,
        output_path = unique_tmp,
        connect_timeout = opts.connect_timeout or 5,
        max_time = opts.max_time or 120,
        skip_health = opts.skip_health,
        is_thumbnail = opts.is_thumbnail,
    }, function(ok, code, _, err_msg)
        if not ok then
            pcall(os.remove, unique_tmp)
            if callback then callback(false, code, nil, err_msg) end
            return
        end
        local ok_ren, ren_err = os.rename(unique_tmp, opts.dest_path)
        if not ok_ren then
            pcall(os.remove, unique_tmp)
            logger.warn("[BridgeAsyncHttp] os.rename failed: " .. tostring(ren_err))
            if callback then callback(false, code, nil, "Failed to move downloaded file: " .. tostring(ren_err)) end
            return
        end
        if callback then callback(true, code, opts.dest_path, nil) end
    end)
end

M.escapeCfgValue = escapeCfgValue
return M
