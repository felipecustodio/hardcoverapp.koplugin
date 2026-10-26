local SETTING = require("hardcover/lib/constants/settings")
local Api = require("hardcover/lib/hardcover_api")

local User = {}

function User:getId()
  local user_id = self.settings:readSetting(SETTING.USER_ID)
  if self.settings:readSetting("user_credential_id") ~= Api.credential_id then
    user_id = nil
  end
  if not user_id then
    local me = Api:me()
    user_id = me.id
    if user_id then
      self.settings:updateSetting(SETTING.USER_ID, user_id)
      self.settings:updateSetting("user_credential_id", Api.credential_id)
    end
  end

  return user_id
end

return User
