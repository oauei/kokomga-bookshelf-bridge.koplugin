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

    -- 1. Hook socket.http
    local ok_http, http = pcall(require, "socket.http")
    if ok_http and http and http.request then
        local orig_http = http.request
        http.request = function(reqt, ...)
            if type(reqt) == "table" and reqt.url and M.isKomgaUrl(reqt.url, profiles_mod) then
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
                if is_main then
                    if reqt.timeout and reqt.timeout > Health.MAIN_THREAD_MAX_TIMEOUT then
                        reqt.timeout = Health.MAIN_THREAD_MAX_TIMEOUT
                    end
                    if ok_su and socketutil and socketutil.set_timeout then
                        pcall(socketutil.set_timeout, socketutil, 1.0, Health.MAIN_THREAD_MAX_TIMEOUT)
                    else
                        http.TIMEOUT = 1.0
                    end
                end

                local res, code, headers, status = orig_http(reqt, ...)

                if is_main and ok_su and socketutil and socketutil.reset_timeout then
                    pcall(function() socketutil:reset_timeout() end)
                end

                local num_code = tonumber(code)
                if res or (num_code and num_code >= 200 and num_code < 500) then
                    Health.reportSuccess()
                else
                    Health.reportFailure(code or status or "Network error")
                end

                return res, code, headers, status
            end
            return orig_http(reqt, ...)
        end
        logger.info("[Bridge] Hooked socket.http.request for Komga authentication and ANR protection")
    end

    -- 2. Hook ssl.https
    local ok_https, https = pcall(require, "ssl.https")
    if ok_https and https and https.request then
        local orig_https = https.request
        https.request = function(reqt, ...)
            if type(reqt) == "table" and reqt.url and M.isKomgaUrl(reqt.url, profiles_mod) then
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
                if is_main then
                    if reqt.timeout and reqt.timeout > Health.MAIN_THREAD_MAX_TIMEOUT then
                        reqt.timeout = Health.MAIN_THREAD_MAX_TIMEOUT
                    end
                    if ok_su and socketutil and socketutil.set_timeout then
                        pcall(socketutil.set_timeout, socketutil, 1.0, Health.MAIN_THREAD_MAX_TIMEOUT)
                    else
                        https.TIMEOUT = 1.0
                    end
                end

                local res, code, headers, status = orig_https(reqt, ...)

                if is_main and ok_su and socketutil and socketutil.reset_timeout then
                    pcall(function() socketutil:reset_timeout() end)
                end

                local num_code = tonumber(code)
                if res or (num_code and num_code >= 200 and num_code < 500) then
                    Health.reportSuccess()
                else
                    Health.reportFailure(code or status or "Network error")
                end

                return res, code, headers, status
            end
            return orig_https(reqt, ...)
        end
        logger.info("[Bridge] Hooked ssl.https.request for Komga authentication and ANR protection")
    end
end

return M
