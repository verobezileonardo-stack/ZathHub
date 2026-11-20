--========================================================
-- ZATH HUB V4 | FAZENDA DE ANIME
-- Revisao: ciclos limitados, coleta sem repeticao por spawn,
-- cancelamento global de sessoes e coleta separada de itens.
--========================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")
local CoreGui = game:GetService("CoreGui")

local Player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function remote(name)
    return Remotes:WaitForChild(name)
end

local UseItem = remote("UseItem")
local CollectVariant = remote("CollectVariantTokenSpawn")
local CollectObject = remote("CollectCollectableObject")
local PickupCrate = remote("PickupCrateBox")
local DepositCrate = remote("DepositCrate")
local CollectPolished = remote("CollectPolisherCrate")
local SellCrate = remote("SellCrate")

local ItemRainEvent = remote("ItemRainDrop")
local ItemRainRemoved = remote("ItemRainRemoved")
local GetItemRainDrops = remote("GetItemRainDrops")
local CollectItemRainItem = remote("CollectItemRainItem")

local SpawnFolder = workspace:WaitForChild("Systems")
    :WaitForChild("VariantTokenSpawns")

-- Cancela uma execucao anterior antes de iniciar esta.
local ENV = (type(getgenv) == "function" and getgenv()) or _G
if ENV.ZATH_HUB_SESSION then
    ENV.ZATH_HUB_SESSION.stopped = true
end

local Session = { stopped = false }
ENV.ZATH_HUB_SESSION = Session

local function running()
    return not Session.stopped
        and ENV.ZATH_HUB_SESSION == Session
end

local Config = {
    Variant = false,
    Items = false,
    Crates = false,
    AntiAFK = false,
    Potions = {
        BluetoothPotion = false,
        CashPotion = false,
        GradeSpeedPotion = false,
        LuckPotion = false
    }
}


--========================================================
-- CONFIGURACOES PERSISTENTES (ARQUIVO LOCAL DO EXECUTOR)
--========================================================

local HttpService = game:GetService("HttpService")
local CONFIG_FOLDER = "ZathHub"
local CONFIG_FILE = CONFIG_FOLDER .. "/config.json"
local filePersistence = false

local function configSnapshot()
    return {
        Variant = Config.Variant == true,
        Items = Config.Items == true,
        Crates = Config.Crates == true,
        AntiAFK = Config.AntiAFK == true,
        Potions = {
            BluetoothPotion = Config.Potions.BluetoothPotion == true,
            CashPotion = Config.Potions.CashPotion == true,
            GradeSpeedPotion = Config.Potions.GradeSpeedPotion == true,
            LuckPotion = Config.Potions.LuckPotion == true
        }
    }
end

local function applyConfig(saved)
    if type(saved) ~= "table" then return end

    for _, key in ipairs({ "Variant", "Items", "Crates", "AntiAFK" }) do
        if type(saved[key]) == "boolean" then
            Config[key] = saved[key]
        end
    end

    if type(saved.Potions) == "table" then
        for key in pairs(Config.Potions) do
            if type(saved.Potions[key]) == "boolean" then
                Config.Potions[key] = saved.Potions[key]
            end
        end
    end
end

local function saveConfig()
    local snapshot = configSnapshot()
    ENV.ZATH_HUB_CONFIG_CACHE = snapshot

    if type(writefile) ~= "function" then
        return false, "Executor sem writefile"
    end

    local ok, err = pcall(function()
        if type(isfolder) == "function" then
            if not isfolder(CONFIG_FOLDER) then
                assert(type(makefolder) == "function", "makefolder indisponivel")
                makefolder(CONFIG_FOLDER)
            end
        elseif type(makefolder) == "function" then
            pcall(makefolder, CONFIG_FOLDER)
        end

        writefile(CONFIG_FILE, HttpService:JSONEncode(snapshot))
    end)

    if ok then
        filePersistence = true
        return true
    end
    return false, tostring(err)
end

local function loadConfig()
    -- Cache da sessao atual como fallback; so o arquivo sobrevive ao rejoin.
    if type(ENV.ZATH_HUB_CONFIG_CACHE) == "table" then
        applyConfig(ENV.ZATH_HUB_CONFIG_CACHE)
    end

    if type(readfile) ~= "function" then
        warn("[ZATH] Executor sem readfile; configuracoes nao persistem apos rejoin.")
        return false
    end

    local ok, result = pcall(function()
        if type(isfile) == "function" and not isfile(CONFIG_FILE) then
            return nil
        end
        return readfile(CONFIG_FILE)
    end)

    if not ok or type(result) ~= "string" or result == "" then
        return false
    end

    local decodedOk, decoded = pcall(function()
        return HttpService:JSONDecode(result)
    end)

    if decodedOk and type(decoded) == "table" then
        applyConfig(decoded)
        filePersistence = true
        return true
    end

    warn("[ZATH] Arquivo de configuracao invalido; usando padroes/cache.")
    return false
end

local loadedFromFile = loadConfig()

local CYCLE_INTERVAL = 30 * 60
local OBJECT_SCAN_INTERVAL = 0.75
local VARIANT_RETRY_INTERVAL = 3

local discovered = {}
local variantAttempted = setmetatable({}, { __mode = "k" })
local objectAttempted = setmetatable({}, { __mode = "k" })
local objectBusy = setmetatable({}, { __mode = "k" })
local rainDrops, rainAttempted = {}, {}
local potionBusy = {}
local crateBusy = false

local VALID_OBJECT_KEYS = {
    LuckPotion = true,
    CashPotion = true,
    GradeToken = true,
    TraitToken = true
}

local ClientData, ItemService
pcall(function()
    ClientData = require(ReplicatedStorage.Client.Data.ClientDataManager)
    ItemService = require(ReplicatedStorage.Shared.Services.ItemService)
end)

--========================================================
-- UTILITARIOS
--========================================================

local function character()
    return Player.Character
end

local function root()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function getPart(object)
    if not object then return nil end
    if object:IsA("BasePart") then return object end
    if object:IsA("Model") then
        return object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function teleport(target)
    if not running() then return false end
    local r, p = root(), getPart(target)
    if not r or not p then return false end
    r.CFrame = p.CFrame + Vector3.new(0, 3, 0)
    task.wait(0.15)
    return running()
end

local function teleportPosition(position)
    if not running() or typeof(position) ~= "Vector3" then return false end
    local r = root()
    if not r then return false end
    r.CFrame = CFrame.new(position)
    task.wait(0.15)
    return running()
end

local function waitUntil(condition, timeout, requireCrates)
    local started = os.clock()
    repeat
        if not running() then return false end
        if requireCrates and not Config.Crates then return false end
        local ok, result = pcall(condition)
        if ok and result then return true end
        task.wait(0.15)
    until os.clock() - started >= timeout
    return false
end

local function getPotionAmount(name)
    if ItemService then
        local ok, amount = pcall(function()
            return ItemService.GetAmountOfItem(Player, name)
        end)
        if ok and amount ~= nil then return tonumber(amount) or 0 end
    end

    if not ClientData then return 0 end
    local ok, data = pcall(function() return ClientData.GetData() end)
    if not ok or type(data) ~= "table" or type(data.Potions) ~= "table" then
        return 0
    end

    local amount = data.Potions[name]
    if type(amount) == "table" then
        return tonumber(amount.Amount) or 0
    end
    return tonumber(amount) or 0
end

local function getPlot()
    local map = workspace:FindFirstChild("Map")
    local plots = map and map:FindFirstChild("PlotModels")
    return plots and plots:FindFirstChild(Player.Name)
end

local function getTaggedInPlot(tag)
    local plot, result = getPlot(), {}
    if not plot then return result end
    for _, object in ipairs(CollectionService:GetTagged(tag)) do
        if object:IsDescendantOf(plot) then
            table.insert(result, object)
        end
    end
    return result
end

--========================================================
-- INVENTARIO E ESTRUTURAS DE CAIXAS
--========================================================

local function getCrateTools(shiny)
    local result = {}
    local containers = { character(), Player:FindFirstChildOfClass("Backpack") }
    for _, container in ipairs(containers) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool")
                    and tool:GetAttribute("InventoryType") == "Crate"
                    and (tool:GetAttribute("Shiny") == true) == shiny then
                    table.insert(result, tool)
                end
            end
        end
    end
    return result
end

local function equipTool(tool)
    local h = humanoid()
    if not h or not tool or not tool.Parent then return false end
    pcall(function() h:EquipTool(tool) end)
    task.wait(0.2)
    return tool.Parent == character()
end

local function getConveyors()
    local result = {}
    for _, part in ipairs(getTaggedInPlot("ConveyorCollectPart")) do
        local count = tonumber(part:GetAttribute("PendingBallCount")) or 0
        if count > 0 then table.insert(result, part) end
    end
    return result
end

local function getPolisher()
    for _, model in ipairs(getTaggedInPlot("CratePolisherModel")) do
        local physical = model:FindFirstChild("PhysicalModel")
        local collectPart = physical and physical:FindFirstChild("CollectPart")
        if collectPart then return model, collectPart end
    end
    return nil, nil
end

local function getSeller()
    for _, object in ipairs(getTaggedInPlot("SellNPC")) do
        local part = getPart(object)
        if part then return part end
    end
    return nil
end

-- Snapshot imutavel do lote: o limite de chamadas nunca cresce durante o ciclo.
local function createCrateBatch()
    local batch, total = {}, 0
    for _, conveyor in ipairs(getConveyors()) do
        local count = math.max(0, math.floor(
            tonumber(conveyor:GetAttribute("PendingBallCount")) or 0
        ))
        if count > 0 then
            batch[conveyor] = { remaining = count }
            total += count
        end
    end
    return batch, total
end

local function nextBatchConveyor(batch)
    for conveyor, info in pairs(batch) do
        if conveyor.Parent and info.remaining > 0 then
            local current = tonumber(conveyor:GetAttribute("PendingBallCount")) or 0
            if current > 0 then return conveyor, info end
            info.remaining = 0
        end
    end
    return nil, nil
end

local function collectNormalCrates(polisher, batch, limit)
    local calls, deposited = 0, 0
    while running() and Config.Crates and calls < limit do
        local held = getCrateTools(false)[1]
        if held then
            if not equipTool(held) or not teleport(polisher) then break end
            DepositCrate:FireServer(polisher)
            local depositedOk = waitUntil(function()
                return not held.Parent
            end, 7, true)
            if not depositedOk then
                warn("[ZATH] Deposito nao confirmado; encerrando o lote.")
                break
            end
            deposited += 1
        else
            local conveyor, info = nextBatchConveyor(batch)
            if not conveyor then break end
            if not teleport(conveyor) then break end

            local pending = tonumber(conveyor:GetAttribute("PendingBallCount")) or 0
            if pending <= 0 then
                info.remaining = 0
            else
                -- Consome o limite antes do remote: falha nao gera repeticao infinita.
                info.remaining -= 1
                calls += 1
                local before = #getCrateTools(false)
                PickupCrate:FireServer(conveyor)

                local appeared = waitUntil(function()
                    return #getCrateTools(false) > before
                end, 7, true)

                if not appeared then
                    warn("[ZATH] Retirada sem confirmacao; tentativa contabilizada.")
                end
            end
        end
        task.wait(0.2)
    end

    print("[ZATH] Lote normal finalizado | chamadas:", calls,
        "| depositos:", deposited, "| limite:", limit)
    return calls, deposited
end

local function waitForPolishing(model, polisher)
    local started = os.clock()
    local sawActive = model:GetAttribute("PolisherActive") == true

    while running() and Config.Crates and os.clock() - started < 180 do
        local active = model:GetAttribute("PolisherActive") == true
        local count = tonumber(polisher:GetAttribute("PolishedBallCount")) or 0
        if active then sawActive = true end
        if count > 0 and (not active) then return true end
        if sawActive and not active and count > 0 then return true end
        if not active and count <= 0 and os.clock() - started >= 8 then
            return false
        end
        task.wait(0.5)
    end
    return false
end

local function collectBlueCrates(polisher)
    if not teleport(polisher) then return end

    local initial = math.max(0, math.floor(
        tonumber(polisher:GetAttribute("PolishedBallCount")) or 0
    ))
    local maxCalls = initial
    local calls = 0

    while running() and Config.Crates and calls < maxCalls do
        local count = tonumber(polisher:GetAttribute("PolishedBallCount")) or 0
        if count <= 0 then break end

        local beforeTools = #getCrateTools(true)
        calls += 1
        CollectPolished:FireServer(polisher)

        local confirmed = waitUntil(function()
            local nowCount = tonumber(polisher:GetAttribute("PolishedBallCount")) or 0
            return #getCrateTools(true) > beforeTools or nowCount < count
        end, 7, true)

        if not confirmed then
            warn("[ZATH] Coleta azul sem confirmacao; limite encerrado.")
            break
        end
        task.wait(0.25)
    end

    print("[ZATH] Coleta azul | chamadas:", calls, "| limite:", maxCalls)
end

local function sellBlueCrates(seller)
    local snapshot = getCrateTools(true)
    if #snapshot == 0 or not teleport(seller) then return end

    for _, tool in ipairs(snapshot) do
        if not running() or not Config.Crates then break end
        if tool.Parent and equipTool(tool) then
            local guid = tool:GetAttribute("InventoryKey")
            if guid then
                SellCrate:FireServer(guid)
                if not waitUntil(function() return not tool.Parent end, 6, true) then
                    warn("[ZATH] Venda nao confirmada; seguindo para o proximo item.")
                end
            end
            task.wait(0.2)
        end
    end
end

local function monitorPolisher(model, polisher, seller, endTime)
    while running() and Config.Crates and os.clock() < endTime do
        local active = model:GetAttribute("PolisherActive") == true
        local count = tonumber(polisher:GetAttribute("PolishedBallCount")) or 0

        if not active and count > 0 then
            collectBlueCrates(polisher)
            sellBlueCrates(seller)
        end
        if #getCrateTools(true) > 0 then sellBlueCrates(seller) end
        task.wait(1.5)
    end
end

local function crateCycle()
    if crateBusy or not running() or not Config.Crates then return end
    crateBusy = true

    local ok, err = pcall(function()
        local model, polisher = getPolisher()
        local seller = getSeller()
        if not model or not polisher or not seller then
            warn("[ZATH] Polidor ou vendedor nao encontrado.")
            return
        end

        local batch, total = createCrateBatch()
        if total <= 0 then return end

        print("[ZATH] Iniciando lote limitado:", total)
        collectNormalCrates(polisher, batch, total)

        if not running() or not Config.Crates then return end
        local endTime = os.clock() + CYCLE_INTERVAL
        print("[ZATH] Coleta normal pausada por 30 minutos.")
        monitorPolisher(model, polisher, seller, endTime)
        print("[ZATH] Intervalo encerrado; novo snapshot sera permitido.")
    end)

    if not ok then warn("[ZATH] Erro no ciclo:", err) end
    crateBusy = false
end

task.spawn(function()
    while running() do
        if Config.Crates and not crateBusy then crateCycle() end
        task.wait(1)
    end
end)

--========================================================
-- VARIANTES: uma chamada por ocupacao/spawn
--========================================================

local function collectVariant(part)
    if not running() or not Config.Variant or not part
        or not part:IsA("BasePart") or not part.Parent then return end

    if part:GetAttribute("Occupied") ~= true then
        variantAttempted[part] = nil
        return
    end

    local variant = part:GetAttribute("Variant")
    if not variant or variantAttempted[part] then return end

    variantAttempted[part] = true
    discovered[tostring(variant)] = true

    task.spawn(function()
        if running() and Config.Variant and part.Parent
            and part:GetAttribute("Occupied") == true
            and teleport(part) then
            CollectVariant:FireServer(part)
        end
    end)
end

local function monitorVariant(part)
    if not part:IsA("BasePart") then return end
    part:GetAttributeChangedSignal("Occupied"):Connect(function()
        if part:GetAttribute("Occupied") ~= true then
            variantAttempted[part] = nil
        else
            collectVariant(part)
        end
    end)
    part:GetAttributeChangedSignal("Variant"):Connect(function()
        collectVariant(part)
    end)
    collectVariant(part)
end

for _, part in ipairs(SpawnFolder:GetChildren()) do monitorVariant(part) end
SpawnFolder.ChildAdded:Connect(monitorVariant)

--========================================================
-- COLLECTABLE OBJECT: uma chamada por ciclo Occupied true
--========================================================

local function collectObject(node)
    if not running() or not Config.Items or not node or not node.Parent then return end
    if node:GetAttribute("Occupied") ~= true then
        objectAttempted[node] = nil
        return
    end

    local key = node:GetAttribute("ObjectKey")
    if not VALID_OBJECT_KEYS[key] or objectAttempted[node] or objectBusy[node] then
        return
    end

    local part = getPart(node)
    if not part then return end

    objectBusy[node] = true
    objectAttempted[node] = true

    task.spawn(function()
        local ok, err = pcall(function()
            if running() and Config.Items and node.Parent
                and node:GetAttribute("Occupied") == true
                and teleport(part) then
                CollectObject:FireServer(node)
            end
        end)
        if not ok then warn("[ZATH] CollectableObject:", err) end
        objectBusy[node] = nil
    end)
end

local function monitorObject(node)
    if not node then return end
    node:GetAttributeChangedSignal("Occupied"):Connect(function()
        if node:GetAttribute("Occupied") ~= true then
            objectAttempted[node] = nil
        else
            collectObject(node)
        end
    end)
    node:GetAttributeChangedSignal("ObjectKey"):Connect(function()
        objectAttempted[node] = nil
        collectObject(node)
    end)
    collectObject(node)
end

for _, node in ipairs(CollectionService:GetTagged("CollectableObject")) do
    monitorObject(node)
end
CollectionService:GetInstanceAddedSignal("CollectableObject"):Connect(monitorObject)

task.spawn(function()
    while running() do
        if Config.Items then
            for _, node in ipairs(CollectionService:GetTagged("CollectableObject")) do
                collectObject(node)
            end
        end
        task.wait(OBJECT_SCAN_INTERVAL)
    end
end)

--========================================================
-- ITEM RAIN: uma tentativa por ID ate o evento de remocao
--========================================================

local function registerRainDrop(data)
    if type(data) == "table" and data.Id ~= nil then
        rainDrops[data.Id] = data
    end
end

local function removeRainDrop(id)
    rainDrops[id] = nil
    rainAttempted[id] = nil
end

pcall(function()
    local drops = GetItemRainDrops:InvokeServer()
    if type(drops) == "table" then
        for _, data in pairs(drops) do registerRainDrop(data) end
    end
end)

ItemRainEvent.OnClientEvent:Connect(registerRainDrop)
ItemRainRemoved.OnClientEvent:Connect(removeRainDrop)

local function collectRainDrop(id, data)
    if not running() or not Config.Items or rainAttempted[id] then return end
    if type(data) ~= "table" or typeof(data.LandPosition) ~= "Vector3" then return end

    local landAt = tonumber(data.LandAt)
    if not landAt or workspace:GetServerTimeNow() < landAt then return end

    rainAttempted[id] = true
    task.spawn(function()
        local ok, err = pcall(function()
            if running() and Config.Items then
                teleportPosition(data.LandPosition + Vector3.new(0, 3, 0))
                if running() and Config.Items then
                    CollectItemRainItem:FireServer(id)
                end
            end
        end)
        if not ok then warn("[ZATH] ItemRain:", err) end
    end)
end

task.spawn(function()
    while running() do
        if Config.Items then
            for id, data in pairs(rainDrops) do collectRainDrop(id, data) end
        end
        task.wait(0.25)
    end
end)

--========================================================
-- POCOES
--========================================================

local function usePotion(name)
    if potionBusy[name] then return end
    potionBusy[name] = true

    task.spawn(function()
        while running() and Config.Potions[name] do
            local before = getPotionAmount(name)
            if before <= 0 then break end

            UseItem:FireServer(name)
            local consumed = waitUntil(function()
                return getPotionAmount(name) < before
            end, 5, false)

            if not consumed then
                warn("[ZATH] Consumo da pocao nao confirmado:", name)
                break
            end
            task.wait(0.2)
        end
        potionBusy[name] = nil
    end)
end

task.spawn(function()
    while running() do
        for name, enabled in pairs(Config.Potions) do
            if enabled and not potionBusy[name] and getPotionAmount(name) > 0 then
                usePotion(name)
            end
        end
        task.wait(0.5)
    end
end)

--========================================================
-- ANTI-AFK
-- Observacao: cobre o evento Idled do cliente; nao controla
-- teleport/servidor AFK implementado pelo proprio jogo.
--========================================================

Player.Idled:Connect(function()
    if running() and Config.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

--========================================================
-- INTERFACE
--========================================================

pcall(function()
    local old = CoreGui:FindFirstChild("ZATH_HUB_V4")
    if old then old:Destroy() end
end)

local parent = CoreGui
pcall(function()
    if type(gethui) == "function" then parent = gethui() end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "ZATH_HUB_V4"
gui.ResetOnSpawn = false
gui.Parent = parent

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(360, 500)
main.Position = UDim2.new(0.5, -180, 0.5, -250)
main.BackgroundColor3 = Color3.fromRGB(17, 17, 24)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local outline = Instance.new("UIStroke", main)
outline.Color = Color3.fromRGB(145, 75, 210)
outline.Thickness = 1.5

local function label(text, x, y, w, h, color, parentObject)
    local obj = Instance.new("TextLabel")
    obj.BackgroundTransparency = 1
    obj.Position = UDim2.fromOffset(x, y)
    obj.Size = UDim2.fromOffset(w, h)
    obj.Font = Enum.Font.Gotham
    obj.Text = text
    obj.TextSize = 12
    obj.TextColor3 = color or Color3.fromRGB(235, 235, 240)
    obj.TextXAlignment = Enum.TextXAlignment.Left
    obj.Parent = parentObject or main
    return obj
end

local function button(text, x, y, w, h, callback, parentObject)
    local obj = Instance.new("TextButton")
    obj.Position = UDim2.fromOffset(x, y)
    obj.Size = UDim2.fromOffset(w, h)
    obj.BackgroundColor3 = Color3.fromRGB(43, 35, 58)
    obj.TextColor3 = Color3.fromRGB(245, 240, 255)
    obj.Font = Enum.Font.GothamBold
    obj.TextSize = 12
    obj.Text = text
    obj.Parent = parentObject or main
    Instance.new("UICorner", obj).CornerRadius = UDim.new(0, 6)
    obj.MouseButton1Click:Connect(callback)
    return obj
end

label("ZATH HUB  |  V4", 15, 10, 260, 28,
    Color3.fromRGB(195, 140, 255)).TextSize = 18

local minimized = false
local body = Instance.new("Frame")
body.Position = UDim2.fromOffset(10, 67)
body.Size = UDim2.new(1, -20, 1, -78)
body.BackgroundTransparency = 1
body.Parent = main

local status = label(
    loadedFromFile and "Configuracoes carregadas do arquivo"
        or (filePersistence and "Configuracoes carregadas" or "Configuracoes padrao/cache"),
    15, 40, 320, 20, Color3.fromRGB(160, 220, 170)
)

local function section(text, y)
    label(text, 5, y, 320, 20, Color3.fromRGB(190, 130, 255), body)
end

local function toggle(text, key, y, tableRef)
    local b
    b = button("", 5, y, 325, 29, function()
        tableRef[key] = not tableRef[key]
        local on = tableRef[key]
        local saved, saveError = saveConfig()
        if saved then
            status.Text = "Configuracao salva automaticamente"
        else
            status.Text = "Aviso: configuracao nao persistida (" .. tostring(saveError) .. ")"
        end
        b.Text = text .. (on and "  [ON]" or "  [OFF]")
        b.BackgroundColor3 = on
            and Color3.fromRGB(75, 45, 115)
            or Color3.fromRGB(43, 35, 58)

        if key == "Variant" and on then
            for _, part in ipairs(SpawnFolder:GetChildren()) do collectVariant(part) end
        elseif key == "Items" and on then
            for _, node in ipairs(CollectionService:GetTagged("CollectableObject")) do
                collectObject(node)
            end
            for id, data in pairs(rainDrops) do collectRainDrop(id, data) end
        elseif tableRef == Config.Potions and on then
            usePotion(key)
        end

        status.Text = text .. (on and " ativado" or " desativado")
    end, body)

    local function refresh()
        local on = tableRef[key]
        b.Text = text .. (on and "  [ON]" or "  [OFF]")
        b.BackgroundColor3 = on
            and Color3.fromRGB(75, 45, 115)
            or Color3.fromRGB(43, 35, 58)
    end
    refresh()
end

section("AUTOMACAO", 0)
toggle("Coletar variantes automaticamente", "Variant", 23, Config)
toggle("Coletar itens e Item Rain (sem dinheiro)", "Items", 57, Config)
toggle("Farm de caixas / polidor / venda", "Crates", 91, Config)
toggle("Anti-AFK do cliente", "AntiAFK", 125, Config)

section("POCOES — CONTROLES INDIVIDUAIS", 165)
toggle("Pocao Bluetooth", "BluetoothPotion", 188, Config.Potions)
toggle("Pocao de Dinheiro (Cash)", "CashPotion", 222, Config.Potions)
toggle("Pocao de Velocidade dos Giros", "GradeSpeedPotion", 256, Config.Potions)
toggle("Pocao de Sorte", "LuckPotion", 290, Config.Potions)

button("SALVAR CONFIGURACOES", 5, 324, 325, 24, function()
    local ok, err = saveConfig()
    status.Text = ok and "Configuracoes salvas no executor"
        or ("Falha ao salvar: " .. tostring(err))
end, body)

section("VARIANTES DESCOBERTAS", 353)
local variantList = label("Aguardando variantes...", 8, 375, 320, 35,
    Color3.fromRGB(220, 210, 240), body)
variantList.TextYAlignment = Enum.TextYAlignment.Top
variantList.TextWrapped = true

local function updateVariants()
    local names = {}
    for name in pairs(discovered) do table.insert(names, name) end
    table.sort(names)
    variantList.Text = #names > 0
        and table.concat(names, "  |  ")
        or "Nenhuma variante descoberta."
end

task.spawn(function()
    while running() and gui.Parent do
        updateVariants()
        task.wait(1)
    end
end)

local minimize = button("—", 320, 9, 25, 25, function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(360, 48)
        or UDim2.fromOffset(360, 500)
    minimize.Text = minimized and "+" or "—"
end)

button("ENCERRAR HUB", 15, 465, 330, 25, function()
    Session.stopped = true
    for key in pairs(Config) do
        if type(Config[key]) == "boolean" then Config[key] = false end
    end
    for key in pairs(Config.Potions) do Config.Potions[key] = false end
    table.clear(rainDrops)
    table.clear(rainAttempted)
    gui:Destroy()
end)

print("[ZATH HUB V4] Inicializado.")
print("[ZATH HUB V4] Limite de coleta por lote ativado.")
print("[ZATH HUB V4] Itens e Item Rain monitorados separadamente.")
print("[ZATH HUB V4] Intervalo entre lotes normais: 30 minutos.")
