-- WPP Bridge Slave Client
-- Conecta o speaker local ao canal de música global

local CHANNEL_NAME = "music"

term.clear()
term.setCursorPos(1,1)
print("--- Music Slave Client ---")

-- 1. Encontrar o periférico Music Bridge
local bridge = peripheral.find("music_bridge")
if not bridge then
    term.setTextColor(colors.red)
    print("ERRO: Periferico 'music_bridge' nao encontrado!")
    print("Certifique-se que o computador esta encostado no bloco Music Bridge.")
    return
end

-- 2. Encontrar o Speaker
local speaker = peripheral.find("speaker")
if not speaker then
    term.setTextColor(colors.red)
    print("ERRO: Nenhum 'speaker' encontrado!")
    return
end

-- 3. Conectar ao canal
print("Conectando ao canal '"..CHANNEL_NAME.."'...")
bridge.joinChannel(CHANNEL_NAME, speaker)

term.setTextColor(colors.green)
print("Sucesso! Conectado e aguardando audio.")
print("Speaker: " .. peripheral.getName(speaker))

-- Loop simples para manter o programa rodando e permitir reinicialização fácil
print("\nPressione qualquer tecla para sair/reiniciar.")
os.pullEvent("key")

-- Ao sair, é boa prática desconectar, embora o mod deva lidar com desconexões
bridge.leaveChannel(CHANNEL_NAME, speaker)
print("Desconectado.")
