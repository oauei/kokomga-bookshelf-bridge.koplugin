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
local _cached_auth_headers = nil
local _cached_auth_key = nil
local ORIGINS_TTL = 30

local function extractOrigin(url)
    if type(url) ~= "string" then return nil end
    local scheme, hostport = url:match("^([%a][%w+.-]*)://([^/?#]+)")
    if not (scheme and hostport) then return nil end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    return scheme .. "://" .. hostport:lower()
end

local function sanitizeHeaderValue(val)
    return tostring(val or ""):gsub("[%z\r\n]+", "")
end

local function shallowCopy(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

local function getKomgaOrigins(profiles_mod)
    local now = os.time()
    if _komga_origins and (now - _komga_origins_time < ORIGINS_TTL) then
        return _komga_origins
    end

    local origins = {}
    local komga = M.getKomgaPlugin()
    local komga_url = komga and komga.settings and komga.settings.server_url
    local origin = extractOrigin(komga_url)
    if origin then origins[origin] = true end

    if profiles_mod and profiles_mod.getProfiles then
        local profiles = profiles_mod.getProfiles()
        if type(profiles) == "table" then
            for _, p in ipairs(profiles) do
                local p_origin = extractOrigin(p and p.base_url)
                if p_origin then origins[p_origin] = true end
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
    _cached_auth_headers = nil
    _cached_auth_key = nil
end

function M.isKomgaUrl(url, profiles_mod)
    if type(url) ~= "string" or url == "" then return false end

    -- 1. Fast O(1) origin lookup (case-insensitive scheme and host)
    local origin = extractOrigin(url)
    if origin then
        local origins = getKomgaOrigins(profiles_mod)
        return origins[origin] == true
    end

    -- 2. Fallback check for relative Komga path segments (ONLY when origin is nil)
    local u_lower = url:lower()
    if u_lower:find("^/opds/v1%.2/") or u_lower:find("^/api/v1/") or u_lower:find("^/api/v2/") then
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

    local auth_key = tostring(api_key or "") .. "\0" .. tostring(auth_header or "")
    if _cached_auth_headers and _cached_auth_key == auth_key then
        return shallowCopy(_cached_auth_headers)
    end

    local headers = {}
    if has_api_key then
        headers["X-API-Key"] = sanitizeHeaderValue(api_key)
    elseif has_auth_header then
        headers["Authorization"] = sanitizeHeaderValue(auth_header)
    end
    _cached_auth_headers = headers
    _cached_auth_key = auth_key
    return shallowCopy(headers)
end

function M.installInterceptor(profiles_mod)
    if M._installed then return end
    M._installed = true

    local Health = require("lib/bridge_health")

    local function wrapRequest(orig_fn, mod_tbl)
        return function(reqt, ...)
            local url_str = (type(reqt) == "table" and reqt.url) or (type(reqt) == "string" and reqt) or nil
            if url_str then
                if not Health.isInSubprocess() then
                    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
                    if ok_net and NetworkMgr then
                        if NetworkMgr.isConnected then
                            if not NetworkMgr:isConnected() then
                                return nil, "Network offline"
                            end
                        elseif NetworkMgr.isOnline and not NetworkMgr:isOnline() then
                            return nil, "Network offline"
                        end
                    end
                end

                if M.isKomgaUrl(url_str, profiles_mod) then
                    local active, reason = Health.isCircuitBreakerActive()
                    if active then
                        logger.info("[Bridge Auth] Fast-failing Komga request (circuit breaker active): " .. tostring(reason))
                        return nil, "Komga server unreachable (circuit breaker active)"
                    end

                    if type(reqt) == "table" then
                        local extra = M.getAuthHeaders(url_str, profiles_mod)
                        if extra then
                            reqt.headers = shallowCopy(reqt.headers)
                            local lower_present = {}
                            for k in pairs(reqt.headers) do lower_present[tostring(k):lower()] = true end
                            for k, v in pairs(extra) do
                                if not lower_present[k:lower()] then
                                    reqt.headers[k] = v
                                end
                            end
                            -- Prevent LuaSocket from auto-forwarding auth headers across redirects
                            reqt.redirect = false
                        end
                    end

                    local is_main = not Health.isInSubprocess()
                    local ok_su, socketutil = pcall(require, "socketutil")
                    local max_t = Health.MAIN_THREAD_MAX_TIMEOUT or 1.5
                    local saved_mod_timeout = mod_tbl and mod_tbl.TIMEOUT
                    local used_mod_timeout = false
                    if is_main then
                        if type(reqt) == "table" and reqt.timeout and reqt.timeout > max_t then
                            reqt.timeout = max_t
                        end
                        if ok_su and socketutil and socketutil.set_timeout then
                            pcall(socketutil.set_timeout, socketutil, max_t, max_t)
                        elseif mod_tbl then
                            mod_tbl.TIMEOUT = max_t
                            used_mod_timeout = true
                        end
                    end

                    local ok_call, res, code, headers, status = pcall(orig_fn, reqt, ...)

                    if is_main then
                        if ok_su and socketutil and socketutil.reset_timeout then
                            pcall(function() socketutil:reset_timeout() end)
                        elseif used_mod_timeout and mod_tbl then
                            mod_tbl.TIMEOUT = saved_mod_timeout
                        end
                    end

                    if not ok_call then
                        local is_thumb = url_str:find("/thumbnail", 1, true) ~= nil
                        Health.reportFailure(res or "Request exception", { is_thumbnail = is_thumb })
                        error(res, 0)
                    end

                    local num_code = tonumber(code)
                    if num_code and num_code >= 200 and num_code < 500 and num_code ~= 408 then
                        Health.reportSuccess()
                    else
                        local is_thumb = url_str:find("/thumbnail", 1, true) ~= nil
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
