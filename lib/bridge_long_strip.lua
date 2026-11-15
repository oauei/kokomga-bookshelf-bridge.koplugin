-- lib/bridge_long_strip.lua
-- Auto-detects long-strip (webtoon) comics by page aspect ratio or Komga metadata
-- and configures continuous vertical scrolling, fit-to-content-width zoom, and LTR order
-- without affecting normal manga or reflowable books.

local logger = require("logger")

local M = {
    ASPECT_RATIO_THRESHOLD = 2.5,
    MAX_SAMPLE_PAGES = 5,
    APPLY_VERSION = 3,
}

function M.isEnabled()
    if G_reader_settings and G_reader_settings.readSetting then
        return G_reader_settings:readSetting("bridge_auto_long_strip") ~= false
    end
    return true
end

local function isTextPdf(document)
    if not document then return false end
    local ok_f, file = pcall(function() return document.file end)
    local ext = (ok_f and type(file) == "string") and file:match("%.([^%.]+)$")
    ext = ext and ext:lower() or ""
    if ext ~= "pdf" then return false end
    if type(document.hasText) == "function" then
        local ok_t, has_t = pcall(document.hasText, document)
        if ok_t and has_t then return true end
    end
    if type(document.getPageText) == "function" then
        local ok_p, txt = pcall(document.getPageText, document, 1)
        if ok_p and type(txt) == "string" and #txt:gsub("%s+", "") > 20 then
            return true
        end
    end
    return false
end

local function hasWebtoonKomgaMetadata(document, filepath)
    if document and type(document.info) == "table" then
        if document.info.readingDirection == "WEBTOON" then
            return true
        end
    end
    return false
end

--- Returns true if document is a non-reflowable comic/image document whose pages
-- indicate a long-strip webtoon (height/width >= 2.5 in sampled pages, or WEBTOON metadata).
function M.isLongStripDocument(document, filepath)
    if not document then return false end
    if document.is_reflowable then return false end
    filepath = filepath or document.file
    if type(filepath) == "string" then
        local ext = filepath:match("%.([^%.]+)$")
        ext = ext and ext:lower() or ""
        if ext == "epub" or ext == "fb2" or ext == "mobi" or ext == "azw3" or ext == "txt" or ext == "html" then
            return false
        end
    end
    if isTextPdf(document) then return false end

    if hasWebtoonKomgaMetadata(document, filepath) then
        return true
    end

    if type(document.getNativePageDimensions) ~= "function" then
        return false
    end

    local page_count = 1
    if type(document.getPageCount) == "function" then
        local ok_c, cnt = pcall(document.getPageCount, document)
        if ok_c and tonumber(cnt) and tonumber(cnt) > 0 then
            page_count = math.floor(tonumber(cnt))
        end
    end

    local sample_limit = math.min(page_count, M.MAX_SAMPLE_PAGES)
    for p = 1, sample_limit do
        local ok_d, dim = pcall(document.getNativePageDimensions, document, p)
        if ok_d and type(dim) == "table" then
            local w = tonumber(dim.w) or 0
            local h = tonumber(dim.h) or 0
            if w > 0 and (h / w) >= M.ASPECT_RATIO_THRESHOLD then
                return true
            end
        end
    end

    return false
end

function M.applyIfNeeded(ui)
    if not M.isEnabled() then return false end
    if not (ui and ui.view and ui.document) then return false end

    local doc_settings = ui.doc_settings
    if doc_settings and doc_settings.readSetting and doc_settings:readSetting("bridge_long_strip_version") == M.APPLY_VERSION then
        return false
    end

    if not M.isLongStripDocument(ui.document, ui.document.file) then
        return false
    end

    logger.info("[Bridge LongStrip] Detected long-strip comic; applying contentwidth + SetScrollMode(true) + RTL preserved: "
        .. tostring(ui.document.file))

    local ok_ev, Event = pcall(require, "ui/event")
    local function sendEvent(name, ...)
        if ok_ev and Event and ui.handleEvent then
            pcall(ui.handleEvent, ui, Event:new(name, ...))
        end
    end

    -- 1. Switch zoom mode to fit content width BEFORE enabling scroll mode
    -- (ReaderView:onSetScrollMode warns if zoom_mode is still a paged mode)
    sendEvent("SetZoomMode", "contentwidth")

    -- 2. Enable continuous vertical scroll mode
    if type(ui.document.configurable) == "table" then
        ui.document.configurable.page_scroll = 1
    end
    sendEvent("SetScrollMode", true)

    -- 3. Refresh touch zones after enabling scroll mode (preserving RTL/LTR reading order)
    if type(ui.view.setupTouchZones) == "function" then
        pcall(ui.view.setupTouchZones, ui.view)
    elseif ui.paging and type(ui.paging.setupTouchZones) == "function" then
        pcall(ui.paging.setupTouchZones, ui.paging)
    end

    -- 4. Persist settings and one-time versioned per-book marker
    if doc_settings and doc_settings.saveSetting then
        pcall(doc_settings.saveSetting, doc_settings, "kopt_page_scroll", 1)
        pcall(doc_settings.saveSetting, doc_settings, "zoom_mode", "contentwidth")
        pcall(doc_settings.saveSetting, doc_settings, "normal_zoom_mode", "contentwidth")
        pcall(doc_settings.saveSetting, doc_settings, "bridge_long_strip_applied", true)
        pcall(doc_settings.saveSetting, doc_settings, "bridge_long_strip_version", M.APPLY_VERSION)
        if doc_settings.flush then
            pcall(doc_settings.flush, doc_settings)
        end
    end

    sendEvent("UpdatePos")
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.setDirty then
        pcall(UIManager.setDirty, UIManager, ui, "ui")
    end

    return true
end

return M
