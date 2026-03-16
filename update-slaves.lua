local CANAL = 65535
local modem = peripheral.find("modem") or error("Precisa de um modem!")
modem.open(CANAL)

term.clear()
term.setCursorPos(1,1)
print("--- GERENCIADOR DINAMICO ---")

-- FASE 1: ESCANEAR REDE
print("Escaneando rede (3s)...")
modem.transmit(CANAL, CANAL, "PING_NETWORK")

local pcsOnline = {}
local scanTimer = os.startTimer(3) -- Espera 3 segundos pelas respostas

while true do
    local event, side, ch, rCh, msg = os.pullEvent()
    if event == "modem_message" and type(msg) == "string" and msg:find("PONG:") then
        local id = msg:sub(6)
        pcsOnline[id] = true
    elseif event == "timer" and side == scanTimer then
        break
    end
end

local totalPcs = 0
for _ in pairs(pcsOnline) do totalPcs = totalPcs + 1 end

if totalPcs == 0 then
    error("Nenhum computador encontrado na rede!")
end

print("Encontrados: " .. totalPcs .. " computadores.")
sleep(1)

-- FASE 2: ATUALIZAR
print("Enviando sinal de atualizacao...")
modem.transmit(CANAL, CANAL, "REBOOT_ALL")

local function drawBar(current, total)
    local w = term.getSize()
    local barW = w - 10
    local prog = math.floor((current / total) * barW)
    term.setCursorPos(1, 8)
    term.write("Progresso: [" .. string.rep("=", prog) .. string.rep(" ", barW - prog) .. "]")
    term.setCursorPos(1, 9)
    term.write(string.format("Status: %d de %d concluidos", current, total))
end

local concluidos = 0
local respondidos = {}
local timeout = os.startTimer(40) -- Tempo limite para o download de todos

while concluidos < totalPcs do
    local event, side, ch, rCh, msg = os.pullEvent()
    
    if event == "modem_message" and type(msg) == "string" and msg:find("UPDATE_OK:") then
        local id = msg:sub(11)
        if not respondidos[id] then
            respondidos[id] = true
            concluidos = concluidos + 1
            drawBar(concluidos, totalPcs)
        end
    elseif event == "timer" and side == timeout then
        print("\n\nERRO: Timeout! Alguns PCs falharam.")
        break
    end
end

if concluidos == totalPcs then
    print("\n\nSUCESSO: Todos os " .. totalPcs .. " PCs estao prontos!")
end