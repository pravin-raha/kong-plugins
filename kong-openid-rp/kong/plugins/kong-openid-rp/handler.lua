local BasePlugin = require "kong.plugins.base_plugin"
local access = require "kong.plugins.kong-openid-rp.access"

local Handler = BasePlugin:extend()

function Handler:new()
  Handler.super.new(self, "kong-openid-rp")
end

function Handler:access(conf)
  Handler.super.access(self)
  local response = access.execute(conf)
  if response ~= nil then
    return response
  end
end

return Handler