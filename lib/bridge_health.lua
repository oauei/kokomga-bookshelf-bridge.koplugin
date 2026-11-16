-- lib/bridge_health.lua
-- Proactive health check and circuit breaker for Komga server connections.
-- Prevents Android ANRs by instantly failing requests when the server is unreachable
-- and strictly bounding main-thread network timeouts.

local logger = require("logger")
local os = require("os")

local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi and ffi then
    pcall(ffi.cdef, "int getpid(void);")
end
local PARENT_PID = nil
if ok_ffi and ffi then
    local ok_p, pid = pcall(function() return ffi.C.getpid() end)
    if ok_p and pid then
        PARENT_PID = pid
    end
end

local M = {
    _breaker_until = 0,
    _breaker_reason = nil,
    _last_checked_at = 0,
    _is_reachable = true,
    _failure_count = 0,
    _timeout_failures = 0,
    _in_subprocess = false,
    _dns_cache = {},
    _async_probe_in_flight = false,
    COOLDOWN_SECONDS = 20,
    CACHE_VALID_SECONDS = 15,
    DNS_CACHE_TTL = 300,
    TIMEOUT_FAILURE_THRESHOLD = 3,
    MAIN_THREAD_MAX_TIMEOUT = 1.5,
    PROBE_TIMEOUT = 0.5, -- 500ms fast probe for LAN/Wi-Fi
}

local function isIpLiteral(host)
    if type(host) ~= "string" then return false end
    return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil or host:find(":", 1, true) ~= nil
end

function M.getCachedIp(host)
    if not host then return nil end
    if isIpLiteral(host) then return host end
    local entry = M._dns_cache[host]
    if entry and (os.time() - entry.ts) < M.DNS_CACHE_TTL then
        return entry.ip
    end
    return nil
end

function M.setCachedIp(host, ip)
    if host and ip and ip ~= "" then
        M._dns_cache[host] = { ip = ip, ts = os.time() }
    end
end

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
    if M._in_subprocess then return true end
    if PARENT_PID and ok_ffi and ffi then
        local ok_p, pid = pcall(function() return ffi.C.getpid() end)
        if ok_p and pid and pid ~= PARENT_PID then
            return true
        end
    end
    return false
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
    M._timeout_failures = 0
    logger.info("[Bridge Health] Circuit breaker reset.")
end

function M.reportSuccess()
    M._failure_count = 0
    M._timeout_failures = 0
    M._is_reachable = true
    M._last_checked_at = os.time()
    if M._breaker_until > 0 then
        M.resetCircuitBreaker()
    end
end

function M.reportFailure(err, opts)
    local err_str = tostring(err):lower()
    local is_timeout = err_str:find("timeout") ~= nil
    local is_hard_unreachable = err_str:find("refused") ~= nil
        or err_str:find("host not found") ~= nil
        or err_str:find("unreachable") ~= nil
        or err_str:find("no route") ~= nil
        or err_str:find("closed") ~= nil
        or err_str:find("network is down") ~= nil
        or err_str:find("network unreachable") ~= nil

    if is_hard_unreachable then
        M.tripCircuitBreaker(err)
        return
    end

    if is_timeout then
        if type(opts) == "table" and opts.is_thumbnail then
            return
        end
        M._timeout_failures = (M._timeout_failures or 0) + 1
        if M._timeout_failures >= (M.TIMEOUT_FAILURE_THRESHOLD or 3) then
            M.tripCircuitBreaker(err)
        end
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

function M.patchNetworkMgrOnline()
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if not (ok_net and NetworkMgr) or NetworkMgr._bridge_is_online_patched then
        return
    end
    NetworkMgr._bridge_is_online_patched = true
    NetworkMgr.isOnline = function(self_nm)
        if self_nm and self_nm.isConnected then
            return self_nm:isConnected()
        end
        return true
    end
    logger.info("[Bridge Health] Patched NetworkMgr:isOnline() to use fast local isConnected()")
end

function M.isServerReachable(url, force_probe)
    -- 1. Check if device has any network connection (avoid blocking DNS in NetworkMgr:isOnline)
    -- Never call NetworkMgr/JNI in a forked subprocess (Android ART aborts on AttachCurrentThread).
    if not M.isInSubprocess() then
        local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_net and NetworkMgr then
            if NetworkMgr.isConnected then
                if not NetworkMgr:isConnected() then
                    logger.info("[Bridge Health] isServerReachable=false: NetworkMgr:isConnected() is false")
                    return false, "Network offline"
                end
            elseif NetworkMgr.isOnline and not NetworkMgr:isOnline() then
                logger.info("[Bridge Health] isServerReachable=false: NetworkMgr:isOnline() is false")
                return false, "Network offline"
            end
        end
    end

    -- 2. Check if circuit breaker is tripped
    if not force_probe then
        local is_active, reason = M.isCircuitBreakerActive()
        if is_active then
            logger.info("[Bridge Health] isServerReachable=false: circuit breaker active (" .. tostring(reason) .. ")")
            return false, "Circuit breaker active: " .. tostring(reason)
        end
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

    local target_ip = M.getCachedIp(host)
    if not target_ip and not M.isInSubprocess() then
        -- Avoid synchronous gethostbyname on the main LuaJIT thread.
        -- Trigger an asynchronous curl probe in the background and return cached reachability.
        local ok_ah, AsyncHttp = pcall(require, "lib/bridge_async_http")
        if ok_ah and AsyncHttp and AsyncHttp.isAvailable and AsyncHttp.isAvailable() then
            if not M._async_probe_in_flight then
                M._async_probe_in_flight = true
                local probe_url = url:gsub("/+$", "") .. "/api/v1/books?size=1"
                AsyncHttp.requestAsync({
                    url = probe_url,
                    method = "HEAD",
                    connect_timeout = 1,
                    max_time = 2,
                    skip_health = true,
                }, function(ok, code, _, err_msg)
                    M._async_probe_in_flight = false
                    M._last_checked_at = os.time()
                    local num_code = tonumber(code) or 0
                    if ok or (num_code >= 200 and num_code < 500) then
                        M.reportSuccess()
                    else
                        M.tripCircuitBreaker(err_msg or "Async probe failed")
                    end
                end)
            end
            return M._is_reachable, M._is_reachable and nil or "Server unreachable (cached)"
        end
        -- If curl is unavailable, avoid blocking main thread with raw hostname connect
        M._last_checked_at = now
        return M._is_reachable
    end

    local probe_ok = false
    local probe_err = nil

    local ok_sock, socket = pcall(require, "socket")
    if ok_sock and socket and socket.tcp then
        local ok_call, s = pcall(socket.tcp)
        if ok_call and s then
            pcall(s.settimeout, s, M.PROBE_TIMEOUT or 0.25)
            local res, err = s:connect(target_ip or host, port)
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
        M.reportSuccess()
        return true
    else
        M.tripCircuitBreaker(probe_err or "Probe failed")
        return false, probe_err or "Server probe failed"
    end
end

return M
