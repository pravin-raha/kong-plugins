local oxd = require "kong.plugins.kong-openid-rp.oxdclient"
local responses = require "kong.tools.responses"
local stringy = require "stringy"
local singletons = require "kong.singletons"
local cache = require "kong.tools.database_cache"
local constants = require "kong.constants"
local USER_INFO = "USER_INFO"
local VALID_REQUEST = "VALID_REQUEST"
local OXDS = "oxds:"

local function isempty(s)
    return s == nil or s == ''
end

local _M = {}

local function getPath()
    local path = ngx.var.request_uri
    local indexOf = string.find(path, "?")
    if indexOf ~= nil then
        return string.sub(path, 1, (indexOf - 1))
    end
    return path
end

local function load_oxd_by_oxd_id(oxd_id)
    local creds, err = singletons.dao.oxds:find_all {
        oxd_id = oxd_id
    }
    if not creds then
        return nil, err
    end
    return creds[1]
end

local function load_consumer(consumer_id, anonymous)
    local result, err = singletons.dao.consumers:find { id = consumer_id }
    if not result then
        if anonymous and not err then
            err = 'anonymous consumer "' .. consumer_id .. '" not found'
        end
        return nil, err
    end
    return result
end

local function set_consumer(consumer, credential)
    ngx.header[constants.HEADERS.CONSUMER_ID] = consumer.id
    ngx.header[constants.HEADERS.CONSUMER_CUSTOM_ID] = consumer.custom_id
    ngx.header[constants.HEADERS.CONSUMER_USERNAME] = consumer.username
    ngx.ctx.authenticated_consumer = consumer
    if credential then
        ngx.header["X-OXD-ID"] = credential.oxd_id
        ngx.ctx.authenticated_credential = credential
        ngx.header[constants.HEADERS.ANONYMOUS] = nil -- in case of auth plugins concatenation
    else
        ngx.header[constants.HEADERS.ANONYMOUS] = true
    end
end

function _M.execute(conf)
    local httpMethod = ngx.req.get_method()
    local authorization_code = ngx.req.get_headers()["authorization_code"]
    local state = ngx.req.get_headers()["state"]
    local oxd_id = ngx.req.get_headers()["oxd_id"]
    local path = getPath()
    local CACHE_TIME_OUT = conf.session_time_second

    -- ------- validation ------
    if isempty(authorization_code) then
        return responses.send_HTTP_BAD_REQUEST("authorization_code is required")
    end
    if isempty(state) then
        return responses.send_HTTP_BAD_REQUEST("state is required")
    end
    if isempty(oxd_id) then
        return responses.send_HTTP_BAD_REQUEST("oxd_id is required")
    end

    local cacheValidRequest = cache.get(VALID_REQUEST .. oxd_id)

    if (cacheValidRequest ~= nil and cacheValidRequest.authorization_code ~= authorization_code) then
        return responses.send_HTTP_BAD_REQUEST("authorization_code is invalid")
    end
    if (cacheValidRequest ~= nil and cacheValidRequest.state ~= state) then
        return responses.send_HTTP_BAD_REQUEST("state is invalid")
    end
    if (cacheValidRequest ~= nil and cacheValidRequest.oxd_id ~= oxd_id) then
        return responses.send_HTTP_BAD_REQUEST("oxd_id is invalid")
    end

    ngx.log(ngx.DEBUG, "kong-openid-rp : Access - http_method: " .. httpMethod .. ", code: " .. authorization_code .. ", path: " .. path .. ", state: " .. state)
    -- ------------------------

    local oxdConfig = cache.get_or_set(OXDS .. oxd_id, CACHE_TIME_OUT, load_oxd_by_oxd_id, oxd_id)
    if oxdConfig == nil then
        return responses.send_HTTP_BAD_REQUEST("oxd_id is invalid")
    end

    local cacheUserInfo = cache.get(USER_INFO .. oxd_id)

    if cacheUserInfo == nil then
        local response = oxd.get_user_info(oxdConfig, authorization_code, state)
        if response == nil then
            return responses.send_HTTP_FORBIDDEN("OP Authorization Server Unreachable")
        end

        if response["status"] == "error" then
            ngx.log(ngx.ERR, "kong-openid-rp : Failed to authenticate! - http_method: " .. httpMethod .. ", authorization_code: " .. authorization_code .. ", state: " .. state)
            ngx.header["X-Openid-Warning"] = "Failed to authenticate by openid-OAuth. Please check authorization_code, state and oxd_id."
            local msg = ""
            if (response["data"] ~= nil) and (response["data"]["description"] ~= nil) then
                msg = " - " .. response["data"]["description"]
            end

            if (response["data"] ~= nil) and (response["data"]["error_description"] ~= nil) then
                msg = " - " .. response["data"]["error_description"]
            end

            return responses.send_HTTP_UNAUTHORIZED("Unauthorized" .. msg)
        end

        if response["status"] == "ok" then
            cache.set(USER_INFO .. oxd_id, response, CACHE_TIME_OUT)
            cache.set(VALID_REQUEST .. oxd_id, { state = state, authorization_code = authorization_code, oxd_id = oxd_id }, CACHE_TIME_OUT)
            cacheUserInfo = response
        end
    end

    -- retrieve the consumer linked to this API key, to set appropriate headers
    local consumer, err = cache.get_or_set(cache.consumer_key(oxdConfig.consumer_id),
        CACHE_TIME_OUT, load_consumer, oxdConfig.consumer_id)

    if err then
        return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
    end

    if cacheUserInfo then
        set_consumer(consumer, oxdConfig)
        return true -- ACCESS GRANTED
    else
        return responses.send_HTTP_UNAUTHORIZED("Unauthorized")
    end

    return responses.send_HTTP_FORBIDDEN("Unknown (unsupported) status code from oxd server for opendid coonect oauth operation.")
end

return _M