-- ZATH HUB | GITHUB LOADER
-- Cache-buster dinamico para evitar receber main.lua antigo do cache.
local CACHE_KEY = tostring(os.time()) .. "-" .. tostring(math.floor(os.clock() * 1000))
local URL = "https://raw.githubusercontent.com/verobezileonardo-stack/ZathHub/main/src/main.lua?zath_cache=" .. CACHE_KEY

local ok, err = pcall(function()
    assert(type(game.HttpGet) == "function", "HttpGet indisponivel")
    local source = game:HttpGet(URL)
    assert(type(source) == "string" and #source > 0, "Arquivo remoto vazio")
    assert(string.find(source, "ZathFloatingButton", 1, true), "Versao inesperada recebida do GitHub")
    assert(not string.find(source, "ENCERRAR HUB", 1, true), "O GitHub retornou uma versao antiga do hub")
    assert(type(loadstring) == "function", "loadstring indisponivel")
    local chunk, compileError = loadstring(source)
    assert(chunk, compileError or "Falha ao compilar main.lua")
    chunk()
end)

if not ok then
    warn("[ZATH HUB] Falha ao carregar: " .. tostring(err))
end
