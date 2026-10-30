-- lib/bridge_linker.lua
-- Links downloaded/matched local books to their OPDS server entries in Bookshelf and Kokomga.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local _ = require("gettext")

local M = {}

local function getKomgaPlugin()
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    return loaded and loaded["kokomga"] or nil
end

local function loadCustomMetadata(fp)
    local sdr1 = fp:gsub("%.%w+$", "") .. ".sdr/custom_metadata.lua"
    local sdr2 = fp .. ".sdr/custom_metadata.lua"
    for _, spath in ipairs({ sdr1, sdr2 }) do
        local f = io.open(spath, "r")
        if f then
            f:close()
            local func = loadfile(spath)
            if func then
                local ok, data = pcall(func)
                if ok and type(data) == "table" then
                    local id = data.komga_book_id or data.komga_id
                    if not id and type(data.custom_props) == "table" then
                        id = data.custom_props.komga_book_id or data.custom_props.komga_id
                    end
                    if not id and type(data.doc_props) == "table" then
                        id = data.doc_props.komga_book_id or data.doc_props.komga_id
                    end
                    if id and id ~= "" then
                        return tostring(id)
                    end
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
            if id and id ~= "" then
                return tostring(id)
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
        if not ok_lfs or not lfs then return true end
        local ok, attr = pcall(lfs.attributes, p, "mode")
        return ok and attr == "file"
    end

    -- 1. Check kokomga.settings.matched_books_cache
    if komga and komga.settings and type(komga.settings.matched_books_cache) == "table" then
        for fp, id in pairs(komga.settings.matched_books_cache) do
            if type(fp) == "string" and type(id) == "string" and id ~= "" then
                if isFile(fp) then
                    books[fp] = tostring(id)
                end
            end
        end
    end

    -- 2. Check Bookshelf library filepaths for .sdr metadata
    local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
    if ok_r and Repo and Repo.getAllFilepaths then
        local filepaths = Repo.getAllFilepaths() or {}
        for _, fp in ipairs(filepaths) do
            if not books[fp] and isFile(fp) then
                local meta_id = loadDocSettingsMetadata(fp) or loadCustomMetadata(fp)
                if meta_id and meta_id ~= "" then
                    books[fp] = tostring(meta_id)
                    if komga and komga.settings and type(komga.settings.matched_books_cache) == "table" then
                        komga.settings.matched_books_cache[fp] = tostring(meta_id)
                    end
                end
            end
        end
    end

    return books
end

function M.executeLink(server)
    if not server or not server.key then return end
    local komga = getKomgaPlugin()
    if not komga then
        UIManager:show(Notification:new{ text = _("kokomga plugin is not loaded.") })
        return
    end

    local server_key = server.key
    local books = M.collectKomgaBooks()

    local to_link = {}
    for fp, id in pairs(books) do
        to_link[#to_link + 1] = { path = fp, id = id }
    end

    if #to_link == 0 then
        UIManager:show(Notification:new{ text = _("No Komga books found to link.") })
        return
    end

    -- 1. Update kokomga settings
    komga.settings.opds_book_sources = komga.settings.opds_book_sources or {}
    for _, item in ipairs(to_link) do
        komga.settings.opds_book_sources[tostring(item.id)] = server_key
    end
    if komga.saveSettings then komga:saveSettings() end

    -- 2. Update kokomga_opds_downloads.lua
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if ok_ls and LuaSettings and komga.getOpdsDownloadsPath then
        local ok_f, kokomga_dl = pcall(LuaSettings.open, LuaSettings, komga:getOpdsDownloadsPath())
        if ok_f and kokomga_dl then
            local downloads = kokomga_dl:readSetting("downloads")
            if type(downloads) ~= "table" then downloads = {} end
            for _, item in ipairs(to_link) do
                local opds_path = "OPDS://" .. server_key .. "/" .. tostring(item.id)
                downloads[opds_path] = item.path
            end
            kokomga_dl:saveSetting("downloads", downloads)
            kokomga_dl:flush()
        end
    end

    -- 3. Update Bookshelf settings store
    local newly_linked = 0
    local ok_bs, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
    if ok_bs and BookshelfSettings and BookshelfSettings.read then
        local ok_dl, OpdsDownload = pcall(require, "lib/bookshelf_opds_download")
        local dl_key = ok_dl and OpdsDownload.STORE_KEY or "opds_downloads"
        local map = BookshelfSettings.read(dl_key)
        if type(map) ~= "table" then map = {} end
        for _, item in ipairs(to_link) do
            local opds_path = "OPDS://" .. server_key .. "/" .. tostring(item.id)
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

    local matched, all_servers = profiles_mod.findServers()
    if not all_servers or #all_servers == 0 then
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
