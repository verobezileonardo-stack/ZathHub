--========================================================
-- ZATH HUB V4 | FAZENDA DE ANIME
-- Revisao: ciclos limitados, coleta sem repeticao por spawn,
-- cancelamento global de sessoes e coleta separada de itens.
--========================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
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
    AntiAFK = false,
    AutoRewards = false,
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
        AntiAFK = Config.AntiAFK == true,
        AutoRewards = Config.AutoRewards == true,
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

    for _, key in ipairs({ "Variant", "Items", "AntiAFK", "AutoRewards" }) do
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
-- INTERFACE | ACRYLIC COM JANELA E BOTAO FLUTUANTE
--========================================================

-- Remove todas as instancias anteriores, inclusive quando o executor
-- colocou o ScreenGui em gethui() em vez de CoreGui.
local parent = CoreGui
pcall(function()
    if type(gethui) == "function" then
        parent = gethui()
    end
end)

pcall(function()
    local previousGui = ENV.ZATH_HUB_GUI
    if previousGui then previousGui:Destroy() end
end)

local guiContainers = { CoreGui }
if parent ~= CoreGui then
    table.insert(guiContainers, parent)
end

for _, container in ipairs(guiContainers) do
    pcall(function()
        for _, child in ipairs(container:GetChildren()) do
            if child.Name == "ZATH_HUB_V4" then
                child:Destroy()
            end
        end
    end)
end

local gui = Instance.new("ScreenGui")
gui.Name = "ZATH_HUB_V4"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 9999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parent
ENV.ZATH_HUB_GUI = gui

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(360, 530)
main.Position = UDim2.new(0.5, -180, 0.5, -265)
main.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
main.BackgroundTransparency = 0.16
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 13)

local outline = Instance.new("UIStroke", main)
outline.Color = Color3.fromRGB(65, 139, 245)
outline.Transparency = 0.28
outline.Thickness = 1.2

local mainGradient = Instance.new("UIGradient", main)
mainGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(27, 30, 45)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 15, 24))
})
mainGradient.Rotation = 90

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
    obj.BackgroundColor3 = Color3.fromRGB(36, 48, 70)
    obj.BackgroundTransparency = 0.12
    obj.TextColor3 = Color3.fromRGB(235, 242, 255)
    obj.Font = Enum.Font.GothamBold
    obj.TextSize = 12
    obj.Text = text
    obj.AutoButtonColor = true
    obj.Parent = parentObject or main
    Instance.new("UICorner", obj).CornerRadius = UDim.new(0, 7)
    obj.MouseButton1Click:Connect(callback)
    return obj
end

local maximized = false
local normalSize = UDim2.fromOffset(360, 530)
local maxSize = UDim2.fromOffset(440, 590)

local header = Instance.new("Frame")
header.Name = "Header"
header.BackgroundTransparency = 1
header.Position = UDim2.fromOffset(0, 0)
header.Size = UDim2.new(1, 0, 0, 62)
header.Parent = main

local title = label("ZATH HUB", 15, 9, 180, 25, Color3.fromRGB(224, 237, 255), header)
title.Font = Enum.Font.GothamBold
title.TextSize = 19

local subtitle = label("V4  •  AUTOMATION", 16, 33, 190, 16, Color3.fromRGB(126, 166, 220), header)
subtitle.TextSize = 9
subtitle.Font = Enum.Font.GothamMedium

local function headerButton(text, x, callback)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(23, 23)
    b.Position = UDim2.new(1, x, 0, 10)
    b.BackgroundColor3 = Color3.fromRGB(48, 54, 72)
    b.BackgroundTransparency = 0.12
    b.Text = text
    b.TextColor3 = Color3.fromRGB(235, 240, 250)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.Parent = header
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.MouseButton1Click:Connect(callback)
    return b
end

local body = Instance.new("Frame")
body.Name = "Content"
body.Position = UDim2.fromOffset(10, 67)
body.Size = UDim2.new(1, -20, 1, -78)
body.BackgroundTransparency = 1
body.Parent = main

local status = label(
    loadedFromFile and "Configuracoes carregadas do arquivo"
        or (filePersistence and "Configuracoes carregadas" or "Configuracoes padrao/cache"),
    15, 49, 230, 12, Color3.fromRGB(155, 205, 175), header
)
status.TextSize = 9

local function section(text, y)
    local line = Instance.new("Frame")
    line.Position = UDim2.fromOffset(5, y + 18)
    line.Size = UDim2.new(1, -10, 0, 1)
    line.BackgroundColor3 = Color3.fromRGB(76, 91, 119)
    line.BackgroundTransparency = 0.55
    line.BorderSizePixel = 0
    line.Parent = body
    local t = label(text, 5, y, 320, 18, Color3.fromRGB(125, 177, 245), body)
    t.Font = Enum.Font.GothamBold
    t.TextSize = 10
end

local function toggle(text, key, y, tableRef)
    local row = Instance.new("Frame")
    row.Position = UDim2.fromOffset(5, y)
    row.Size = UDim2.new(1, -10, 0, 29)
    row.BackgroundColor3 = Color3.fromRGB(38, 43, 58)
    row.BackgroundTransparency = 0.42
    row.BorderSizePixel = 0
    row.Parent = body
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)

    local name = label(text, 9, 0, 255, 29, Color3.fromRGB(230, 234, 244), row)
    name.Font = Enum.Font.GothamMedium
    name.TextSize = 11

    local track = Instance.new("Frame")
    track.Name = "Switch"
    track.Size = UDim2.fromOffset(42, 22)
    track.Position = UDim2.new(1, -51, 0.5, -11)
    track.BorderSizePixel = 0
    track.Parent = row
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.Size = UDim2.fromOffset(16, 16)
    knob.Position = UDim2.new(0, 3, 0.5, -8)
    knob.BorderSizePixel = 0
    knob.Parent = track
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local hitbox = Instance.new("TextButton")
    hitbox.Size = UDim2.fromScale(1, 1)
    hitbox.BackgroundTransparency = 1
    hitbox.Text = ""
    hitbox.Parent = row

    local function refresh()
        local on = tableRef[key] == true
        track.BackgroundColor3 = on
            and Color3.fromRGB(42, 133, 245)
            or Color3.fromRGB(91, 96, 108)
        knob.BackgroundColor3 = on
            and Color3.fromRGB(17, 20, 29)
            or Color3.fromRGB(164, 168, 177)
        knob.Position = on
            and UDim2.new(1, -19, 0.5, -8)
            or UDim2.new(0, 3, 0.5, -8)
    end

    hitbox.MouseButton1Click:Connect(function()
        tableRef[key] = not tableRef[key]
        local on = tableRef[key]
        local saved, saveError = saveConfig()
        status.Text = saved and "Configuracao salva automaticamente"
            or ("Nao foi possivel salvar: " .. tostring(saveError))

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
        refresh()
    end)
    refresh()
end

section("AUTOMACAO", 0)
toggle("Coletar variantes automaticamente", "Variant", 23, Config)
toggle("Coletar itens e Item Rain (sem dinheiro)", "Items", 57, Config)
toggle("Anti-AFK do cliente", "AntiAFK", 91, Config)
toggle("Auto Collect Rewards", "AutoRewards", 125, Config)

section("POCOES", 171)
toggle("Pocao Bluetooth", "BluetoothPotion", 194, Config.Potions)
toggle("Pocao de Dinheiro (Cash)", "CashPotion", 228, Config.Potions)
toggle("Pocao de Velocidade dos Giros", "GradeSpeedPotion", 262, Config.Potions)
toggle("Pocao de Sorte", "LuckPotion", 296, Config.Potions)

button("SALVAR CONFIGURACOES", 5, 330, 325, 25, function()
    local ok, err = saveConfig()
    status.Text = ok and "Configuracoes salvas no executor"
        or ("Falha ao salvar: " .. tostring(err))
end, body)

section("VARIANTES DESCOBERTAS", 362)
local variantList = label("Aguardando variantes...", 8, 384, 320, 35,
    Color3.fromRGB(210, 220, 238), body)
variantList.TextYAlignment = Enum.TextYAlignment.Top
variantList.TextWrapped = true

local rewardStatus = label(
    "Rewards: desligado",
    8, 421, 320, 18,
    Color3.fromRGB(155, 205, 175), body
)
rewardStatus.TextSize = 9

local function updateVariants()
    local names = {}
    for name in pairs(discovered) do table.insert(names, name) end
    table.sort(names)
    variantList.Text = #names > 0
        and table.concat(names, "  |  ")
        or "Nenhuma variante descoberta."
end

--========================================================
-- AUTO COLLECT REWARDS | DETECCAO PELO PAINEL DO JOGO
-- Nao inventa RemoteEvent: aciona o botao real de resgate
-- quando estiver visivel e habilitado na interface.
--========================================================

local rewardButtonStates = setmetatable({}, { __mode = "k" })
local REWARD_SCAN_INTERVAL = 1
local REWARD_RETRY_DELAY = 4
local REWARD_MAX_FAILED_ATTEMPTS = 2
local rewardTriggerCount = 0

local function lowerText(value)
    return string.lower(tostring(value or ""))
end

local function containsAny(source, words)
    for _, word in ipairs(words) do
        if string.find(source, word, 1, true) then
            return true
        end
    end
    return false
end

local REWARD_WORDS = {
    "reward", "rewards", "recompensa", "recompensas",
    "playtime", "timeplayed", "time_played", "timereward",
    "tempojogado", "tempo_jogado"
}

local ACTION_WORDS = {
    "claim", "collect", "resgatar", "coletar", "receber", "pegar"
}

local BLOCKED_WORDS = {
    "claimed", "collected", "resgatado", "coletado",
    "locked", "bloqueado", "aguarde", "wait",
    "coming soon", "em breve", "disponivel em", "available in"
}

local function safeText(instance)
    local ok, value = pcall(function()
        return instance.Text
    end)
    return ok and type(value) == "string" and value or ""
end

local function rewardButtonInfo(buttonObject)
    if not buttonObject:IsA("GuiButton") then return false, "", "" end

    local ownText = lowerText(buttonObject.Name .. " " .. safeText(buttonObject))
    local descendantText = ""

    for _, descendant in ipairs(buttonObject:GetDescendants()) do
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
            descendantText = descendantText .. " " ..
                lowerText(descendant.Name .. " " .. safeText(descendant))
        end
    end

    local actionText = ownText .. " " .. descendantText
    if not containsAny(actionText, ACTION_WORDS) then
        return false, actionText, ""
    end

    local contextText = ownText .. " " .. descendantText
    local ancestor = buttonObject.Parent
    local depth = 0

    while ancestor and depth < 5 do
        contextText = contextText .. " " .. lowerText(ancestor.Name)
        if ancestor:IsA("TextLabel") or ancestor:IsA("TextButton") then
            contextText = contextText .. " " .. lowerText(safeText(ancestor))
        end
        ancestor = ancestor.Parent
        depth = depth + 1
    end

    local isRewardContext = containsAny(contextText, REWARD_WORDS)
    return isRewardContext, actionText, contextText
end

local function rewardButtonVisible(buttonObject)
    local current = buttonObject
    while current do
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end
        if current:IsA("ScreenGui") and not current.Enabled then
            return false
        end
        current = current.Parent
    end

    if buttonObject.AbsoluteSize.X <= 0 or buttonObject.AbsoluteSize.Y <= 0 then
        return false
    end

    local ok, active = pcall(function()
        return buttonObject.Active
    end)
    if ok and not active then return false end

    local interactableOk, interactable = pcall(function()
        return buttonObject.Interactable
    end)
    if interactableOk and not interactable then return false end

    return true
end

local function rewardButtonReady(buttonObject, actionText)
    if not rewardButtonVisible(buttonObject) then return false end
    if containsAny(actionText, BLOCKED_WORDS) then return false end
    return true
end

local function clickRewardButton(buttonObject)
    -- Prefer firing the actual UI activation signal so the game's own
    -- LocalScript performs its normal server request and validation.
    if type(firesignal) == "function" then
        local ok = pcall(function()
            firesignal(buttonObject.Activated)
        end)
        if ok then return true end

        ok = pcall(function()
            firesignal(buttonObject.MouseButton1Click)
        end)
        if ok then return true end
    end

    -- Fallback to a real cursor click at the center of the visible button.
    local center = buttonObject.AbsolutePosition + (buttonObject.AbsoluteSize / 2)
    local x, y = center.X, center.Y

    local inputOk, inputService = pcall(function()
        return game:GetService("VirtualInputManager")
    end)

    if inputOk and inputService then
        local sent = pcall(function()
            inputService:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.08)
            inputService:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
        if sent then return true end
    end

    local userOk = pcall(function()
        VirtualUser:CaptureController()
        local camera = workspace.CurrentCamera
        local cframe = camera and camera.CFrame or CFrame.new()
        VirtualUser:Button1Down(Vector2.new(x, y), cframe)
        task.wait(0.08)
        VirtualUser:Button1Up(Vector2.new(x, y), cframe)
    end)

    return userOk
end

task.spawn(function()
    while running() and gui.Parent do
        if not Config.AutoRewards then
            rewardStatus.Text = "Rewards: desligado"
        else
            local playerGui = Player:FindFirstChildOfClass("PlayerGui")
            local scanned = 0
            local ready = 0

            if playerGui then
                for _, candidate in ipairs(playerGui:GetDescendants()) do
                    if candidate:IsA("GuiButton") then
                        local isReward, actionText = rewardButtonInfo(candidate)
                        if isReward then
                            scanned = scanned + 1
                            local isReady = rewardButtonReady(candidate, actionText)
                            local state = rewardButtonStates[candidate]

                            if not state then
                                state = { attempted = false, failures = 0, lastAttempt = 0 }
                                rewardButtonStates[candidate] = state
                            end

                            if not isReady then
                                -- A recompensa mudou para bloqueada/resgatada.
                                -- Permite uma nova coleta quando voltar a ficar pronta.
                                state.attempted = false
                                state.failures = 0
                                state.lastAttempt = 0
                            else
                                ready = ready + 1
                                local elapsed = os.clock() - state.lastAttempt
                                local mayRetry = not state.attempted
                                    and state.failures < REWARD_MAX_FAILED_ATTEMPTS
                                    and elapsed >= REWARD_RETRY_DELAY

                                if mayRetry then
                                    state.lastAttempt = os.clock()
                                    local clicked = clickRewardButton(candidate)
                                    if clicked then
                                        state.attempted = true
                                        rewardTriggerCount = rewardTriggerCount + 1
                                    else
                                        state.failures = state.failures + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if scanned == 0 then
                rewardStatus.Text = "Rewards: abra o painel de recompensas"
            elseif ready == 0 then
                rewardStatus.Text = "Rewards: " .. scanned .. " encontradas • aguardando"
            else
                rewardStatus.Text = "Rewards: " .. ready .. " liberada(s) • " ..
                    rewardTriggerCount .. " clique(s) enviado(s)"
            end
        end

        task.wait(REWARD_SCAN_INTERVAL)
    end
end)

task.spawn(function()
    while running() and gui.Parent do
        updateVariants()
        task.wait(1)
    end
end)

local floating = Instance.new("TextButton")
floating.Name = "ZathFloatingButton"
floating.Size = UDim2.fromOffset(50, 50)
floating.Position = UDim2.new(0, 24, 0.5, -25)
floating.BackgroundColor3 = Color3.fromRGB(35, 112, 220)
floating.BackgroundTransparency = 0.02
floating.Text = "Z"
floating.TextColor3 = Color3.fromRGB(8, 15, 27)
floating.Font = Enum.Font.GothamBlack
floating.TextSize = 22
floating.Visible = false
floating.AutoButtonColor = true
floating.Active = true
floating.Draggable = true
floating.ZIndex = 100
floating.Parent = gui

local floatingAspect = Instance.new("UIAspectRatioConstraint")
floatingAspect.AspectRatio = 1
floatingAspect.Parent = floating

Instance.new("UICorner", floating).CornerRadius = UDim.new(1, 0)
local floatStroke = Instance.new("UIStroke", floating)
floatStroke.Color = Color3.fromRGB(150, 205, 255)
floatStroke.Thickness = 1.8
floatStroke.Transparency = 0.05

local function setPanelVisible(visible)
    -- Estados mutuamente exclusivos: janela OU bolinha, nunca os dois.
    if visible then
        floating.Visible = false
        main.Visible = true
    else
        main.Visible = false
        floating.Visible = true
    end
end

local closeButton = headerButton("×", -33, function()
    -- O X encerra o hub; nao existe botao extra no rodape.
    Session.stopped = true
    ContextActionService:UnbindAction(KEYBIND_ACTION)
    if ENV.ZATH_HUB_GUI == gui then
        ENV.ZATH_HUB_GUI = nil
    end
    gui:Destroy()
end)

local maximizeButton = headerButton("□", -61, function()
    maximized = not maximized
    main.Size = maximized and maxSize or normalSize
    maximizeButton.Text = maximized and "▣" or "□"
end)

local minimizeButton = headerButton("−", -89, function()
    -- Minimizar esconde a janela inteira; somente a bolinha permanece.
    setPanelVisible(false)
end)

floating.MouseButton1Click:Connect(function()
    setPanelVisible(true)
end)

-- Atalho global: Ctrl esquerdo alterna a janela usando prioridade alta.
-- Isso evita que a interface/jogo consuma o atalho antes do hub recebe-lo.
local KEYBIND_ACTION = "ZATH_HUB_TOGGLE_WINDOW"
local lastKeybindToggle = 0

local function handleHubKeybind(_, inputState)
    if inputState ~= Enum.UserInputState.Begin then
        return Enum.ContextActionResult.Sink
    end

    if not running() or not gui.Parent then
        return Enum.ContextActionResult.Sink
    end

    if UserInputService:GetFocusedTextBox() then
        return Enum.ContextActionResult.Pass
    end

    -- Pequena trava contra chamadas duplicadas do mesmo pressionamento.
    local now = os.clock()
    if now - lastKeybindToggle < 0.25 then
        return Enum.ContextActionResult.Sink
    end
    lastKeybindToggle = now

    setPanelVisible(not main.Visible)
    return Enum.ContextActionResult.Sink
end

ContextActionService:BindActionAtPriority(
    KEYBIND_ACTION,
    handleHubKeybind,
    false,
    Enum.ContextActionPriority.High.Value + 1000,
    Enum.KeyCode.LeftControl
)

print("[ZATH HUB V4] Inicializado.")
print("[ZATH HUB V4] Limite de coleta por lote ativado.")
print("[ZATH HUB V4] Itens e Item Rain monitorados separadamente.")
print("[ZATH HUB V4] Intervalo entre lotes normais: 30 minutos.")
