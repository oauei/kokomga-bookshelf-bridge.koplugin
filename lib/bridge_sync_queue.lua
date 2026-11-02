-- lib/bridge_sync_queue.lua
-- Persistent offline action queue for Komga reading progress and completion events.
-- Buffers updates when offline or when server is unreachable, and automatically
-- replays them in the background upon reconnect to prevent duplicate Keep Reading entries.

local logger = require("logger")
local os = require("os")

local M = {
    _flushing = false,
    _settings_file = "kokomga_sync_queue.lua",
}

local function getSettings()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if ok_ds and DataStorage and ok_ls and LuaSettings then
        local dir = DataStorage:getSettingsDir()
        return LuaSettings:open(dir .. "/" .. M._settings_file)
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

function M.remove(book_id)
    local id = normalizeBookId(book_id)
    if not id then return false end

    local s = getSettings()
    if not s then return false end

    local q = s:readSetting("queue") or {}
    if q[id] then
        q[id] = nil
        s:saveSetting("queue", q)
        s:flush()
        logger.info("[Bridge SyncQueue] Removed book " .. tostring(id) .. " from queue")
        return true
    end
    return false
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

function M.isServerFurther(server_book, queued_item)
    if not server_book or type(server_book) ~= "table" or not queued_item then
        return false, "missing data"
    end

    local s_prog = server_book.readProgress
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
    local series_id = server_book.seriesId
    if series_id then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        local ok_ls, LuaSettings = pcall(require, "luasettings")
        if ok_ds and ok_ls and DataStorage and LuaSettings then
            local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
            if s then
                local lists = s:readSetting("lists") or {}
                local aq = lists["active_queue"]
                local frontier_dto = aq and aq.items and aq.items.by_series and aq.items.by_series[tostring(series_id)]
                if frontier_dto then
                    local ok_d, Dedup = pcall(require, "lib/hybrid_dedup")
                    if ok_d and Dedup and Dedup.extractChapterNumber then
                        local frontier_num = Dedup.extractChapterNumber(frontier_dto)
                        local book_num = Dedup.extractChapterNumber(server_book)
                            or (queued_item.filepath and Dedup.extractChapterNumber({ filepath = queued_item.filepath }))
                        if frontier_num and book_num and book_num < frontier_num and not q_completed then
                            return true, string.format("server series frontier chapter %s > queued chapter %s", tostring(frontier_num), tostring(book_num))
                        end
                    end
                end
            end
        end
    end

    return false, "queue is further"
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
        logger.info("[Bridge SyncQueue] Flush already in progress, skipping")
        if on_complete then on_complete(false, "In progress") end
        return false
    end

    local q = M.getQueue()
    local count = 0
    for _ in pairs(q) do count = count + 1 end
    if count == 0 then
        if on_complete then on_complete(true, 0) end
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
    logger.info(string.format("[Bridge SyncQueue] Starting flush for %d pending items", count))

    -- Check if we can run in a background subprocess via ffiutil
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    local ok_json, JSON = pcall(require, "json")
    local can_fork = ok_ffi and ffiutil and ffiutil.runInSubProcess and ok_json and JSON

    if can_fork and not (ok_h and Health and Health.isInSubprocess and Health.isInSubprocess()) then
        local actions_list = {}
        for _, item in pairs(q) do
            actions_list[#actions_list + 1] = item
        end

        local pid, parent_read_fd = ffiutil.runInSubProcess(function(pid, child_write_fd)
            local results = { succeeded = {}, unreachable = false, error = nil }
            for _, item in ipairs(actions_list) do
                local server_book, s_err, s_unreachable = fetchServerBook(api, item.book_id)
                if s_unreachable then
                    results.unreachable = true
                    results.error = tostring(s_err)
                    break
                end

                local server_further, reason = false, nil
                if server_book and type(server_book) == "table" then
                    server_further, reason = M.isServerFurther(server_book, item)
                end

                if server_further then
                    logger.info(string.format("[Bridge SyncQueue] Server progress is further for book %s (%s). Dropping stale queued update.",
                        tostring(item.book_id), tostring(reason)))
                    results.succeeded[item.book_id] = true
                else
                    local success, err, is_unreachable
                    if item.action == "delete" then
                        success, err, is_unreachable = api:request("/api/v1/books/" .. tostring(item.book_id) .. "/read-progress", "DELETE", nil, { timeout = 3, total_timeout = 5 })
                    else
                        success, err, is_unreachable = api:patch_read_progress(item.book_id, item.page, item.completed, { timeout = 3, total_timeout = 5 })
                    end

                    if success then
                        results.succeeded[item.book_id] = true
                    else
                        local err_str = tostring(err):lower()
                        if is_unreachable or err_str:find("timeout") or err_str:find("unreachable") or err_str:find("refused") then
                            results.unreachable = true
                            results.error = tostring(err)
                            break
                        else
                            -- Client error (e.g. 404 book deleted), consider handled to avoid infinite queue loop
                            results.succeeded[item.book_id] = true
                        end
                    end
                end
            end
            local out = JSON.encode(results)
            ffiutil.writeToFD(child_write_fd, out, true)
        end, true)

        if pid then
            local ok_ui, UIManager = pcall(require, "ui/uimanager")
            local function check_proc()
                if ffiutil.isSubProcessDone(pid) then
                    local ret_str = ""
                    if parent_read_fd then
                        ret_str = ffiutil.readAllFromFD(parent_read_fd)
                    end
                    local ok, res = pcall(JSON.decode, ret_str)
                    M._flushing = false

                    local flushed_cnt = 0
                    if ok and type(res) == "table" then
                        if res.succeeded then
                            for book_id in pairs(res.succeeded) do
                                M.remove(book_id)
                                flushed_cnt = flushed_cnt + 1
                            end
                        end
                        if res.unreachable and ok_h and Health and Health.tripCircuitBreaker then
                            Health.tripCircuitBreaker(res.error or "Server unreachable during flush")
                        end
                    end
                    logger.info(string.format("[Bridge SyncQueue] Subprocess flush complete. Flushed %d items", flushed_cnt))
                    if on_complete then on_complete(true, flushed_cnt) end
                else
                    if ok_ui and UIManager and UIManager.scheduleIn then
                        UIManager:scheduleIn(0.5, check_proc)
                    else
                        M._flushing = false
                    end
                end
            end

            if ok_ui and UIManager and UIManager.scheduleIn then
                UIManager:scheduleIn(0.5, check_proc)
            else
                M._flushing = false
            end
            return true
        end
    end

    -- Synchronous fallback (used in headless tests or when subprocess fork is unavailable)
    local flushed_cnt = 0
    local unreachable_encountered = false

    for book_id, item in pairs(q) do
        local server_book, s_err, s_unreachable = fetchServerBook(api, book_id)
        if s_unreachable then
            logger.warn("[Bridge SyncQueue] Flush interrupted by unreachable server during book check:", tostring(s_err))
            if ok_h and Health and Health.tripCircuitBreaker then
                Health.tripCircuitBreaker(s_err)
            end
            unreachable_encountered = true
            break
        end

        local server_further, reason = false, nil
        if server_book and type(server_book) == "table" then
            server_further, reason = M.isServerFurther(server_book, item)
        end

        if server_further then
            logger.info(string.format("[Bridge SyncQueue] Server progress is further for book %s (%s). Dropping stale queued update.",
                tostring(book_id), tostring(reason)))
            M.remove(book_id)
            flushed_cnt = flushed_cnt + 1
        else
            local success, err, is_unreachable
            if item.action == "delete" then
                success, err, is_unreachable = api:request("/api/v1/books/" .. tostring(book_id) .. "/read-progress", "DELETE", nil, { timeout = 3, total_timeout = 5 })
            else
                success, err, is_unreachable = api:patch_read_progress(book_id, item.page, item.completed, { timeout = 3, total_timeout = 5 })
            end

            if success then
                M.remove(book_id)
                flushed_cnt = flushed_cnt + 1
                logger.info(string.format("[Bridge SyncQueue] Flushed book %s (page=%s, completed=%s)",
                    tostring(book_id),
                    tostring(item.page),
                    tostring(item.completed)
                ))
            else
                local err_str = tostring(err):lower()
                if is_unreachable or err_str:find("timeout") or err_str:find("unreachable") or err_str:find("refused") then
                    logger.warn("[Bridge SyncQueue] Flush interrupted by unreachable server:", tostring(err))
                    if ok_h and Health and Health.tripCircuitBreaker then
                        Health.tripCircuitBreaker(err)
                    end
                    unreachable_encountered = true
                    break
                else
                    -- Client error (e.g. 404 book deleted), remove so it doesn't block the queue
                    logger.warn(string.format("[Bridge SyncQueue] Dropping book %s from queue after client error: %s", tostring(book_id), tostring(err)))
                    M.remove(book_id)
                end
            end
        end
    end

    M._flushing = false
    logger.info(string.format("[Bridge SyncQueue] Synchronous flush finished. %d items sent, remaining=%d", flushed_cnt, M.count()))
    if on_complete then on_complete(not unreachable_encountered, flushed_cnt) end
    return not unreachable_encountered, flushed_cnt
end

return M
