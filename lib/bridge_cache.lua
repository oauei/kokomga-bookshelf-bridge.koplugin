-- lib/bridge_cache.lua
-- Aliases cover cache lookups across network profiles so covers aren't redownloaded when roaming.

local logger = require("logger")

local M = {}

local function isValidId(id)
    if type(id) ~= "string" and type(id) ~= "number" then return false end
    local s = tostring(id)
    return s ~= "" and #s <= 128 and s:match("^[%w%-_]+$") ~= nil
end

local function patchPrefetchTarget(cache_tbl)
    if not (cache_tbl and type(cache_tbl) == "table" and type(cache_tbl.prefetchCovers) == "function") then
        return
    end
    if cache_tbl._bridge_prefetch_patched then return end
    cache_tbl._bridge_prefetch_patched = true

    local orig_prefetch = cache_tbl.prefetchCovers
    cache_tbl.prefetchCovers = function(self_c, item_list, type_label)
        if not item_list or #item_list == 0 then return end
        if type_label ~= "series" and type_label ~= "book" then
            logger.warn("[Bridge Cache] prefetchCovers rejected invalid type_label: " .. tostring(type_label))
            return
        end

        local ok_ah, AsyncHttp = pcall(require, "lib/bridge_async_http")
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if not (ok_ah and AsyncHttp and AsyncHttp.isAvailable and AsyncHttp.isAvailable()
                and ok_ui and UIManager and UIManager.scheduleIn) then
            return orig_prefetch(self_c, item_list, type_label)
        end

        local ok_h, Health = pcall(require, "lib/bridge_health")
        if ok_h and Health and Health.isCircuitBreakerActive and Health.isCircuitBreakerActive() then
            return
        end

        pcall(self_c.ensureStructure, self_c)
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if not (ok_ds and DataStorage) then
            return orig_prefetch(self_c, item_list, type_label)
        end

        local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
        local meta_cache = self_c.plugin and self_c.plugin.settings and self_c.plugin.settings.library_metadata_cache
        local covers_map = meta_cache and meta_cache.covers or {}
        local never_update = self_c.plugin and self_c.plugin.settings and self_c.plugin.settings.never_update_covers

        local to_download = {}
        for _, item in ipairs(item_list) do
            if item and isValidId(item.id) then
                local id_str = tostring(item.id)
                local cache_key = type_label .. "_" .. id_str
                local local_path = covers_dir .. "/" .. cache_key .. ".jpg"
                local f = io.open(local_path, "rb")
                local exists = (f ~= nil)
                if f then f:close() end
                local needs_dl = not exists or (not never_update and covers_map[cache_key] ~= item.lastModified)
                if needs_dl then
                    to_download[#to_download + 1] = {
                        id = id_str,
                        lastModified = item.lastModified,
                        cache_key = cache_key,
                        dest_path = local_path,
                    }
                end
            end
        end

        if #to_download == 0 then return end

        local api = self_c.plugin and self_c.plugin.api
        local base_url = api and api.base_url
        if not base_url or base_url == "" then
            return orig_prefetch(self_c, item_list, type_label)
        end

        local endpoint_type = (type_label == "series") and "series" or "books"
        local headers = {}
        if api.get_headers then
            local ok_hdr, h = pcall(api.get_headers, api)
            if ok_hdr and type(h) == "table" then
                for k, v in pairs(h) do headers[k] = v end
            end
        end

        logger.info(string.format("[Bridge Cache] Async pre-fetching %d covers for %s", #to_download, tostring(type_label)))

        local idx = 1
        local dirty = false
        local function flushSettings()
            if dirty and self_c.plugin and self_c.plugin.saveSettings then
                dirty = false
                pcall(self_c.plugin.saveSettings, self_c.plugin)
            end
        end

        local function stepNext()
            if idx > #to_download then
                flushSettings()
                return
            end
            local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
            if ok_net and NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
                flushSettings()
                return
            end
            if ok_h and Health and Health.isCircuitBreakerActive and Health.isCircuitBreakerActive() then
                flushSettings()
                return
            end
            local entry = to_download[idx]
            idx = idx + 1
            local url = tostring(base_url):gsub("/+$", "") .. "/api/v1/" .. endpoint_type .. "/" .. entry.id .. "/thumbnail"
            AsyncHttp.downloadAsync({
                url = url,
                headers = headers,
                tmp_path = entry.dest_path .. ".tmp",
                dest_path = entry.dest_path,
                connect_timeout = 2,
                max_time = 8,
                is_thumbnail = true,
                skip_health = true,
            }, function(ok, code, _, err_msg)
                if ok and meta_cache and meta_cache.covers then
                    meta_cache.covers[entry.cache_key] = entry.lastModified
                    dirty = true
                elseif not ok then
                    logger.warn(string.format("[Bridge Cache] cover prefetch failed for %s: code=%s err=%s",
                        entry.cache_key, tostring(code), tostring(err_msg)))
                end
                if idx <= #to_download then
                    UIManager:scheduleIn(0.15, stepNext)
                else
                    flushSettings()
                end
            end)
        end

        UIManager:scheduleIn(0.1, stepNext)
    end

    logger.info("[Bridge Cache] Patched KomgaCache.prefetchCovers to run asynchronously")
end

local function installPrefetchHook()
    pcall(require, "plugins/kokomga.koplugin/core/cache")
    pcall(require, "core/cache")
    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("core/cache") and type(v) == "table" then
            patchPrefetchTarget(v)
            patchPrefetchTarget(getmetatable(v))
        end
    end
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local komga = loaded and loaded["kokomga"]
    if komga and komga.cache then
        patchPrefetchTarget(komga.cache)
        patchPrefetchTarget(getmetatable(komga.cache))
    end
end

local _aliased_cover_cache = {}

function M.clearAliasedCoverCache()
    _aliased_cover_cache = {}
end

function M.installCacheHook(profiles_mod)
    if M._installed then return end

    installPrefetchHook()

    local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
    if not (ok_c and OpdsCovers and OpdsCovers.cachedPath) then
        return
    end
    M._installed = true

    local orig_cachedPath = OpdsCovers.cachedPath
    OpdsCovers.cachedPath = function(rec)
        local path = orig_cachedPath(rec)
        if path then return path end

        local rec_url = rec and rec.opds and (rec.opds.cover_url or rec.opds.thumbnail_url)
        if not rec_url or type(rec_url) ~= "string" then return nil end

        local cached_alias = _aliased_cover_cache[rec_url]
        if cached_alias ~= nil then
            return cached_alias or nil
        end

        -- If not found under current profile, check candidate hashes from other profiles
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not (ok_lfs and lfs and profiles_mod and profiles_mod.getAllKomgaServerKeys) then
            _aliased_cover_cache[rec_url] = false
            return nil
        end

        local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
        if not (ok_s and OpdsSource and OpdsSource.serverKey) then
            _aliased_cover_cache[rec_url] = false
            return nil
        end

        local base_dir = OpdsCovers.cacheDir and OpdsCovers.cacheDir()
        if not base_dir then
            _aliased_cover_cache[rec_url] = false
            return nil
        end

        local all_keys = profiles_mod.getAllKomgaServerKeys()
        local url_hash = OpdsSource.serverKey(rec_url)

        -- 1. Check same url_hash under other server keys
        for _, sk in ipairs(all_keys) do
            local candidate = base_dir .. "/" .. sk .. "/" .. url_hash .. ".img"
            local ok_a, a = pcall(lfs.attributes, candidate)
            if ok_a and a and a.mode == "file" then
                _aliased_cover_cache[rec_url] = candidate
                return candidate
            end
        end

        -- 2. Check alternative base URLs from profiles (linear scan, no N^2 nesting)
        local rel_path = rec_url:match("^https?://[^/]+(/.+)$")
        if rel_path then
            local profiles = profiles_mod.getProfiles and profiles_mod.getProfiles() or {}
            for _, p in ipairs(profiles) do
                if p.base_url and p.base_url ~= "" then
                    local pb = profiles_mod.normalizeBaseUrl(p.base_url)
                    local alt_url = pb .. rel_path
                    if alt_url ~= rec_url then
                        local alt_hash = OpdsSource.serverKey(alt_url)
                        for _, sk in ipairs(all_keys) do
                            local candidate = base_dir .. "/" .. sk .. "/" .. alt_hash .. ".img"
                            local ok_a, a = pcall(lfs.attributes, candidate)
                            if ok_a and a and a.mode == "file" then
                                _aliased_cover_cache[rec_url] = candidate
                                return candidate
                            end
                        end
                    end
                end
            end
        end

        _aliased_cover_cache[rec_url] = false
        return nil
    end

    logger.info("[Bridge] Hooked Bookshelf OpdsCovers.cachedPath for cross-profile cover aliasing")
end

return M
