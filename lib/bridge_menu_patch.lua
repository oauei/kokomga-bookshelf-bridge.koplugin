-- lib/bridge_menu_patch.lua
-- Non-invasively injects network profile switching and library shelf picking into Bookshelf and Kokomga menus.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local M = {}

local function liveModule(name)
    for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local ok, m = pcall(require, mod)
        local found = ok and m and m.instance and m.instance[name]
        if found then return found end
    end
end

local _captured_komga = nil

local function usable(plugin)
    return plugin and (plugin.settings or plugin.api or plugin.sync) and plugin
end

local function getUpvalueByName(fn, target_name)
    if type(fn) ~= "function" then return nil end
    local i = 1
    while true do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
        if name == target_name then return val end
        i = i + 1
    end
    return nil
end

local function extractFromKomgaSpec()
    local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
    local komga_spec = ok_s and Sources and Sources.get and Sources.get("komga")
    if not (komga_spec and komga_spec.fetch) then return nil end
    local liveFn = getUpvalueByName(komga_spec.fetch, "livePlugin")
    if type(liveFn) == "function" then
        local p = getUpvalueByName(liveFn, "registered_plugin") or liveFn()
        if usable(p) then return p end
    end
    return nil
end

local function hookBookshelfInstance(bs)
    if bs and not bs._bridge_source_changed_hooked then
        bs._bridge_source_changed_hooked = true
        local orig_sc = bs.sourceChanged
        if type(orig_sc) == "function" then
            bs.sourceChanged = function(self_bs, id)
                orig_sc(self_bs, id)
                if id == "komga" then
                    pcall(orig_sc, self_bs, "hybrid")
                end
            end
        end
    end
end

local function hookBookshelfRegister()
    hookBookshelfInstance(liveModule("bookshelf"))
    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("core/bookshelf") and type(v) == "table" and v.register then
            if not v._bridge_register_hooked then
                v._bridge_register_hooked = true
                local orig_reg = v.register
                v.register = function(bookshelf, plugin)
                    if usable(plugin) then _captured_komga = plugin end
                    hookBookshelfInstance(bookshelf)
                    return orig_reg(bookshelf, plugin)
                end
            end
        end
    end
end

local function hookSourcesChanged()
    local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
    if ok_s and Sources and type(Sources.changed) == "function" and not Sources._bridge_changed_hooked then
        Sources._bridge_changed_hooked = true
        local orig_changed = Sources.changed
        Sources.changed = function(id)
            orig_changed(id)
            if id == "komga" or id == "opds" then
                pcall(orig_changed, "hybrid")
            end
        end
    end
end

local function getKomgaPlugin()
    if usable(_captured_komga) then return _captured_komga end
    local ext = extractFromKomgaSpec()
    if usable(ext) then
        _captured_komga = ext
        return ext
    end

    local live = liveModule("kokomga")
    if usable(live) then
        _captured_komga = live
        return live
    end

    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local p = loaded and loaded["kokomga"]
    if usable(p) then
        _captured_komga = p
        return p
    end

    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("kokomga") and usable(v) then
            _captured_komga = v
            return v
        end
    end

    return live or p or _captured_komga or nil
end

M.getKomgaPlugin = getKomgaPlugin
M.getKokomgaPlugin = getKomgaPlugin
M.hookSourcesChanged = hookSourcesChanged
M.hookBookshelfRegister = hookBookshelfRegister

local function findKokomgaMenu()
    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("ui/menus/menu") and type(v) == "table" and v.createSettingsMenu then
            return v
        end
    end
    local komga = getKomgaPlugin()
    if komga and komga.menu then
        return getmetatable(komga.menu) or komga.menu
    end
    local ok_m, KokomgaMenu = pcall(require, "ui/menus/menu")
    if ok_m and KokomgaMenu and KokomgaMenu.createSettingsMenu then
        return KokomgaMenu
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 1. Patch Bookshelf Settings Menu
-- ---------------------------------------------------------------------------

function M.patchBookshelfSettings(profiles_mod)
    local ok_s, Settings = pcall(require, "lib/bookshelf_settings")
    if not (ok_s and Settings and Settings._librarySubItems) then return end
    if Settings._bridge_patched then return end
    Settings._bridge_patched = true

    local orig_librarySubItems = Settings._librarySubItems
    Settings._librarySubItems = function(self_s)
        local items = orig_librarySubItems(self_s) or {}

        -- Insert "Switch Komga server / network…"
        local switch_item = {
            text      = _("Switch Komga server / network") .. "…",
            help_text = _("Switch between saved Komga server networks and profiles (e.g., Home vs University). Updates Kokomga, OPDS catalog, and all hybrid shelves together."),
            callback  = function(touchmenu_instance)
                if touchmenu_instance then UIManager:close(touchmenu_instance) end
                UIManager:nextTick(function()
                    profiles_mod.showNetworkProfilesDialog()
                end)
            end,
        }

        table.insert(items, switch_item)
        return items
    end

    logger.info("[Bridge] Patched Bookshelf Settings menu with network switcher")
end

-- ---------------------------------------------------------------------------
-- 2. Patch Kokomga Options Menu
-- ---------------------------------------------------------------------------

function M.patchKokomgaMenu(profiles_mod)
    local KokomgaMenu = findKokomgaMenu()
    if not (KokomgaMenu and KokomgaMenu.createSettingsMenu) then return end
    if KokomgaMenu._bridge_patched then return end
    KokomgaMenu._bridge_patched = true

    local orig_createSettingsMenu = KokomgaMenu.createSettingsMenu
    KokomgaMenu.createSettingsMenu = function(self_m)
        local ok, menu = pcall(orig_createSettingsMenu, self_m)
        if not ok or type(menu) ~= "table" then
            logger.warn("[Bridge] Error in Kokomga createSettingsMenu:", tostring(menu))
            menu = {}
        end

        local found = false
        for sec_idx, section in ipairs(menu) do
            if section.text == "Server Setup" or section.text == _("Server Setup") or (section.text and section.text:find("Setup")) then
                if section.sub_item_table_func then
                    local orig_sub = section.sub_item_table_func
                    section.sub_item_table_func = function()
                        local ok_s, sub_items = pcall(orig_sub)
                        sub_items = (ok_s and type(sub_items) == "table") and sub_items or {}
                        table.insert(sub_items, 1, {
                            text = _("Switch Server / Network Profiles…"),
                            keep_menu_open = true,
                            callback = function()
                                profiles_mod.showNetworkProfilesDialog()
                            end,
                        })
                        table.insert(sub_items, 2, {
                            text_func = function()
                                local ok_sq, SyncQueue = pcall(require, "lib/bridge_sync_queue")
                                local count = (ok_sq and SyncQueue and SyncQueue.count) and SyncQueue.count() or 0
                                if count > 0 then
                                    return string.format(_("Offline Sync Queue (%d pending)"), count)
                                else
                                    return _("Offline Sync Queue (empty)")
                                end
                            end,
                            help_text = _("Pushes buffered offline reading progress and finished book actions to the Komga server."),
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local ok_sq, SyncQueue = pcall(require, "lib/bridge_sync_queue")
                                if ok_sq and SyncQueue then
                                    local count = SyncQueue.count()
                                    if count == 0 then
                                        UIManager:show(Notification:new{ text = _("Offline sync queue is empty.") })
                                        return
                                    end
                                    local ok_h, Health = pcall(require, "lib/bridge_health")
                                    local reachable, reason = true, nil
                                    if ok_h and Health and Health.isServerReachable then
                                        reachable, reason = Health.isServerReachable()
                                    end
                                    if not reachable then
                                        UIManager:show(Notification:new{ text = _("Server unreachable. Actions will sync automatically when reconnected.") })
                                        return
                                    end
                                    UIManager:show(Notification:new{ text = string.format(_("Syncing %d pending action(s)..."), count) })
                                    SyncQueue.flush(self_m.plugin and self_m.plugin.api, function(success, res)
                                        if success then
                                            if type(res) == "table" then
                                                local pushed = res.pushed or 0
                                                local pruned = res.pruned or 0
                                                if pruned > 0 then
                                                    UIManager:show(Notification:new{ text = string.format(_("Successfully synced %d action(s), pruned %d stale record(s)."), pushed, pruned) })
                                                else
                                                    UIManager:show(Notification:new{ text = string.format(_("Successfully synced %d action(s) to Komga."), pushed) })
                                                end
                                            else
                                                UIManager:show(Notification:new{ text = string.format(_("Successfully synced %s actions to Komga."), tostring(res)) })
                                            end
                                        else
                                            UIManager:show(Notification:new{ text = string.format(_("Sync paused: %s"), tostring(res)) })
                                        end
                                        if touchmenu_instance and touchmenu_instance.updateItems then
                                            touchmenu_instance:updateItems()
                                        end
                                    end)
                                end
                            end,
                        })
                        return sub_items
                    end
                    found = true
                end
            elseif section.text == "Options" or section.text == _("Options") or (section.text and section.text:find("Option")) then
                if section.sub_item_table_func then
                    local orig_sub_opt = section.sub_item_table_func
                    section.sub_item_table_func = function()
                        local ok_s, sub_items = pcall(orig_sub_opt)
                        sub_items = (ok_s and type(sub_items) == "table") and sub_items or {}

                        local rtl_idx = nil
                        for idx, item in ipairs(sub_items) do
                            if item.text and (item.text == "Auto RTL for Komga books" or item.text == _("Auto RTL for Komga books") or item.text:find("Auto RTL")) then
                                rtl_idx = idx
                                break
                            end
                        end

                        local adv_item = {
                            text = _("Auto RTL Advanced (Manga only)"),
                            help_text = _("Automatically sets RTL for Manga (CBZ/CBR and scanned PDFs) while keeping Light Novels (EPUBs and text PDFs) in normal LTR reading order."),
                            checked_func = function()
                                return G_reader_settings and G_reader_settings:isTrue("bridge_auto_rtl_advanced")
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local curr = G_reader_settings and G_reader_settings:isTrue("bridge_auto_rtl_advanced")
                                local new_val = not curr
                                if G_reader_settings then
                                    G_reader_settings:saveSetting("bridge_auto_rtl_advanced", new_val)
                                    pcall(function() G_reader_settings:flush() end)
                                end
                                if new_val and self_m.plugin and self_m.plugin.settings and self_m.plugin.settings.auto_rtl_direction then
                                    self_m.plugin.settings.auto_rtl_direction = false
                                    pcall(function() self_m.plugin:saveSettings() end)
                                end
                                if touchmenu_instance and touchmenu_instance.updateItems then
                                    touchmenu_instance:updateItems()
                                end
                            end,
                        }

                        local defer_item = {
                            text = _("Defer reading progress sync (idle/close only)"),
                            help_text = _("Prevents page-turn latency by debouncing Komga progress updates until 5 seconds of reading inactivity or document close."),
                            checked_func = function()
                                if G_reader_settings and G_reader_settings.readSetting then
                                    local val = G_reader_settings:readSetting("bridge_defer_progress_sync")
                                    if val ~= nil then return val == true end
                                end
                                return true
                            end,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local curr = true
                                if G_reader_settings and G_reader_settings.readSetting then
                                    local val = G_reader_settings:readSetting("bridge_defer_progress_sync")
                                    if val ~= nil then curr = (val == true) end
                                end
                                local new_val = not curr
                                if G_reader_settings then
                                    G_reader_settings:saveSetting("bridge_defer_progress_sync", new_val)
                                    pcall(function() G_reader_settings:flush() end)
                                end
                                if touchmenu_instance and touchmenu_instance.updateItems then
                                    touchmenu_instance:updateItems()
                                end
                            end,
                        }

                        if rtl_idx then
                            table.insert(sub_items, rtl_idx + 1, adv_item)
                            table.insert(sub_items, rtl_idx + 2, defer_item)
                        else
                            table.insert(sub_items, adv_item)
                            table.insert(sub_items, defer_item)
                        end
                        return sub_items
                    end
                end
            end
        end

        if not found and #menu > 0 then
            table.insert(menu, 1, {
                text = _("Switch Server / Network Profiles…"),
                keep_menu_open = true,
                callback = function()
                    profiles_mod.showNetworkProfilesDialog()
                end,
            })
        end

        return menu
    end

    logger.info("[Bridge] Patched Kokomga Settings menu with network switcher and Auto RTL Advanced")
end

-- ---------------------------------------------------------------------------
-- 3. Enhance Komga Shelf Source with Library Selection
-- ---------------------------------------------------------------------------

function M.enhanceKomgaShelfSource(profiles_mod)
    local ok_s, Sources = pcall(require, "lib/bookshelf_sources")
    if not (ok_s and Sources and Sources.get) then return end

    local komga_spec = Sources.get("komga")
    if not (komga_spec and komga_spec.pick) then return end
    if komga_spec._bridge_pick_patched then return end
    komga_spec._bridge_pick_patched = true

    local orig_pick = komga_spec.pick
    komga_spec.pick = function(draft, done)
        local komga = getKomgaPlugin()
        local libraries = nil
        if komga and komga.api then
            local ok_l, res = pcall(komga.api.get_libraries, komga.api)
            if ok_l and type(res) == "table" then
                libraries = res
            end
        end

        if not libraries or #libraries == 0 then
            return orig_pick(draft, done)
        end

        local d = nil
        -- Offer "All Libraries" vs specific library
        local buttons = {
            {
                {
                    text = _("All Libraries (All Series)"),
                    callback = function()
                        if d then UIManager:close(d); d = nil end
                        draft.source.library_id = nil
                        draft.source.library_names = nil
                        orig_pick(draft, done)
                    end,
                },
            },
        }

        for _, lib in ipairs(libraries) do
            local l = lib
            buttons[#buttons + 1] = {
                {
                    text = l.name or l.id,
                    callback = function()
                        if d then UIManager:close(d); d = nil end
                        draft.source.list = "all_series"
                        draft.source.library_id = { l.id }
                        draft.source.library_names = { [l.id] = l.name }
                        draft.label = l.name
                        done()
                    end,
                },
            }
        end

        buttons[#buttons + 1] = {
            {
                text = _("Other Komga Lists (Keep Reading, On Deck…)"),
                callback = function()
                    if d then UIManager:close(d); d = nil end
                    orig_pick(draft, done)
                end,
            },
        }

        buttons[#buttons + 1] = {
            {
                text = _("Cancel"),
                callback = function()
                    if d then UIManager:close(d); d = nil end
                    done(false)
                end,
            },
        }

        d = ButtonDialog:new{
            title = _("Select Komga Shelf Content"),
            buttons = buttons,
        }
        UIManager:show(d)
    end

    if komga_spec.editor_rows and not komga_spec._bridge_editor_rows_patched then
        komga_spec._bridge_editor_rows_patched = true
        local orig_editor_rows = komga_spec.editor_rows
        komga_spec.editor_rows = function(draft)
            local rows = orig_editor_rows and orig_editor_rows(draft) or {}
            if draft and draft.source and draft.source.kind == "komga" then
                if #rows < 3 then
                    rows[#rows + 1] = {
                        {
                            text = _("Include local library (Convert to Hybrid)"),
                            callback = function(d, done)
                                d.source.kind = "hybrid"
                                d.source.remote_kind = "komga"
                                done()
                            end,
                        },
                    }
                elseif #rows > 0 and #rows[#rows] < 3 then
                    table.insert(rows[#rows], {
                        text = _("Convert to Hybrid"),
                        callback = function(d, done)
                            d.source.kind = "hybrid"
                            d.source.remote_kind = "komga"
                            done()
                        end,
                    })
                end
            end
            return rows
        end
    end

    logger.info("[Bridge] Enhanced Komga shelf source with library picker and hybrid conversion")
end

-- ---------------------------------------------------------------------------
-- 4. Fix Spring Boot Sort Encoding Bug in KomgaAPI
-- ---------------------------------------------------------------------------

local function patchApiTable(target)
    if not (target and target.get_books_for_series) then return false end
    if target._bridge_sort_patched then return true end
    target._bridge_sort_patched = true

    local orig_get_books = target.get_books_for_series
    target.get_books_for_series = function(self, series_id, filters, page, size)
        -- Komga server defaults to metadata.numberSort,asc for series books.
        -- When { sort = "metadata.numberSort,asc" } is passed, escape_uri escapes ',' as '%2C',
        -- which breaks Spring Boot's SortHandlerMethodArgumentResolver (yielding HTTP 500/400).
        if filters and filters.sort then
            local clean = {}
            for k, v in pairs(filters) do clean[k] = v end
            clean.sort = nil
            local ok_res, res = pcall(orig_get_books, self, series_id, clean, page, size)
            if ok_res and res then return res end
        end
        return orig_get_books(self, series_id, filters, page, size)
    end
    return true
end

function M.patchKomgaApi()
    pcall(require, "plugins/kokomga.koplugin/core/api")
    pcall(require, "core/api")

    -- 1. Scan package.loaded for any core/api module
    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("core/api") and type(v) == "table" then
            patchApiTable(v)
        end
    end

    -- 2. Check live plugin instance and its metatable
    local komga = getKomgaPlugin()
    if komga and komga.api then
        patchApiTable(komga.api)
        patchApiTable(getmetatable(komga.api))
    end

    -- 3. Hook KomgaPlugin.init and initAPI on prototype so subsequent instances/re-inits are automatically patched
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local proto = loaded and loaded["kokomga"]
    if proto then
        if proto.initAPI and not proto._bridge_initapi_hooked then
            proto._bridge_initapi_hooked = true
            local orig_init_api = proto.initAPI
            proto.initAPI = function(self_k)
                orig_init_api(self_k)
                if self_k.api then
                    patchApiTable(self_k.api)
                    patchApiTable(getmetatable(self_k.api))
                end
            end
        end
        if proto.init and not proto._bridge_init_api_hooked then
            proto._bridge_init_api_hooked = true
            local orig_init = proto.init
            proto.init = function(self_k, ...)
                orig_init(self_k, ...)
                if self_k.api then
                    patchApiTable(self_k.api)
                    patchApiTable(getmetatable(self_k.api))
                end
            end
        end
    end

    logger.info("[Bridge] Patched KomgaAPI:get_books_for_series to fix Spring Boot sort encoding")
end

-- ---------------------------------------------------------------------------
-- 5. Patch Kokomga Auto-RTL for CBZ/PDF Only (Fork Alignment)
-- ---------------------------------------------------------------------------

local function getPageWordCount(document, pageno)
    if not (document and pageno) then return 0 end
    local text_boxes = nil

    if document.getPageText and type(document.getPageText) == "function" then
        local ok, res = pcall(document.getPageText, document, pageno)
        if ok and res then text_boxes = res end
    end

    if not text_boxes then
        local backend = document._document or document
        if backend and backend.openPage and type(backend.openPage) == "function" then
            local ok_p, page = pcall(backend.openPage, backend, pageno)
            if ok_p and page then
                if page.getPageText and type(page.getPageText) == "function" then
                    local ok_t, res = pcall(page.getPageText, page)
                    if ok_t and res then text_boxes = res end
                end
                pcall(page.close, page)
            end
        end
    end

    if not text_boxes then return 0 end

    if type(text_boxes) == "string" then
        local _, count = text_boxes:gsub("%S+", "")
        return count
    end

    if type(text_boxes) == "table" then
        local count = 0
        for _, line in ipairs(text_boxes) do
            if type(line) == "table" then
                if #line > 0 then
                    count = count + #line
                elseif line.text and type(line.text) == "string" then
                    local _, c = line.text:gsub("%S+", "")
                    count = count + c
                end
            elseif type(line) == "string" then
                local _, c = line:gsub("%S+", "")
                count = count + c
            end
        end
        return count
    end

    return 0
end

local function isTextPdf(document)
    if not document then return false end

    local total_pages = 1
    if document.page_count and type(document.page_count) == "number" then
        total_pages = document.page_count
    elseif document.getPageCount and type(document.getPageCount) == "function" then
        local ok, count = pcall(document.getPageCount, document)
        if ok and type(count) == "number" then total_pages = count end
    end

    -- Sample pages across the first 10 pages to avoid front-cover and illustration bias
    local pages_to_check = {}
    if total_pages <= 3 then
        for p = 1, total_pages do pages_to_check[#pages_to_check + 1] = p end
    else
        local candidates = { 2, 3, 5, 8 }
        for _, p in ipairs(candidates) do
            if p <= total_pages then
                pages_to_check[#pages_to_check + 1] = p
            end
        end
    end

    for _, pageno in ipairs(pages_to_check) do
        local words = getPageWordCount(document, pageno)
        if words > 20 then
            return true, words
        end
    end

    return false, 0
end

local function isMangaDocument(document, filepath)
    if type(filepath) ~= "string" then return false end
    local lower = filepath:lower()

    -- 1. CBZ / CBR / ZIP / RAR are always manga / comics
    if lower:match("%.cbz$") or lower:match("%.cbr$") or lower:match("%.zip$") or lower:match("%.rar$") then
        return true
    end

    -- 2. EPUB / MOBI / AZW3 / FB2 / TXT / HTML are reflowable text (Light Novels / Books)
    if lower:match("%.epub$") or lower:match("%.mobi$") or lower:match("%.azw3?$")
        or lower:match("%.fb2$") or lower:match("%.txt$") or lower:match("%.html?$") then
        return false
    end

    -- 3. PDF: check if it's a text PDF (>20 words per page) or scanned comic/manga (<=20 words per page)
    if lower:match("%.pdf$") then
        local is_text, word_count = isTextPdf(document)
        if is_text then
            logger.info(string.format("[Bridge] PDF has %d words on sampled page (>20) -> Light Novel (LTR)", word_count))
            return false
        else
            logger.info(string.format("[Bridge] PDF has %d words on sampled page (<=20) -> Manga/Comic (RTL)", word_count))
            return true
        end
    end

    if document and document.is_flow_document then
        return false
    end

    return false
end

local function copy_file(src, dst)
    if not src or not dst or src == "" or dst == "" then return false end
    local ok_u, util = pcall(require, "util")
    if ok_u and util and util.makePath then
        local dest_dir = dst:match("^(.*)/[^/]+$")
        if dest_dir then util.makePath(dest_dir .. "/") end
    end

    local ok_fu, ffiutil = pcall(require, "ffi/util")
    if ok_fu and ffiutil and ffiutil.copyFile then
        local ok, res = pcall(ffiutil.copyFile, src, dst)
        if ok and res then return true end
    end

    local rf = io.open(src, "rb")
    if not rf then return false end
    local wf = io.open(dst, "wb")
    if not wf then
        rf:close()
        return false
    end
    local data = rf:read("*a")
    if data then
        wf:write(data)
        wf:flush()
    end
    rf:close()
    wf:close()
    return true
end

local function getDirectoryCover(filepath)
    if type(filepath) ~= "string" or filepath == "" then return nil end
    local dir = filepath:match("^(.*)/[^/]+$")
    if not dir or dir == "" then return nil end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local candidates = { ".cover.jpg", ".cover.png", ".cover.webp", ".cover", "cover.jpg", "cover.png", "folder.jpg" }
    for _, name in ipairs(candidates) do
        local p = dir .. "/" .. name
        if ok_lfs and lfs and lfs.attributes(p, "mode") == "file" then
            return p
        else
            local f = io.open(p, "rb")
            if f then
                f:close()
                return p
            end
        end
    end
    return nil
end

M.copy_file = copy_file
M.getDirectoryCover = getDirectoryCover
M.getPageWordCount = getPageWordCount
M.isTextPdf = isTextPdf
M.isMangaDocument = isMangaDocument

function M.handleAutoRtlAdvanced(ui)
    if not (G_reader_settings and G_reader_settings:isTrue("bridge_auto_rtl_advanced")) then
        return false
    end

    if not ui then
        local ok_r, RUI = pcall(require, "apps/reader/readerui")
        ui = ok_r and RUI and RUI.instance
    end
    if not (ui and ui.view and ui.document) then return false end

    local document = ui.document
    local filepath = document.file
    local is_manga = isMangaDocument(document, filepath)

    local target_order = is_manga and true or false
    local order_changed = false

    if ui.view.inverse_reading_order ~= target_order then
        logger.info(string.format("[Bridge] Auto-RTL Advanced: setting %s to %s reading order",
            is_manga and "Manga" or "Light Novel",
            target_order and "RTL" or "LTR"
        ))
        if type(ui.view.onToggleReadingOrder) == "function" then
            ui.view:onToggleReadingOrder(target_order)
        else
            ui.view.inverse_reading_order = target_order
            if type(ui.view.setupTouchZones) == "function" then
                ui.view:setupTouchZones()
            elseif ui.rolling and type(ui.rolling.setupTouchZones) == "function" then
                ui.rolling:setupTouchZones()
            elseif ui.paging and type(ui.paging.setupTouchZones) == "function" then
                ui.paging:setupTouchZones()
            end
        end
        if ui.doc_settings then
            pcall(function() ui.doc_settings:saveSetting("inverse_reading_order", target_order) end)
            pcall(function() ui.doc_settings:flush() end)
        end
        order_changed = true
    end

    -- Always ensure touch zones are synchronized with current inverse_reading_order
    if type(ui.view.setupTouchZones) == "function" then
        ui.view:setupTouchZones()
    elseif ui.rolling and type(ui.rolling.setupTouchZones) == "function" then
        ui.rolling:setupTouchZones()
    elseif ui.paging and type(ui.paging.setupTouchZones) == "function" then
        ui.paging:setupTouchZones()
    end

    return order_changed
end

local function hookOnReaderReady(proto)
    if not proto or proto._bridge_rtl_hooked then return end
    if type(proto.onReaderReady) ~= "function" then return end
    proto._bridge_rtl_hooked = true

    local orig_onReaderReady = proto.onReaderReady
    proto.onReaderReady = function(self_k)
        local document = self_k.ui and self_k.ui.document
        local filepath = document and document.file
        local is_manga = isMangaDocument(document, filepath)

        local saved_rtl = nil
        local adv_active = G_reader_settings and G_reader_settings:isTrue("bridge_auto_rtl_advanced")
        if adv_active and self_k.settings and self_k.settings.auto_rtl_direction and not is_manga then
            -- Temporarily suppress standard auto_rtl_direction during onReaderReady for Light Novels
            saved_rtl = self_k.settings.auto_rtl_direction
            self_k.settings.auto_rtl_direction = false
        end

        local ok, res = pcall(orig_onReaderReady, self_k)

        if saved_rtl ~= nil then
            self_k.settings.auto_rtl_direction = saved_rtl
        end

        if adv_active then
            M.handleAutoRtlAdvanced(self_k.ui)
        end

        local ok_h, Health = pcall(require, "lib/bridge_health")
        if ok_h and Health and Health.isServerReachable and Health.isServerReachable() then
            local ok_sq, SyncQueue = pcall(require, "lib/bridge_sync_queue")
            if ok_sq and SyncQueue and SyncQueue.hasPending and SyncQueue.hasPending() then
                SyncQueue.flush(self_k.api)
            end
        end

        if not ok then
            logger.warn("[Bridge] Error in patched Kokomga onReaderReady:", tostring(res))
            return nil
        end
        return res
    end
    logger.info("[Bridge] Patched KokomgaPlugin:onReaderReady for Auto-RTL Advanced and sync queue flush")
end

local function hookScreensaverCover(proto)
    if not proto or proto._bridge_screensaver_hooked then return end
    proto._bridge_screensaver_hooked = true

    if type(proto.applyBookCoverToScreensaver) == "function" then
        local orig_apply = proto.applyBookCoverToScreensaver
        proto.applyBookCoverToScreensaver = function(self_k, target_path)
            local ui = self_k.ui
            local filepath = target_path or (ui and ui.document and ui.document.file)
            if filepath and isMangaDocument(ui and ui.document, filepath) then
                local series_cover = getDirectoryCover(filepath)
                local dest = (self_k.settings and self_k.settings.boox_screensaver_path) or "/sdcard/Pictures/Screensaver/koreaderCover.png"
                if series_cover and copy_file(series_cover, dest) then
                    logger.info("[Bridge] Copied Manga series directory cover to Boox screensaver path:", series_cover, "->", dest)
                    return
                end
                logger.info("[Bridge] Manga series directory cover not found, falling back to chapter cover")
            end
            return orig_apply(self_k, target_path)
        end
        logger.info("[Bridge] Patched KokomgaPlugin:applyBookCoverToScreensaver for Manga series cover")
    end
end

function M.patchKokomgaAutoRtl()
    -- 1. Hook Reader modules if in reader view
    local ok_rr, ReaderRolling = pcall(require, "apps/reader/modules/readerrolling")
    if ok_rr and ReaderRolling and not ReaderRolling._bridge_rtl_hooked then
        ReaderRolling._bridge_rtl_hooked = true
        local orig_rr_ready = ReaderRolling.onReaderReady
        ReaderRolling.onReaderReady = function(self_rr, ...)
            if orig_rr_ready then orig_rr_ready(self_rr, ...) end
            M.handleAutoRtlAdvanced(self_rr.ui)
        end
    end

    local ok_rp, ReaderPaging = pcall(require, "apps/reader/modules/readerpaging")
    if ok_rp and ReaderPaging and not ReaderPaging._bridge_rtl_hooked then
        ReaderPaging._bridge_rtl_hooked = true
        local orig_rp_ready = ReaderPaging.onReaderReady
        ReaderPaging.onReaderReady = function(self_rp, ...)
            if orig_rp_ready then orig_rp_ready(self_rp, ...) end
            M.handleAutoRtlAdvanced(self_rp.ui)
        end
    end

    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_r and ReaderUI and ReaderUI.instance then
        M.handleAutoRtlAdvanced(ReaderUI.instance)
    end

    -- 2. Scan loaded plugins for kokomga prototype
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local proto = loaded and loaded["kokomga"]
    if proto then
        hookOnReaderReady(proto)
        hookScreensaverCover(proto)
        if proto.init and not proto._bridge_init_rtl_hooked then
            proto._bridge_init_rtl_hooked = true
            local orig_init = proto.init
            proto.init = function(self_k, ...)
                _captured_komga = self_k
                orig_init(self_k, ...)
                hookOnReaderReady(self_k)
                hookScreensaverCover(self_k)
            end
        end
    end

    -- 3. Scan live instance
    local live = liveModule("kokomga")
    if live then
        _captured_komga = live
        hookOnReaderReady(live)
        hookScreensaverCover(live)
        hookOnReaderReady(getmetatable(live))
        hookScreensaverCover(getmetatable(live))
    end
end

M.hookScreensaverCover = hookScreensaverCover

-- ---------------------------------------------------------------------------
-- 6. Patch Kokomga Sync for ANR & Offline Protection
-- ---------------------------------------------------------------------------

local function patchSyncTarget(sync_target)
    if not (sync_target and type(sync_target) == "table") then return end
    if sync_target._bridge_anr_patched then return end
    sync_target._bridge_anr_patched = true

    local Health = require("lib/bridge_health")
    local _ = require("gettext")

    -- 1. promptNextChapter
    if sync_target.promptNextChapter then
        local orig_prompt = sync_target.promptNextChapter
        sync_target.promptNextChapter = function(self_s, ui, show_native_func)
            local reachable, reason = Health.isServerReachable()

            -- 1. Always mark summary as complete in document settings and BookList cache
            if ui and ui.doc_settings then
                local summary = ui.doc_settings:readSetting("summary") or {}
                summary.status = "complete"
                summary.modified = os.date("%Y-%m-%d", os.time())
                ui.doc_settings:saveSetting("summary", summary)
                pcall(function() ui.doc_settings:flush() end)
            end
            if ui and ui.document and ui.document.file then
                pcall(function()
                    local BookList = require("ui/widget/booklist")
                    if BookList and BookList.setBookInfoCacheProperty then
                        BookList.setBookInfoCacheProperty(ui.document.file, "status", "complete")
                    end
                end)
            end

            -- 2. Immediately enqueue completion in offline sync queue (never debounced)
            local filepath = ui and ui.document and ui.document.file
            local book_id = filepath and self_s.getOrMatchBook and self_s:getOrMatchBook(filepath)
            if book_id then
                local current_page = ui.view and ui.view.state and ui.view.state.page or 1
                local total_pages = ui.view and ui.view.state and ui.view.state.page_count
                    or (ui.document and ui.document.getPageCount and ui.document:getPageCount())
                    or current_page
                local SyncQueue = require("lib/bridge_sync_queue")
                SyncQueue.enqueue("progress", book_id, {
                    page = total_pages,
                    total_pages = total_pages,
                    completed = true,
                    filepath = filepath,
                })
                logger.info(string.format("[Bridge] Immediate completion buffered for book %s (page %d/%d, completed=true)",
                    tostring(book_id), total_pages, total_pages))
            end

            -- 3. Offline handling: allow Kokomga to check book_index without hanging on network
            if not reachable then
                logger.info("[Bridge] Komga server unreachable (" .. tostring(reason) .. "), running promptNextChapter in offline mode")
                local orig_resolve = self_s.resolveNextBook
                if orig_resolve then
                    self_s.resolveNextBook = function(self_r, bid)
                        local index = self_r.plugin and self_r.plugin.book_index
                        local known = index and index.getNext(bid)
                        if known then return known, "index" end
                        return nil, known == false and "none" or "offline"
                    end
                end

                local ok, ret = pcall(orig_prompt, self_s, ui, show_native_func)
                if orig_resolve then
                    self_s.resolveNextBook = orig_resolve
                end

                if not ok then
                    logger.err("[Bridge] promptNextChapter offline error:", tostring(ret))
                    if show_native_func then
                        show_native_func()
                        return true
                    end
                    return false
                end
                return ret
            end

            local ok, ret = pcall(orig_prompt, self_s, ui, show_native_func)
            if not ok then
                logger.err("[Bridge] promptNextChapter error:", tostring(ret))
                if show_native_func then
                    show_native_func()
                    return true
                end
                return false
            end
            return ret
        end
    end

    -- 2. preDownloadNextBook
    if sync_target.preDownloadNextBook then
        local orig_predl = sync_target.preDownloadNextBook
        sync_target.preDownloadNextBook = function(self_s, filepath)
            local reachable, reason = Health.isServerReachable()
            if not reachable then
                logger.info("[Bridge] Komga server unreachable (" .. tostring(reason) .. "), skipping preDownloadNextBook")
                return
            end
            return orig_predl(self_s, filepath)
        end
    end

    -- 3. downloadBookCoverIfMissing
    if sync_target.downloadBookCoverIfMissing then
        local orig_dl_cover = sync_target.downloadBookCoverIfMissing
        sync_target.downloadBookCoverIfMissing = function(self_s, book, local_path)
            local reachable = Health.isServerReachable()
            if not reachable then
                logger.info("[Bridge] Komga server unreachable, skipping downloadBookCoverIfMissing")
                return
            end
            return orig_dl_cover(self_s, book, local_path)
        end
    end

    -- 4. downloadSeriesCoverIfMissing
    if sync_target.downloadSeriesCoverIfMissing then
        local orig_dl_series_cover = sync_target.downloadSeriesCoverIfMissing
        sync_target.downloadSeriesCoverIfMissing = function(self_s, book, final_dir, series_title)
            local reachable = Health.isServerReachable()
            if not reachable then
                logger.info("[Bridge] Komga server unreachable, skipping downloadSeriesCoverIfMissing")
                return
            end
            return orig_dl_series_cover(self_s, book, final_dir, series_title)
        end
    end

    -- 5. downloadBook
    if sync_target.downloadBook then
        local orig_dl_book = sync_target.downloadBook
        sync_target.downloadBook = function(self_s, book, series_title, on_success_callback, on_failure_callback)
            local reachable, reason = Health.isServerReachable()
            if not reachable then
                if self_s.plugin and self_s.plugin.notify then
                    self_s.plugin:notify(_("Komga server is unreachable. Cannot download book."), "error")
                end
                if on_failure_callback then
                    local ok_ui, UIManager = pcall(require, "ui/uimanager")
                    if ok_ui and UIManager and UIManager.nextTick then
                        UIManager:nextTick(function()
                            on_failure_callback("Komga server unreachable")
                        end)
                    else
                        on_failure_callback("Komga server unreachable")
                    end
                end
                return
            end
            return orig_dl_book(self_s, book, series_title, on_success_callback, on_failure_callback)
        end
    end

    -- 6. pushProgressForDocument
    if sync_target.pushProgressForDocument then
        local orig_push_doc = sync_target.pushProgressForDocument
        local function unscheduleDebounce(self_s)
            if self_s._debounced_progress_timer then
                if UIManager and UIManager.unschedule then
                    pcall(UIManager.unschedule, UIManager, self_s._debounced_progress_timer)
                end
                self_s._debounced_progress_timer = nil
            end
        end

        sync_target.flushDebouncedProgress = function(self_s)
            unscheduleDebounce(self_s)
            if self_s._pending_push_ui then
                local p_ui = self_s._pending_push_ui
                local p_net = self_s._pending_ensure_networking
                self_s._pending_push_ui = nil
                self_s._pending_ensure_networking = nil
                logger.info("[Bridge] Explicit flush of debounced reading progress")
                pcall(sync_target.pushProgressForDocument, self_s, p_ui, false, p_net)
            end
        end

        sync_target.pushProgressForDocument = function(self_s, ui, is_quiet, ensure_networking)
            local defer_enabled = true
            if G_reader_settings and G_reader_settings.readSetting then
                local val = G_reader_settings:readSetting("bridge_defer_progress_sync")
                if val ~= nil then defer_enabled = (val == true) end
            end

            local is_finished = false
            if ui and ui.document then
                local current_page = ui.view and ui.view.state and ui.view.state.page or 1
                local total_pages = ui.view and ui.view.state and ui.view.state.page_count
                    or (ui.document and ui.document.getPageCount and ui.document:getPageCount())
                    or 0
                if total_pages > 0 and current_page >= total_pages then
                    is_finished = true
                end
                if ui.doc_settings then
                    local summary = ui.doc_settings:readSetting("summary")
                    if type(summary) == "table" and summary.status == "complete" then
                        is_finished = true
                    end
                    local lpct = tonumber(ui.doc_settings:readSetting("percent_finished"))
                    if lpct and lpct >= 0.99 then
                        is_finished = true
                    end
                end
            end

            -- When reading normally (is_quiet == true), debounce progress push to avoid page turn latency.
            -- Completion events (is_finished == true) must NEVER be debounced.
            if not is_finished and defer_enabled and is_quiet then
                unscheduleDebounce(self_s)

                self_s._pending_push_ui = ui
                self_s._pending_ensure_networking = ensure_networking

                self_s._debounced_progress_timer = function()
                    self_s._debounced_progress_timer = nil
                    if self_s._pending_push_ui then
                        local p_ui = self_s._pending_push_ui
                        local p_net = self_s._pending_ensure_networking
                        self_s._pending_push_ui = nil
                        self_s._pending_ensure_networking = nil
                        logger.info("[Bridge] Executing debounced pushProgressForDocument after 5s idle pause")
                        pcall(sync_target.pushProgressForDocument, self_s, p_ui, false, p_net)
                    end
                end

                if UIManager and UIManager.scheduleIn then
                    UIManager:scheduleIn(5, self_s._debounced_progress_timer)
                else
                    self_s._debounced_progress_timer()
                end
                return
            end

            unscheduleDebounce(self_s)
            self_s._pending_push_ui = nil
            self_s._pending_ensure_networking = nil

            local SyncQueue = require("lib/bridge_sync_queue")
            local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
            local is_offline = ok_nm and NetworkMgr and (not NetworkMgr:isOnline())
            local reachable, reason = Health.isServerReachable()
            local cb_active = (self_s.isCircuitBreakerActive and self_s:isCircuitBreakerActive())

            if is_offline or not reachable or cb_active then
                if ui and ui.document then
                    local filepath = ui.document.file
                    local book_id = filepath and self_s.getOrMatchBook and self_s:getOrMatchBook(filepath)
                    if book_id then
                        local current_page = ui.view and ui.view.state and ui.view.state.page or 1
                        local total_pages = ui.view and ui.view.state and ui.view.state.page_count
                            or (ui.document and ui.document.getPageCount and ui.document:getPageCount())
                            or current_page
                        local is_completed = (total_pages and total_pages > 0 and current_page >= total_pages)
                        if ui.doc_settings then
                            local summary = ui.doc_settings:readSetting("summary")
                            if summary and type(summary) == "table" and summary.status == "complete" then
                                is_completed = true
                            end
                            local lpct = tonumber(ui.doc_settings:readSetting("percent_finished"))
                            if lpct and lpct >= 0.99 then
                                is_completed = true
                            end
                        end
                        SyncQueue.enqueue("progress", book_id, {
                            page = current_page,
                            total_pages = total_pages,
                            completed = is_completed,
                            filepath = filepath,
                        })
                        logger.info(string.format("[Bridge] Offline/unreachable: buffered pushProgressForDocument for book %s (page %d/%d, completed=%s)",
                            tostring(book_id), current_page, total_pages, tostring(is_completed)))
                    end
                end
                return
            end

            -- Server is reachable: flush any pending offline queue items in background
            if SyncQueue.hasPending() and self_s.plugin and self_s.plugin.api then
                SyncQueue.flush(self_s.plugin.api)
            end

            return orig_push_doc(self_s, ui, is_quiet, ensure_networking)
        end
    end

    -- 7. pushProgress
    if sync_target.pushProgress then
        local orig_push = sync_target.pushProgress
        sync_target.pushProgress = function(self_s, book_id, current_page, total_pages, is_quiet)
            local SyncQueue = require("lib/bridge_sync_queue")
            local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
            local is_offline = ok_nm and NetworkMgr and (not NetworkMgr:isOnline())
            local reachable, reason = Health.isServerReachable()
            local cb_active = (self_s.isCircuitBreakerActive and self_s:isCircuitBreakerActive())

            if is_offline or not reachable or cb_active then
                local completed = (total_pages and total_pages > 0 and current_page >= total_pages)
                SyncQueue.enqueue("progress", book_id, {
                    page = current_page,
                    total_pages = total_pages,
                    completed = completed,
                })
                logger.info(string.format("[Bridge] Offline/unreachable: buffered pushProgress for book %s (page %d/%s, completed=%s)",
                    tostring(book_id), current_page, tostring(total_pages), tostring(completed)))
                return
            end

            return orig_push(self_s, book_id, current_page, total_pages, is_quiet)
        end
    end

    -- 8. collectBgDownloads
    if sync_target.collectBgDownloads then
        local orig_collect = sync_target.collectBgDownloads
        sync_target.collectBgDownloads = function(self_s)
            local pushes_before = {}
            if self_s.bg_processes then
                for _, proc in ipairs(self_s.bg_processes) do
                    if proc.is_push and proc.book_id then
                        pushes_before[proc.pid] = {
                            book_id = proc.book_id,
                            page = proc.page,
                            start_time = proc.start_time,
                        }
                    end
                end
            end

            orig_collect(self_s)

            -- If circuit breaker tripped during collect, enqueue any removed pushes
            if self_s.isCircuitBreakerActive and self_s:isCircuitBreakerActive() then
                local remaining_pids = {}
                if self_s.bg_processes then
                    for _, proc in ipairs(self_s.bg_processes) do
                        remaining_pids[proc.pid] = true
                    end
                end
                for pid, info in pairs(pushes_before) do
                    if not remaining_pids[pid] then
                        local SyncQueue = require("lib/bridge_sync_queue")
                        SyncQueue.enqueue("progress", info.book_id, { page = info.page })
                        logger.info(string.format("[Bridge] Enqueued failed push for book %s after circuit breaker trip", tostring(info.book_id)))
                    end
                end
            end
        end
    end

    logger.info("[Bridge] Patched KomgaSync with ANR offline protection and offline sync queue")
end

local function hookOnNetworkConnected(target)
    if not (target and type(target) == "table") then return end
    if target._bridge_net_hooked then return end
    target._bridge_net_hooked = true
    local orig_net = target.onNetworkConnected
    target.onNetworkConnected = function(self_k, ...)
        local Health = require("lib/bridge_health")
        Health.resetCircuitBreaker()
        local SyncQueue = require("lib/bridge_sync_queue")
        local api = self_k.api or (self_k.getKomgaPlugin and self_k.getKomgaPlugin() and self_k.getKomgaPlugin().api)
        if api then
            SyncQueue.flush(api)
        else
            SyncQueue.flush()
        end
        if orig_net then
            return orig_net(self_k, ...)
        end
    end
end

local function hookOnCloseDocument(target)
    if not (target and type(target) == "table") then return end
    if target._bridge_close_hooked then return end
    target._bridge_close_hooked = true
    local orig_close = target.onCloseDocument
    target.onCloseDocument = function(self_k, ...)
        if self_k.sync and self_k.sync.flushDebouncedProgress then
            pcall(self_k.sync.flushDebouncedProgress, self_k.sync)
        end
        if orig_close then
            return orig_close(self_k, ...)
        end
    end
end

function M.patchKokomgaSync()
    pcall(require, "plugins/kokomga.koplugin/core/sync")
    pcall(require, "core/sync")
    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:find("core/sync") and type(v) == "table" then
            patchSyncTarget(v)
            patchSyncTarget(getmetatable(v))
        end
    end

    local komga = getKomgaPlugin()
    if komga then
        hookOnNetworkConnected(komga)
        hookOnNetworkConnected(getmetatable(komga))
        hookOnCloseDocument(komga)
        hookOnCloseDocument(getmetatable(komga))
        if komga.sync then
            patchSyncTarget(komga.sync)
            patchSyncTarget(getmetatable(komga.sync))
        end
    end

    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local proto = loaded and loaded["kokomga"]
    if proto then
        hookOnNetworkConnected(proto)
        hookOnNetworkConnected(getmetatable(proto))
        if proto.sync then
            patchSyncTarget(proto.sync)
            patchSyncTarget(getmetatable(proto.sync))
        end
        if proto.init and not proto._bridge_init_sync_hooked then
            proto._bridge_init_sync_hooked = true
            local orig_init = proto.init
            proto.init = function(self_k, ...)
                orig_init(self_k, ...)
                hookOnNetworkConnected(self_k)
                if self_k.sync then
                    patchSyncTarget(self_k.sync)
                    patchSyncTarget(getmetatable(self_k.sync))
                end
            end
        end
    end
end

function M.installAll(profiles_mod)
    hookBookshelfRegister()
    hookSourcesChanged()
    M.patchBookshelfSettings(profiles_mod)
    M.patchKokomgaMenu(profiles_mod)
    M.enhanceKomgaShelfSource(profiles_mod)
    M.patchKomgaApi()
    M.patchKokomgaAutoRtl()
    M.patchKokomgaSync()
end

return M
