local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

if sethiddenproperty then
	sethiddenproperty(Workspace, "StreamOutBehavior", Enum.StreamOutBehavior.Default)
    sethiddenproperty(workspace, "StreamingMinRadius", 5000)
end

local function applyPersistentStreaming(model)
	if model:IsA("Model") then
		pcall(function()
			model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		end)
	end
end

for _, descendant in ipairs(Workspace:GetDescendants()) do
	applyPersistentStreaming(descendant)
end

Workspace.DescendantAdded:Connect(function(descendant)
	applyPersistentStreaming(descendant)
end)

local States = {
	IDLE = "idle",
	INITIALIZING = "initializing",
	STREAMING = "streaming",
	PHASE1 = "phase1",
	PHASE2 = "phase2",
	ROAMING = "roaming",
	ERROR = "error"
}

local StateMachine = {
	current = States.IDLE,
	previous = nil,
	transitions = {
		[States.IDLE] = {States.INITIALIZING, States.ERROR},
		[States.INITIALIZING] = {States.STREAMING, States.PHASE1, States.ERROR, States.IDLE},
		[States.STREAMING] = {States.PHASE1, States.ERROR, States.IDLE},
		[States.PHASE1] = {States.PHASE2, States.ERROR, States.IDLE},
		[States.PHASE2] = {States.ROAMING, States.ERROR, States.IDLE},
		[States.ROAMING] = {States.IDLE, States.ERROR},
		[States.ERROR] = {States.IDLE}
	}
}

function StateMachine:transition(newState)
	local allowed = self.transitions[self.current]
	if not allowed or not table.find(allowed, newState) then
		warn("[MapLoader] Invalid transition:", self.current, "->", newState)
		return false
	end
	self.previous = self.current
	self.current = newState
	return true
end

function StateMachine:canStop()
	return self.current ~= States.IDLE and self.current ~= States.ERROR
end

local LoadStrategies = {
	SLOW = {
		name = "Slow",
		chunkSize = 250,
		batchSize = 100,
		fastWait = 2.5,
		sweepTween = 1.2,
		hopInterval = 0.35,
		hopRadius = 60,
		hopYRange = 20,
	},
	FAST = {
		name = "Fast",
		chunkSize = 250,
		batchSize = 100,
		fastWait = 0.12,
		sweepTween = 1.2,
		hopInterval = 0.05,
		hopRadius = 60,
		hopYRange = 20,
	}
}

local FlyMethods = {
	CFLY = "cfly",
	SFLY = "sfly"
}

local MoveMethods = {
	TPPOS = "tppos",
	TWEENTPPOS = "tweentppos"
}

local currentStrategy = LoadStrategies.SLOW
local currentFlyMethod = FlyMethods.CFLY
local currentMoveMethod = MoveMethods.TPPOS
local tweenSpeedForMovement = 0.5

local ROAM_WAIT = 0.35

local STREAMING_TIMEOUT = 25
local STABILITY_CHECK_INTERVAL = 0.25
local STABILITY_REQUIRED_TIME = 2
local MAX_CHUNK_RETRIES = 3

local GAME_ID = game.PlaceId

local GameConfigs = {
	[606849621] = {
		name = "Jailbreak",
		useCustomBounds = true,
		bounds = {
			topLeft = Vector3.new(-2898.492, 15.887, -5235.022),
			topRight = Vector3.new(3003.559, 15.887, -5235.022),
			bottomLeft = Vector3.new(-2898.484, 16.062, 3514.802),
			bottomRight = Vector3.new(3003.488, 16.159, 3514.865)
		},
		chunkSize = 800,
		gridSpacing = 700,
		heightOffset = 150,
		skipStabilityCheck = true,
		fastWait = 0.04,
		sweepTween = 0.4,
		phaseTimeTarget = 240
	}
}

local currentGameConfig = GameConfigs[GAME_ID]

local FLYING = false
local flyKeyDown = nil
local flyKeyUp = nil
local iyflyspeed = 50
local vehicleflyspeed = 50
local QEfly = true

local cflyLoop = nil
local cflyActive = false
local cflyPaused = false
local cflyRespawnConn = nil

local function sFLY(vfly)
	local char = player.Character or player.CharacterAdded:Wait()
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		repeat task.wait() until char:FindFirstChildOfClass("Humanoid")
		humanoid = char:FindFirstChildOfClass("Humanoid")
	end

	if flyKeyDown or flyKeyUp then
		flyKeyDown:Disconnect()
		flyKeyUp:Disconnect()
	end

	local T = char:FindFirstChild("HumanoidRootPart")
	if not T then return end

	local CONTROL = {F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0}
	local lCONTROL = {F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0}
	local SPEED = 0

	local function FLY()
		FLYING = true
		local BG = Instance.new('BodyGyro')
		local BV = Instance.new('BodyVelocity')
		BG.P = 9e4
		BG.Parent = T
		BV.Parent = T
		BG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
		BG.CFrame = T.CFrame
		BV.Velocity = Vector3.new(0, 0, 0)
		BV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
		task.spawn(function()
			repeat task.wait()
				local cam = workspace.CurrentCamera
				if not vfly and humanoid then
					humanoid.PlatformStand = true
				end

				if CONTROL.L + CONTROL.R ~= 0 or CONTROL.F + CONTROL.B ~= 0 or CONTROL.Q + CONTROL.E ~= 0 then
					SPEED = 50
				elseif not (CONTROL.L + CONTROL.R ~= 0 or CONTROL.F + CONTROL.B ~= 0 or CONTROL.Q + CONTROL.E ~= 0) and SPEED ~= 0 then
					SPEED = 0
				end
				if (CONTROL.L + CONTROL.R) ~= 0 or (CONTROL.F + CONTROL.B) ~= 0 or (CONTROL.Q + CONTROL.E) ~= 0 then
					BV.Velocity = ((cam.CFrame.LookVector * (CONTROL.F + CONTROL.B)) + ((cam.CFrame * CFrame.new(CONTROL.L + CONTROL.R, (CONTROL.F + CONTROL.B + CONTROL.Q + CONTROL.E) * 0.2, 0).p) - cam.CFrame.p)) * SPEED
					lCONTROL = {F = CONTROL.F, B = CONTROL.B, L = CONTROL.L, R = CONTROL.R}
				elseif (CONTROL.L + CONTROL.R) == 0 and (CONTROL.F + CONTROL.B) == 0 and (CONTROL.Q + CONTROL.E) == 0 and SPEED ~= 0 then
					BV.Velocity = ((cam.CFrame.LookVector * (lCONTROL.F + lCONTROL.B)) + ((cam.CFrame * CFrame.new(lCONTROL.L + lCONTROL.R, (lCONTROL.F + lCONTROL.B + CONTROL.Q + CONTROL.E) * 0.2, 0).p) - cam.CFrame.p)) * SPEED
				else
					BV.Velocity = Vector3.new(0, 0, 0)
				end
				BG.CFrame = cam.CFrame
			until not FLYING
			CONTROL = {F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0}
			lCONTROL = {F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0}
			SPEED = 0
			BG:Destroy()
			BV:Destroy()

			if humanoid then humanoid.PlatformStand = false end
		end)
	end

	flyKeyDown = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.W then
			CONTROL.F = (vfly and vehicleflyspeed or iyflyspeed)
		elseif input.KeyCode == Enum.KeyCode.S then
			CONTROL.B = - (vfly and vehicleflyspeed or iyflyspeed)
		elseif input.KeyCode == Enum.KeyCode.A then
			CONTROL.L = - (vfly and vehicleflyspeed or iyflyspeed)
		elseif input.KeyCode == Enum.KeyCode.D then
			CONTROL.R = (vfly and vehicleflyspeed or iyflyspeed)
		elseif input.KeyCode == Enum.KeyCode.E and QEfly then
			CONTROL.Q = (vfly and vehicleflyspeed or iyflyspeed)*2
		elseif input.KeyCode == Enum.KeyCode.Q and QEfly then
			CONTROL.E = -(vfly and vehicleflyspeed or iyflyspeed)*2
		end
		pcall(function() camera.CameraType = Enum.CameraType.Track end)
	end)

	flyKeyUp = UserInputService.InputEnded:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.W then
			CONTROL.F = 0
		elseif input.KeyCode == Enum.KeyCode.S then
			CONTROL.B = 0
		elseif input.KeyCode == Enum.KeyCode.A then
			CONTROL.L = 0
		elseif input.KeyCode == Enum.KeyCode.D then
			CONTROL.R = 0
		elseif input.KeyCode == Enum.KeyCode.E then
			CONTROL.Q = 0
		elseif input.KeyCode == Enum.KeyCode.Q then
			CONTROL.E = 0
		end
	end)
	FLY()
end

local function sNOFLY()
	FLYING = false
	if flyKeyDown or flyKeyUp then 
		flyKeyDown:Disconnect() 
		flyKeyUp:Disconnect() 
	end
	if player.Character:FindFirstChildOfClass('Humanoid') then
		player.Character:FindFirstChildOfClass('Humanoid').PlatformStand = false
	end
	pcall(function() workspace.CurrentCamera.CameraType = Enum.CameraType.Custom end)
end

local function applyCflyToCharacter(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if humanoid then humanoid.PlatformStand = true end
	if hrp then hrp.Anchored = true end
	if head then head.Anchored = true end
end

local function startCfly()
	if cflyActive then return end
	cflyActive = true
	cflyPaused = false

	applyCflyToCharacter(player.Character)

	if cflyRespawnConn then cflyRespawnConn:Disconnect() end
	cflyRespawnConn = player.CharacterAdded:Connect(function(newChar)
		if not cflyActive then return end
		newChar:WaitForChild("HumanoidRootPart", 10)
		newChar:WaitForChild("Head", 10)
		newChar:WaitForChild("Humanoid", 10)
		task.wait(0.1)
		applyCflyToCharacter(newChar)
	end)

	if cflyLoop then cflyLoop:Disconnect() end

	cflyLoop = RunService.Heartbeat:Connect(function(dt)
		if cflyPaused then return end

		local char = player.Character
		if not char then return end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local h = char:FindFirstChild("Head")
		if not hum or not h then return end

		local moveDirection = hum.MoveDirection * (50 * dt)
		local headCFrame = h.CFrame
		local cam = workspace.CurrentCamera
		local camCFrame = cam.CFrame
		local camOffset = headCFrame:ToObjectSpace(camCFrame).Position
		camCFrame = camCFrame * CFrame.new(-camOffset.X, -camOffset.Y, -camOffset.Z + 1)
		local camPos = camCFrame.Position
		local headPos = headCFrame.Position
		local objVel = CFrame.new(camPos, Vector3.new(headPos.X, camPos.Y, headPos.Z)):VectorToObjectSpace(moveDirection)
		h.CFrame = CFrame.new(headPos) * (camCFrame - camPos) * CFrame.new(objVel)
	end)
end

local function stopCfly()
	if not cflyActive then return end
	cflyActive = false
	cflyPaused = false

	if cflyLoop then
		cflyLoop:Disconnect()
		cflyLoop = nil
	end

	if cflyRespawnConn then
		cflyRespawnConn:Disconnect()
		cflyRespawnConn = nil
	end

	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if humanoid then humanoid.PlatformStand = false end
	if hrp then hrp.Anchored = false end
	if head then head.Anchored = false end
end

local function tpCharTo(pos)
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	if not hrp then return end

	cflyPaused = true
	hrp.CFrame = CFrame.new(pos)
	if head then
		head.CFrame = CFrame.new(pos + Vector3.new(0, 1.5, 0))
	end
	RunService.Heartbeat:Wait()
	cflyPaused = false
end

local function tweenTpPos(pos)
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	if currentFlyMethod == FlyMethods.SFLY then
		if flyKeyDown then flyKeyDown:Disconnect() end
		if flyKeyUp then flyKeyUp:Disconnect() end
	end

	local tween = TweenService:Create(
		hrp,
		TweenInfo.new(tweenSpeedForMovement, Enum.EasingStyle.Linear),
		{CFrame = CFrame.new(pos)}
	)
	tween:Play()
	tween.Completed:Wait()

	if currentFlyMethod == FlyMethods.SFLY and FLYING then
		sFLY(false)
	end
end

local function moveCharacter(pos)
	if currentMoveMethod == MoveMethods.TWEENTPPOS then
		tweenTpPos(pos)
	else
		tpCharTo(pos)
	end
end

local function startFly()
	if currentFlyMethod == FlyMethods.SFLY then
		sFLY(false)
	else
		startCfly()
	end
end

local function stopFly()
	if currentFlyMethod == FlyMethods.SFLY then
		sNOFLY()
	else
		stopCfly()
	end
end

local stopRequested = false

local function hopAroundChunk(chunkPos, duration)
	local elapsed = 0
	local hopInterval = currentStrategy.hopInterval
	local hopRadius = currentStrategy.hopRadius
	local hopYRange = currentStrategy.hopYRange

	moveCharacter(chunkPos)

	while elapsed < duration do
		if stopRequested then return end

		local offsetX = math.random(-hopRadius * 10, hopRadius * 10) / 10
		local offsetY = math.random(-hopYRange * 10, hopYRange * 10) / 10
		local offsetZ = math.random(-hopRadius * 10, hopRadius * 10) / 10

		moveCharacter(Vector3.new(
			chunkPos.X + offsetX,
			chunkPos.Y + offsetY,
			chunkPos.Z + offsetZ
		))

		task.wait(hopInterval)
		elapsed += hopInterval
	end
end

local function calculateMapBounds()
	print("[MapLoader] Calculating map bounds...")

	local positions = {}
	local partCount = 0

	for _, part in ipairs(Workspace:GetDescendants()) do
		if part:IsA("BasePart") and part.Anchored then
			table.insert(positions, part.Position)
			partCount += 1

			if partCount % 500 == 0 then
				task.wait()
			end
		end
	end

	if #positions == 0 then return nil end

	local function trimOutliers(coords)
		table.sort(coords)
		local n = #coords
		local q1_idx = math.floor(n * 0.25)
		local q3_idx = math.floor(n * 0.75)
		
		if q1_idx < 1 then q1_idx = 1 end
		if q3_idx > n then q3_idx = n end
		
		local q1 = coords[q1_idx]
		local q3 = coords[q3_idx]
		local iqr = q3 - q1
		local lowerBound = q1 - (1.5 * iqr)
		local upperBound = q3 + (1.5 * iqr)
		
		return lowerBound, upperBound
	end

	local xCoords, yCoords, zCoords = {}, {}, {}
	for _, pos in ipairs(positions) do
		table.insert(xCoords, pos.X)
		table.insert(yCoords, pos.Y)
		table.insert(zCoords, pos.Z)
	end

	local minX, maxX = trimOutliers(xCoords)
	local minY, maxY = trimOutliers(yCoords)
	local minZ, maxZ = trimOutliers(zCoords)

	local avgY = (minY + maxY) / 2

	return {
		topLeft = Vector3.new(minX, avgY, minZ),
		topRight = Vector3.new(maxX, avgY, minZ),
		bottomLeft = Vector3.new(minX, avgY, maxZ),
		bottomRight = Vector3.new(maxX, avgY, maxZ),
		center = Vector3.new((minX + maxX)/2, avgY, (minZ + maxZ)/2),
		dimensions = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ),
		partCount = partCount
	}
end

local function calculateOptimalSpacing(dimensions)
	local area = dimensions.X * dimensions.Z
	local targetPoints = 200
	local spacing = math.sqrt(area / targetPoints)
	return math.clamp(spacing, 300, 1000)
end

local function hasTerrainInMap()
	if not gethiddenproperty then return false end
	pcall(function()
		writefile("MLSG.txt", gethiddenproperty(workspace.Terrain, "SmoothGrid"))
		writefile("MLPG.txt", gethiddenproperty(workspace.Terrain, "PhysicsGrid"))
	end)
	
	task.wait(0.5)
	
	local smoothGridContent = ""
	local physicsGridContent = ""
	
	pcall(function()
		smoothGridContent = readfile("MLSG.txt") or ""
		physicsGridContent = readfile("MLPG.txt") or ""
	end)
	
	local hasContent =
		(smoothGridContent ~= "" and smoothGridContent ~= "nil") or
		(physicsGridContent ~= "" and physicsGridContent ~= "nil")
	
	pcall(function()
		delfile("MLSG.txt")
		delfile("MLPG.txt")
	end)

	return hasContent
end

local function expandBounds(bounds, offset)
	return {
		topLeft = bounds.topLeft - Vector3.new(offset, 0, offset),
		topRight = bounds.topRight + Vector3.new(offset, 0, offset),
		bottomLeft = bounds.bottomLeft - Vector3.new(offset, 0, offset),
		bottomRight = bounds.bottomRight + Vector3.new(offset, 0, offset),
		center = bounds.center,
		dimensions = bounds.dimensions + Vector3.new(offset * 2, 0, offset * 2),
		partCount = bounds.partCount
	}
end

local function shouldUseBoundedMode(bounds)
	if not bounds then return false, nil end

	local dims = bounds.dimensions

	if dims.X > 3000 or dims.Z > 3000 then
		local spacing = calculateOptimalSpacing(dims)

		if hasTerrainInMap() then
			bounds = expandBounds(bounds, 2048)
			print("[MapLoader] Terrain detected, expanding bounds by 2048 studs")
		else
			print("[MapLoader] No Terrain detected")
		end

		print(string.format("[MapLoader] Large map detected: %.0f x %.0f studs", dims.X, dims.Z))
		print(string.format("[MapLoader] Using bounded mode with %.0f stud spacing", spacing))

		return true, {
			name = "Auto-Detected Map",
			useCustomBounds = true,
			bounds = bounds,
			chunkSize = math.clamp(spacing * 1.2, 400, 1000),
			gridSpacing = spacing,
			heightOffset = 150,
			skipStabilityCheck = true,
			fastWait = 0.04,
			sweepTween = 0.5,
			timeTarget = nil
		}
	end

	print(string.format("[MapLoader] Standard-sized map: %.0f x %.0f studs", dims.X, dims.Z))
	print("[MapLoader] Using standard streaming mode")

	return false, nil
end

local DUMMY_FOLDER = Instance.new("Folder")

local running = false
local minimized = false

local originalCFrame
local originalCameraType
local savedFramePos

local gui, frame, content
local barBg, progressFill, progressText
local actionBtn, strategyBtn, flyMethodBtn, moveMethodBtn

local globalStartTime
local totalWorkItems
local globalDone

local allParts = {}
local chunkCenters = {}
local chunkSize = currentStrategy.chunkSize

local function setRendering(on)
	RunService:Set3dRenderingEnabled(on)
end

local function restoreCamera()
	setRendering(true)
	stopFly()
	if originalCameraType then camera.CameraType = originalCameraType end
	if originalCFrame then camera.CFrame = originalCFrame end
end

local function formatETA(startTime, done, total)
	if done >= total then return "00:00" end
	local elapsed = tick() - startTime
	local avg = elapsed / math.max(done, 1)
	local remain = math.max(0, total - done)
	local eta = math.floor(avg * remain)
	return string.format("%02d:%02d", math.floor(eta / 60), eta % 60)
end

local function phaseText(phase, done, total, eta)
	return string.format("Phase %s | %d/%d | ETA %s", phase, done, total, eta)
end

local function setProgress(alpha, text)
	progressFill.Size = UDim2.new(math.clamp(alpha, 0, 1), 0, 1, 0)
	progressText.Text = text
	barBg.BackgroundColor3 = Color3.fromHex("#1d2f49")
end

local function generateBoundedGrid(config)
	local bounds = config.bounds
	local spacing = config.gridSpacing

	local avgY = (bounds.topLeft.Y + bounds.topRight.Y + bounds.bottomLeft.Y + bounds.bottomRight.Y) / 4

	local minX = math.min(bounds.topLeft.X, bounds.topRight.X, bounds.bottomLeft.X, bounds.bottomRight.X)
	local maxX = math.max(bounds.topLeft.X, bounds.topRight.X, bounds.bottomLeft.X, bounds.bottomRight.X)
	local minZ = math.min(bounds.topLeft.Z, bounds.topRight.Z, bounds.bottomLeft.Z, bounds.bottomRight.Z)
	local maxZ = math.max(bounds.topLeft.Z, bounds.topRight.Z, bounds.bottomLeft.Z, bounds.bottomRight.Z)

	local centers = {}

	for x = minX, maxX, spacing do
		for z = minZ, maxZ, spacing do
			table.insert(centers, {
				position = Vector3.new(x, avgY, z),
				parts = {},
				retries = 0,
				maxRetries = MAX_CHUNK_RETRIES
			})
		end
	end

	return centers
end

local function countPartsInRadius(position, radius)
	local success, parts = pcall(function()
		return Workspace:GetPartBoundsInRadius(position, radius)
	end)

	if success and parts then
		local count = 0
		for _, part in ipairs(parts) do
			if part:IsA("BasePart") and part.Anchored then
				count += 1
			end
		end
		return count
	end

	return 0
end

local function verifyChunkStable(position, radius)
	local startTime = tick()
	local lastCount = countPartsInRadius(position, radius)
	local stableTime = 0
	local maxCount = lastCount

	pcall(function()
		task.spawn(function()
			pcall(function()
				player:RequestStreamAroundAsync(position, STREAMING_TIMEOUT)
			end)
		end)
	end)

	while tick() - startTime < STREAMING_TIMEOUT do
		if stopRequested then return false end

		task.wait(STABILITY_CHECK_INTERVAL)

		local currentCount = countPartsInRadius(position, radius)
		local delta = math.max(0, currentCount - lastCount)

		if delta > 0 then
			stableTime = 0
			maxCount = math.max(maxCount, currentCount)
		else
			stableTime += STABILITY_CHECK_INTERVAL
		end

		lastCount = currentCount

		if stableTime >= STABILITY_REQUIRED_TIME then
			return true
		end
	end

	return maxCount > 0
end

local function calculateOptimalChunkSize(parts)
	if #parts == 0 then return currentStrategy.chunkSize end

	local bounds = {
		min = Vector3.new(math.huge, math.huge, math.huge),
		max = Vector3.new(-math.huge, -math.huge, -math.huge)
	}

	for _, p in ipairs(parts) do
		bounds.min = Vector3.new(
			math.min(bounds.min.X, p.Position.X),
			math.min(bounds.min.Y, p.Position.Y),
			math.min(bounds.min.Z, p.Position.Z)
		)
		bounds.max = Vector3.new(
			math.max(bounds.max.X, p.Position.X),
			math.max(bounds.max.Y, p.Position.Y),
			math.max(bounds.max.Z, p.Position.Z)
		)
	end

	local volume = (bounds.max - bounds.min)
	local totalVolume = volume.X * volume.Y * volume.Z

	if totalVolume <= 0 then return currentStrategy.chunkSize end

	local density = #parts / totalVolume
	local adaptiveSize = math.clamp(500 / math.sqrt(math.max(density, 0.0001)), 250, 2000)

	return math.floor(adaptiveSize)
end

local function streamParts(callback)
	StateMachine:transition(States.STREAMING)

	local batch = {}
	local charModel = player.Character or DUMMY_FOLDER
	local processedCount = 0
	local batchSize = currentStrategy.batchSize

	setProgress(0, "Streaming parts... 0 found")

	for _, inst in ipairs(Workspace:GetDescendants()) do
		if stopRequested then return false end

		if inst:IsA("BasePart") and inst.Transparency < 1 and not inst:IsDescendantOf(charModel) then
			batch[#batch + 1] = inst
			processedCount += 1

			if #batch >= batchSize then
				callback(batch)
				batch = {}
				task.wait()
				setProgress(0, string.format("Streaming parts... %d found", processedCount))
			end
		end
	end

	if #batch > 0 then
		callback(batch)
	end

	return true
end

local function buildCenters(parts, chunkSizeOverride)
	local size = chunkSizeOverride or chunkSize
	local buckets = {}

	for _, p in ipairs(parts) do
		local cx = math.floor(p.Position.X / size)
		local cy = math.floor(p.Position.Y / size)
		local cz = math.floor(p.Position.Z / size)
		local key = cx..","..cy..","..cz

		if not buckets[key] then
			buckets[key] = { sum = Vector3.zero, count = 0, parts = {} }
		end
		buckets[key].sum += p.Position
		buckets[key].count += 1
		table.insert(buckets[key].parts, p)
	end

	local centers = {}
	for _, b in pairs(buckets) do
		table.insert(centers, {
			position = b.sum / b.count,
			parts = b.parts,
			retries = 0,
			maxRetries = MAX_CHUNK_RETRIES
		})
	end

	return centers
end

local function buildColumns(centers, chunkSizeOverride)
	local size = chunkSizeOverride or chunkSize
	local minX = math.huge

	for _, c in ipairs(centers) do
		minX = math.min(minX, c.position.X)
	end

	local columns = {}
	for _, c in ipairs(centers) do
		local col = math.floor((c.position.X - minX) / size)
		columns[col] = columns[col] or {}
		table.insert(columns[col], c)
	end

	return columns
end

local function executePhase1(centers)
	if not StateMachine:transition(States.PHASE1) then return false end

	setRendering(false)

	local skipStability = currentGameConfig and currentGameConfig.skipStabilityCheck

	for i, center in ipairs(centers) do
		if stopRequested then return false end

		globalDone += 1

		hopAroundChunk(center.position, currentStrategy.fastWait)

		if not skipStability then
			verifyChunkStable(center.position, 100)
		end

		setProgress(
			globalDone / totalWorkItems,
			phaseText("1/2", globalDone, totalWorkItems, formatETA(globalStartTime, globalDone, totalWorkItems))
		)
	end

	setRendering(true)
	return true
end

local function executePhase2(columns)
	if not StateMachine:transition(States.PHASE2) then return false end

    setRendering(false)

	local skipStability = currentGameConfig and currentGameConfig.skipStabilityCheck

	for col = 0, math.huge do
		local list = columns[col]
		if not list then break end

		table.sort(list, function(a, b)
			return a.position.Z > b.position.Z
		end)

		for _, c in ipairs(list) do
			if stopRequested then return false end

			globalDone += 1

			hopAroundChunk(c.position, currentStrategy.fastWait)

			if not skipStability then
				verifyChunkStable(c.position, 100)
			end

			setProgress(
				globalDone / totalWorkItems,
				phaseText("2/2", globalDone, totalWorkItems, formatETA(globalStartTime, globalDone, totalWorkItems))
			)
		end
	end

    setRendering(true)
	return true
end

local function executeRoaming(centers)
	if not StateMachine:transition(States.ROAMING) then return false end

	setProgress(1, "Roaming")

	while not stopRequested do
		local center = centers[math.random(1, #centers)]
		moveCharacter(center.position)
		task.wait(ROAM_WAIT)
	end

	return true
end

local function runLoader()
	running = true
	stopRequested = false

	originalCFrame = camera.CFrame
	originalCameraType = camera.CameraType

	startFly()

	actionBtn.Text = "Stop"
	actionBtn.BackgroundColor3 = Color3.fromHex("#c4302b")

	if not StateMachine:transition(States.INITIALIZING) then
		restoreCamera()
		running = false
		StateMachine:transition(States.ERROR)
		return
	end

	if not currentGameConfig then
		setProgress(0.1, "Analyzing map boundaries...")
		local detectedBounds = calculateMapBounds()

		if detectedBounds then
			local useBounded, autoConfig = shouldUseBoundedMode(detectedBounds)
			if useBounded then
				currentGameConfig = autoConfig
			end
		end
	end

	if currentGameConfig and currentGameConfig.useCustomBounds then
		print("[MapLoader] Detected:", currentGameConfig.name)
		print("[MapLoader] Using custom bounds and optimized settings")

		chunkCenters = generateBoundedGrid(currentGameConfig)

		if #chunkCenters == 0 then
			restoreCamera()
			running = false
			StateMachine:transition(States.IDLE)
			setProgress(0, "Grid generation failed")
			actionBtn.Text = "Start"
			return
		end

		local columns = buildColumns(chunkCenters, currentGameConfig.chunkSize)

		local p1Total = #chunkCenters
		local p2Total = 0
		for _, col in pairs(columns) do p2Total += #col end

		totalWorkItems = p1Total + p2Total
		globalDone = 0
		globalStartTime = tick()

		local originalFastWait = currentStrategy.fastWait
		local originalSweepTween = currentStrategy.sweepTween

		if currentGameConfig.fastWait then currentStrategy.fastWait = currentGameConfig.fastWait end
		if currentGameConfig.sweepTween then currentStrategy.sweepTween = currentGameConfig.sweepTween end

		local success = executePhase1(chunkCenters)
		if not success then
			currentStrategy.fastWait = originalFastWait
			currentStrategy.sweepTween = originalSweepTween
			restoreCamera()
			running = false
			StateMachine:transition(States.IDLE)
			actionBtn.Text = "Start"
			setProgress(0, "Stopped")
			return
		end

		success = executePhase2(columns)
		if not success then
			currentStrategy.fastWait = originalFastWait
			currentStrategy.sweepTween = originalSweepTween
			restoreCamera()
			running = false
			StateMachine:transition(States.IDLE)
			actionBtn.Text = "Start"
			setProgress(0, "Stopped")
			return
		end

		currentStrategy.fastWait = originalFastWait
		currentStrategy.sweepTween = originalSweepTween

		local phaseElapsed = tick() - globalStartTime
		print(string.format("[MapLoader] Phases complete in %.1fs - starting roaming", phaseElapsed))

		executeRoaming(chunkCenters)

		restoreCamera()
		running = false
		StateMachine:transition(States.IDLE)
		actionBtn.Text = "Start"
		setProgress(1, string.format("Complete | %s", currentGameConfig.name))

		if not GameConfigs[GAME_ID] then
			currentGameConfig = nil
		end
		return
	end

	allParts = {}
	local streamSuccess = streamParts(function(batch)
		for _, part in ipairs(batch) do
			table.insert(allParts, part)
		end
	end)

	if not streamSuccess or #allParts == 0 then
		restoreCamera()
		running = false
		StateMachine:transition(States.IDLE)
		setProgress(0, "No parts found or stopped")
		actionBtn.Text = "Start"
		return
	end

	chunkSize = calculateOptimalChunkSize(allParts)
	chunkCenters = buildCenters(allParts, chunkSize)

	if #chunkCenters == 0 then
		restoreCamera()
		running = false
		StateMachine:transition(States.IDLE)
		setProgress(0, "No chunks generated")
		actionBtn.Text = "Start"
		return
	end

	local columns = buildColumns(chunkCenters, chunkSize)

	local p1Total = #chunkCenters
	local p2Total = 0
	for _, col in pairs(columns) do p2Total += #col end

	totalWorkItems = p1Total + p2Total
	globalDone = 0
	globalStartTime = tick()

	local success = executePhase1(chunkCenters)
	if not success then
		restoreCamera()
		running = false
		StateMachine:transition(States.IDLE)
		actionBtn.Text = "Start"
		setProgress(0, "Stopped")
		return
	end

	success = executePhase2(columns)
	if not success then
		restoreCamera()
		running = false
		StateMachine:transition(States.IDLE)
		actionBtn.Text = "Start"
		setProgress(0, "Stopped")
		return
	end

	executeRoaming(chunkCenters)

	restoreCamera()
	running = false
	StateMachine:transition(States.IDLE)
	actionBtn.Text = "Start"
	setProgress(0, "Complete")
end

pcall(function()
    player.PlayerGui:FindFirstChild("MapLoader"):Destroy()
end)

gui = Instance.new("ScreenGui", player.PlayerGui)
gui.Name = "MapLoader"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.IgnoreGuiInset = true

frame = Instance.new("Frame", gui)
frame.Size = UDim2.new(0, 369, 0, 188)
frame.Position = UDim2.new(0.5, -170, 0.5, -118)
frame.BackgroundColor3 = Color3.fromHex("#151618")
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true

local stroke = Instance.new("UIStroke", frame)
stroke.Thickness = 1
stroke.Color = Color3.new(32, 32, 32)
stroke.Transparency = 0.75

local title = Instance.new("TextLabel", frame)
title.Size = UDim2.new(1, 0, 0, 36)
title.BackgroundColor3 = Color3.fromHex("#294a7a")
title.Text = currentGameConfig and ("MapLoader | " .. currentGameConfig.name) or "MapLoader"
title.Font = Enum.Font.BuilderSansExtraBold
title.TextSize = 18
title.TextColor3 = Color3.new(1, 1, 1)
title.TextXAlignment = Enum.TextXAlignment.Center
title.BorderSizePixel = 0

local close = Instance.new("TextButton", frame)
close.Size = UDim2.new(0, 36, 0, 36)
close.Position = UDim2.new(1, -36, 0, 0)
close.Text = "x"
close.Font = Enum.Font.BuilderSansExtraBold
close.TextSize = 20
close.TextColor3 = Color3.new(1, 1, 1)
close.BackgroundTransparency = 1
close.BorderSizePixel = 0

local minimize = Instance.new("TextButton", frame)
minimize.Size = UDim2.new(0, 36, 0, 36)
minimize.Position = UDim2.new(1, -60, 0, 0)
minimize.Text = "-"
minimize.Font = Enum.Font.BuilderSansExtraBold
minimize.TextSize = 24
minimize.TextColor3 = Color3.new(1, 1, 1)
minimize.BackgroundTransparency = 1
minimize.BorderSizePixel = 0

content = Instance.new("Frame", frame)
content.Position = UDim2.new(0, 0, 0, 36)
content.Size = UDim2.new(1, 0, 1, -36)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0

barBg = Instance.new("Frame", content)
barBg.Size = UDim2.new(0.94, 0, 0, 20)
barBg.Position = UDim2.new(0.03, 0, 0, 14)
barBg.BackgroundColor3 = Color3.fromHex("#1d2f49")
barBg.BorderSizePixel = 0

progressFill = Instance.new("Frame", barBg)
progressFill.Size = UDim2.new(0, 0, 1, 0)
progressFill.BackgroundColor3 = Color3.fromHex("#e6b32f")
progressFill.BorderSizePixel = 0

progressText = Instance.new("TextLabel", barBg)
progressText.Size = UDim2.new(1, 0, 1, 0)
progressText.BackgroundTransparency = 1
progressText.Text = "Idle"
progressText.Font = Enum.Font.BuilderSansExtraBold
progressText.TextSize = 12
progressText.TextColor3 = Color3.new(1, 1, 1)
progressText.BorderSizePixel = 0

strategyBtn = Instance.new("TextButton", content)
strategyBtn.Size = UDim2.new(0.94, 0, 0, 28)
strategyBtn.Position = UDim2.new(0.03, 0, 0, 42)
strategyBtn.Text = "Strategy: " .. currentStrategy.name
strategyBtn.Font = Enum.Font.BuilderSansExtraBold
strategyBtn.TextSize = 12
strategyBtn.BackgroundColor3 = Color3.fromHex("#23456d")
strategyBtn.TextColor3 = Color3.new(1, 1, 1)
strategyBtn.BorderSizePixel = 0
strategyBtn.AutoButtonColor = false

flyMethodBtn = Instance.new("TextButton", content)
flyMethodBtn.Size = UDim2.new(0.4645, 0, 0, 28)
flyMethodBtn.Position = UDim2.new(0.03, 0, 0, 74)
flyMethodBtn.Text = "Fly: " .. (currentFlyMethod == FlyMethods.CFLY and "cFLY" or "sFLY")
flyMethodBtn.Font = Enum.Font.BuilderSansExtraBold
flyMethodBtn.TextSize = 12
flyMethodBtn.BackgroundColor3 = Color3.fromHex("#23456d")
flyMethodBtn.TextColor3 = Color3.new(1, 1, 1)
flyMethodBtn.BorderSizePixel = 0
flyMethodBtn.AutoButtonColor = false

moveMethodBtn = Instance.new("TextButton", content)
moveMethodBtn.Size = UDim2.new(0.4645, 0, 0, 28)
moveMethodBtn.Position = UDim2.new(0.03, 176, 0, 74)
moveMethodBtn.Text = "Move: " .. (currentMoveMethod == MoveMethods.TPPOS and "tpPos" or "tweenTpPos")
moveMethodBtn.Font = Enum.Font.BuilderSansExtraBold
moveMethodBtn.TextSize = 12
moveMethodBtn.BackgroundColor3 = Color3.fromHex("#23456d")
moveMethodBtn.TextColor3 = Color3.new(1, 1, 1)
moveMethodBtn.BorderSizePixel = 0
moveMethodBtn.AutoButtonColor = false

actionBtn = Instance.new("TextButton", content)
actionBtn.Size = UDim2.new(0.94, 0, 0, 32)
actionBtn.Position = UDim2.new(0.03, 0, 0, 106)
actionBtn.Text = "Start"
actionBtn.Font = Enum.Font.BuilderSansExtraBold
actionBtn.TextSize = 15
actionBtn.BackgroundColor3 = Color3.fromHex("#57993d")
actionBtn.TextColor3 = Color3.new(1, 1, 1)
actionBtn.BorderSizePixel = 0
actionBtn.AutoButtonColor = false

local BTN_ACTION_DEFAULT = Color3.fromHex("#57993d")
local BTN_ACTION_HOVER   = Color3.fromHex("#5cb337")
local BTN_ACTION_DOWN    = Color3.fromHex("#6bcd2b")

local BTN_STOP_DEFAULT = Color3.fromHex("#993d3d")
local BTN_STOP_HOVER   = Color3.fromHex("#b33636")
local BTN_STOP_DOWN    = Color3.fromHex("#cd362c")

local BTN_OPTION_DEFAULT = Color3.fromHex("#23456d")
local BTN_OPTION_HOVER   = Color3.fromHex("#4296fa")
local BTN_OPTION_DOWN    = Color3.fromHex("#1b87fa")

local actionHovering = false
local strategyHovering = false
local flyHovering = false
local moveHovering = false

local isJailbreak = currentGameConfig and currentGameConfig.name == "Jailbreak"

local darkenedOptionDefault = Color3.fromHex("#122337")
local darkenedOptionHover = Color3.fromHex("#142d4b")
local darkenedOptionDown = Color3.fromHex("#08284b")

if isJailbreak then
	flyMethodBtn.BackgroundColor3 = darkenedOptionDefault
	moveMethodBtn.BackgroundColor3 = darkenedOptionDefault
	flyMethodBtn.TextColor3 = Color3.fromHex("#4c4c4c")
	moveMethodBtn.TextColor3 = Color3.fromHex("#4c4c4c")
end

actionBtn.MouseEnter:Connect(function()
	actionHovering = true
	actionBtn.BackgroundColor3 = running and BTN_STOP_HOVER or BTN_ACTION_HOVER
end)

actionBtn.MouseLeave:Connect(function()
	actionHovering = false
	actionBtn.BackgroundColor3 = running and BTN_STOP_DEFAULT or BTN_ACTION_DEFAULT
end)

strategyBtn.MouseEnter:Connect(function()
	strategyHovering = true
	strategyBtn.BackgroundColor3 = BTN_OPTION_HOVER
end)

strategyBtn.MouseLeave:Connect(function()
	strategyHovering = false
	strategyBtn.BackgroundColor3 = BTN_OPTION_DEFAULT
end)

flyMethodBtn.MouseEnter:Connect(function()
	flyHovering = true
	if isJailbreak then
		flyMethodBtn.BackgroundColor3 = darkenedOptionHover
	else
		flyMethodBtn.BackgroundColor3 = BTN_OPTION_HOVER
	end
end)

flyMethodBtn.MouseLeave:Connect(function()
	flyHovering = false
	if isJailbreak then
		flyMethodBtn.BackgroundColor3 = darkenedOptionDefault
	else
		flyMethodBtn.BackgroundColor3 = BTN_OPTION_DEFAULT
	end
end)

moveMethodBtn.MouseEnter:Connect(function()
	moveHovering = true
	if isJailbreak then
		moveMethodBtn.BackgroundColor3 = darkenedOptionHover
	else
		moveMethodBtn.BackgroundColor3 = BTN_OPTION_HOVER
	end
end)

moveMethodBtn.MouseLeave:Connect(function()
	moveHovering = false
	if isJailbreak then
		moveMethodBtn.BackgroundColor3 = darkenedOptionDefault
	else
		moveMethodBtn.BackgroundColor3 = BTN_OPTION_DEFAULT
	end
end)

actionBtn.MouseButton1Down:Connect(function()
	actionBtn.BackgroundColor3 = running and BTN_STOP_DOWN or BTN_ACTION_DOWN
end)

actionBtn.MouseButton1Up:Connect(function()
	if running then
		actionBtn.BackgroundColor3 = actionHovering and BTN_STOP_HOVER or BTN_STOP_DEFAULT
	else
		actionBtn.BackgroundColor3 = actionHovering and BTN_ACTION_HOVER or BTN_ACTION_DEFAULT
	end
end)

strategyBtn.MouseButton1Down:Connect(function()
	strategyBtn.BackgroundColor3 = BTN_OPTION_DOWN
end)

strategyBtn.MouseButton1Up:Connect(function()
	strategyBtn.BackgroundColor3 = strategyHovering and BTN_OPTION_HOVER or BTN_OPTION_DEFAULT
end)

flyMethodBtn.MouseButton1Down:Connect(function()
	if isJailbreak then
		flyMethodBtn.BackgroundColor3 = darkenedOptionDown
	else
		flyMethodBtn.BackgroundColor3 = BTN_OPTION_DOWN
	end
end)

flyMethodBtn.MouseButton1Up:Connect(function()
	if isJailbreak then
		flyMethodBtn.BackgroundColor3 = flyHovering and darkenedOptionHover or darkenedOptionDefault
	else
		flyMethodBtn.BackgroundColor3 = flyHovering and BTN_OPTION_HOVER or BTN_OPTION_DEFAULT
	end
end)

moveMethodBtn.MouseButton1Down:Connect(function()
	if isJailbreak then
		moveMethodBtn.BackgroundColor3 = darkenedOptionDown
	else
		moveMethodBtn.BackgroundColor3 = BTN_OPTION_DOWN
	end
end)

moveMethodBtn.MouseButton1Up:Connect(function()
	if isJailbreak then
		moveMethodBtn.BackgroundColor3 = moveHovering and darkenedOptionHover or darkenedOptionDefault
	else
		moveMethodBtn.BackgroundColor3 = moveHovering and BTN_OPTION_HOVER or BTN_OPTION_DEFAULT
	end
end)

actionBtn.MouseButton1Click:Connect(function()
	if running then
		stopRequested = true
		StateMachine:transition(States.IDLE)
		restoreCamera()
		running = false
		actionBtn.Text = "Start"
		actionBtn.BackgroundColor3 = BTN_ACTION_DEFAULT
		setProgress(0, "Idle")
	else
		task.spawn(runLoader)
	end
end)

strategyBtn.MouseButton1Click:Connect(function()
	if running then return end

	if currentStrategy == LoadStrategies.SLOW then
		currentStrategy = LoadStrategies.FAST
	else
		currentStrategy = LoadStrategies.SLOW
	end

	strategyBtn.Text = "Strategy: " .. currentStrategy.name
end)

flyMethodBtn.MouseButton1Click:Connect(function()
    if running or GAME_ID == 606849621 then return end

	if currentFlyMethod == FlyMethods.CFLY then
		currentFlyMethod = FlyMethods.SFLY
	else
		currentFlyMethod = FlyMethods.CFLY
	end

	flyMethodBtn.Text = "Fly: " .. (currentFlyMethod == FlyMethods.CFLY and "cFLY" or "sFLY")
end)

moveMethodBtn.MouseButton1Click:Connect(function()
	if running or GAME_ID == 606849621 then return end

	if currentMoveMethod == MoveMethods.TPPOS then
		currentMoveMethod = MoveMethods.TWEENTPPOS
	else
		currentMoveMethod = MoveMethods.TPPOS
	end

	moveMethodBtn.Text = "Move: " .. (currentMoveMethod == MoveMethods.TPPOS and "tpPos" or "tweenTpPos")
end)

close.MouseButton1Click:Connect(function()
    frame:Destroy()
end)

minimize.MouseButton1Click:Connect(function()
	minimized = not minimized
	if minimized then
		savedFramePos = frame.Position
		content.Visible = false
		frame.Size = UDim2.new(0, 220, 0, 36)
		frame.Position = UDim2.new(0, 10, 1, -46)
	else
		content.Visible = true
		frame.Size = UDim2.new(0, 369, 0, 188)
		frame.Position = savedFramePos or frame.Position
	end
end)

print("[MapLoader] Initialized | State:", StateMachine.current)
print("[MapLoader] Fly Method:", currentFlyMethod, "| Move Method:", currentMoveMethod)
