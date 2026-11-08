-- lib/bridge_profiles.lua
-- Network profile switcher for Komga and Bookshelf OPDS servers.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local M = {}

local function getKomgaPlugin()
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    return loaded and loaded["kokomga"] or nil
end

function M.normalizeBaseUrl(url)
    if type(url) ~= "string" then return "" end
    local ok_u, util = pcall(require, "util")
    if ok_u and util and util.trim then
        url = util.trim(url)
    else
        url = url:gsub("^%s+", ""):gsub("%s+$", "")
    end
    if url == "" then return "" end
    if not url:match("^%a+://") then
        url = "http://" .. url
    end
    url = url:gsub("/+$", "")
    return url
end

function M.deriveOpdsUrl(base_url)
    base_url = M.normalizeBaseUrl(base_url)
    if base_url == "" then return "" end
    if base_url:find("/opds", 1, true) then
        return base_url
    end
    return base_url .. "/opds/v1.2/catalog"
end

function M.getProfiles()
    local komga = getKomgaPlugin()
    local profiles = nil
    if komga and komga.settings and type(komga.settings.network_profiles) == "table" then
        profiles = komga.settings.network_profiles
    else
        local ok_bs, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
        if ok_bs and BookshelfSettings and BookshelfSettings.read then
            local saved = BookshelfSettings.read("komga_network_profiles")
            if type(saved) == "table" then
                profiles = saved
            end
        end
    end

    if not profiles or #profiles == 0 then
        profiles = {}
        local curr_url = (komga and komga.settings and komga.settings.server_url) or ""
        curr_url = M.normalizeBaseUrl(curr_url)
        if curr_url ~= "" then
            profiles[1] = {
                name = _("Current"),
                base_url = curr_url,
                active = true,
            }
        end
        M.saveProfiles(profiles)
    end

    local curr_url = komga and komga.settings and M.normalizeBaseUrl(komga.settings.server_url) or ""
    local has_active = false
    for _, p in ipairs(profiles) do
        if curr_url ~= "" and p.base_url == curr_url then
            p.active = true
            has_active = true
        else
            p.active = false
        end
    end
    if not has_active and #profiles > 0 then
        profiles[1].active = true
    end

    return profiles
end

function M.saveProfiles(profiles)
    local komga = getKomgaPlugin()
    if komga and komga.settings then
        komga.settings.network_profiles = profiles
        if komga.saveSettings then
            komga:saveSettings()
        end
    end
    local ok_bs, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
    if ok_bs and BookshelfSettings and BookshelfSettings.save then
        BookshelfSettings.save("komga_network_profiles", profiles)
        if BookshelfSettings.flush then
            BookshelfSettings.flush()
        end
    end
end

function M.getAllKomgaServerKeys()
    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    local keys = {}
    local seen = {}
    local function addKey(url)
        if type(url) == "string" and url ~= "" and ok_s and OpdsSource then
            local opds_url = M.deriveOpdsUrl(url)
            local k = OpdsSource.serverKey(opds_url)
            if k and not seen[k] then
                seen[k] = true
                keys[#keys + 1] = k
            end
        end
    end

    local komga = getKomgaPlugin()
    if komga and komga.settings and komga.settings.server_url then
        addKey(komga.settings.server_url)
    end
    local profiles = M.getProfiles()
    for _, p in ipairs(profiles) do
        if p.base_url then addKey(p.base_url) end
    end
    return keys
end

function M.findServers()
    local komga = getKomgaPlugin()
    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    if not (ok_s and OpdsSource) then return {}, {} end
    local all_servers = (OpdsSource.servers and OpdsSource.servers())
        or (OpdsSource.getServers and OpdsSource.getServers())
        or {}

    local komga_url = komga and komga.settings and komga.settings.server_url
    local matched = {}

    if type(komga_url) == "string" and komga_url ~= "" then
        local k_origin = komga_url:match("^(https?://[^/]+)")
        local k_clean = komga_url:gsub("/+$", ""):lower()
        if k_origin then
            k_origin = k_origin:lower()
            for _, s in ipairs(all_servers) do
                local s_origin = s.url and s.url:match("^(https?://[^/]+)")
                local s_clean = s.url and s.url:gsub("/+$", ""):lower() or ""
                if (s_origin and s_origin:lower() == k_origin)
                    or (s_clean ~= "" and (s_clean:find(k_clean, 1, true) or k_clean:find(s_clean, 1, true))) then
                    matched[#matched + 1] = s
                end
            end
        end
    end

    return matched, all_servers
end

function M.switchServerAddress(new_base_url, profile_name)
    new_base_url = M.normalizeBaseUrl(new_base_url)
    if new_base_url == "" then return false end

    local komga = getKomgaPlugin()
    local old_base_url = (komga and komga.settings and komga.settings.server_url) or ""
    old_base_url = M.normalizeBaseUrl(old_base_url)

    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    local new_opds_url = M.deriveOpdsUrl(new_base_url)
    local old_opds_url = (old_base_url ~= "") and M.deriveOpdsUrl(old_base_url) or ""

    local new_server_key = (ok_s and OpdsSource) and OpdsSource.serverKey(new_opds_url) or nil
    local old_server_key = (ok_s and OpdsSource and old_opds_url ~= "") and OpdsSource.serverKey(old_opds_url) or nil

    -- 1. Update Kokomga settings & re-init API
    if komga and komga.settings then
        komga.settings.server_url = new_base_url
        if komga.saveSettings then komga:saveSettings() end
        if komga.initAPI then komga:initAPI() end
    end

    -- 2. Update OPDS catalog in Bookshelf
    local ok_c, Catalogs = pcall(require, "lib/bookshelf_opds_catalogs")
    if ok_c and Catalogs and Catalogs.list then
        local cat_list = Catalogs.list() or {}
        local found = false
        local fallback_user, fallback_pass
        for _, s in ipairs(cat_list) do
            if s.username or s.password then
                fallback_user = fallback_user or s.username
                fallback_pass = fallback_pass or s.password
            end
            if (old_opds_url ~= "" and s.url == old_opds_url)
                or (old_base_url ~= "" and s.url and s.url:find(old_base_url, 1, true))
                or (s.url and s.url:find("/opds/v1.2/catalog", 1, true)) then
                s.url = new_opds_url
                found = true
                break
            end
        end
        if not found and #cat_list > 0 then
            local matched = M.findServers()
            if matched and #matched > 0 then
                for _, s in ipairs(cat_list) do
                    if s.url == matched[1].url then
                        s.url = new_opds_url
                        found = true
                        break
                    end
                end
            end
        end
        if not found and #cat_list > 0 then
            cat_list[#cat_list + 1] = {
                title = "Komga",
                url = new_opds_url,
                username = fallback_user,
                password = fallback_pass,
            }
        end
        if Catalogs.persist then
            Catalogs.persist(cat_list)
        end
    end

    -- 3. Update tabs in Bookshelf TabModel
    local ok_tm, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if ok_tm and TabModel and TabModel.load then
        local tabs = TabModel.load() or {}
        local changed = false
        for _, t in ipairs(tabs) do
            if t.source and (t.source.kind == "opds" or t.source.kind == "hybrid") then
                if old_server_key and t.source.id == old_server_key then
                    t.source.id = new_server_key
                    changed = true
                elseif not t.source.id or t.source.id == "" then
                    t.source.id = new_server_key
                    changed = true
                end

                if old_base_url ~= "" and type(t.source.feed_url) == "string" and t.source.feed_url:find(old_base_url, 1, true) then
                    t.source.feed_url = t.source.feed_url:gsub(old_base_url, new_base_url)
                    changed = true
                end

                if type(t.source.opds) == "table" then
                    for _, s in ipairs(t.source.opds) do
                        if type(s) == "table" then
                            if old_server_key and s.id == old_server_key then
                                s.id = new_server_key
                                changed = true
                            end
                            if old_base_url ~= "" and type(s.feed_url) == "string" and s.feed_url:find(old_base_url, 1, true) then
                                s.feed_url = s.feed_url:gsub(old_base_url, new_base_url)
                                changed = true
                            end
                        end
                    end
                end
            end
        end
        if changed and TabModel.save then
            TabModel.save(tabs)
        end
    end

    -- 4. Mark active profile in profiles list
    local profiles = M.getProfiles()
    for _, p in ipairs(profiles) do
        p.active = (p.base_url == new_base_url)
    end
    M.saveProfiles(profiles)

    local ok_h, Health = pcall(require, "lib/bridge_health")
    if ok_h and Health and Health.resetCircuitBreaker then
        Health.resetCircuitBreaker()
    end

    -- 5. Notify Bookshelf if running (deferred via nextTick to avoid destroying widget tree during event dispatch)
    local ok_bw, BookshelfWidget = pcall(require, "lib/bookshelf_widget")
    if ok_bw and BookshelfWidget and BookshelfWidget.live then
        local bw = BookshelfWidget.live
        UIManager:nextTick(function()
            local ok_rb, rb_err = pcall(function()
                if bw and bw._rebuild then
                    bw:_rebuild()
                end
                if UIManager and UIManager.setDirty then
                    UIManager:setDirty(bw, "ui")
                end
            end)
            if not ok_rb then
                logger.warn("[Bridge] Deferred Bookshelf rebuild after profile switch failed:", tostring(rb_err))
            end
        end)
    end

    logger.info("[Bridge] Switched Komga server address to:", new_base_url)
    return true
end

function M.promptAddProfile(on_saved)
    local dialog = nil
    dialog = InputDialog:new{
        title = _("Add Network Profile"),
        input = "",
        input_type = "string",
        hint = _("Profile Name (e.g. Home LAN, Tailscale)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "cancel",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        local name = dialog:getInputText()
                        UIManager:close(dialog)
                        if not name or name:gsub("%s+", "") == "" then return end

                        UIManager:nextTick(function()
                            local url_dialog = nil
                            url_dialog = InputDialog:new{
                                title = _("Server Base URL"),
                                input = "http://",
                                input_type = "string",
                                hint = "http://192.168.1.100:25600",
                                buttons = {
                                    {
                                        {
                                            text = _("Cancel"),
                                            id = "cancel",
                                            callback = function() UIManager:close(url_dialog) end,
                                        },
                                        {
                                            text = _("Save"),
                                            is_enter_default = true,
                                            callback = function()
                                                local raw_url = url_dialog:getInputText()
                                                local clean_url = M.normalizeBaseUrl(raw_url)
                                                UIManager:close(url_dialog)
                                                if clean_url ~= "" then
                                                    local profiles = M.getProfiles()
                                                    profiles[#profiles + 1] = {
                                                        name = name,
                                                        base_url = clean_url,
                                                        active = false,
                                                    }
                                                    M.saveProfiles(profiles)
                                                    if on_saved then
                                                        UIManager:nextTick(on_saved)
                                                    end
                                                end
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(url_dialog)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function M.promptEditProfile(idx, on_saved)
    local profiles = M.getProfiles()
    local p = profiles[idx]
    if not p then return end

    local dialog = nil
    dialog = ButtonDialog:new{
        title = p.name .. " (" .. p.base_url .. ")",
        buttons = {
            {
                {
                    text = _("Edit Name"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            local inp = nil
                            inp = InputDialog:new{
                                title = _("Edit Profile Name"),
                                input = p.name,
                                buttons = {
                                    {
                                        { text = _("Cancel"), callback = function() UIManager:close(inp) end },
                                        {
                                            text = _("Save"),
                                            is_enter_default = true,
                                            callback = function()
                                                local n = inp:getInputText()
                                                UIManager:close(inp)
                                                if n and n:gsub("%s+", "") ~= "" then
                                                    p.name = n
                                                    M.saveProfiles(profiles)
                                                    if on_saved then
                                                        UIManager:nextTick(on_saved)
                                                    end
                                                end
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(inp)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Edit Base URL"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            local inp = nil
                            inp = InputDialog:new{
                                title = _("Edit Server Base URL"),
                                input = p.base_url,
                                buttons = {
                                    {
                                        { text = _("Cancel"), callback = function() UIManager:close(inp) end },
                                        {
                                            text = _("Save"),
                                            is_enter_default = true,
                                            callback = function()
                                                local u = M.normalizeBaseUrl(inp:getInputText())
                                                UIManager:close(inp)
                                                if u ~= "" then
                                                    p.base_url = u
                                                    M.saveProfiles(profiles)
                                                    if on_saved then
                                                        UIManager:nextTick(on_saved)
                                                    end
                                                end
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(inp)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Delete Profile"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:nextTick(function()
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete this profile?"),
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    table.remove(profiles, idx)
                                    M.saveProfiles(profiles)
                                    if on_saved then
                                        UIManager:nextTick(on_saved)
                                    end
                                end,
                            })
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Back"),
                    callback = function()
                        UIManager:close(dialog)
                        if on_saved then
                            UIManager:nextTick(on_saved)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function M.promptManageProfiles(on_saved)
    local profiles = M.getProfiles()
    local buttons = {}
    local dialog = nil

    buttons[#buttons + 1] = {
        {
            text = _("+ Add Profile…"),
            callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    M.promptAddProfile(function()
                        M.promptManageProfiles(on_saved)
                    end)
                end)
            end,
        },
    }

    for i, p in ipairs(profiles) do
        local label = (p.active and "✓ " or "") .. p.name .. "\n" .. p.base_url
        local idx = i
        buttons[#buttons + 1] = {
            {
                text = label,
                callback = function()
                    UIManager:close(dialog)
                    UIManager:nextTick(function()
                        M.promptEditProfile(idx, function()
                            M.promptManageProfiles(on_saved)
                        end)
                    end)
                end,
            },
        }
    end

    buttons[#buttons + 1] = {
        {
            text = _("Done"),
            callback = function()
                UIManager:close(dialog)
                if on_saved then
                    UIManager:nextTick(on_saved)
                end
            end,
        },
    }

    dialog = ButtonDialog:new{
        title = _("Manage Network Profiles"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M.showNetworkProfilesDialog(on_complete)
    local profiles = M.getProfiles()
    local buttons = {}
    local dialog = nil

    for p_idx, p in ipairs(profiles) do
        local label = (p.active and "✓ " or "") .. p.name .. "\n" .. p.base_url
        local target_url = p.base_url
        local target_name = p.name
        buttons[#buttons + 1] = {
            {
                text = label,
                callback = function()
                    UIManager:close(dialog)
                    UIManager:nextTick(function()
                        local ok_sw, sw_err = pcall(function()
                            M.switchServerAddress(target_url, target_name)
                        end)
                        if not ok_sw then
                            logger.error("[Bridge Profiles] Error switching server address:", tostring(sw_err))
                        end
                        UIManager:show(Notification:new{
                            text = _("Switched Komga server to: ") .. target_name,
                            timeout = 3,
                        })
                        if on_complete then
                            pcall(on_complete)
                        end
                    end)
                end,
            },
        }
    end

    buttons[#buttons + 1] = {
        {
            text = _("Manage Profiles…"),
            callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    M.promptManageProfiles(function()
                        M.showNetworkProfilesDialog(on_complete)
                    end)
                end)
            end,
        },
    }

    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
                if on_complete then
                    pcall(on_complete)
                end
            end,
        },
    }

    dialog = ButtonDialog:new{
        title = _("Select Komga Server Network"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return M
