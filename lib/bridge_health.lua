-- lib/bridge_health.lua
-- Proactive health check and circuit breaker for Komga server connections.
-- Prevents Android ANRs by instantly failing requests when the server is unreachable
-- and strictly bounding main-thread network timeouts.

local logger = require("logger")
local os = require("os")

local M = {
    _breaker_until = 0,
    _breaker_reason = nil,
    _last_checked_at = 0,
    _is_reachable = true,
    _failure_count = 0,
    _in_subprocess = false,
    COOLDOWN_SECONDS = 60,
    CACHE_VALID_SECONDS = 15,
    MAIN_THREAD_MAX_TIMEOUT = 1.5,
}

local function parseUrl(url)
    if type(url) ~= "string" or url == "" then return nil, nil, nil end
    local scheme, host, port = url:match("^(https?)://([^:/]+):?(%d*)")
    if not host then return nil, nil end
    port = tonumber(port)
    if not port then
        port = (scheme == "https") and 443 or 80
    end
    return host, port, scheme
end

M.parseUrl = parseUrl

function M.setInSubprocess(val)
    M._in_subprocess = not not val
end

function M.isInSubprocess()
    return M._in_subprocess
end

function M.isCircuitBreakerActive()
    local now = os.time()
    if M._breaker_until and M._breaker_until > now then
        return true, M._breaker_reason
    end
    return false, nil
end

function M.tripCircuitBreaker(reason, duration)
    duration = duration or M.COOLDOWN_SECONDS
    M._breaker_until = os.time() + duration
    M._breaker_reason = tostring(reason or "Server unreachable")
    M._is_reachable = false
    M._failure_count = M._failure_count + 1
    logger.warn("[Bridge Health] Tripped circuit breaker for " .. duration .. "s. Reason: " .. M._breaker_reason)
end

function M.resetCircuitBreaker()
    M._breaker_until = 0
    M._breaker_reason = nil
    M._last_checked_at = 0
    M._is_reachable = true
    M._failure_count = 0
    logger.info("[Bridge Health] Circuit breaker reset.")
end

function M.reportSuccess()
    M._failure_count = 0
    M._is_reachable = true
    M._last_checked_at = os.time()
    if M._breaker_until > 0 then
        M.resetCircuitBreaker()
    end
end

function M.reportFailure(err)
    local err_str = tostring(err):lower()
    local is_unreachable = err_str:find("timeout") ~= nil
        or err_str:find("refused") ~= nil
        or err_str:find("host not found") ~= nil
        or err_str:find("unreachable") ~= nil
        or err_str:find("no route") ~= nil
        or err_str:find("closed") ~= nil
        or err_str:find("network is down") ~= nil
        or err_str:find("network unreachable") ~= nil
    if is_unreachable then
        M.tripCircuitBreaker(err)
    end
end

function M.getActiveServerUrl(profiles_mod)
    if profiles_mod and profiles_mod.getProfiles then
        local profiles = profiles_mod.getProfiles()
        if type(profiles) == "table" then
            for _, p in ipairs(profiles) do
                if p.active and p.base_url and p.base_url ~= "" then
                    return p.base_url
                end
            end
            if profiles[1] and profiles[1].base_url then
                return profiles[1].base_url
            end
        end
    end
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_pl and PluginLoader and PluginLoader.loaded_plugins or nil
    local komga = loaded and loaded["kokomga"]
    if komga and komga.settings and komga.settings.server_url then
        return komga.settings.server_url
    end
    return nil
end

function M.isServerReachable(url, force_probe)
    -- 1. Check if device has any network connection
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        return false, "Network offline"
    end

    -- 2. Check if circuit breaker is tripped
    local is_active, reason = M.isCircuitBreakerActive()
    if is_active then
        return false, "Circuit breaker active: " .. tostring(reason)
    end

    local now = os.time()
    if not force_probe and (now - M._last_checked_at) < M.CACHE_VALID_SECONDS then
        return M._is_reachable, M._is_reachable and nil or "Server unreachable (cached)"
    end

    -- 3. Perform fast socket probe if host is available
    if not url then
        local ok_pr, Profiles = pcall(require, "lib/bridge_profiles")
        url = M.getActiveServerUrl(ok_pr and Profiles)
    end

    if not url then return true end

    local host, port = parseUrl(url)
    if not host then return true end

    local probe_ok = false
    local probe_err = nil

    local ok_sock, socket = pcall(require, "socket")
    if ok_sock and socket and socket.tcp then
        local ok_call, s = pcall(socket.tcp)
        if ok_call and s then
            pcall(s.settimeout, s, 1.0)
            local res, err = s:connect(host, port)
            pcall(s.close, s)
            if res then
                probe_ok = true
            else
                probe_err = err or "Connection failed"
            end
        end
    else
        -- If socket.tcp is unavailable in current runtime, rely on HTTP error tracking
        probe_ok = true
    end

    M._last_checked_at = now
    if probe_ok then
        M._is_reachable = true
        return true
    else
        M.tripCircuitBreaker(probe_err or "Probe failed")
        return false, probe_err or "Server probe failed"
    end
end

return M
