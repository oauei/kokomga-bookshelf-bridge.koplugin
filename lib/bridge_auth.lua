-- lib/bridge_auth.lua
-- Intercepts HTTP/HTTPS requests to inject Komga authentication headers.

local logger = require("logger")

local M = {}

function M.getKomgaPlugin()
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    return loaded and loaded["kokomga"] or nil
end

local _komga_origins = nil
local _komga_origins_time = 0
local ORIGINS_TTL = 30

local function getKomgaOrigins(profiles_mod)
    local now = os.time()
    if _komga_origins and (now - _komga_origins_time < ORIGINS_TTL) then
        return _komga_origins
    end

    local origins = {}
    local komga = M.getKomgaPlugin()
    local komga_url = komga and komga.settings and komga.settings.server_url
    if type(komga_url) == "string" and komga_url ~= "" then
        local origin = komga_url:match("^(https?://[^/]+)")
        if origin then origins[origin:lower()] = true end
    end

    if profiles_mod and profiles_mod.getProfiles then
        local profiles = profiles_mod.getProfiles()
        if type(profiles) == "table" then
            for _, p in ipairs(profiles) do
                if type(p.base_url) == "string" and p.base_url ~= "" then
                    local p_origin = p.base_url:match("^(https?://[^/]+)")
                    if p_origin then origins[p_origin:lower()] = true end
                end
            end
        end
    end

    _komga_origins = origins
    _komga_origins_time = now
    return origins
end

function M.invalidateOrigins()
    _komga_origins = nil
    _komga_origins_time = 0
end

function M.isKomgaUrl(url, profiles_mod)
    if type(url) ~= "string" or url == "" then return false end

    -- 1. Fast O(1) origin lookup
    local origin = url:match("^(https?://[^/]+)")
    if origin then
        local origins = getKomgaOrigins(profiles_mod)
        if origins[origin:lower()] then
            return true
        end
    end

    -- 2. Fallback check for relative or standard Komga path segments
    local u_lower = url:lower()
    if u_lower:find("/opds/v1.2/", 1, true) or u_lower:find("/api/v1/", 1, true) or u_lower:find("/api/v2/", 1, true) then
        return true
    end

    return false
end

function M.getAuthHeaders(url, profiles_mod)
    if not M.isKomgaUrl(url, profiles_mod) then return nil end
    local komga = M.getKomgaPlugin()
    if not (komga and komga.settings) then return nil end

    local api_key = komga.settings.api_key
    local auth_header = komga.settings.auth_header
    local has_api_key = type(api_key) == "string" and api_key ~= ""
    local has_auth_header = type(auth_header) == "string" and auth_header ~= ""
    if not (has_api_key or has_auth_header) then return nil end

    local headers = {}
    if has_api_key then
        headers["X-API-Key"] = api_key
    elseif has_auth_header then
        headers["Authorization"] = auth_header
    end
    return headers
end

function M.installInterceptor(profiles_mod)
    if M._installed then return end
    M._installed = true

    local Health = require("lib/bridge_health")

    local function wrapRequest(orig_fn, mod_tbl)
        return function(reqt, ...)
            if type(reqt) == "table" and reqt.url then
                if not Health.isInSubprocess() then
                    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
                    if ok_net and NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
                        return nil, "Network offline"
                    end
                end

                if M.isKomgaUrl(reqt.url, profiles_mod) then
                    local active, reason = Health.isCircuitBreakerActive()
                    if active then
                        logger.info("[Bridge Auth] Fast-failing Komga request (circuit breaker active): " .. tostring(reason))
                        return nil, "Komga server unreachable (circuit breaker active)"
                    end

                    local extra = M.getAuthHeaders(reqt.url, profiles_mod)
                    if extra then
                        reqt.headers = reqt.headers or {}
                        for k, v in pairs(extra) do
                            if not reqt.headers[k] then
                                reqt.headers[k] = v
                            end
                        end
                    end

                    local is_main = not Health.isInSubprocess()
                    local ok_su, socketutil = pcall(require, "socketutil")
                    local max_t = Health.MAIN_THREAD_MAX_TIMEOUT or 1.5
                    if is_main then
                        if reqt.timeout and reqt.timeout > max_t then
                            reqt.timeout = max_t
                        end
                        if ok_su and socketutil and socketutil.set_timeout then
                            pcall(socketutil.set_timeout, socketutil, max_t, max_t)
                        else
                            mod_tbl.TIMEOUT = max_t
                        end
                    end

                    local res, code, headers, status = orig_fn(reqt, ...)

                    if is_main and ok_su and socketutil and socketutil.reset_timeout then
                        pcall(function() socketutil:reset_timeout() end)
                    end

                    local num_code = tonumber(code)
                    if res or (num_code and num_code >= 200 and num_code < 500) then
                        Health.reportSuccess()
                    else
                        local is_thumb = reqt.url:find("/thumbnail", 1, true) ~= nil
                        Health.reportFailure(code or status or "Network error", { is_thumbnail = is_thumb })
                    end

                    return res, code, headers, status
                end
            end
            return orig_fn(reqt, ...)
        end
    end

    -- 1. Hook socket.http
    local ok_http, http = pcall(require, "socket.http")
    if ok_http and http and http.request then
        http.request = wrapRequest(http.request, http)
        logger.info("[Bridge] Hooked socket.http.request for Komga authentication and ANR protection")
    end

    -- 2. Hook ssl.https
    local ok_https, https = pcall(require, "ssl.https")
    if ok_https and https and https.request then
        https.request = wrapRequest(https.request, https)
        logger.info("[Bridge] Hooked ssl.https.request for Komga authentication and ANR protection")
    end
end

return M
