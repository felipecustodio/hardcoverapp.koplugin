-- wrapper around hardcover_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Api = require("hardcover/lib/hardcover_api")
local Book = require("hardcover/lib/book")
local User = require("hardcover/lib/user")

local SETTING = require("hardcover/lib/constants/settings")

local cache = {}

local Hardcover = {}
Hardcover.__index = Hardcover

function Hardcover:new(o)
  return setmetatable(o, self)
end

function Hardcover:showLinkBookDialog(force_search, link_callback)
  local search_value, books, err = self:findBookOptions(force_search)

  if err then
    logger.err(err)
    return
  end

  self.dialog_manager:buildSearchDialog(
    "Select book",
    books,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      self:linkBook(book)
      link_callback(book)
    end,
    function(search)
      self.dialog_manager:updateSearchResults(search)
      return true
    end,
    search_value
  )
end

function Hardcover:cacheRandomBooks()
  local user_id = User:getId()

  local books, error = Api:getRandomToRead(user_id, 10)
  if error then
    UIManager:show(InfoMessage:new {
      text = _("Error fetching to-read list"),
      icon = "notice-warning",
      timeout = 2
    })
    return
  end

  cache.random_books = books
  return books
end

function Hardcover:showRandomBookDialog()
  self.wifi:wifiPrompt(function(wifi_enabled)
    local books = cache.random_books
    if not books then
      books = self:cacheRandomBooks()
    end

    if not cache.random_books or #cache.random_books == 0 then
      UIManager:show(Notification:new {
        text = "No books found on Want to Read list",
        timeout = 4
      })

      if wifi_enabled then
        UIManager:nextTick(function()
          self.wifi:wifiDisablePrompt()
        end)
      end

      return
    end

    self.dialog_manager:buildBookListDialog("Suggest a book", cache.random_books, function()
      books = self:cacheRandomBooks()
      if books then
        self.dialog_manager:updateRandomBooks(books)
      end
    end, wifi_enabled)
  end)
end

function Hardcover:updateCurrentBookStatus(status, privacy_setting_id)
  self.cache:updateBookStatus(self.ui.document.file, status, privacy_setting_id)
  if not self.state.book_status.id then
    self.dialog_manager:showError("Book status could not be updated")
  end
end

function Hardcover:changeBookVisibility(visibility)
  self.cache:cacheUserBook()

  if self.state.book_status.id then
    self:updateCurrentBookStatus(self.state.book_status.status_id, visibility)
  end
end

function Hardcover:linkBook(book)
  local filename = self.ui.document.file

  local delete = {}
  local clear_keys = { "book_id", "edition_id", "edition_format", "pages", "title" }
  for _, key in ipairs(clear_keys) do
    if book[key] == nil then
      table.insert(delete, key)
    end
  end

  local new_settings = {
    book_id = book.book_id,
    edition_id = book.edition_id,
    edition_format = Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete
  }

  self.settings:updateBookSetting(filename, new_settings)
  self.cache:cacheUserBook()

  if book.book_id and self.state.book_status.id then
    if new_settings.edition_id and new_settings.edition_id ~= self.state.book_status.edition_id then
      -- update edition
      self.state.book_status = Api:updateUserBook(
        new_settings.book_id,
        self.state.book_status.status_id,
        self.state.book_status.privacy_setting_id,
        new_settings.edition_id
      ) or {}
    end
  end

  return true
end

-- could be moved to book search model
function Hardcover:findBookOptions(force_search)
  local props = self.ui.document:getProps()
  local identifiers = Book:parseIdentifiers(props.identifiers)
  local user_id = User:getId()

  if not force_search then
    local book_lookup = Api:findBookByIdentifiers(identifiers, user_id)
    if book_lookup then
      return nil, { book_lookup }
    end
  end

  local title = props.title
  if not title or title == "" then
    local _dir, path = util.splitFilePathName(self.ui.document.file)
    local filename, _suffix = util.splitFileNameSuffix(path)

    title = filename:gsub("_", " ")
  end
  local result, err = Api:findBooks(title, props.authors, user_id)
  return title, result, err
end

function Hardcover:autolinkBook(book)
  if not book then
    return
  end

  local linked = self:linkBook(book)
  if linked then
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end
end

local function matchText(text)
  return (text or ""):lower():gsub("%d+", function(number)
    return tostring(tonumber(number))
  end):gsub("[%p%s]", "")
end

function Hardcover:findAutomaticBook(props, user_id)
  user_id = user_id or User:getId()
  local identifiers = Book:parseIdentifiers(props.identifiers)
  if not self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) then
    identifiers.book_slug = nil
    identifiers.edition_id = nil
  end
  if not self.settings:readSetting(SETTING.LINK_BY_ISBN) then
    identifiers.isbn_10 = nil
    identifiers.isbn_13 = nil
  end
  local book = Api:findBookByIdentifiers(identifiers, user_id)
  if book then
    return book
  end
  if not props.title or not props.authors or not self.settings:readSetting(SETTING.LINK_BY_TITLE) then
    return
  end
  local results, err = Api:findBooks(props.title, props.authors, user_id)
  if not results then
    return nil, err
  end
  local match
  for _, candidate in ipairs(results) do
    if matchText(candidate.title) == matchText(props.title) then
      for _, contribution in ipairs(candidate.contributions or {}) do
        local author = contribution.author and contribution.author.name
        for name in props.authors:gmatch("[^;\n]+") do
          if author and matchText(author) == matchText(name) then
            if match and match.book_id ~= candidate.book_id then
              return nil, "Several Hardcover books match; use Link book"
            end
            match = candidate
          end
        end
      end
    end
  end
  return match
end

function Hardcover:tryAutolink()
  if not self.ui.document or self.settings:bookLinked() then
    return
  end
  local document = self.ui.document
  local props = document:getProps()
  self.wifi:withWifi(function()
    local book = self:findAutomaticBook(props)
    if self.ui.document == document then
      self:autolinkBook(book)
    end
  end)
end

return Hardcover
