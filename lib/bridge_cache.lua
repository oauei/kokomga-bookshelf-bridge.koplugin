-- lib/bridge_cache.lua
-- Aliases cover cache lookups across network profiles so covers aren't redownloaded when roaming.

local logger = require("logger")

local M = {}

function M.installCacheHook(profiles_mod)
    if M._installed then return end
    M._installed = true

    local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
    if not (ok_c and OpdsCovers and OpdsCovers.cachedPath) then
        return
    end

    local orig_cachedPath = OpdsCovers.cachedPath
    OpdsCovers.cachedPath = function(rec)
        local path = orig_cachedPath(rec)
        if path then return path end

        -- If not found under current profile, check candidate hashes from other profiles
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not (ok_lfs and lfs and profiles_mod and profiles_mod.getAllKomgaServerKeys) then
            return nil
        end

        local rec_url = rec and rec.opds and (rec.opds.cover_url or rec.opds.thumbnail_url)
        if not rec_url or type(rec_url) ~= "string" then return nil end

        local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
        if not (ok_s and OpdsSource and OpdsSource.serverKey) then return nil end

        local base_dir = OpdsCovers.cacheDir and OpdsCovers.cacheDir()
        if not base_dir then return nil end

        local all_keys = profiles_mod.getAllKomgaServerKeys()
        local url_hash = OpdsSource.serverKey(rec_url)

        -- 1. Check same url_hash under other server keys
        for _, sk in ipairs(all_keys) do
            local candidate = base_dir .. "/" .. sk .. "/" .. url_hash .. ".img"
            local ok_a, a = pcall(lfs.attributes, candidate)
            if ok_a and a and a.mode == "file" then
                return candidate
            end
        end

        -- 2. Check alternative base URLs from profiles
        local profiles = profiles_mod.getProfiles and profiles_mod.getProfiles() or {}
        for _, p1 in ipairs(profiles) do
            if p1.base_url and p1.base_url ~= "" then
                local pb1 = profiles_mod.normalizeBaseUrl(p1.base_url)
                for _, p2 in ipairs(profiles) do
                    if p2.base_url and p2.base_url ~= "" and p2.base_url ~= p1.base_url then
                        local pb2 = profiles_mod.normalizeBaseUrl(p2.base_url)
                        if rec_url:find(pb2, 1, true) then
                            local alt_url = rec_url:gsub(pb2, pb1)
                            local alt_hash = OpdsSource.serverKey(alt_url)
                            for _, sk in ipairs(all_keys) do
                                local candidate = base_dir .. "/" .. sk .. "/" .. alt_hash .. ".img"
                                local ok_a, a = pcall(lfs.attributes, candidate)
                                if ok_a and a and a.mode == "file" then
                                    return candidate
                                end
                            end
                        end
                    end
                end
            end
        end

        return nil
    end

    logger.info("[Bridge] Hooked Bookshelf OpdsCovers.cachedPath for cross-profile cover aliasing")
end

return M
