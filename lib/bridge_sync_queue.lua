-- lib/bridge_sync_queue.lua
-- Persistent offline action queue for Komga reading progress and completion events.
-- Buffers updates when offline or when server is unreachable, and automatically
-- replays them in the background upon reconnect to prevent duplicate Keep Reading entries.

local logger = require("logger")
local os = require("os")

local M = {
    _flushing = false,
    _flushing_started_at = nil,
    _settings_file = "kokomga_sync_queue.lua",
}

local function getSettings()
    if M._flushing and M._flush_settings and M._flush_settings_file == M._settings_file then
        return M._flush_settings
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if ok_ds and DataStorage and ok_ls and LuaSettings then
        local dir = DataStorage:getSettingsDir()
        local s = LuaSettings:open(dir .. "/" .. M._settings_file)
        if M._flushing and s then
            M._flush_settings = s
            M._flush_settings_file = M._settings_file
        end
        return s
    end
    return nil
end

local function normalizeBookId(book_id)
    if type(book_id) ~= "string" and type(book_id) ~= "number" then return nil end
    local s = tostring(book_id)
    return s:match("^komga://book/(.+)$") or s
end

M.normalizeBookId = normalizeBookId

function M.getQueue()
    local s = getSettings()
    if s then
        return s:readSetting("queue") or {}
    end
    return {}
end

function M.count()
    local q = M.getQueue()
    local n = 0
    for _ in pairs(q) do
        n = n + 1
    end
    return n
end

function M.hasPending()
    return M.count() > 0
end

function M.enqueue(action_type, book_id, data)
    local id = normalizeBookId(book_id)
    if not id or id == "" then return false end

    local s = getSettings()
    if not s then return false end

    local q = s:readSetting("queue") or {}
    data = data or {}
    local existing = q[id]

    if action_type == "delete" then
        q[id] = {
            action = "delete",
            book_id = id,
            timestamp = os.time(),
            title = data.title or (existing and existing.title),
        }
    else
        local new_page = tonumber(data.page) or (existing and existing.page) or 1
        local new_total = tonumber(data.total_pages) or (existing and existing.total_pages)
        local new_completed = (data.completed == true) or (existing and existing.completed == true) or false
        if new_total and new_total > 0 and new_page >= new_total then
            new_completed = true
        end
        if existing and existing.page and new_page < existing.page and not data.force_page then
            new_page = existing.page
        end

        q[id] = {
            action = "progress",
            book_id = id,
            page = new_page,
            total_pages = new_total,
            completed = new_completed,
            timestamp = os.time(),
            title = data.title or (existing and existing.title),
            filepath = data.filepath or (existing and existing.filepath),
        }
    end

    s:saveSetting("queue", q)
    s:flush()

    local entry = q[id]
    logger.info(string.format("[Bridge SyncQueue] Enqueued offline action '%s' for book %s (page=%s, completed=%s)",
        tostring(entry.action),
        tostring(id),
        tostring(entry.page),
        tostring(entry.completed)
    ))
    return true
end

function M.removeMultiple(book_ids, defer_flush)
    if not book_ids or #book_ids == 0 then return false end
    local s = getSettings()
    if not s then return false end

    local q = s:readSetting("queue") or {}
    local changed = false
    for _, raw_id in ipairs(book_ids) do
        local id = normalizeBookId(raw_id)
        if id and q[id] then
            q[id] = nil
            changed = true
            logger.info("[Bridge SyncQueue] Removed book " .. tostring(id) .. " from queue")
        end
    end
    if changed then
        s:saveSetting("queue", q)
        if not defer_flush then
            s:flush()
        end
        return true
    end
    return false
end

function M.remove(book_id, defer_flush)
    return M.removeMultiple({ book_id }, defer_flush)
end

function M.clear()
    local s = getSettings()
    if s then
        s:saveSetting("queue", {})
        s:flush()
        logger.info("[Bridge SyncQueue] Cleared offline queue")
        return true
    end
    return false
end

local function getKomgaApi()
    local ok_p, PluginLoader = pcall(require, "pluginloader")
    local loaded = ok_p and PluginLoader and PluginLoader.loaded_plugins or nil
    local komga = loaded and loaded["kokomga"]
    if komga and komga.api then return komga.api end

    for _, k in ipairs({ "plugins/kokomga.koplugin/core/api", "core/api" }) do
        local ok, Api = pcall(require, k)
        if ok and Api and Api.instance then return Api.instance end
    end
    return nil
end

local _cached_frontier_by_series = nil
local _cached_frontier_time = 0

local function getFrontierBySeries()
    local now = os.time()
    if _cached_frontier_by_series and (now - _cached_frontier_time < 10) then
        return _cached_frontier_by_series
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if ok_ds and ok_ls and DataStorage and LuaSettings then
        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
        if s then
            local lists = s:readSetting("lists") or {}
            local aq = lists["active_queue"]
            local by_series = (aq and aq.items and aq.items.by_series) or {}
            _cached_frontier_by_series = by_series
            _cached_frontier_time = now
            return by_series
        end
    end
    return {}
end

function M.isServerFurther(server_book, queued_item)
    if not server_book or type(server_book) ~= "table" or not queued_item then
        return false, "missing data"
    end

    local raw_prog = server_book.readProgress
    local s_prog = (type(raw_prog) == "table") and raw_prog or nil
    local s_completed = (s_prog and s_prog.completed == true)
    local s_page = s_prog and tonumber(s_prog.page) or 0
    local q_completed = (queued_item.completed == true)
    local q_page = tonumber(queued_item.page) or 0

    -- 1. Unread action in queue ("delete")
    if queued_item.action == "delete" then
        if s_completed or s_page > 0 then
            return true, "server has progress while queue is delete/unread"
        end
        return true, "server already unread"
    end

    -- 2. Book completion comparison
    if s_completed then
        if not q_completed then
            return true, string.format("server is completed, queue is page %d", q_page)
        else
            return true, "both completed"
        end
    end

    if q_completed then
        return false, "queue is completed, server is not"
    end

    -- 3. In-progress page comparison
    if s_page >= q_page and s_page > 0 then
        return true, string.format("server page %d >= queue page %d", s_page, q_page)
    end

    -- 4. Series frontier comparison (if book belongs to a series)
    local raw_series_id = server_book.seriesId
    local series_id = (type(raw_series_id) == "string" or type(raw_series_id) == "number") and raw_series_id or nil
    if series_id then
        local by_series = getFrontierBySeries()
        local frontier_dto = by_series and by_series[tostring(series_id)]
        if type(frontier_dto) == "table" then
            local ok_d, Dedup = pcall(require, "lib/hybrid_dedup")
            if ok_d and Dedup and Dedup.extractChapterNumber then
                local ok_fn, frontier_num = pcall(Dedup.extractChapterNumber, frontier_dto)
                local ok_bn, book_num = pcall(Dedup.extractChapterNumber, server_book)
                if not ok_bn or not book_num then
                    if queued_item.filepath then
                        ok_bn, book_num = pcall(Dedup.extractChapterNumber, { filepath = queued_item.filepath })
                    end
                end
                if ok_fn and ok_bn and frontier_num and book_num and book_num < frontier_num and not q_completed then
                    return true, string.format("server series frontier chapter %s > queued chapter %s", tostring(frontier_num), tostring(book_num))
                end
            end
        end
    end

    return false, "queue is further"
end

local function buildApiRequestOpts(api, path, method, body_table)
    local base_url = api and api.base_url
    if not base_url or base_url == "" then
        local ok_h, Health = pcall(require, "lib/bridge_health")
        local ok_p, Profiles = pcall(require, "lib/bridge_profiles")
        if ok_h and Health and Health.getActiveServerUrl then
            base_url = Health.getActiveServerUrl(ok_p and Profiles)
        end
    end
    if not base_url or base_url == "" then return nil end
    local url = tostring(base_url):gsub("/+$", "") .. path

    local headers = {}
    if api and type(api.get_headers) == "function" then
        local ok_hdr, h = pcall(api.get_headers, api)
        if ok_hdr and type(h) == "table" then
            for k, v in pairs(h) do headers[k] = v end
        end
    end
    local ok_ba, BridgeAuth = pcall(require, "lib/bridge_auth")
    local ok_p, Profiles = pcall(require, "lib/bridge_profiles")
    if ok_ba and BridgeAuth and BridgeAuth.getAuthHeaders then
        local extra = BridgeAuth.getAuthHeaders(url, ok_p and Profiles)
        if type(extra) == "table" then
            for k, v in pairs(extra) do
                if not headers[k] then headers[k] = v end
            end
        end
    end

    local body_str = nil
    if body_table ~= nil then
        local ok_j, json = pcall(require, "json")
        if ok_j and json and json.encode then
            body_str = json.encode(body_table)
            headers["Content-Type"] = "application/json"
        end
    end

    return {
        url = url,
        method = method or "GET",
        headers = headers,
        body = body_str,
        connect_timeout = 2,
        max_time = 5,
    }
end
M.buildApiRequestOpts = buildApiRequestOpts

local function invalidateActiveQueueAndRepo()
    _cached_frontier_by_series = nil
    _cached_frontier_time = 0
    pcall(function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
        if s then
            local lists = s:readSetting("lists") or {}
            if lists["active_queue"] ~= nil then
                lists["active_queue"] = nil
                s:saveSetting("lists", lists)
                s:flush()
            end
        end
    end)

    local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
    if ok_repo and Repo then
        if Repo.invalidateBookCache then
            pcall(Repo.invalidateBookCache, "hybrid-remote-mode")
        end
        if Repo.invalidateAllCache then
            pcall(Repo.invalidateAllCache)
        end
    end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_ev, Event = pcall(require, "ui/event")
    if ok_ui and ok_ev and UIManager and Event and UIManager.nextTick and UIManager.broadcastEvent then
        UIManager:nextTick(function()
            UIManager:broadcastEvent(Event:new("BookshelfRefreshLibrary"))
        end)
    end
end

local function fetchServerBook(api, book_id)
    if not api or not book_id then return nil, "missing api or book_id" end
    local res, err, is_unreachable
    if type(api.get_book) == "function" then
        res, err, is_unreachable = api:get_book(book_id)
    elseif type(api.request) == "function" then
        res, err, is_unreachable = api:request("/api/v1/books/" .. tostring(book_id), "GET", nil, { timeout = 3, total_timeout = 5 })
    end
    if not res and err then
        local err_str = tostring(err):lower()
        if is_unreachable or err_str:find("timeout") or err_str:find("unreachable") or err_str:find("refused") then
            return nil, err, true
        end
    end
    return res, err, false
end

function M.flush(api, on_complete)
    if M._flushing then
        local elapsed = M._flushing_started_at and (os.time() - M._flushing_started_at) or 0
        if elapsed > 60 then
            logger.warn(string.format("[Bridge SyncQueue] Stale flush lock detected (%ds elapsed); resetting lock", elapsed))
            M._flushing = false
            M._flushing_started_at = nil
        else
            logger.info("[Bridge SyncQueue] Flush already in progress, skipping")
            if on_complete then on_complete(false, "In progress") end
            return false
        end
    end

    local q = M.getQueue()
    local count = 0
    for _ in pairs(q) do count = count + 1 end
    if count == 0 then
        local stats = { pushed = 0, pruned = 0, total = 0 }
        setmetatable(stats, { __tostring = function() return "0" end })
        if on_complete then on_complete(true, stats) end
        return true
    end

    local ok_h, Health = pcall(require, "lib/bridge_health")
    if ok_h and Health and Health.isServerReachable then
        local reachable, reason = Health.isServerReachable()
        if not reachable then
            logger.info("[Bridge SyncQueue] Komga server unreachable (" .. tostring(reason) .. "), skipping flush")
            if on_complete then on_complete(false, reason) end
            return false
        end
    end

    api = api or getKomgaApi()
    if not api then
        logger.warn("[Bridge SyncQueue] No Komga API available to flush queue")
        if on_complete then on_complete(false, "No API") end
        return false
    end

    M._flushing = true
    M._flushing_started_at = os.time()
    logger.info(string.format("[Bridge SyncQueue] Starting cooperative flush for %d pending items", count))

    local actions_list = {}
    for _, item in pairs(q) do
        actions_list[#actions_list + 1] = item
    end

    local pushed_cnt = 0
    local pruned_cnt = 0
    local unreachable_encountered = false
    local failure_reason = nil

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local has_ui = (ok_ui and UIManager and UIManager.scheduleIn)
    local ok_ah, AsyncHttp = pcall(require, "lib/bridge_async_http")
    local use_async_http = has_ui and ok_ah and AsyncHttp and AsyncHttp.isAvailable and AsyncHttp.isAvailable()

    local function finish_flush()
        if pushed_cnt > 0 or pruned_cnt > 0 then
            local s = getSettings()
            if s and s.flush then
                pcall(function() s:flush() end)
            end
        end
        M._flush_settings = nil
        M._flush_settings_file = nil
        M._flushing = false
        M._flushing_started_at = nil
        if pushed_cnt > 0 or pruned_cnt > 0 then
            invalidateActiveQueueAndRepo()
        end
        local stats = {
            pushed = pushed_cnt,
            pruned = pruned_cnt,
            total = pushed_cnt + pruned_cnt,
        }
        setmetatable(stats, {
            __tostring = function() return tostring(stats.total) end
        })
        logger.info(string.format("[Bridge SyncQueue] Cooperative flush finished. Pushed: %d, Pruned: %d, Remaining: %d",
            pushed_cnt, pruned_cnt, M.count()))
        if on_complete then
            if unreachable_encountered then
                on_complete(false, failure_reason or "Server unreachable", stats)
            else
                on_complete(true, stats)
            end
        end
    end

    local function step(idx)
        if unreachable_encountered or idx > #actions_list then
            finish_flush()
            return
        end

        local item = actions_list[idx]
        local book_id = item and item.book_id
        if not book_id then
            if has_ui then
                UIManager:scheduleIn(0.05, function() step(idx + 1) end)
            else
                step(idx + 1)
            end
            return
        end

        local function scheduleNext()
            if has_ui then
                UIManager:scheduleIn(0.05, function() step(idx + 1) end)
            else
                step(idx + 1)
            end
        end

        local function handlePushResult(success, err, is_unreachable)
            if success then
                M.remove(book_id, true)
                pushed_cnt = pushed_cnt + 1
                logger.info(string.format("[Bridge SyncQueue] Flushed book %s (page=%s, completed=%s)",
                    tostring(book_id),
                    tostring(item.page),
                    tostring(item.completed)
                ))
                scheduleNext()
            else
                local err_str = tostring(err):lower()
                if is_unreachable or err_str:find("timeout") or err_str:find("unreachable") or err_str:find("refused") then
                    logger.warn("[Bridge SyncQueue] Flush interrupted by unreachable server:", tostring(err))
                    if ok_h and Health and Health.tripCircuitBreaker then
                        Health.tripCircuitBreaker(err)
                    end
                    unreachable_encountered = true
                    failure_reason = tostring(err)
                    finish_flush()
                else
                    logger.warn(string.format("[Bridge SyncQueue] Dropping book %s from queue after client error: %s", tostring(book_id), tostring(err)))
                    M.remove(book_id, true)
                    pruned_cnt = pruned_cnt + 1
                    scheduleNext()
                end
            end
        end

        local function performPush()
            if use_async_http then
                local req_opts
                if item.action == "delete" then
                    req_opts = buildApiRequestOpts(api, "/api/v1/books/" .. tostring(book_id) .. "/read-progress", "DELETE", nil)
                else
                    req_opts = buildApiRequestOpts(api, "/api/v1/books/" .. tostring(book_id) .. "/read-progress", "PATCH", {
                        page = item.page,
                        completed = item.completed or false,
                    })
                end
                if req_opts then
                    AsyncHttp.requestAsync(req_opts, function(ok, code, _, err_msg)
                        local is_unreach = (tonumber(code) or 0) == 0
                        handlePushResult(ok, err_msg, is_unreach)
                    end)
                    return
                end
            end

            local success, err, is_unreachable
            if item.action == "delete" then
                success, err, is_unreachable = api:request("/api/v1/books/" .. tostring(book_id) .. "/read-progress", "DELETE", nil, { timeout = 3, total_timeout = 5 })
            else
                success, err, is_unreachable = api:patch_read_progress(book_id, item.page, item.completed, { timeout = 3, total_timeout = 5 })
            end
            handlePushResult(success, err, is_unreachable)
        end

        local function handleServerBook(server_book, s_err, s_unreachable)
            if s_unreachable then
                logger.warn("[Bridge SyncQueue] Flush interrupted by unreachable server during book check:", tostring(s_err))
                if ok_h and Health and Health.tripCircuitBreaker then
                    Health.tripCircuitBreaker(s_err)
                end
                unreachable_encountered = true
                failure_reason = tostring(s_err)
                finish_flush()
                return
            end

            local server_further, reason = false, nil
            if server_book and type(server_book) == "table" then
                server_further, reason = M.isServerFurther(server_book, item)
            end

            if server_further then
                logger.info(string.format("[Bridge SyncQueue] Server progress is further for book %s (%s). Dropping stale queued update.",
                    tostring(book_id), tostring(reason)))
                M.remove(book_id, true)
                pruned_cnt = pruned_cnt + 1
                scheduleNext()
            else
                performPush()
            end
        end

        -- Skip redundant GET when item is already completed=true (not a delete)
        if item.completed == true and item.action ~= "delete" then
            performPush()
            return
        end

        if use_async_http then
            local get_opts = buildApiRequestOpts(api, "/api/v1/books/" .. tostring(book_id), "GET", nil)
            if get_opts then
                AsyncHttp.requestAsync(get_opts, function(ok, code, resp_body, err_msg)
                    local num_code = tonumber(code) or 0
                    if not ok then
                        local is_unreach = (num_code == 0)
                        handleServerBook(nil, err_msg, is_unreach)
                        return
                    end
                    local ok_j, json = pcall(require, "json")
                    local decoded = nil
                    if ok_j and json and json.decode and resp_body and resp_body ~= "" then
                        local ok_d, tbl = pcall(json.decode, resp_body)
                        if ok_d and type(tbl) == "table" then decoded = tbl end
                    end
                    handleServerBook(decoded, nil, false)
                end)
                return
            end
        end

        local ok_step, step_err = pcall(function()
            local server_book, s_err, s_unreachable = fetchServerBook(api, book_id)
            handleServerBook(server_book, s_err, s_unreachable)
        end)
        if not ok_step then
            logger.warn("[Bridge SyncQueue] Unexpected error flushing item " .. tostring(idx) .. ": " .. tostring(step_err))
            scheduleNext()
        end
    end

    step(1)
    if unreachable_encountered then
        return false, failure_reason or "Server unreachable"
    end
    return true, (pushed_cnt + pruned_cnt)
end

return M
