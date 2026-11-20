-- ZATH HUB | GITHUB LOADER
local URL = "https://raw.githubusercontent.com/verobezileonardo-stack/ZathHub/main/src/main.lua"

local ok, err = pcall(function()
    assert(type(game.HttpGet) == "function", "HttpGet indisponivel")
    local source = game:HttpGet(URL)
    assert(type(source) == "string" and #source > 0, "Arquivo remoto vazio")
    assert(type(loadstring) == "function", "loadstring indisponivel")
    local chunk, compileError = loadstring(source)
    assert(chunk, compileError or "Falha ao compilar main.lua")
    chunk()
end)

if not ok then
    warn("[ZATH HUB] Falha ao carregar: " .. tostring(err))
end
