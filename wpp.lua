local debugMode = false
local CURRENT_VERSION = "1"
local THIS_COMPUTER_ID = os.getComputerID()

local currentProtocol = "wpp@default"
local prefetchCache = {}

local function splitString (inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

local function log(message)
    local logMessage = debug.getinfo(2).currentline ..": ".. message

    if debugMode then
        print(logMessage)
    end
end

-- Start->Wireless Modem Setup
peripheral.find("modem", function(name, wrapped)
    if wrapped.isWireless() then
        rednet.open(name)
    end
end)
 
if not rednet.isOpen() then
    error("No wireless modem found", 2)
end
-- End->Wireless Modem Setup

-- Start->
local function parsePeripheralUrl(peripheralUrl)
    local urlParts = splitString(peripheralUrl, "/")

    if urlParts[1] == (currentProtocol ..":") and urlParts[2] and urlParts[3] then
        return {clientId=tonumber(urlParts[2]), peripheralId=urlParts[3]}
    else
        return nil
    end
end

local function sendMessage(clientId, type, data)
    if debugMode then log("Sending message with type '".. type .."' to ".. currentProtocol .." clientId ".. clientId) end
    rednet.send(clientId, {type=type, version=CURRENT_VERSION, data=data}, currentProtocol)
end

local function sendMessageBroadcast(type, data)
    if debugMode then log("Broadcasting message type '".. type .."' on ".. currentProtocol) end
    rednet.broadcast({type=type, version=CURRENT_VERSION, data=data}, currentProtocol)
end

local function sendReply(clientId, data)
    sendMessage(clientId, "reply", data)
end

local function recieveReply(expectedClientId)
    local timerId = os.startTimer(10)
    while true do
        local event = {os.pullEvent()}
        
        if event[1] == "timer" and event[2] == timerId then
            return nil
        elseif event[1] == "rednet_message" then
            local senderId = event[2]
            local message = event[3]
            local protocol = event[4]
            
            if protocol == currentProtocol and (not expectedClientId or senderId == expectedClientId) then
                if type(message) == "table" and message.type == "reply" then
                    os.cancelTimer(timerId)
                    return message
                end
            end
        end
    end
end
-- End->

local nativePeripheral = peripheral
local originalGetName = nativePeripheral.getName
if originalGetName then
    peripheral.getName = function(nameOrTable)
        if type(nameOrTable) == "table" and nameOrTable._wpp_name then
            return nameOrTable._wpp_name
        end
        return originalGetName(nameOrTable)
    end
end

local audio_queues = {}
local function pumpAudioQueues()
    for name, queue in pairs(audio_queues) do
        while #queue > 0 do
            local item = queue[1]
            if nativePeripheral.call(name, item.methodName, item.buffer, item.volume) then
                table.remove(queue, 1)
            else
                break
            end
        end
    end
end

-- Start->Wrapped Peripheral API funtcions
local wrappedPeripheralApi = {
    getNames=function(clientId)
        sendReply(clientId, nativePeripheral.getNames())
    end,
    isPresent=function(clientId, peripheralName)
        sendReply(clientId, nativePeripheral.isPresent(peripheralName))
    end,
    getType=function(clientId, peripheralName)
        sendReply(clientId, nativePeripheral.getType(peripheralName))
    end,
    getMethods=function(clientId, peripheralName)
        sendReply(clientId, nativePeripheral.getMethods(peripheralName))
    end,
    call=function(clientId, peripheralName, methodName, ...)
        local args = ...
        local status,result = pcall(function()
            return {nativePeripheral.call(peripheralName, methodName, unpack(args))}
        end)
        sendReply(clientId, {returned=result, error=not status})
    end,
    wppPrefetch=function(clientId, peripheralName, methods)
        local methodResults = {}
        for possibleMethodName,methodInfo in pairs(methods) do
            local methodName = (type(methodInfo) == "table") and possibleMethodName or methodInfo
            local methodArgs = (type(methodInfo) == "table") and methodInfo or {}
            local status,result = pcall(function()
                return {nativePeripheral.call(peripheralName, methodName, unpack(methodArgs))}
            end)
            if status then methodResults[methodName] = result end
        end
        sendReply(clientId, methodResults)
    end,
    wppMulticastCall=function(peripheralName, methodName, ...)
        local args = ...
        pcall(function() nativePeripheral.call(peripheralName, methodName, unpack(args)) end)
    end,
    wppMulticastPlayAudioDFPWM=function(_type, methodName, chunk, volume)
        local dfpwm = require("cc.audio.dfpwm")
        local decoder = dfpwm.make_decoder()
        local buffer = decoder(chunk)
        
        local locals = {nativePeripheral.find(_type)}
        for _, loc in ipairs(locals) do
            local name = nativePeripheral.getName(loc)
            audio_queues[name] = audio_queues[name] or {}
            table.insert(audio_queues[name], {methodName=methodName, buffer=buffer, volume=volume})
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

function wireless.setDebugMode(mode)
    debugMode = mode
end

function wireless.connect(networkId)
    currentProtocol = "wpp@".. networkId
end

function wireless.host(networkId)
    rednet.unhost(currentProtocol)
    wireless.connect(networkId)
    rednet.host(currentProtocol, tostring(THIS_COMPUTER_ID))
end

function wireless.localEventHandler(event)
    if event[1] == "speaker_audio_empty" or event[1] == "timer" then
        pumpAudioQueues()
    end
    
    if event[1] == "rednet_message" then
        if event[4] == currentProtocol then
            if event[3].version and event[3].version == CURRENT_VERSION then
                if event[3].type == "function" then
                    wrappedPeripheralApi[event[3].data.func](event[2], unpack(event[3].data.args or {}))
                elseif event[3].type == "multicast_function" then
                    wrappedPeripheralApi[event[3].data.func](unpack(event[3].data.args or {}))
                end
            end
        end
    end
end

function wireless.listen(networkId)
    wireless.host(networkId)
    print("Listening for WPP events on ".. currentProtocol)
    while true do
        local event = {os.pullEvent()}
        wireless.localEventHandler(event)
    end
end

function wireless.prefetchMethods(peripheralUrl, methods)
    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)
    if parsedPeripheralUrl == nil then
        prefetchCache[peripheralUrl] = {}
        for possibleMethodName,methodInfo in pairs(methods) do
            local methodName = (type(methodInfo) == "table") and possibleMethodName or methodInfo
            local methodArgs = (type(methodInfo) == "table") and methodInfo or {}
            local status,result = pcall(function() return {remotePeripheral.call(peripheralUrl, methodName, unpack(methodArgs))} end)
            if status then prefetchCache[peripheralUrl][methodName] = result end
        end
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="wppPrefetch", args={parsedPeripheralUrl.peripheralId, methods}})
        local reply = recieveReply(parsedPeripheralUrl.clientId)
        if reply then prefetchCache[peripheralUrl] = reply.data end
    end
end

function remotePeripheral.getNames()
    local allNames = nativePeripheral.getNames()
    local clients = table.pack(rednet.lookup(currentProtocol))
    for n,clientId in ipairs(clients) do
        if clientId ~= THIS_COMPUTER_ID then
            sendMessage(clientId, "function", {func="getNames"})
            local reply = recieveReply(clientId)
            if reply then for _,name in ipairs(reply.data) do table.insert(allNames, currentProtocol .."://" .. clientId .. "/" .. name) end end
        end
    end
    return allNames
end

function remotePeripheral.isPresent(peripheralUrl)
    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)
    if parsedPeripheralUrl == nil then
        return nativePeripheral.isPresent(peripheralUrl)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="isPresent", args={parsedPeripheralUrl.peripheralId}})
        local reply = recieveReply(parsedPeripheralUrl.clientId)
        return reply and reply.data or false
    end
end

function remotePeripheral.getType(peripheralUrl)
    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)
    if parsedPeripheralUrl == nil then
        return nativePeripheral.getType(peripheralUrl)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="getType", args={parsedPeripheralUrl.peripheralId}})
        local reply = recieveReply(parsedPeripheralUrl.clientId)
        return reply and reply.data or nil
    end
end

function remotePeripheral.getMethods(peripheralUrl)
    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)
    if parsedPeripheralUrl == nil then
        return nativePeripheral.getMethods(peripheralUrl)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="getMethods", args={parsedPeripheralUrl.peripheralId}})
        local reply = recieveReply(parsedPeripheralUrl.clientId)
        return reply and reply.data or nil
    end
end

function remotePeripheral.call(peripheralUrl, method, ...)
    if prefetchCache[peripheralUrl] and prefetchCache[peripheralUrl][method] then
        local returnValue = prefetchCache[peripheralUrl][method]
        prefetchCache[peripheralUrl][method] = nil
        return unpack(returnValue)
    end
    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)
    if parsedPeripheralUrl == nil then
        return nativePeripheral.call(peripheralUrl, method, ...)
    else
        sendMessage(parsedPeripheralUrl.clientId, "function", {func="call", args={parsedPeripheralUrl.peripheralId, method, {...}}})
        local reply = recieveReply(parsedPeripheralUrl.clientId)
        if reply then
            if reply.data.error then error(reply.data.returned) end
            return unpack(reply.data.returned)
        end
        return nil
    end
end

function remotePeripheral.wrap(peripheralUrl)
    local parsedPeripheralUrl = parsePeripheralUrl(peripheralUrl)
    if parsedPeripheralUrl == nil then
        return nativePeripheral.wrap(peripheralUrl)
    else
        if not remotePeripheral.isPresent(peripheralUrl) then return nil end
        local peripheralMethods = remotePeripheral.getMethods(peripheralUrl)
        local wrappedMethodsTable = {}
        if peripheralMethods then
            for n,method in ipairs(peripheralMethods) do
                wrappedMethodsTable[method] = function(...) return remotePeripheral.call(peripheralUrl, method, ...) end
            end
        end
        wrappedMethodsTable["wppPrefetch"] = function(methods) wireless.prefetchMethods(peripheralUrl, methods) end
        wrappedMethodsTable._wpp_name = parsedPeripheralUrl.peripheralId
        return wrappedMethodsTable
    end
end

function remotePeripheral.find(_type, filterFunction)
    local foundToReturn = {nativePeripheral.find(_type, filterFunction)}
    local allPeripherals = remotePeripheral.getNames()
    for n,peripheralUrl in ipairs(allPeripherals) do
        if remotePeripheral.getType(peripheralUrl) == _type then
            local wrappedPeripheral = remotePeripheral.wrap(peripheralUrl)
            if filterFunction then
                local peripheralName = (type(peripheralUrl) == "string") and peripheralUrl or wrappedPeripheral._wpp_name
               if filterFunction(peripheralName, wrappedPeripheral) then table.insert(foundToReturn, wrappedPeripheral) end
            else
                table.insert(foundToReturn, wrappedPeripheral)
            end
        end
    end
    return #foundToReturn > 0 and table.unpack(foundToReturn) or nil
end

function remotePeripheral.multicastCall(_type, method, ...)
    local args = {...}
    local locals = {nativePeripheral.find(_type)}
    for _, loc in ipairs(locals) do
        local name = nativePeripheral.getName(loc)
        pcall(function() nativePeripheral.call(name, method, unpack(args)) end)
    end
    sendMessageBroadcast("multicast_function", {func="wppMulticastCallType", args={_type, method, args}})
end

local _wpp_master_decoder = nil
function remotePeripheral.multicastCallDFPWM(_type, method, chunk, volume)
    local locals = {nativePeripheral.find(_type)}
    if next(locals) then
        if not _wpp_master_decoder then 
            local dfpwm = require("cc.audio.dfpwm")
            _wpp_master_decoder = dfpwm.make_decoder() 
        end
        local buffer = _wpp_master_decoder(chunk)
        for _, loc in ipairs(locals) do
            local name = nativePeripheral.getName(loc)
            audio_queues[name] = audio_queues[name] or {}
            table.insert(audio_queues[name], {methodName=method, buffer=buffer, volume=volume})
        end
        pumpAudioQueues()
    end
    sendMessageBroadcast("multicast_function", {func="wppMulticastPlayAudioDFPWM", args={_type, method, chunk, volume}})
end

return {wireless=wireless, peripheral=remotePeripheral}
