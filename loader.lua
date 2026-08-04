local Prepass = loadstring(game:HttpGet("https://raw.githubusercontent.com/visionarytools/tool2/refs/heads/main/source/prepass.lua", true))()

local Options = {
    ReadMe = false,
    SafeMode = false,
    BoostFPS = true,
    ShutdownWhenDone = true,
    mode = "full",
    Decompile = true,
    DecompileTimeout = -1,
    SaveBytecode = true,
    DecompileIgnore = {},
    IgnoreList = {},
    NilInstances = true,
    SavePlayerGui = true,
}

local PrepassOptions = {
    RequestsPerMinute = 1495,
    MaxInFlight       = 30,
    ApiUrl            = "https://api.lua.expert/decompile",
    Verbose           = true,
    SkipPrepass       = false,
    SkipSaveInstance  = false,
    UssiRepoURL       = "https://raw.githubusercontent.com/visionarytools/tool2/refs/heads/main/source/",
    UssiScript        = "source",
}

Prepass(Options, PrepassOptions)
