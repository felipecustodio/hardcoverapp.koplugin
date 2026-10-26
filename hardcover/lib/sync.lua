local Api = require("hardcover/lib/hardcover_api")
local NetworkManager = require("ui/network/manager")
local logger = require("logger")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

local Sync = {}
Sync.__index = Sync
local running = false

function Sync:new(o)
  return setmetatable(o, self)
end

function Sync:enqueue(filename, update)
  local pending = self.settings:readSetting("pending_sync") or {}
  local key = Api.credential_id .. ":" .. filename
  local previous = pending[key] or {}
  local entry = {}
  for key, value in pairs(previous) do
    entry[key] = value
  end
  for key, value in pairs(update) do
    entry[key] = value
  end
  if update.page then
    entry.mapped_page = update.mapped_page
    entry.edition_id = update.edition_id
  end
  if update.status_id or update.privacy_setting_id then
    entry.status_revision = (previous.status_revision or 0) + 1
  end
  entry.started_at = previous.started_at or os.date("%Y-%m-%d")
  local account_id
  if self.settings:readSetting("user_credential_id") == Api.credential_id then
    account_id = self.settings:readSetting(SETTING.USER_ID)
  end
  entry.filename = filename
  entry.account_id = previous.account_id or account_id
  entry.credential_id = Api.credential_id
  pending[key] = entry
  self.settings:updateSetting("pending_sync", pending)
  return entry
end

function Sync:pending()
  return next(self.settings:readSetting("pending_sync") or {}) ~= nil
end

function Sync:send(filename, entry, me)
  if (entry.account_id and entry.account_id ~= me.id)
      or (not entry.account_id and entry.credential_id ~= Api.credential_id) then
    return nil, "Pending update belongs to another Hardcover account"
  end

  local linked = self.settings:readBookSettings(filename) or {}
  if not linked.book_id then
    local book, err = self.hardcover:findAutomaticBook(entry.props or {}, me.id)
    if not book then
      return nil, err or "Select a Hardcover book with Link book"
    end
    self.settings:updateBookSetting(filename, {
      book_id = book.book_id,
      edition_id = book.edition_id,
      edition_format = book.edition_format,
      pages = book.pages,
      title = book.title,
    })
    linked = self.settings:readBookSettings(filename)
  end

  local status, err = Api:findUserBook(linked.book_id, me.id)
  if err then
    return nil, err
  end

  local created = not (status and status.id)
  if created then
    status = Api:updateUserBook(linked.book_id, HARDCOVER.STATUS.READING,
      me.account_privacy_setting_id, linked.edition_id)
    if not status then
      return nil, "Could not add book to Hardcover"
    end
  end

  if entry.status_id == HARDCOVER.STATUS.READING and status.status_id ~= HARDCOVER.STATUS.READING then
    status = Api:updateUserBook(linked.book_id, HARDCOVER.STATUS.READING,
      entry.privacy_setting_id or status.privacy_setting_id, status.edition_id)
    if not status then
      return nil, "Could not start reading"
    end
  end

  local progress_done = false
  if entry.page and status.status_id == HARDCOVER.STATUS.READING then
    local reads = status.user_book_reads or {}
    local current_read = reads[#reads]
    local edition_id = current_read and current_read.edition_id or status.edition_id
    local pages = linked.pages
    if edition_id and (edition_id ~= linked.edition_id or not pages or pages <= 0) then
      local edition = Api:hydrateBookFromEdition(edition_id, me.id)
      if not edition then
        return nil, "Could not load reading edition"
      end
      pages = edition.pages
    end
    if not pages or pages <= 0 then
      return nil, "Select an edition with a page count"
    end
    local page
    if entry.mapped_page and entry.edition_id == edition_id then
      page = entry.mapped_page
    elseif pages and entry.document_pages and entry.document_pages > 0 then
      page = math.floor(entry.page / entry.document_pages * pages)
    elseif not pages then
      return nil, "Select an edition with a page count"
    end
    page = math.max(0, math.min(page or 0, pages or page))
    if current_read and not current_read.finished_at then
      page = math.max(page, current_read.progress_pages or 0)
      if created or page ~= current_read.progress_pages then
        status = Api:updatePage(current_read.id, edition_id, page,
          created and entry.started_at or current_read.started_at)
      end
      progress_done = status ~= nil
    elseif not current_read or entry.status_id == HARDCOVER.STATUS.READING then
      status = Api:createRead(status.id, edition_id, page, entry.started_at)
      progress_done = status ~= nil
    end
    if not status then
      return nil, "Could not update reading progress"
    end
  end

  if entry.status_id and (entry.status_id ~= status.status_id or entry.privacy_setting_id) then
    status = Api:updateUserBook(linked.book_id, entry.status_id,
      entry.privacy_setting_id or status.privacy_setting_id, status.edition_id)
    if not status then
      return nil, "Could not update book status"
    end
  end
  return status, nil, progress_done
end

function Sync:drain()
  if running or not NetworkManager:isConnected() or not Api.enabled then
    return
  end
  local pending = self.settings:readSetting("pending_sync") or {}
  if not next(pending) then
    return
  end

  running = true
  local me = Api:me()
  if not me.id or not me.account_privacy_setting_id then
    running = false
    return
  end
  if self.settings:readSetting("user_credential_id") ~= Api.credential_id
      or self.settings:readSetting(SETTING.USER_ID) ~= me.id then
    self.settings:updateSetting(SETTING.USER_ID, me.id)
    self.settings:updateSetting("user_credential_id", Api.credential_id)
  end
  local acknowledged = {}

  local keys = {}
  for key in pairs(pending) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    local current_a = pending[a].credential_id == Api.credential_id
    local current_b = pending[b].credential_id == Api.credential_id
    if current_a ~= current_b then
      return current_b
    end
    return a < b
  end)
  for _, key in ipairs(keys) do
    if not NetworkManager:isConnected() or not Api.enabled then
      break
    end
    pending = self.settings:readSetting("pending_sync") or {}
    local entry = pending[key]
    if entry then
      local filename = entry.filename
      if not entry.account_id and entry.credential_id == Api.credential_id then
        entry.account_id = me.id
        self.settings:updateSetting("pending_sync", pending)
      end
      if not self.settings:fileSyncEnabled(filename) and not entry.status_id then
        pending[key] = nil
        self.settings:updateSetting("pending_sync", pending)
      else
        local ok, status, err, progress_done = pcall(self.send, self, filename, entry, me)
        if ok and status then
          pending = self.settings:readSetting("pending_sync") or {}
          local current = pending[key]
          if current == entry then
            pending[key] = nil
          elseif current and entry.status_revision and current.status_revision == entry.status_revision then
            current.status_id = nil
            current.privacy_setting_id = nil
            current.status_revision = nil
          end
          self.settings:updateSetting("pending_sync", pending)
          acknowledged[entry] = progress_done
          if self.on_synced then
            self.on_synced(filename, status)
          end
        else
          logger.warn("Hardcover update retained:", filename, ok and err or status)
        end
      end
    end
  end
  running = false
  return acknowledged
end

return Sync
