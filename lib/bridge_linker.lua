-- lib/bridge_linker.lua
-- Links downloaded/matched local books to their OPDS server entries in Bookshelf and Kokomga.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local _ = require("gettext")

local M = {}

local MAX_CUSTOM_META_BYTES = 65536

local function validateKomgaId(id)
    if type(id) == "number" then
        id = tostring(id)
    end
    if type(id) == "string" and #id > 0 and #id <= 128 and id:match("^[%w%-_]+$") then
        return id
    end
    return nil
end

local function getKomgaPlugin()
    local ok_mp, MenuPatch = pcall(require, "lib/bridge_menu_patch")
    if ok_mp and type(MenuPatch) == "table" and type(MenuPatch.getKomgaPlugin) == "function" then
        local ok_k, k = pcall(MenuPatch.getKomgaPlugin)
        if ok_k and type(k) == "table" then
            return k
        end
    end
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local p = loaded and loaded["kokomga"] or nil
    return type(p) == "table" and p or nil
end

local function loadCustomMetadata(fp)
    if type(fp) ~= "string" or fp == "" then return nil end
    local sdr1 = fp:gsub("%.%w+$", "") .. ".sdr/custom_metadata.lua"
    local sdr2 = fp .. ".sdr/custom_metadata.lua"
    for _, spath in ipairs({ sdr1, sdr2 }) do
        local f = io.open(spath, "r")
        if f then
            local size = f:seek("end")
            f:close()
            if size and size > 0 and size <= MAX_CUSTOM_META_BYTES then
                local env = {}
                local func, load_err = loadfile(spath, "t", env)
                if func then
                    if setfenv then
                        pcall(setfenv, func, env)
                    end
                    local ok, data = pcall(func)
                    if ok and type(data) == "table" then
                        local id = data.komga_book_id or data.komga_id
                        if not id and type(data.custom_props) == "table" then
                            id = data.custom_props.komga_book_id or data.custom_props.komga_id
                        end
                        if not id and type(data.doc_props) == "table" then
                            id = data.doc_props.komga_book_id or data.doc_props.komga_id
                        end
                        local valid_id = validateKomgaId(id)
                        if valid_id then
                            return valid_id
                        end
                    end
                else
                    logger.dbg("[Bridge Linker] Rejected custom_metadata.lua:", tostring(load_err))
                end
            end
        end
    end
    return nil
end

local function loadDocSettingsMetadata(fp)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings then
        local ds
        if DocSettings.openSettingsFile then
            local ok, res = pcall(DocSettings.openSettingsFile, DocSettings, fp)
            if ok and res then ds = res end
        end
        if not ds and DocSettings.open then
            local ok, res = pcall(DocSettings.open, DocSettings, fp)
            if ok and res then ds = res end
        end
        if ds and ds.readSetting then
            local id = ds:readSetting("komga_book_id") or ds:readSetting("komga_id")
            if not id then
                local cp = ds:readSetting("custom_props")
                if type(cp) == "table" then
                    id = cp.komga_book_id or cp.komga_id
                end
            end
            if not id then
                local dp = ds:readSetting("doc_props")
                if type(dp) == "table" then
                    id = dp.komga_book_id or dp.komga_id
                end
            end
            local valid_id = validateKomgaId(id)
            if valid_id then
                return valid_id
            end
        end
    end
    return nil
end

function M.collectKomgaBooks()
    local komga = getKomgaPlugin()
    local books = {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    local function isFile(p)
        if type(p) ~= "string" or p == "" then return false end
        if not ok_lfs or not lfs or not lfs.attributes then return false end
        local ok, attr = pcall(lfs.attributes, p, "mode")
        return ok and attr == "file"
    end

    -- 1. Check kokomga.settings.matched_books_cache
    if komga and type(komga.settings) == "table" and type(komga.settings.matched_books_cache) == "table" then
        for fp, id in pairs(komga.settings.matched_books_cache) do
            local valid_id = validateKomgaId(id)
            if type(fp) == "string" and valid_id then
                if isFile(fp) then
                    books[fp] = valid_id
                end
            end
        end
    end

    -- 2. Check Bookshelf library filepaths for .sdr metadata (strictly scoped to Komga download dir)
    local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
    if ok_r and Repo and Repo.getAllFilepaths and komga and type(komga.getDownloadDir) == "function" then
        local ok_dl, komga_dl = pcall(komga.getDownloadDir, komga)
        local stripped = (ok_dl and type(komga_dl) == "string") and komga_dl:gsub("/+$", "") or nil
        local dl_prefix = (stripped and #stripped > 1) and (stripped .. "/") or nil
        if dl_prefix then
            local ok_fps, filepaths = pcall(Repo.getAllFilepaths)
            filepaths = (ok_fps and type(filepaths) == "table") and filepaths or {}
            for _, fp in ipairs(filepaths) do
                if type(fp) == "string" and not books[fp] and fp:sub(1, #dl_prefix) == dl_prefix and isFile(fp) then
                    local meta_id = loadDocSettingsMetadata(fp) or loadCustomMetadata(fp)
                    if meta_id then
                        books[fp] = meta_id
                        if type(komga.settings) == "table" and type(komga.settings.matched_books_cache) == "table" then
                            komga.settings.matched_books_cache[fp] = meta_id
                        end
                    end
                end
            end
        end
    end

    return books
end

function M.executeLink(server)
    if type(server) ~= "table" or type(server.key) ~= "string" or server.key == "" then return end
    local komga = getKomgaPlugin()
    if not komga then
        UIManager:show(Notification:new{ text = _("kokomga plugin is not loaded.") })
        return
    end

    local server_key = server.key
    local books = M.collectKomgaBooks()

    local to_link = {}
    for fp, id in pairs(books) do
        local valid_id = validateKomgaId(id)
        if valid_id then
            to_link[#to_link + 1] = { path = fp, id = valid_id }
        end
    end

    if #to_link == 0 then
        UIManager:show(Notification:new{ text = _("No Komga books found to link.") })
        return
    end

    -- 1. Update kokomga settings
    if type(komga.settings) ~= "table" then
        komga.settings = {}
    end
    komga.settings.opds_book_sources = komga.settings.opds_book_sources or {}
    for _, item in ipairs(to_link) do
        komga.settings.opds_book_sources[item.id] = server_key
    end
    if type(komga.saveSettings) == "function" then
        pcall(komga.saveSettings, komga)
    end

    -- 2. Update kokomga_opds_downloads.lua
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if ok_ls and LuaSettings and type(komga.getOpdsDownloadsPath) == "function" then
        local ok_p, dl_path = pcall(komga.getOpdsDownloadsPath, komga)
        if ok_p and type(dl_path) == "string" and dl_path ~= "" then
            local ok_f, kokomga_dl = pcall(LuaSettings.open, LuaSettings, dl_path)
            if ok_f and kokomga_dl then
                local downloads = kokomga_dl:readSetting("downloads")
                if type(downloads) ~= "table" then downloads = {} end
                for _, item in ipairs(to_link) do
                    local opds_path = "OPDS://" .. server_key .. "/" .. item.id
                    downloads[opds_path] = item.path
                end
                kokomga_dl:saveSetting("downloads", downloads)
                kokomga_dl:flush()
            end
        end
    end

    -- 3. Update Bookshelf settings store
    local newly_linked = 0
    local ok_bs, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
    if ok_bs and BookshelfSettings and BookshelfSettings.read then
        local ok_dl, OpdsDownload = pcall(require, "lib/bookshelf_opds_download")
        local dl_key = (ok_dl and type(OpdsDownload) == "table" and OpdsDownload.STORE_KEY) or "opds_downloads"
        local map = BookshelfSettings.read(dl_key)
        if type(map) ~= "table" then map = {} end
        for _, item in ipairs(to_link) do
            local opds_path = "OPDS://" .. server_key .. "/" .. item.id
            if not map[opds_path] then
                newly_linked = newly_linked + 1
            end
            map[opds_path] = item.path
        end
        BookshelfSettings.save(dl_key, map)
        if BookshelfSettings.flush then BookshelfSettings.flush() end
    end

    -- 4. Invalidate Bookshelf caches
    local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
    if ok_r and Repo then
        if Repo.invalidateBookCache then Repo.invalidateBookCache("komga_link") end
        if Repo.invalidateWalkCache then Repo.invalidateWalkCache() end
        if Repo.invalidateLightMeta then Repo.invalidateLightMeta() end
    end

    -- 5. Rebuild live widget if open
    local ok_bw, BookshelfWidget = pcall(require, "lib/bookshelf_widget")
    if ok_bw and BookshelfWidget and BookshelfWidget.live then
        pcall(function()
            if BookshelfWidget.live._rebuild then BookshelfWidget.live:_rebuild() end
            UIManager:setDirty(BookshelfWidget.live, "ui")
        end)
    end

    local server_title = server.title or server.url or server_key
    local msg
    if newly_linked > 0 then
        msg = string.format(_("Linked %d Komga book(s) to OPDS server '%s' (%d total)."),
            newly_linked, tostring(server_title), #to_link)
    else
        msg = string.format(_("All %d Komga book(s) are already linked to OPDS server '%s'."),
            #to_link, tostring(server_title))
    end

    UIManager:show(Notification:new{
        text = msg,
        timeout = 5,
    })
end

function M.linkKomgaBooksPrompt(profiles_mod)
    local komga = getKomgaPlugin()
    if not komga then
        UIManager:show(Notification:new{ text = _("kokomga plugin is not loaded.") })
        return
    end

    if type(profiles_mod) ~= "table" or type(profiles_mod.findServers) ~= "function" then
        UIManager:show(Notification:new{ text = _("No OPDS servers configured in KOReader.") })
        return
    end
    local ok_fs, matched, all_servers = pcall(profiles_mod.findServers)
    if not ok_fs or not all_servers or #all_servers == 0 then
        UIManager:show(Notification:new{ text = _("No OPDS servers configured in KOReader.") })
        return
    end

    if matched and #matched == 1 then
        local s = matched[1]
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Link Komga books to OPDS server:\n\n%s\n(%s)?"), s.title or s.key, s.url or ""),
            ok_text = _("Link"),
            ok_callback = function() M.executeLink(s) end,
        })
        return
    end

    if #all_servers == 1 then
        local s = all_servers[1]
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Link Komga books to OPDS server:\n\n%s\n(%s)?"), s.title or s.key, s.url or ""),
            ok_text = _("Link"),
            ok_callback = function() M.executeLink(s) end,
        })
        return
    end

    local buttons = {}
    local dialog = nil
    local candidate_list = (matched and #matched > 1) and matched or all_servers
    for _, s in ipairs(candidate_list) do
        buttons[#buttons + 1] = {
            {
                text = (s.title or s.key) .. "\n" .. (s.url or ""),
                callback = function()
                    if dialog then UIManager:close(dialog); dialog = nil end
                    M.executeLink(s)
                end,
            }
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                if dialog then UIManager:close(dialog); dialog = nil end
            end,
        }
    }

    dialog = ButtonDialog:new{
        title = _("Select Komga OPDS server"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return M
