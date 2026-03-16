local debugMode = false
local CURRENT_VERSION = "2" -- Network Consistency
local THIS_COMPUTER_ID = os.getComputerID()

local currentProtocol = "wpp@default"
local prefetchCache = {}

local function splitString (inputstr, sep)
    if sep == nil then sep = "%s" end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do table.insert(t, str) end
    return t
end

local function log(message)
    if debugMode then print(debug.getinfo(2).currentline ..": ".. message) end
end

-- Start->Wireless Modem Setup
peripheral.find("modem", function(name, wrapped)
    if wrapped.isWireless() then rednet.open(name) end
end)
 
if not rednet.isOpen() then error("No wireless modem found", 2) end
-- End->Wireless Modem Setup

local function parsePeripheralUrl(peripheralUrl)
    local urlParts = splitString(peripheralUrl, "/")
    if urlParts[1] == (currentProtocol ..":") and urlParts[2] and urlParts[3] then
        return {clientId=tonumber(urlParts[2]), peripheralId=urlParts[3]}
    end
    return nil
end

local function sendMessage(clientId, type, data)
    rednet.send(clientId, {type=type, version=CURRENT_VERSION, data=data}, currentProtocol)
end

local function sendMessageBroadcast(type, data)
    rednet.broadcast({type=type, version=CURRENT_VERSION, data=data}, currentProtocol)
end

local function sendReply(clientId, data)
    sendMessage(clientId, "reply", data)
end

local function recieveReply(expectedClientId, timeout)
    timeout = timeout or 5
    local timerId = os.startTimer(timeout)
    while true do
        local event = {os.pullEvent()}
        if event[1] == "timer" and event[2] == timerId then
            return nil
        elseif event[1] == "rednet_message" then
            local senderId, message, protocol = event[2], event[3], event[4]
            if protocol == currentProtocol and (not expectedClientId or senderId == expectedClientId) then
                if type(message) == "table" and message.type == "reply" then
                    os.cancelTimer(timerId)
                    return message
                end
            end
        end
    end
end

local nativePeripheral = peripheral
local originalGetName = nativePeripheral.getName
if originalGetName then
    peripheral.getName = function(nameOrTable)
        if type(nameOrTable) == "table" and nameOrTable._wpp_name then return nameOrTable._wpp_name end
        return originalGetName(nameOrTable)
    end
end

local audio_queues = {}
local _wpp_last_wakeup_tick = -1

local function pumpAudioQueues()
    local current_epoch = os.epoch("ingame")
    local current_time = current_epoch / 1000
    local next_wakeup = nil
    
    for name, queue in pairs(audio_queues) do
        while #queue > 0 do
            local item = queue[1]
            if item.play_at then
                local delta = item.play_at - current_time
                local should_play = (delta <= 0) or (delta < -3) or (delta > 10)
                if not should_play then
                    if not next_wakeup or item.play_at < next_wakeup then next_wakeup = item.play_at end
                    break 
                end
            end
            if nativePeripheral.call(name, item.methodName, item.buffer, item.volume) then
                table.remove(queue, 1)
            else
                break
            end
        end
    end
    
    if next_wakeup and _wpp_last_wakeup_tick ~= current_epoch then
        local wait_time = math.max(0, next_wakeup - current_time)
        os.startTimer(wait_time)
        _wpp_last_wakeup_tick = current_epoch
    end
end

local _wpp_decoders = {}

local wrappedPeripheralApi = {
    getNames=function(clientId) sendReply(clientId, nativePeripheral.getNames()) end,
    isPresent=function(clientId, peripheralName) sendReply(clientId, nativePeripheral.isPresent(peripheralName)) end,
    getType=function(clientId, peripheralName) sendReply(clientId, nativePeripheral.getType(peripheralName)) end,
    getMethods=function(clientId, peripheralName) sendReply(clientId, nativePeripheral.getMethods(peripheralName)) end,
    call=function(clientId, peripheralName, methodName, ...)
        local args = ...
        local status,result = pcall(function() return {nativePeripheral.call(peripheralName, methodName, unpack(args))} end)
        sendReply(clientId, {returned=result, error=not status})
    end,
    -- Fast Type Search Wrapper
    findInRemote=function(clientId, _type)
        local names = {nativePeripheral.getNames()}
        local foundNames = {}
        for _, name in ipairs(names) do
            if nativePeripheral.getType(name) == _type then
                table.insert(foundNames, name)
            end
        end
        sendReply(clientId, foundNames)
    end,
    wppPrefetch=function(clientId, peripheralName, methods)
        local methodResults = {}
        for possibleMethodName,methodInfo in pairs(methods) do
            local methodName = (type(methodInfo) == "table") and possibleMethodName or methodInfo
            local methodArgs = (type(methodInfo) == "table") and methodInfo or {}
            local status,result = pcall(function() return {nativePeripheral.call(peripheralName, methodName, unpack(methodArgs))} end)
            if status then methodResults[methodName] = result end
        end
        sendReply(clientId, methodResults)
    end,
    wppMulticastCall=function(peripheralName, methodName, ...)
        local args = ...
        pcall(function() nativePeripheral.call(peripheralName, methodName, unpack(args)) end)
    end,
    wppMulticastPlayAudioDFPWM=function(_type, methodName, chunk, volume, play_at)
        local dfpwm = require("cc.audio.dfpwm")
        local locals = {nativePeripheral.find(_type)}
        for _, loc in ipairs(locals) do
            local name = nativePeripheral.getName(loc)
            if not _wpp_decoders[name] then _wpp_decoders[name] = dfpwm.make_decoder() end
            local buffer = _wpp_decoders[name](chunk)
            audio_queues[name] = audio_queues[name] or {}
            table.insert(audio_queues[name], {methodName=methodName, buffer=buffer, volume=volume, play_at=play_at})
        end
        pumpAudioQueues()
    end,
    wppMulticastCallType = function(_type, methodName, args)
        local locals = {nativePeripheral.find(_type)}
        for _, loc in ipairs(locals) do
            local name = nativePeripheral.getName(loc)
            pcall(function() nativePeripheral.call(name, methodName, unpack(args)) end)
        end
    end
}

local remotePeripheral = {}
local wireless = {}

function wireless.setDebugMode(mode) debugMode = mode end
function wireless.connect(networkId) currentProtocol = "wpp@".. networkId end
function wireless.host(networkId)
    rednet.unhost(currentProtocol)
    wireless.connect(networkId)
    rednet.host(currentProtocol, tostring(THIS_COMPUTER_ID))
end

function wireless.localEventHandler(event)
    if event[1] == "speaker_audio_empty" or event[1] == "timer" then pumpAudioQueues() end
    if event[1] == "rednet_message" then
        if event[4] == currentProtocol and event[3].version == CURRENT_VERSION then
            if event[3].type == "function" then
                wrappedPeripheralApi[event[3].data.func](event[2], unpack(event[3].data.args or {}))
            elseif event[3].type == "multicast_function" then
                wrappedPeripheralApi[event[3].data.func](unpack(event[3].data.args or {}))
            end
        end
    end
end

function wireless.listen(networkId)
    wireless.host(networkId)
    print("Listening for WPP events on ".. currentProtocol)
    while true do wireless.localEventHandler({os.pullEvent()}) end
end

function wireless.prefetchMethods(peripheralUrl, methods)
    local parsed = parsePeripheralUrl(peripheralUrl)
    if not parsed then
        prefetchCache[peripheralUrl] = {}
        for k,v in pairs(methods) do
            local m = (type(v) == "table") and k or v
            local a = (type(v) == "table") and v or {}
            local s,r = pcall(function() return {remotePeripheral.call(peripheralUrl, m, unpack(a))} end)
            if s then prefetchCache[peripheralUrl][m] = r end
        end
    else
        sendMessage(parsed.clientId, "function", {func="wppPrefetch", args={parsed.peripheralId, methods}})
        local reply = recieveReply(parsed.clientId)
        if reply then prefetchCache[peripheralUrl] = reply.data end
    end
end

function remotePeripheral.getNames()
    local allNames = nativePeripheral.getNames()
    local clients = table.pack(rednet.lookup(currentProtocol))
    for n,clientId in ipairs(clients) do
        if clientId ~= THIS_COMPUTER_ID then
            sendMessage(clientId, "function", {func="getNames"})
            local reply = recieveReply(clientId, 1.0) -- Increased timeout for stability
            if reply then for _,name in ipairs(reply.data) do table.insert(allNames, currentProtocol .."://" .. clientId .. "/" .. name) end end
        end
    end
    return allNames
end

function remotePeripheral.isPresent(peripheralUrl)
    local parsed = parsePeripheralUrl(peripheralUrl)
    if not parsed then return nativePeripheral.isPresent(peripheralUrl) end
    sendMessage(parsed.clientId, "function", {func="isPresent", args={parsed.peripheralId}})
    local reply = recieveReply(parsed.clientId)
    return reply and reply.data or false
end

function remotePeripheral.getType(peripheralUrl)
    local parsed = parsePeripheralUrl(peripheralUrl)
    if not parsed then return nativePeripheral.getType(peripheralUrl) end
    sendMessage(parsed.clientId, "function", {func="getType", args={parsed.peripheralId}})
    local reply = recieveReply(parsed.clientId)
    return reply and reply.data or nil
end

function remotePeripheral.getMethods(peripheralUrl)
    local parsed = parsePeripheralUrl(peripheralUrl)
    if not parsed then return nativePeripheral.getMethods(peripheralUrl) end
    sendMessage(parsed.clientId, "function", {func="getMethods", args={parsed.peripheralId}})
    local reply = recieveReply(parsed.clientId)
    return reply and reply.data or nil
end

function remotePeripheral.call(peripheralUrl, method, ...)
    if prefetchCache[peripheralUrl] and prefetchCache[peripheralUrl][method] then
        local ret = prefetchCache[peripheralUrl][method]
        prefetchCache[peripheralUrl][method] = nil
        return unpack(ret)
    end
    local parsed = parsePeripheralUrl(peripheralUrl)
    if not parsed then return nativePeripheral.call(peripheralUrl, method, ...) end
    sendMessage(parsed.clientId, "function", {func="call", args={parsed.peripheralId, method, {...}}})
    local reply = recieveReply(parsed.clientId)
    if reply then
        if reply.data.error then error(reply.data.returned) end
        return unpack(reply.data.returned)
    end
end

function remotePeripheral.wrap(peripheralUrl)
    local parsed = parsePeripheralUrl(peripheralUrl)
    if not parsed then return nativePeripheral.wrap(peripheralUrl) end
    local methods = remotePeripheral.getMethods(peripheralUrl)
    if not methods then return nil end
    local t = {}
    for _,m in ipairs(methods) do t[m] = function(...) return remotePeripheral.call(peripheralUrl, m, ...) end end
    t["wppPrefetch"] = function(m) wireless.prefetchMethods(peripheralUrl, m) end
    t._wpp_name = parsed.peripheralId
    return t
end

function remotePeripheral.find(_type, filterFunction)
    local found = {nativePeripheral.find(_type, filterFunction)}
    local clients = table.pack(rednet.lookup(currentProtocol))
    
    for _,clientId in ipairs(clients) do
        if clientId ~= THIS_COMPUTER_ID then
            sendMessage(clientId, "function", {func="findInRemote", args={_type}})
            local reply = recieveReply(clientId, 1.0) -- Higher timeout for busy Slaves
            if reply then
                for _,name in ipairs(reply.data) do
                    local url = currentProtocol .. "://" .. clientId .. "/" .. name
                    local w = remotePeripheral.wrap(url)
                    if w and (not filterFunction or filterFunction(url, w)) then 
                        table.insert(found, w) 
                    end
                end
            end
        end
    end
    
    if #found > 0 then return table.unpack(found) end
end

function remotePeripheral.multicastCall(_type, method, ...)
    local args = {...}
    local locals = {nativePeripheral.find(_type)}
    for _, loc in ipairs(locals) do pcall(function() nativePeripheral.call(nativePeripheral.getName(loc), method, unpack(args)) end) end
    sendMessageBroadcast("multicast_function", {func="wppMulticastCallType", args={_type, method, args}})
end

local _sync_decoders = {}
function remotePeripheral.multicastCallDFPWM(_type, method, chunk, volume, play_at)
    play_at = play_at or ((os.epoch("ingame") / 1000) + 1.0)
    local locals = {nativePeripheral.find(_type)}
    if next(locals) then
        local df = require("cc.audio.dfpwm")
        for _, loc in ipairs(locals) do
            local n = nativePeripheral.getName(loc)
            if not _sync_decoders[n] then _sync_decoders[n] = df.make_decoder() end
            audio_queues[n] = audio_queues[n] or {}
            table.insert(audio_queues[n], {methodName=method, buffer=_sync_decoders[n](chunk), volume=volume, play_at=play_at})
        end
        pumpAudioQueues()
    end
    sendMessageBroadcast("multicast_function", {func="wppMulticastPlayAudioDFPWM", args={_type, method, chunk, volume, play_at}})
end

return {wireless=wireless, peripheral=remotePeripheral}
