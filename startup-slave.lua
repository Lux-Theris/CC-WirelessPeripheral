local MASTER_URL = "https://raw.githubusercontent.com/Lux-Theris/CC-WirelessPeripheral/refs/heads/main/wpp.lua"
local WPP_PATH = "wpp.lua"
local CANAL = 65535 

local modem = peripheral.find("modem")
if modem then modem.open(CANAL) end

local function updateWpp()
    local response = http.get(MASTER_URL)
    if response then
        local f = fs.open(WPP_PATH, "w")
        f.write(response.readAll())
        f.close()
        response.close()
        -- Confirma que terminou a atualização
        if modem then modem.transmit(CANAL, CANAL, "UPDATE_OK:" .. os.getComputerID()) end
        return true
    end
    return false
end

-- Tenta atualizar ao ligar (importante para novos PCs na rede)
-- updateWpp() -- Removido do startup direto para evitar loops de reboot infinito. O master controla o update via REBOOT_ALL.

local wpp = require("wpp")
wpp.wireless.host("music")

while true do
    local event = {os.pullEvent()}
    if event[1] == "modem_message" then
        local msg = event[5]
        
        -- Responde ao Master para ser contado na rede
        if msg == "PING_NETWORK" then
            modem.transmit(CANAL, CANAL, "PONG:" .. os.getComputerID())
            
        -- Ordem de reiniciar e atualizar
        elseif msg == "REBOOT_ALL" then
            sleep(math.random(1, 3))
            updateWpp()
            os.reboot()
        end
    end
    wpp.wireless.localEventHandler(event)
end