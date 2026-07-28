local Prepass = loadstring(game:HttpGet("https://raw.githubusercontent.com/visionarytools/tool1/refs/heads/main/source/prepass.lua", true))()

local Options = {
    ReadMe = true, -- false
    SafeMode = false, -- false
    BoostFPS = true,
    ShutdownWhenDone = false, -- true
    mode = "full",
    Decompile = true,
    DecompileTimeout = -1,
    SaveBytecode = false, -- true
    DecompileIgnore = {},
    IgnoreList = {},
    NilInstances = false, -- true
    SavePlayerGui = true,
    SetStreaming = false,
    DecompilePrepass = true, -- false
}

local PrepassOptions = {
    RequestsPerMinute = 1495,
    MaxInFlight       = 30,
    ApiUrl            = "https://api.lua.expert/decompile",
    Verbose           = false, -- true
    SkipPrepass       = false,
    SkipSaveInstance  = false,
    UssiRepoURL       = "https://raw.githubusercontent.com/visionarytools/tool2/refs/heads/main/source/",
    UssiScript        = "source",
}

Prepass(Options, PrepassOptions)
