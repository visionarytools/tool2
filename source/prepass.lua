assert(getscriptbytecode, "executor does not support getscriptbytecode")

local HttpRequest = request or http_request
assert(HttpRequest, "executor does not support an http request function")

local cloneref = cloneref or function(o) return o end

local game = cloneref(game)
local workspace = cloneref(workspace)

local HttpService = cloneref(game:GetService("HttpService"))
local RunService = cloneref(game:GetService("RunService"))

local CoreContainers = {}
for _, ServiceName in next, { "CoreGui", "CorePackages", "RobloxReplicatedStorage", "RobloxLocalReplicatedStorage" } do
    local Ok, Service = pcall(game.GetService, game, ServiceName)
    if Ok and Service then
        CoreContainers[#CoreContainers + 1] = cloneref(Service)
    end
end

local function IsCoreInstance(o)
    for _, Container in next, CoreContainers do
        local Ok, Res = pcall(function() return o == Container or o:IsDescendantOf(Container) end)
        if Ok and Res then return true end
    end
    local OkLocked, Locked = pcall(function() return o.RobloxLocked end)
    if OkLocked and Locked then return true end
    return false
end

local Config = {
    RequestsPerMinute = 1400,
    MaxInFlight = 30,
    RequestTimeout = 20,
    ApiUrl  = "https://api.lua.expert/decompile",
    Verbose = true,
}

local function Base64Encode(Data)
    if base64_encode then return base64_encode(Data) end
    local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return ((Data:gsub(".", function(x)
        local R, Byte = "", x:byte()
        for i = 8, 1, -1 do
            R = R .. (Byte % 2 ^ i - Byte % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return R
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local C = 0
        for i = 1, 6 do
            C = C + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
        end
        return B:sub(C + 1, C + 1)
    end) .. ({ "", "==", "=" })[#Data % 3 + 1])
end

local Cache = {}
local NextSlot = 0

local function AcquireRateSlot()
    local MinGap = 60 / Config.RequestsPerMinute
    local Now = os.clock()
    local MySlot = NextSlot > Now and NextSlot or Now
    NextSlot = MySlot + MinGap
    local Delay = MySlot - Now
    if Delay > 0 then
        task.wait(Delay)
    end
end

local function DecompileViaAPI(Bytecode)
    AcquireRateSlot()
    local Settled, Result = false, nil
    task.spawn(function()
        local Ok, Res = pcall(HttpRequest, {
            Url = Config.ApiUrl,
            Method = "POST",
            Headers = { ["content-type"] = "application/json" },
            Body = HttpService:JSONEncode({ script = Base64Encode(Bytecode) }),
        })
        if not Settled then
            Settled = true
            Result = { Ok = Ok, Res = Res }
        end
    end)

    local Deadline = os.clock() + Config.RequestTimeout
    while not Settled and os.clock() < Deadline do
        task.wait(0.05)
    end

    if not Settled then
        Settled = true
        return false, "timeout"
    end

    if not Result.Ok then
        return false, tostring(Result.Res)
    end
    if not Result.Res or Result.Res.StatusCode ~= 200 then
        return false, Result.Res and Result.Res.Body or "no response"
    end
    return true, Result.Res.Body
end

local function RunPool(Items, Worker)
    local Total = #Items
    if Total == 0 then return end
    local NextIndex, Done = 1, 0

    local function StartNext()
        if NextIndex > Total then return end
        local i = NextIndex
        NextIndex += 1
        task.spawn(function()
            Worker(Items[i])
            Done += 1
            StartNext()
        end)
    end

    for _ = 1, math.min(Config.MaxInFlight, Total) do
        StartNext()
    end
    while Done < Total do
        task.wait()
    end
end

local function ResolveName(o)
    local Ok, Name = pcall(function() return o:GetFullName() end)
    if Ok and type(Name) == "string" and Name ~= "" then
        return Name
    end
    local Ok2, Short = pcall(function() return o.Name end)
    return (Ok2 and Short) or "<unknown>"
end

local function GatherUniqueScripts()
    local Objs = {}
    for _, o in next, game:GetDescendants() do
        if o:IsA("LuaSourceContainer") and not IsCoreInstance(o) then
            local IsServer = o:IsA("Script") and (o.RunContext == Enum.RunContext.Legacy or o.RunContext == Enum.RunContext.Server)
            if not IsServer then
                Objs[#Objs + 1] = cloneref(o)
            end
        end
    end

    if getloadedmodules then
        local OkM, Mods = pcall(getloadedmodules)
        if OkM and type(Mods) == "table" then
            for _, m in next, Mods do
                if not IsCoreInstance(m) then
                    Objs[#Objs + 1] = cloneref(m)
                end
            end
        end
    end

    local Seen, Unique = {}, {}
    for _, o in next, Objs do
        local Ok, Bc = pcall(getscriptbytecode, o)
        if Ok and type(Bc) == "string" and Bc ~= "" and not Seen[Bc] then
            Seen[Bc] = true
            Unique[#Unique + 1] = { Bytecode = Bc, Name = ResolveName(o) }
        end
    end
    return Unique
end

local NoOpUi = { Update = function() end, Destroy = function() end }

local function CreateProgressUI(Total)
    if type(Drawing) ~= "table" and type(Drawing) ~= "userdata" then
        return NoOpUi
    end

    local State = { Done = 0, Dispatched = 0, Name = "" }
    local Objects = {}
    local Connection

    local Ok = pcall(function()
        local Camera = workspace.CurrentCamera and cloneref(workspace.CurrentCamera)
        local Viewport = (Camera and Camera.ViewportSize) or Vector2.new(1280, 720)
        local BarWidth, BarHeight = 420, 14
        local BarX = math.floor((Viewport.X - BarWidth) / 2)
        local BarY = 24

        local function Square(Color, Filled, Thickness)
            local S = Drawing.new("Square")
            S.Color = Color
            S.Filled = Filled
            S.Thickness = Thickness or 1
            S.Visible = true
            Objects[#Objects + 1] = S
            return S
        end

        local Bg = Square(Color3.fromRGB(20, 20, 20), true)
        Bg.Size = Vector2.new(BarWidth, BarHeight)
        Bg.Position = Vector2.new(BarX, BarY)
        Bg.Transparency = 0.85

        local DispatchedFill = Square(Color3.fromRGB(200, 160, 60), true)
        DispatchedFill.Size = Vector2.new(0, BarHeight)
        DispatchedFill.Position = Vector2.new(BarX, BarY)
        DispatchedFill.Transparency = 0.55

        local CompletedFill = Square(Color3.fromRGB(80, 180, 90), true)
        CompletedFill.Size = Vector2.new(0, BarHeight)
        CompletedFill.Position = Vector2.new(BarX, BarY)

        local Border = Square(Color3.fromRGB(220, 220, 220), false, 1)
        Border.Size = Vector2.new(BarWidth, BarHeight)
        Border.Position = Vector2.new(BarX, BarY)

        local function Text(Size, Color)
            local T = Drawing.new("Text")
            T.Size = Size
            T.Color = Color
            T.Center = true
            T.Outline = true
            T.Visible = true
            T.Text = ""
            Objects[#Objects + 1] = T
            return T
        end

        local Progress = Text(14, Color3.fromRGB(255, 255, 255))
        Progress.Position = Vector2.new(Viewport.X / 2, BarY + BarHeight + 4)
        Progress.Text = ("0 / %d"):format(Total)

        local Name = Text(13, Color3.fromRGB(200, 200, 200))
        Name.Position = Vector2.new(Viewport.X / 2, BarY + BarHeight + 22)

        Connection = RunService.RenderStepped:Connect(function()
            CompletedFill.Size = Vector2.new(BarWidth * (State.Done / Total), BarHeight)
            DispatchedFill.Size = Vector2.new(BarWidth * (State.Dispatched / Total), BarHeight)
            Progress.Text = ("%d / %d"):format(State.Done, Total)
            local Display = State.Name
            if #Display > 80 then
                Display = "..." .. Display:sub(-77)
            end
            Name.Text = Display
        end)
    end)

    if not Ok then
        if Connection then pcall(function() Connection:Disconnect() end) end
        for _, d in next, Objects do
            pcall(function() d:Remove() end)
        end
        return NoOpUi
    end

    return {
        Update = function(_, Done, Dispatched, ScriptName)
            State.Done = Done
            State.Dispatched = Dispatched
            if ScriptName then State.Name = ScriptName end
        end,
        Destroy = function()
            if Connection then pcall(function() Connection:Disconnect() end) end
            for _, d in next, Objects do
                pcall(function() d:Remove() end)
            end
        end,
    }
end

local function Prepass()
    local Unique = GatherUniqueScripts()
    local Total = #Unique
    if Config.Verbose then
        print(("[prepass] %d unique scripts"):format(Total))
    end
    if Total == 0 then return end

    local Ui = CreateProgressUI(Total)
    local OkCount, Completed, Dispatched = 0, 0, 0

    RunPool(Unique, function(Item)
        Dispatched += 1
        Ui:Update(Completed, Dispatched, Item.Name)
        if not Cache[Item.Bytecode] then
            local Ok, Body = DecompileViaAPI(Item.Bytecode)
            if Ok then
                Cache[Item.Bytecode] = Body
                OkCount += 1
            end
        end
        Completed += 1
        Ui:Update(Completed, Dispatched, Item.Name)
    end)

    Ui:Destroy()

    if Config.Verbose then
        print(("[prepass] cached %d / %d"):format(OkCount, Total))
    end
end

local HookInstalled = false
local function InstallDecompileHook()
    if HookInstalled then return end
    HookInstalled = true

    local OldDecompile = getgenv().decompile
    getgenv().decompile = function(Scr)
        local Ok, Bc = pcall(getscriptbytecode, Scr)
        if Ok and type(Bc) == "string" and Bc ~= "" then
            local Hit = Cache[Bc]
            if Hit then
                return Hit
            end
        end

        if OldDecompile then
            return OldDecompile(Scr)
        end

        if Ok and type(Bc) == "string" and Bc ~= "" then
            local Good, Body = DecompileViaAPI(Bc)
            if Good then
                Cache[Bc] = Body
            end
            return Body
        end
        return "-- could not read script bytecode"
    end
end

return function(Options, PrepassOptions)
    PrepassOptions = PrepassOptions or {}
    for k, v in next, PrepassOptions do
        Config[k] = v
    end

    InstallDecompileHook()

    if not PrepassOptions.SkipPrepass then
        Prepass()
    end

    if PrepassOptions.SkipSaveInstance then
        return
    end

    local RepoURL = PrepassOptions.UssiRepoURL or "https://raw.githubusercontent.com/luau/UniversalSynSaveInstance/main/"
    local ScriptName = PrepassOptions.UssiScript or "saveinstance"
    local synsaveinstance = loadstring(game:HttpGet(RepoURL .. ScriptName .. ".lua", true), ScriptName)()

    return synsaveinstance(Options or {})
end
