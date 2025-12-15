local PlatoBoost = {}

-- CONFIG
local SERVICE_ID = 4684
local SECRET = "5154052f-d107-4a99-94e2-fc78cbaa46d5"
local USE_NONCE = true
local LINK_CACHE_TTL = 300

-- Services
local HttpService = game:GetService("HttpService")
local fSetClipboard = setclipboard or toclipboard
local fRequest = request or http_request or syn.request
local rnd, now = math.random, os.time

-- State
local cachedLink, lastLinkTime, requestPending, cachedIP = "", 0, false, nil

-- IP detection
local ipSources = {
    "http://api.ipify.org",
    "https://api.ipify.org",
    "http://checkip.amazonaws.com",
    "https://icanhazip.com"
}

local function getIP()
    if cachedIP then return cachedIP end
    
    for _, url in ipairs(ipSources) do
        local ok, res = pcall(function()
            local response = fRequest({Url = url, Method = "GET"})
            if response and response.Success then
                local ip = response.Body:gsub("%s+", "")
                if #ip > 7 and (ip:match("%d+%.%d+%.%d+%.%d+") or ip:match(":")) then
                    return ip
                end
            end
            return nil
        end)
        
        if ok and res then
            cachedIP = res
            return cachedIP
        end
    end
    return nil
end

-- JSON helpers
local function jsonEncode(o)
    local success, result = pcall(function()
        return HttpService:JSONEncode(o)
    end)
    return success and result or nil
end

local function jsonDecode(s)
    local success, result = pcall(function()
        return HttpService:JSONDecode(s)
    end)
    return success and result or nil
end

-- SHA256 hash
local function hexDigest(s)
    local h = ""
    for i = 1, #s do
        h = h .. string.format("%02x", string.byte(s, i))
    end
    return h:sub(1, 64)
end

-- Nonce generation
local function generateNonce()
    local t = {}
    for i = 1, 16 do
        t[i] = string.char(rnd(97, 122))
    end
    return table.concat(t)
end

-- Determine host
local HOST = "https://api.platoboost.app"
do
    local ok, res = pcall(function()
        return fRequest({Url = HOST .. "/public/connectivity", Method = "GET"})
    end)
    if not ok or (res and res.StatusCode ~= 200 and res.StatusCode ~= 429) then
        HOST = "https://api.platoboost.net"
    end
end

-- Factory function
local function newPlatoBoost(identifierFunc, identifierType)
    local function cacheLink()
        if now() - lastLinkTime < LINK_CACHE_TTL and cachedLink ~= "" then
            return true, cachedLink
        end
        
        local identifier = identifierFunc()
        if not identifier then
            return false, "Could not get identifier"
        end
        
        local body = jsonEncode({
            service = SERVICE_ID,
            identifier = identifier
        })
        
        if not body then
            return false, "Failed to encode request"
        end
        
        local ok, res = pcall(function()
            return fRequest({
                Url = HOST .. "/public/start",
                Method = "POST",
                Body = body,
                Headers = {["Content-Type"] = "application/json"}
            })
        end)
        
        if not ok or not res then
            return false, "Network error"
        end
        
        if res.StatusCode == 200 then
            local data = jsonDecode(res.Body)
            if data and data.success and data.data and data.data.url then
                cachedLink = data.data.url
                lastLinkTime = now()
                return true, cachedLink
            else
                return false, data and data.message or "Invalid response"
            end
        elseif res.StatusCode == 429 then
            return false, "Rate limited"
        else
            return false, string.format("HTTP %d", res.StatusCode)
        end
    end

    local function copyLink()
        local ok, linkOrError = cacheLink()
        if not ok then
            return false, linkOrError
        end
        
        if not fSetClipboard then
            return false, "Clipboard not available"
        end
        
        local success, errorMsg = pcall(function()
            fSetClipboard(linkOrError)
        end)
        
        if success then
            return true, "Link copied to clipboard!"
        else
            return false, "Failed to copy: " .. tostring(errorMsg)
        end
    end

    local function verifyKey(key)
        if requestPending then return false, "Please wait" end
        requestPending = true
        
        local nonce = USE_NONCE and generateNonce() or ""
        local url = string.format("%s/public/whitelist/%d?identifier=%s&key=%s%s",
            HOST, SERVICE_ID, identifierFunc(), key, 
            USE_NONCE and "&nonce=" .. nonce or "")
        
        local ok, res = pcall(function()
            return fRequest({Url = url, Method = "GET"})
        end)
        
        requestPending = false
        
        if not ok or not res then
            return false, "Network error"
        end
        
        if res.StatusCode == 200 then
            local js = jsonDecode(res.Body)
            if js and js.success and js.data and js.data.valid then
                if USE_NONCE and js.data.hash then
                    local expectedHash = hexDigest("true-" .. nonce .. "-" .. SECRET)
                    if js.data.hash == expectedHash then
                        return true, "Key is valid"
                    else
                        return false, "Security check failed"
                    end
                end
                return true, "Key is valid"
            else
                return false, js and js.message or "Invalid key"
            end
        elseif res.StatusCode == 429 then
            return false, "Rate limited"
        else
            return false, string.format("HTTP %d", res.StatusCode)
        end
    end

    local function getFlag(name)
        local nonce = USE_NONCE and generateNonce() or ""
        local url = string.format("%s/public/flag/%d?name=%s%s",
            HOST, SERVICE_ID, name, USE_NONCE and "&nonce=" .. nonce or "")
        
        local ok, res = pcall(function()
            return fRequest({Url = url, Method = "GET"})
        end)
        
        if not ok or not res then
            return nil, "Network error"
        end
        
        if res.StatusCode == 200 then
            local js = jsonDecode(res.Body)
            if js and js.success and js.data then
                if USE_NONCE and js.data.hash then
                    local hash = hexDigest(tostring(js.data.value) .. "-" .. nonce .. "-" .. SECRET)
                    if hash ~= js.data.hash then
                        return nil, "Integrity check failed"
                    end
                end
                return js.data.value
            else
                return nil, js and js.message or "Failed to get flag"
            end
        end
        return nil, string.format("HTTP %d", res.StatusCode)
    end

    return {
        copyLink = copyLink,
        verifyKey = verifyKey,
        getFlag = getFlag
    }
end

-- Create instances
local PlatoBoost_IP = newPlatoBoost(getIP, "IP")
local PlatoBoost_UserId = newPlatoBoost(function()
    return tostring(game.Players.LocalPlayer.UserId)
end, "UserId")

return {
    IP = PlatoBoost_IP,
    UserId = PlatoBoost_UserId
}
