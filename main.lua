local _ = require("gettext")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FileManagerUtil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local math = require("math")

local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("hardcover/lib/table_util")
local Api = require("hardcover/lib/hardcover_api")
local AutoWifi = require("hardcover/lib/auto_wifi")
local Cache = require("hardcover/lib/cache")
local debounce = require("hardcover/lib/debounce")
local Hardcover = require("hardcover/lib/hardcover")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local PageMapper = require("hardcover/lib/page_mapper")
local Sync = require("hardcover/lib/sync")
local throttle = require("hardcover/lib/throttle")
local User = require("hardcover/lib/user")

local DialogManager = require("hardcover/lib/ui/dialog_manager")
local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

local HardcoverApp = WidgetContainer:extend {
  name = "hardcoverappsync",
  is_doc_only = false,
  state = nil,
  settings = nil,
  width = nil,
  enabled = true
}

local HIGHLIGHT_MENU_NAME = "13_0_make_hardcover_highlight_item"
local observed_status = {}
local saveSummary = FileManagerUtil.saveSummary
FileManagerUtil.saveSummary = function(doc_settings_or_file, summary)
  local file = type(doc_settings_or_file) == "table"
      and doc_settings_or_file:readSetting("doc_path") or doc_settings_or_file
  local previous = observed_status[file]
  if not previous then
    previous = (DocSettings:open(file):readSetting("summary") or {}).status
  end
  local settings = saveSummary(doc_settings_or_file, summary)
  observed_status[file] = summary.status
  if previous ~= summary.status then
    UIManager:broadcastEvent(Event:new("HardcoverBookStatusChanged", file, settings.data))
  end
  return settings
end


function HardcoverApp:onDispatcherRegisterActions()
  Dispatcher:registerAction("hardcover_link", {
    category = "none",
    event = "HardcoverLink",
    title = _("Hardcover: Link book"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_track", {
    category = "none",
    event = "HardcoverTrack",
    title = _("Hardcover: Track progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_stop_track", {
    category = "none",
    event = "HardcoverStopTrack",
    title = _("Hardcover: Stop tracking progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_update_progress", {
    category = "none",
    event = "HardcoverUpdateProgress",
    title = _("Hardcover: Update progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_random_books", {
    category = "none",
    event = "HardcoverSuggestBook",
    title = _("Hardcover: Suggest a book"),
    general = true,
  })
end

function HardcoverApp:init()
  self.closed = false
  self.suspended = false
  self.state = {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
  }
  --logger.warn("HARDCOVER app init")
  self.settings = HardcoverSettings:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_settings.lua"),
    self.ui
  )
  self.settings:subscribe(function(field, change, original_value) self:onSettingsChanged(field, change, original_value) end)

  User.settings = self.settings
  Api.on_error = function(err)
    if not err or not self.enabled then
      return
    end

    if err == HARDCOVER.ERROR.TOKEN or _t.dig(err, "extensions", "code") == HARDCOVER.ERROR.JWT or (err.message and string.find(err.message, "JWT")) then
      self:disable()
      UIManager:show(InfoMessage:new {
        text = "Your Hardcover API key is not valid or has expired. Please update it and restart",
        icon = "notice-warning",
      })
    end
  end

  self.cache = Cache:new {
    settings = self.settings,
    state = self.state
  }
  self.page_mapper = PageMapper:new {
    state = self.state,
    ui = self.ui,
  }
  self.wifi = AutoWifi:new {
    settings = self.settings
  }
  self.dialog_manager = DialogManager:new {
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }
  self.hardcover = Hardcover:new {
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }
  self.sync = Sync:new {
    settings = self.settings,
    hardcover = self.hardcover,
    on_synced = function(filename, status)
      if not self.closed and not self.suspended and filename == self.settings:getFilePath() then
        self.state.book_status = status
      end
    end,
  }
  self.cache.sync = self.sync
  self.cache.request_sync = function() self:startReadCache() end

  self.menu = HardcoverMenu:new {
    enabled = true,

    cache = self.cache,
    dialog_manager = self.dialog_manager,
    hardcover = self.hardcover,
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
  }

  self:onDispatcherRegisterActions()
  self:initializePageUpdate()
  self.ui.menu:registerToMainMenu(self)
  UIManager:unschedule(self.startReadCache)
  UIManager:scheduleIn(2, self.startReadCache, self)
end

function HardcoverApp:_bookSettingChanged(setting, key)
  return setting[key] ~= nil or _t.contains(_t.dig(setting, "_delete"), key)
end

-- Open note dialog
--
-- UIManager:broadcastEvent(Event:new("HardcoverNote", note_params))
--
-- note_params can contain:
--   text: Value will prepopulate the note section
--   page_number: The local page number
--   remote_page (optional): The mapped page in the linked book edition
--   note_type: one of "quote" or "note"
function HardcoverApp:onHardcoverNote(note_params)
  -- open journal dialog
  self.dialog_manager:journalEntryForm(
    note_params.text,
    self.ui.document,
    note_params.page_number,
    self.settings:pages(),
    note_params.remote_page,
    note_params.note_type or "quote"
  )
end

function HardcoverApp:disable()
  self.enabled = false
  Api.enabled = false
  if self.menu then
    self.menu.enabled = false
  end
  self:registerHighlight()
end

function HardcoverApp:onHardcoverLink()
  self.hardcover:showLinkBookDialog(false, function(book)
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end)
end

function HardcoverApp:onHardcoverTrack()
  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function HardcoverApp:onHardcoverStopTrack()
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
end

function HardcoverApp:onHardcoverUpdateProgress()
  if self.ui.document and self.settings:bookLinked() then
    self:updatePageNow(function(result)
      if result then
        UIManager:show(Notification:new {
          text = _("Progress updated")
        })
      else
        logger.warn("Unsuccessful updating page progress", self.ui.document.file)
      end
    end)
  else
    logger.warn(self.state.book_status)
    local error
    if not self.ui.document then
      error = "No book active"
    elseif not self.state.book_status.id then
      error = "Book has not been mapped"
    end

    local error_message = error and "Unable to update reading progress: " .. error or "Unable to update reading progress"
    UIManager:show(InfoMessage:new {
      text = error_message,
      icon = "notice-warning",
    })
  end
end

function HardcoverApp:onHardcoverSuggestBook()
  self.hardcover:showRandomBookDialog()
end

function HardcoverApp:onSettingsChanged(field, change, original_value)
  if field == SETTING.BOOKS and change.filename == self.settings:getFilePath() then
    local book_settings = change.config
    if self:_bookSettingChanged(book_settings, "sync") then
      if book_settings.sync then
        if not self.state.book_status.id then
          self:startReadCache()
        end
      else
        self:cancelPendingUpdates()
      end
    end

    if self:_bookSettingChanged(book_settings, "book_id") then
      self.state.book_status = {}
      self:registerHighlight()
      UIManager:scheduleIn(1, self.startReadCache, self)
    end
  elseif field == SETTING.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_HARDCOVER or field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_TITLE then
    if change then
      self.hardcover:tryAutolink()
    end
  end
end

function HardcoverApp:queueCurrentProgress()
  if not self.enabled or self.closed or not self.ui.document or not self.settings:syncEnabled() then
    return
  end
  local document = self.ui.document
  local props = document:getProps()
  local page = self.ui:getCurrentPage()
  local pages = self.settings:pages()
  local summary = self.ui.doc_settings:readSetting("summary") or {}
  if self.state.local_status and summary.status ~= self.state.local_status then
    self:onHardcoverBookStatusChanged(document.file, { summary = summary, doc_props = props })
  end
  self.state.local_status = summary.status
  observed_status[document.file] = summary.status
  return self.sync:enqueue(document.file, {
    props = {
      title = props.title,
      authors = props.authors,
      identifiers = props.identifiers,
    },
    page = page,
    document_pages = document:getPageCount(),
    mapped_page = pages and pages > 0 and self.page_mapper:getMappedPage(page, document:getPageCount(), pages) or nil,
    edition_id = self.settings:getLinkedEditionId(),
  })
end

function HardcoverApp:_handlePageUpdate()
  self:startReadCache()
end

function HardcoverApp:initializePageUpdate()
  local track_frequency = math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60

  HardcoverApp._throttledHandlePageUpdate, HardcoverApp._cancelPageUpdate = throttle(
    track_frequency,
    HardcoverApp._handlePageUpdate
  )

  HardcoverApp.onPageUpdate, HardcoverApp._cancelPageUpdateEvent = debounce(2, HardcoverApp.pageUpdateEvent)
end

function HardcoverApp:pageUpdateEvent(page)
  self.state.last_page = self.state.page
  self.state.page = page

  if not self.enabled or not self.settings:syncEnabled() then
    return
  end
  self:queueCurrentProgress()
  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()

  if self.settings:trackByTime() then
    self:_throttledHandlePageUpdate()
  elseif self.settings:trackByProgress() and self.state.last_page then
    local percent_interval = self.settings:trackPercentageInterval()

    local previous_percent = self.page_mapper:getRemotePagePercent(
      self.state.last_page,
      document_pages,
      remote_pages
    )

    local current_percent = self.page_mapper:getRemotePagePercent(
      self.state.page,
      document_pages,
      remote_pages
    )

    local last_compare = math.floor(previous_percent * 100 / percent_interval)
    local current_compare = math.floor(current_percent * 100 / percent_interval)

    if last_compare ~= current_compare then
      self:_handlePageUpdate()
    end
  end
end

function HardcoverApp:onPosUpdate(_, page)
  self:pageUpdateEvent(page)
end

function HardcoverApp:onUpdatePos()
  self.page_mapper:cachePageMap()
end

function HardcoverApp:onReaderReady()
  --logger.warn("HARDCOVER on ready")

  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()
  self.state.link_required = false
  self.state.local_status = (self.ui.doc_settings:readSetting("summary") or {}).status
  self:queueCurrentProgress()

  if self.ui.document and (self.settings:syncEnabled() or (not self.settings:bookLinked() and self.settings:autolinkEnabled())) then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end
end

function HardcoverApp:cancelPendingUpdates()
  if self._cancelPageUpdate then
    self:_cancelPageUpdate()
  end

  if self._cancelPageUpdateEvent then
    self:_cancelPageUpdateEvent()
  end
end

function HardcoverApp:onCloseDocument()
  self:queueCurrentProgress()
  self.closed = true
  UIManager:unschedule(self.startReadCache)
  self:cancelPendingUpdates()
  self.state.book_status = {}
  self.state.page_map = nil
end

function HardcoverApp:onCloseWidget()
  self.closed = true
  UIManager:unschedule(self.startReadCache)
  self:cancelPendingUpdates()
end

function HardcoverApp:onSuspend()
  self:queueCurrentProgress()
  self.suspended = true
  UIManager:unschedule(self.startReadCache)
  self:cancelPendingUpdates()
end

function HardcoverApp:onResume()
  if self.closed then
    return
  end
  self.suspended = false
  UIManager:scheduleIn(2, self.startReadCache, self)
end

function HardcoverApp:updatePageNow(callback)
  local entry = self:queueCurrentProgress()
  self:startReadCache(function(acknowledged)
    if callback then
      callback(acknowledged and acknowledged[entry] and self.state.book_status)
    end
  end)
end

function HardcoverApp:onNetworkDisconnecting()
  self:queueCurrentProgress()
  UIManager:unschedule(self.startReadCache)
  self:cancelPendingUpdates()
end

function HardcoverApp:onNetworkConnected()
  self:startReadCache()
end

function HardcoverApp:onEndOfBook()
  local file_path = self.ui.document.file

  if not self.settings:fileSyncEnabled(file_path) then
    return
  end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end

  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"

    if action == "pop-up" then
      mark_read = 'later'
    end
  end

  if not mark_read then
    return
  end

  local marker = function()
    self.cache:updateBookStatus(file_path, HARDCOVER.STATUS.FINISHED)
  end

  if mark_read == 'later' then
    UIManager:scheduleIn(30, function()
      local status = "reading"
      if DocSettings:hasSidecarFile(file_path) then
        local summary = DocSettings:open(file_path):readSetting("summary")
        if summary and summary.status and summary.status ~= "" then
          status = summary.status
        end
      end
      if status == "complete" then
        marker()
      end
    end)
  else
    self:queueCurrentProgress()
    marker()
  end
end

function HardcoverApp:syncFileUpdates(filename)
  return self.enabled and not self.closed and self.settings:fileSyncEnabled(filename)
end

function HardcoverApp:onHardcoverBookStatusChanged(file, doc_settings)
  if not self:syncFileUpdates(file) or not doc_settings or not doc_settings.summary then
    return
  end

  local status
  if doc_settings.summary.status == "complete" then
    status = HARDCOVER.STATUS.FINISHED
  elseif doc_settings.summary.status == "reading" then
    status = HARDCOVER.STATUS.READING
  elseif doc_settings.summary.status == "abandoned" then
    status = HARDCOVER.STATUS.DNF
  end

  if status then
    if file == self.settings:getFilePath() then
      self.state.local_status = doc_settings.summary.status
    end
    local props = doc_settings.doc_props
    if not props then
      local BookInfo = require("apps/filemanager/filemanagerbookinfo")
      props = BookInfo.getDocProps({ ui = self.ui }, file)
    end
    self.sync:enqueue(file, { props = props, status_id = status })
    UIManager:nextTick(self.startReadCache, self)
  end
end

function HardcoverApp:startReadCache(callback)
  if not self.enabled or self.closed or self.suspended then
    return
  end
  UIManager:unschedule(self.startReadCache)
  self.wifi:withWifi(function()
    if self.closed or self.suspended or not NetworkManager:isConnected() then
      return
    end
    Trapper:wrap(function()
      if self.ui.document and not self.settings:syncEnabled() and not self.settings:bookLinked()
          and self.settings:autolinkEnabled() then
        self.hardcover:tryAutolink()
      end
      local acknowledged = self.sync:drain()
      if self.closed or self.suspended then
        return
      end
      if self.ui.document and self.settings:bookLinked() then
        self.cache:cacheUserBook()
      end
      if self.closed or self.suspended then
        return
      end
      if callback then
        callback(acknowledged)
      end
      if self.sync:pending() then
        UIManager:scheduleIn(60, self.startReadCache, self)
        if self.ui.document and not self.settings:bookLinked() and not self.state.link_required then
          self.state.link_required = true
          UIManager:show(Notification:new {
            text = _("Could not link automatically. Use Hardcover > Link book."),
          })
        end
      end
    end)
  end)
end

function HardcoverApp:registerHighlight()
  self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_MENU_NAME)

  if self.enabled and self.settings:bookLinked() then
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_MENU_NAME, function(this)
      return {
        text_func = function()
          return _("Hardcover quote")
        end,
        callback = function()
          local selected_text = this.selected_text
          local raw_page = selected_text.pos0.page
          if not raw_page then
            raw_page = self.view.document:getPageFromXPointer(selected_text.pos0)
          end
          -- open journal dialog
          self:onHardcoverNote({
            text = selected_text.text,
            page_number = raw_page,
            note_type = "quote"
          })

          this:onClose()
        end,
      }
    end)
  end
end

function HardcoverApp:addToMainMenu(menu_items)
  menu_items.hardcover = self.menu:mainMenu()
end

return HardcoverApp
