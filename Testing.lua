local PlatoBoost = {}

-- CONFIG
local SERVICE_ID = 4684
local SECRET = "5154052f-d107-4a99-94e2-fc78cbaa46d5"
local USE_NONCE = true
local LINK_CACHE_TTL = 5

-- Services
local HttpService = game:GetService("HttpService")
local fSetClipboard = setclipboard or toclipboard
local fRequest = request or http_request or syn.request
local rnd, now = math.random, os.time

-- State
local cachedLink, lastLinkTime, requestPending = "", 0, false

-- Debug logging
local function Log(message, isError)
    local prefix = isError and "[❌ PlatoBoost ERROR]" or "[ℹ️ PlatoBoost INFO]"
    print(string.format("%s %s", prefix, message))
end

-- IP services
local ipSources = {
    "http://api.ipify.org",
    "https://ipinfo.io/ip",
    "https://v4.ident.me/"
}

local function isValidIP(ip)
    if not ip then return false end
    ip = ip:match("%S+") or ""
    if ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") then return true end
    return ip:match(":") ~= nil
end

local function getIP()
    for _, url in ipairs(ipSources) do
        local ok, res = pcall(function()
            local response = fRequest({Url = url, Method = "GET"})
            if response and response.Success then
                return response.Body
            end
            return nil
        end)
        if ok and res and isValidIP(res) then
            local cleanIP = res:match("%S+")
            Log(string.format("Got IP: %s", cleanIP), false)
            return cleanIP
        end
    end
    Log("Could not determine IP address", true)
    return nil
end

-- JSON helpers
local function jsonEncode(o) 
    local success, result = pcall(function()
        return HttpService:JSONEncode(o)
    end)
    if success then
        return result
    else
        Log(string.format("JSON encode failed: %s", result), true)
        return nil
    end
end

local function jsonDecode(s) 
    local success, result = pcall(function()
        return HttpService:JSONDecode(s)
    end)
    if success then
        return result
    else
        Log(string.format("JSON decode failed: %s", result), true)
        return nil
    end
end

-- SHA256 hash (simplified version)
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
    local nonce = table.concat(t)
    Log(string.format("Generated nonce: %s", nonce), false)
    return nonce
end

-- Determine host
local HOST = "https://api.platoboost.app"
do
    local ok, res = pcall(function()
        return fRequest({Url = HOST .. "/public/connectivity", Method = "GET"})
    end)
    
    if not ok or not res then
        Log("Primary host failed, switching to backup", true)
        HOST = "https://api.platoboost.net"
    elseif res.StatusCode ~= 200 and res.StatusCode ~= 429 then
        Log(string.format("Primary host returned %d, switching to backup", res.StatusCode), true)
        HOST = "https://api.platoboost.net"
    else
        Log(string.format("Using host: %s", HOST), false)
    end
end

-- Factory for separate instances (IP or UserId)
local function newPlatoBoost(identifierFunc, identifierType)
    Log(string.format("Creating new PlatoBoost instance for: %s", identifierType), false)
    
    local function cacheLink()
        Log("Checking link cache...", false)
        
        if now() - lastLinkTime < LINK_CACHE_TTL and cachedLink ~= "" then
            Log("Returning cached link", false)
            return true, cachedLink
        end
        
        Log("Requesting new link from API...", false)
        local identifier = identifierFunc()
        if not identifier then
            return false, string.format("Failed to get %s identifier", identifierType)
        end
        
        Log(string.format("Using identifier: %s", identifier), false)
        
        local requestData = {
            service = SERVICE_ID,
            identifier = identifier
        }
        
        local body = jsonEncode(requestData)
        if not body then
            return false, "Failed to encode request data"
        end
        
        local ok, res = pcall(function()
            return fRequest({
                Url = HOST .. "/public/start",
                Method = "POST",
                Body = body,
                Headers = {
                    ["Content-Type"] = "application/json"
                }
            })
        end)
        
        if not ok or not res then
            Log("Network request failed", true)
            return false, "Network error"
        end
        
        Log(string.format("API response: HTTP %d", res.StatusCode), false)
        
        if res.StatusCode == 200 then
            local data = jsonDecode(res.Body)
            if not data then
                return false, "Invalid API response"
            end
            
            if data.success and data.data and data.data.url then
                cachedLink = data.data.url
                lastLinkTime = now()
                Log("Successfully got new link", false)
                return true, cachedLink
            else
                local errorMsg = data.message or "Unknown API error"
                Log(string.format("API error: %s", errorMsg), true)
                return false, errorMsg
            end
        elseif res.StatusCode == 429 then
            Log("Rate limited by API", true)
            return false, "Rate limited - please wait 20 seconds"
        else
            Log(string.format("Unexpected HTTP status: %d", res.StatusCode), true)
            return false, string.format("Server error (HTTP %d)", res.StatusCode)
        end
    end

    local function copyLink()
        Log(string.format("copyLink() called for %s", identifierType), false)
        
        local ok, linkOrError = cacheLink()
        if not ok then
            Log(string.format("Failed to get link: %s", linkOrError), true)
            return false, linkOrError
        end
        
        if not fSetClipboard then
            Log("Clipboard function not available", true)
            return false, "Clipboard not supported"
        end
        
        local success, errorMsg = pcall(function()
            fSetClipboard(linkOrError)
        end)
        
        if success then
            Log("Link copied to clipboard successfully", false)
            return true, "Link copied to clipboard"
        else
            Log(string.format("Clipboard error: %s", errorMsg), true)
            return false, string.format("Failed to copy: %s", errorMsg)
        end
    end

    local function verifyKey(key)
        Log(string.format("verifyKey() called for %s with key: %s...", identifierType, string.sub(key, 1, 8)), false)
        
        if requestPending then
            Log("Request already in progress", true)
            return false, "Please wait, another request is processing"
        end
        
        if not key or #key < 5 then
            Log("Key too short", true)
            return false, "Key is too short"
        end
        
        requestPending = true
        local nonce = USE_NONCE and generateNonce() or ""
        
        local url = string.format("%s/public/whitelist/%d?identifier=%s&key=%s%s",
            HOST, SERVICE_ID, identifierFunc(), key, 
            USE_NONCE and "&nonce=" .. nonce or "")
        
        Log(string.format("Verifying key via: %s", string.sub(url, 1, 100) .. "..."), false)
        
        local ok, res = pcall(function()
            return fRequest({Url = url, Method = "GET"})
        end)
        
        requestPending = false
        
        if not ok or not res then
            Log("Network request failed", true)
            return false, "Network error - check your connection"
        end
        
        Log(string.format("Key verification response: HTTP %d", res.StatusCode), false)
        
        if res.StatusCode == 200 then
            local js = jsonDecode(res.Body)
            if not js then
                return false, "Invalid server response"
            end
            
            if js.success then
                if js.data and js.data.valid then
                    if USE_NONCE then
                        local expectedHash = hexDigest("true-" .. nonce .. "-" .. SECRET)
                        if js.data.hash == expectedHash then
                            Log("Key is valid (with nonce verification)", false)
                            return true, "Key is valid"
                        else
                            Log("Nonce verification failed", true)
                            return false, "Security verification failed"
                        end
                    else
                        Log("Key is valid", false)
                        return true, "Key is valid"
                    end
                else
                    Log("Key is invalid or expired", true)
                    return false, "Invalid or expired key"
                end
            else
                local errorMsg = js.message or "Key verification failed"
                Log(string.format("API error: %s", errorMsg), true)
                return false, errorMsg
            end
        elseif res.StatusCode == 429 then
            Log("Rate limited during key verification", true)
            return false, "Rate limited - please wait before trying again"
        else
            Log(string.format("Server error during verification: HTTP %d", res.StatusCode), true)
            return false, string.format("Server error (HTTP %d)", res.StatusCode)
        end
    end

    local function getFlag(name)
        Log(string.format("getFlag() called for: %s", name), false)
        
        local nonce = USE_NONCE and generateNonce() or ""
        local url = string.format("%s/public/flag/%d?name=%s%s",
            HOST, SERVICE_ID, name, USE_NONCE and "&nonce=" .. nonce or "")
        
        local ok, res = pcall(function()
            return fRequest({Url = url, Method = "GET"})
        end)
        
        if not ok or not res then
            Log("Network request failed", true)
            return nil, "Network error"
        end
        
        if res.StatusCode == 200 then
            local js = jsonDecode(res.Body)
            if not js then
                return nil, "Invalid response"
            end
            
            if js.success and js.data then
                if USE_NONCE then
                    local hash = hexDigest(tostring(js.data.value) .. "-" .. nonce .. "-" .. SECRET)
                    if hash ~= js.data.hash then
                        Log("Integrity check failed for flag", true)
                        return nil, "Integrity verification failed"
                    end
                end
                Log(string.format("Got flag value: %s", tostring(js.data.value)), false)
                return js.data.value
            else
                local errorMsg = js.message or "Failed to get flag"
                Log(string.format("API error: %s", errorMsg), true)
                return nil, errorMsg
            end
        end
        
        Log(string.format("Flag request failed: HTTP %d", res.StatusCode), true)
        return nil, string.format("Server error (HTTP %d)", res.StatusCode)
    end

    return {
        copyLink = copyLink,
        verifyKey = verifyKey,
        getFlag = getFlag
    }
end

-- Create and export both instances
local PlatoBoost_IP = newPlatoBoost(function()
    local ip = getIP()
    if not ip then
        error("Unable to determine IP address")
    end
    return ip
end, "IP")

local PlatoBoost_UserId = newPlatoBoost(function()
    return tostring(game.Players.LocalPlayer.UserId)
end, "UserId")

-- Initialize
Log("PlatoBoost system initialized successfully", false)
Log(string.format("Service ID: %d", SERVICE_ID), false)
Log(string.format("Host: %s", HOST), false)
Log(string.format("Using nonce: %s", tostring(USE_NONCE)), false)

return {
    IP = PlatoBoost_IP,
    UserId = PlatoBoost_UserId
}
