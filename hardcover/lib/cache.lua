local Api = require("hardcover/lib/hardcover_api")
local User = require("hardcover/lib/user")

local Cache = {}
Cache.__index = Cache

function Cache:new(o)
  return setmetatable(o, self)
end

function Cache:updateBookStatus(filename, status, privacy_setting_id)
  self.sync:enqueue(filename, {
    status_id = status,
    privacy_setting_id = privacy_setting_id,
  })
  self.request_sync()
end

function Cache:cacheUserBook()
  local status, errors = Api:findUserBook(self.settings:getLinkedBookId(), User:getId())
  if not errors then
    self.state.book_status = status or {}
  end

  return errors
end

return Cache
