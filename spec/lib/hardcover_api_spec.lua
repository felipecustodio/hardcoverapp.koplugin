describe("Hardcover API acknowledgments", function()
  local api, saved, content, reply, online
  local modules = {
    "hardcover/lib/hardcover_api", "hardcover_config", "logger", "socket.http", "ltn12",
    "json", "ffi/util", "ffi/sha2", "ui/trapper", "ui/network/manager", "socketutil", "hardcover_version",
    "hardcover/lib/user",
  }
  before_each(function()
    saved = {}
    for _, name in ipairs(modules) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
    online = true
    content = "200:valid"
    reply = { data = { user_books = {} } }
    package.loaded.hardcover_config = { token = "test-credential" }
    package.loaded.logger = { dbg = function() end, warn = function() end }
    package.loaded["socket.http"] = {}
    package.loaded.ltn12 = {}
    package.loaded.json = { decode = setmetatable({}, { __call = function(_, body)
      if body == "invalid" then error("Invalid JSON") end
      return reply
    end }) }
    package.loaded["ffi/util"] = { template = function(value) return value end }
    package.loaded["ffi/sha2"] = { sha256 = function() return "test-credential-digest" end }
    package.loaded["ui/trapper"] = { dismissableRunInSubprocess = function() return true, content end }
    package.loaded["ui/network/manager"] = { isConnected = function() return online end }
    package.loaded.socketutil = {}
    package.loaded.hardcover_version = { 0, 4, 0 }
    api = require("hardcover/lib/hardcover_api")
  end)
  after_each(function()
    for _, name in ipairs(modules) do package.loaded[name] = saved[name] end
  end)

  it("distinguishes a failed lookup from an absent library entry", function()
    online = false
    local book, err = api:findUserBook(1, 7)
    assert.is_nil(book)
    assert.is_not_nil(err)
    online = true
    book, err = api:findUserBook(1, 7)
    assert.is_nil(book)
    assert.is_nil(err)
  end)

  it("rejects partial GraphQL results instead of acknowledging a mutation", function()
    reply = { data = { user_books = {} }, errors = {{ message = "Permission denied" }} }
    local book, err = api:findUserBook(1, 7)
    assert.is_nil(book)
    assert.is_not_nil(err)
  end)

  it("retains failed HTTP and malformed responses as errors", function()
    for _, response in ipairs({ "503:valid", "200:invalid", "timeout:", "200:" }) do
      content = response
      if response == "200:" then reply = nil end
      local book, err = api:findUserBook(1, 7)
      assert.is_nil(book)
      assert.is_not_nil(err)
    end
  end)

  it("returns an inserted read so a retry does not create another read", function()
    reply = { data = { insert_user_book_read = { user_book_read = {
      id = 9, progress_pages = 40, edition_id = 10, started_at = "2026-10-26",
      user_book = { id = 8, book_id = 1, status_id = 2 },
    } } } }
    local book = api:createRead(8, 10, 40, "2026-10-26")
    assert.are.equal(2, book.status_id)
    assert.are.equal(9, book.user_book_reads[1].id)
    assert.are.equal(40, book.user_book_reads[1].progress_pages)
  end)

  it("does not acknowledge a rejected progress mutation", function()
    reply = { data = { update_user_book_read = { error = "Invalid edition" } } }
    assert.is_nil(api:updatePage(9, 10, 40, "2026-10-26"))
  end)

  it("replaces a cached account only after authenticating the current credential", function()
    local User = require("hardcover/lib/user")
    local data = { user_id = 99, user_credential_id = "old-credential" }
    User.settings = {
      readSetting = function(_,key) return data[key] end,
      updateSetting = function(_,key,value) data[key] = value end,
    }
    reply = { data = { me = {{ id = 7, account_privacy_setting_id = 2 }} } }
    assert.are.equal(7, User:getId())
    assert.are.equal(7, data.user_id)
    assert.are.equal(api.credential_id, data.user_credential_id)
  end)

  it("does not use another credential's cached account while authentication fails", function()
    local User = require("hardcover/lib/user")
    local data = { user_id = 99, user_credential_id = "old-credential" }
    User.settings = {
      readSetting = function(_,key) return data[key] end,
      updateSetting = function(_,key,value) data[key] = value end,
    }
    content = "503:valid"
    assert.is_nil(User:getId())
    assert.are.equal(99, data.user_id)
    assert.are.equal("old-credential", data.user_credential_id)
  end)
end)
