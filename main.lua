-- main.lua
-- Kokomga-Bookshelf Bridge Plugin entry point.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Profiles = require("lib/bridge_profiles")
local Auth = require("lib/bridge_auth")
local Cache = require("lib/bridge_cache")
local Linker = require("lib/bridge_linker")
local MenuPatch = require("lib/bridge_menu_patch")

local BridgePlugin = WidgetContainer:extend{
    name = "kokomga_bookshelf_bridge",
    is_doc_only = false,
}

function BridgePlugin:init()
    BridgePlugin.instance = self
    logger.info("[Bridge] Initializing Kokomga-Bookshelf Bridge...")

    -- 1. Install HTTP/HTTPS auth interceptor
    Auth.installInterceptor(Profiles)

    -- 2. Install cover cache cross-profile aliasing hook
    Cache.installCacheHook(Profiles)

    -- 3. Install menu patches across Bookshelf and Kokomga
    MenuPatch.installAll(Profiles)

    -- 4. Register global dispatcher action
    local ok_disp, Dispatcher = pcall(require, "dispatcher")
    if ok_disp and Dispatcher and Dispatcher.registerAction then
        pcall(Dispatcher.registerAction, Dispatcher, "komga_switch_network", {
            category = "none",
            event = "KomgaSwitchNetwork",
            title = _("Switch Komga Server Network"),
            general = true,
        })
    end
end

function BridgePlugin:onKomgaSwitchNetwork()
    Profiles.showNetworkProfilesDialog()
    return true
end

function BridgePlugin:onReaderReady()
    MenuPatch.patchKokomgaAutoRtl()
end

function BridgePlugin:addToMainMenu(menu_items)
    menu_items.kokomga_bookshelf_bridge = {
        text = _("Komga Bridge"),
        sorting_hint = "search",
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Switch server network…"),
                    keep_menu_open = true,
                    callback = function()
                        Profiles.showNetworkProfilesDialog()
                    end,
                },
                {
                    text = _("Manage network profiles…"),
                    keep_menu_open = true,
                    callback = function()
                        Profiles.promptManageProfiles()
                    end,
                },
                {
                    text = _("Link Komga books to OPDS…"),
                    keep_menu_open = true,
                    callback = function()
                        Linker.linkKomgaBooksPrompt(Profiles)
                    end,
                },
            }
        end,
    }
end

-- Public API for other plugins (such as bookshelf-hybrid or kokomga)
BridgePlugin.getProfiles = Profiles.getProfiles
BridgePlugin.saveProfiles = Profiles.saveProfiles
BridgePlugin.switchServerAddress = Profiles.switchServerAddress
BridgePlugin.showNetworkProfilesDialog = Profiles.showNetworkProfilesDialog
BridgePlugin.normalizeBaseUrl = Profiles.normalizeBaseUrl
BridgePlugin.deriveOpdsUrl = Profiles.deriveOpdsUrl
BridgePlugin.getAuthHeaders = function(url) return Auth.getAuthHeaders(url, Profiles) end
BridgePlugin.linkKomgaBooksPrompt = function() return Linker.linkKomgaBooksPrompt(Profiles) end
BridgePlugin.getKokomgaPlugin = MenuPatch.getKokomgaPlugin

return BridgePlugin
