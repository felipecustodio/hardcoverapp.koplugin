describe("durable Hardcover synchronization", function()
  local Sync, settings, sync, api, remote, online, disk, saved, writes, match
  local modules = { "hardcover/lib/sync", "hardcover/lib/hardcover_api", "ui/network/manager", "logger" }
  local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
  end
  local function queued(file)
    return settings:readSetting("pending_sync")[api.credential_id .. ":" .. file]
  end
  local function restart()
    settings = { data = copy(disk) }
    function settings:readSetting(key) return self.data[key] end
    function settings:updateSetting(key, value)
      self.data[key] = value
      disk = copy(self.data)
    end
    function settings:readBookSettings(file) return self.data.books[file] end
    function settings:updateBookSetting(file, update)
      local book = self.data.books[file] or {}
      for key, value in pairs(update) do book[key] = value end
      self.data.books[file] = book
      disk = copy(self.data)
    end
    function settings:fileSyncEnabled(file)
      local book = self.data.books[file] or {}
      return book.sync ~= false
    end
    sync = Sync:new {
      settings = settings,
      hardcover = { findAutomaticBook = function() return copy(match) end },
    }
  end
  local function reading(book_id, page)
    return {
      id = book_id + 100, book_id = book_id, status_id = 2,
      edition_id = 10, privacy_setting_id = 3, rating = 4.5,
      user_book_reads = {{ id = book_id + 200, edition_id = 10,
        progress_pages = page, started_at = "2026-09-01" }},
    }
  end
  before_each(function()
    saved = {}
    for _, name in ipairs(modules) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
    online, remote, writes = false, {}, 0
    disk = { user_id = 7, user_credential_id = "original-credential",
      books = { a = { book_id = 1, edition_id = 10, pages = 200 } } }
    match = { book_id = 2, edition_id = 10, title = "Second book", pages = 200 }
    api = { enabled = true, credential_id = "original-credential" }
    function api:me() return { id = 7, account_privacy_setting_id = 2 } end
    function api:findUserBook(id) return copy(remote[id]) end
    function api:updateUserBook(id, status, privacy, edition)
      writes = writes + 1
      local book = remote[id] or reading(id, 0)
      book.status_id, book.privacy_setting_id, book.edition_id = status, privacy, edition
      if status == 3 then book.user_book_reads[#book.user_book_reads].finished_at = "2026-10-26" end
      remote[id] = book
      return copy(book)
    end
    function api:updatePage(id, edition, page, started)
      writes = writes + 1
      for _, book in pairs(remote) do
        for _, read in ipairs(book.user_book_reads) do
          if read.id == id then
            read.edition_id, read.progress_pages, read.started_at = edition, page, started
            return copy(book)
          end
        end
      end
    end
    function api:createRead(id, edition, page, started)
      writes = writes + 1
      for _, book in pairs(remote) do
        if book.id == id then
          book.user_book_reads[#book.user_book_reads + 1] = {
            id = id + 1000, edition_id = edition, progress_pages = page, started_at = started,
          }
          return copy(book)
        end
      end
    end
    function api:hydrateBookFromEdition() return { pages = 400 } end
    package.loaded["hardcover/lib/hardcover_api"] = api
    package.loaded["ui/network/manager"] = { isConnected = function() return online end }
    package.loaded.logger = { warn = function() end }
    Sync = require("hardcover/lib/sync")
    restart()
  end)
  after_each(function()
    for _, name in ipairs(modules) do package.loaded[name] = saved[name] end
  end)

  it("adds a missing book with account privacy and restores its offline page after restart", function()
    sync:enqueue("b", { props = { title = "Second book" }, page = 30, document_pages = 100 })
    sync:drain()
    assert.is_nil(remote[2])
    restart()
    online = true
    sync:drain()
    assert.are.equal(2, remote[2].status_id)
    assert.are.equal(2, remote[2].privacy_setting_id)
    assert.are.equal(60, remote[2].user_book_reads[1].progress_pages)
    assert.are.equal(2, settings:readBookSettings("b").book_id)
    assert.is_false(sync:pending())
  end)

  it("keeps only the latest offline position across restart", function()
    remote[1] = reading(1, 10)
    sync:enqueue("a", { page = 10, document_pages = 100 })
    sync:enqueue("a", { page = 40, document_pages = 100 })
    restart()
    online = true
    sync:drain()
    assert.are.equal(80, remote[1].user_book_reads[1].progress_pages)
    assert.are.equal("2026-09-01", remote[1].user_book_reads[1].started_at)
    assert.are.equal(4.5, remote[1].rating)
    assert.is_false(sync:pending())
  end)

  it("preserves existing non-reading status, edition, privacy and history on open", function()
    for _, status in ipairs({ 1, 3, 5 }) do
      remote[1] = reading(1, 180)
      remote[1].status_id = status
      local before = copy(remote[1])
      sync:enqueue("a", { page = 1, document_pages = 100 })
      online = true
      sync:drain()
      assert.are.same(before, remote[1])
    end
    assert.are.equal(0, writes)
  end)

  it("does not treat a failed library lookup as a missing book", function()
    api.findUserBook = function() return nil, { status = 503 } end
    sync:enqueue("a", { page = 20, document_pages = 100 })
    online = true
    sync:drain()
    assert.are.equal(0, writes)
    assert.is_true(sync:pending())
  end)

  it("retains failed progress and retries after another restart", function()
    remote[1] = reading(1, 10)
    local update = api.updatePage
    api.updatePage = function() return nil end
    sync:enqueue("a", { page = 20, document_pages = 100 })
    online = true
    sync:drain()
    assert.is_true(sync:pending())
    assert.are.equal(10, remote[1].user_book_reads[1].progress_pages)
    restart()
    api.updatePage = update
    sync:drain()
    assert.are.equal(40, remote[1].user_book_reads[1].progress_pages)
    assert.is_false(sync:pending())
  end)

  it("does not lower remote progress during replay", function()
    remote[1] = reading(1, 150)
    sync:enqueue("a", { page = 10, document_pages = 100 })
    online = true
    sync:drain()
    assert.are.equal(150, remote[1].user_book_reads[1].progress_pages)
    assert.are.equal(0, writes)
  end)

  it("maps progress to the existing remote edition without replacing it", function()
    remote[1] = reading(1, 10)
    remote[1].edition_id = 20
    remote[1].user_book_reads[1].edition_id = 20
    sync:enqueue("a", { page = 25, document_pages = 100, mapped_page = 50, edition_id = 10 })
    online = true
    sync:drain()
    assert.are.equal(20, remote[1].edition_id)
    assert.are.equal(100, remote[1].user_book_reads[1].progress_pages)
    assert.are.equal(3, remote[1].privacy_setting_id)
  end)

  it("sends queued progress before an explicit completion and does not reopen it", function()
    remote[1] = reading(1, 10)
    sync:enqueue("a", { page = 95, document_pages = 100 })
    sync:enqueue("a", { status_id = 3 })
    restart()
    online = true
    sync:drain()
    assert.are.equal(3, remote[1].status_id)
    assert.are.equal(190, remote[1].user_book_reads[1].progress_pages)
    sync:enqueue("a", { page = 1, document_pages = 100 })
    sync:drain()
    assert.are.equal(3, remote[1].status_id)
    assert.are.equal(190, remote[1].user_book_reads[1].progress_pages)
  end)

  it("retains another account's updates without changing that account's library", function()
    sync:enqueue("a", { page = 20, document_pages = 100 })
    api.me = function() return { id = 8, account_privacy_setting_id = 2 } end
    online = true
    sync:drain()
    assert.are.equal(0, writes)
    assert.is_true(sync:pending())
  end)

  it("does not lose a newer position queued while a request is running", function()
    remote[1] = reading(1, 10)
    local update = api.updatePage
    api.updatePage = function(self, ...)
      sync:enqueue("a", { page = 40, document_pages = 100 })
      return update(self, ...)
    end
    sync:enqueue("a", { page = 20, document_pages = 100 })
    online = true
    sync:drain()
    assert.are.equal(40, remote[1].user_book_reads[1].progress_pages)
    assert.is_true(sync:pending())
    api.updatePage = update
    sync:drain()
    assert.are.equal(80, remote[1].user_book_reads[1].progress_pages)
    assert.is_false(sync:pending())
  end)

  it("does not resend a successful mutation whose response was lost", function()
    remote[1] = reading(1, 10)
    local update = api.updatePage
    api.updatePage = function(self, ...)
      update(self, ...)
      return nil
    end
    sync:enqueue("a", { page = 20, document_pages = 100 })
    online = true
    sync:drain()
    assert.is_true(sync:pending())
    restart()
    api.updatePage = update
    sync:drain()
    assert.are.equal(1, writes)
    assert.are.equal(40, remote[1].user_book_reads[1].progress_pages)
    assert.is_false(sync:pending())
  end)

  it("drops automatic updates after tracking is disabled", function()
    sync:enqueue("a", { page = 20, document_pages = 100 })
    settings:updateBookSetting("a", { sync = false })
    online = true
    sync:drain()
    assert.are.equal(0, writes)
    assert.is_false(sync:pending())
  end)

  it("keeps an unmatched book without blocking other pending books", function()
    remote[1] = reading(1, 10)
    match = nil
    sync:enqueue("a", { page = 20, document_pages = 100 })
    sync:enqueue("b", { props = { title = "Unknown" }, page = 20, document_pages = 100 })
    online = true
    sync:drain()
    assert.are.equal(40, remote[1].user_book_reads[1].progress_pages)
    assert.is_nil(queued("a"))
    assert.is_not_nil(queued("b"))
  end)

  it("does not replay first-run offline activity with different credentials", function()
    settings:updateSetting("user_id", nil)
    sync:enqueue("a", { page = 20, document_pages = 100 })
    restart()
    api.credential_id = "another-credential"
    online = true
    sync:drain()
    assert.are.equal(0, writes)
    assert.is_true(sync:pending())
  end)

  it("serializes drains from separate reader and file browser instances", function()
    remote[1] = reading(1, 10)
    local second = Sync:new { settings = settings, hardcover = sync.hardcover }
    local lookup = api.findUserBook
    local overlap = false
    api.findUserBook = function(self, id)
      if not overlap then
        overlap = true
        second:drain()
      end
      return lookup(self, id)
    end
    sync:enqueue("a", { page = 20, document_pages = 100 })
    online = true
    sync:drain()
    assert.are.equal(1, writes)
    assert.are.equal(40, remote[1].user_book_reads[1].progress_pages)
    assert.is_false(sync:pending())
  end)

  it("acknowledges a status without repeating it from a newer progress snapshot", function()
    remote[1] = reading(1, 10)
    local update = api.updateUserBook
    api.updateUserBook = function(self, ...)
      sync:enqueue("a", { page = 30, document_pages = 100 })
      return update(self, ...)
    end
    sync:enqueue("a", { status_id = 3 })
    online = true
    sync:drain()
    assert.is_true(sync:pending())
    assert.is_nil(queued("a").status_id)
    remote[1].status_id = 5
    api.updateUserBook = update
    sync:drain()
    assert.are.equal(5, remote[1].status_id)
    assert.are.equal(1, writes)
  end)

  it("retains a newer explicit status while acknowledging an older one", function()
    remote[1] = reading(1, 10)
    local update = api.updateUserBook
    api.updateUserBook = function(self, ...)
      sync:enqueue("a", { status_id = 5 })
      return update(self, ...)
    end
    sync:enqueue("a", { status_id = 3 })
    online = true
    sync:drain()
    assert.are.equal(5, queued("a").status_id)
    api.updateUserBook = update
    sync:drain()
    assert.are.equal(5, remote[1].status_id)
    assert.is_false(sync:pending())
  end)

  it("does not merge offline activity from different credentials", function()
    local accounts = { [7] = { [1] = reading(1, 0) }, [8] = { [1] = reading(1, 0) } }
    local account = 8
    api.me = function()
      remote = accounts[account]
      return { id = account, account_privacy_setting_id = 2 }
    end
    sync:enqueue("a", { page = 20, document_pages = 100 })
    api.credential_id = "another-credential"
    sync:enqueue("a", { page = 40, document_pages = 100 })
    online = true
    sync:drain()
    assert.are.equal(0, accounts[7][1].user_book_reads[1].progress_pages)
    assert.are.equal(80, accounts[8][1].user_book_reads[1].progress_pages)
    assert.is_true(sync:pending())
    account = 7
    api.credential_id = "original-credential"
    sync:drain()
    assert.are.equal(40, accounts[7][1].user_book_reads[1].progress_pages)
    assert.are.equal(80, accounts[8][1].user_book_reads[1].progress_pages)
    assert.is_false(sync:pending())
  end)

  it("does not label a new credential's activity with a cached old account ID", function()
    api.credential_id = "another-credential"
    sync:enqueue("a", { page = 40, document_pages = 100 })
    restart()
    api.credential_id = "original-credential"
    online = true
    sync:drain()
    assert.are.equal(0, writes)
    assert.is_true(sync:pending())
  end)

  it("retrieves a missing local page count from the existing reading edition", function()
    settings.data.books.a.pages = nil
    remote[1] = reading(1, 10)
    sync:enqueue("a", { page = 20, document_pages = 100 })
    online = true
    sync:drain()
    assert.are.equal(80, remote[1].user_book_reads[1].progress_pages)
    assert.is_false(sync:pending())
  end)

  it("does not acknowledge skipped progress on a non-reading book", function()
    remote[1] = reading(1, 10)
    remote[1].status_id = 3
    local entry = sync:enqueue("a", { page = 20, document_pages = 100 })
    online = true
    local acknowledged = sync:drain()
    assert.is_false(acknowledged[entry])
    assert.are.equal(10, remote[1].user_book_reads[1].progress_pages)
    assert.are.equal(0, writes)
  end)
end)
