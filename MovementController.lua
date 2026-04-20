local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local character
local humanoid
local rootPart

local config = {
	WalkSpeed = 16,
	SprintSpeed = 24,
	CrouchSpeed = 9,

	SpeedLerp = 12,

	DefaultFOV = 70,
	SprintFOV = 80,
	SlideFOV = 86,
	FOVLerp = 10,

	DefaultCameraOffset = Vector3.new(0, 0, 0),
	CrouchCameraOffset = Vector3.new(0, -1.35, 0),

	SlideMinimumStartSpeed = 26,
	SlideBoost = 11,
	SlideDecay = 24,
	SlideCooldown = 0.75,
	SlideJumpCancelBoost = 1.08,

	BobWalkSpeed = 8,
	BobSprintSpeed = 12,
	BobCrouchSpeed = 5,

	BobWalkAmountX = 0.06,
	BobWalkAmountY = 0.11,

	BobSprintAmountX = 0.09,
	BobSprintAmountY = 0.18,

	BobCrouchAmountX = 0.03,
	BobCrouchAmountY = 0.05,

	BobLerpSpeed = 10,

	LandingImpactStrength = 0.38,
	LandingRecoverSpeed = 12,
	LandingVelocityThreshold = -18,

	CameraTiltAmount = 4,
	CameraTiltLerp = 8,

	UseStamina = true,
	MaxStamina = 100,
	StaminaDrain = 20,
	StaminaRegen = 16,
	MinSprintStamina = 8,
}

local state = {
	Sprinting = false,
	Crouching = false,
	Sliding = false,
	CanSlide = true,
	InAir = false,
	Stamina = config.MaxStamina,
}

local inputState = {
	ShiftHeld = false,
}

local slideConnection
local slideVelocity

local cameraBobTime = 0
local bobOffset = Vector3.zero
local landingOffset = Vector3.zero
local crouchOffset = Vector3.zero
local tiltAngle = 0

local lastYVelocity = 0
local currentSpeed = config.WalkSpeed
local targetFOV = config.DefaultFOV
local defaultHipHeight = nil

local function cleanupSlide()
	if slideConnection then
		slideConnection:Disconnect()
		slideConnection = nil
	end

	if slideVelocity then
		slideVelocity:Destroy()
		slideVelocity = nil
	end
end

local function setCharacterSpeedTarget()
	if not humanoid then return end

	local targetSpeed
	if state.Sliding then
		targetSpeed = 0
	elseif state.Crouching then
		targetSpeed = config.CrouchSpeed
	elseif state.Sprinting then
		targetSpeed = config.SprintSpeed
	else
		targetSpeed = config.WalkSpeed
	end

	currentSpeed = currentSpeed + (targetSpeed - currentSpeed) * math.clamp(config.SpeedLerp * RunService.RenderStepped:Wait(), 0, 1)
	humanoid.WalkSpeed = currentSpeed
end

local function updateStateTargets()
	if state.Sliding then
		targetFOV = config.SlideFOV
	elseif state.Sprinting then
		targetFOV = config.SprintFOV
	else
		targetFOV = config.DefaultFOV
	end

	if state.Crouching then
		crouchOffset = config.CrouchCameraOffset
		if defaultHipHeight then
			humanoid.HipHeight = defaultHipHeight - 0.45
		end
	elseif state.Sliding then
		crouchOffset = Vector3.new(0, -1.0, 0)
		if defaultHipHeight then
			humanoid.HipHeight = defaultHipHeight - 0.3
		end
	else
		crouchOffset = config.DefaultCameraOffset
		if defaultHipHeight then
			humanoid.HipHeight = defaultHipHeight
		end
	end
end

local function movingEnough()
	if not humanoid then return false end
	return humanoid.MoveDirection.Magnitude > 0.05
end

local function grounded()
	if not humanoid then return false end
	return humanoid.FloorMaterial ~= Enum.Material.Air
end

local function canSprint()
	if not humanoid then return false end
	if state.Sliding then return false end
	if state.Crouching then return false end
	if not grounded() then return false end
	if not movingEnough() then return false end
	if not inputState.ShiftHeld then return false end

	if config.UseStamina and state.Stamina < config.MinSprintStamina then
		return false
	end

	return true
end

local function startSprint()
	if state.Sprinting then return end
	if not canSprint() then return end
	state.Sprinting = true
end

local function stopSprint()
	if not state.Sprinting then return end
	state.Sprinting = false
end

local function setCrouch(enabled)
	if not humanoid then return end
	if state.Sliding then return end

	state.Crouching = enabled
	if enabled then
		state.Sprinting = false
	end
end

local function toggleCrouch()
	setCrouch(not state.Crouching)
end

local function stopSlide()
	if not humanoid then return end
	if not state.Sliding then return end

	state.Sliding = false
	humanoid.AutoRotate = true
	cleanupSlide()

	task.delay(config.SlideCooldown, function()
		state.CanSlide = true
	end)
end

local function startSlide()
	if not humanoid or not rootPart then return end
	if state.Sliding then return end
	if not state.CanSlide then return end
	if not state.Sprinting then return end
	if not grounded() then return end
	if not movingEnough() then return end

	state.Sliding = true
	state.Sprinting = false
	state.Crouching = false
	state.CanSlide = false

	humanoid.AutoRotate = false

	local planarVelocity = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z)
	local moveDirection = humanoid.MoveDirection.Magnitude > 0.05 and humanoid.MoveDirection.Unit or rootPart.CFrame.LookVector
	local slideSpeed = math.max(config.SlideMinimumStartSpeed, planarVelocity.Magnitude + config.SlideBoost)

	slideVelocity = Instance.new("BodyVelocity")
	slideVelocity.Name = "SlideVelocity"
	slideVelocity.MaxForce = Vector3.new(100000, 0, 100000)
	slideVelocity.P = 3000
	slideVelocity.Velocity = moveDirection * slideSpeed
	slideVelocity.Parent = rootPart

	slideConnection = RunService.RenderStepped:Connect(function(dt)
		if not state.Sliding or not slideVelocity or not slideVelocity.Parent or not rootPart then
			stopSlide()
			return
		end

		if not grounded() then
			stopSlide()
			return
		end

		local horizontal = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z)
		local direction = horizontal.Magnitude > 0.1 and horizontal.Unit or moveDirection

		slideSpeed -= config.SlideDecay * dt
		if slideSpeed <= 8 then
			stopSlide()
			return
		end

		slideVelocity.Velocity = direction * slideSpeed
	end)
end

local function jumpCancelSlide()
	if not humanoid or not rootPart then return end
	if not state.Sliding then return end

	local horizontal = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z)
	stopSlide()
	humanoid.Jump = true

	if horizontal.Magnitude > 0 then
		rootPart.AssemblyLinearVelocity = Vector3.new(
			horizontal.X * config.SlideJumpCancelBoost,
			rootPart.AssemblyLinearVelocity.Y,
			horizontal.Z * config.SlideJumpCancelBoost
		)
	end
end

local function setupCharacter(char)
	character = char
	humanoid = char:WaitForChild("Humanoid")
	rootPart = char:WaitForChild("HumanoidRootPart")
	defaultHipHeight = humanoid.HipHeight

	cleanupSlide()

	state.Sprinting = false
	state.Crouching = false
	state.Sliding = false
	state.CanSlide = true
	state.InAir = false
	state.Stamina = config.MaxStamina

	inputState.ShiftHeld = false

	cameraBobTime = 0
	bobOffset = Vector3.zero
	landingOffset = Vector3.zero
	crouchOffset = Vector3.zero
	tiltAngle = 0
	lastYVelocity = 0
	currentSpeed = config.WalkSpeed
	targetFOV = config.DefaultFOV

	humanoid.WalkSpeed = config.WalkSpeed
	humanoid.HipHeight = defaultHipHeight
	humanoid.CameraOffset = Vector3.zero
	camera.FieldOfView = config.DefaultFOV
end

player.CharacterAdded:Connect(setupCharacter)
if player.Character then
	setupCharacter(player.Character)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if not humanoid then return end

	if input.KeyCode == Enum.KeyCode.LeftShift then
		inputState.ShiftHeld = true
		startSprint()

	elseif input.KeyCode == Enum.KeyCode.C then
		toggleCrouch()

	elseif input.KeyCode == Enum.KeyCode.LeftControl then
		startSlide()

	elseif input.KeyCode == Enum.KeyCode.Space then
		if state.Sliding then
			jumpCancelSlide()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		inputState.ShiftHeld = false
		stopSprint()
	end
end)

RunService.RenderStepped:Connect(function(dt)
	if not humanoid or not rootPart then return end

	if not state.Sliding then
		if canSprint() then
			startSprint()
		else
			stopSprint()
		end
	end

	if config.UseStamina then
		if state.Sprinting then
			state.Stamina = math.max(0, state.Stamina - config.StaminaDrain * dt)
			if state.Stamina <= 0 then
				stopSprint()
			end
		else
			state.Stamina = math.min(config.MaxStamina, state.Stamina + config.StaminaRegen * dt)
		end
	end

	updateStateTargets()

	local targetSpeed
	if state.Sliding then
		targetSpeed = 0
	elseif state.Crouching then
		targetSpeed = config.CrouchSpeed
	elseif state.Sprinting then
		targetSpeed = config.SprintSpeed
	else
		targetSpeed = config.WalkSpeed
	end
	
	currentSpeed = currentSpeed + (targetSpeed - currentSpeed) * math.clamp(config.SpeedLerp * dt, 0, 1)
	humanoid.WalkSpeed = currentSpeed

	camera.FieldOfView = camera.FieldOfView + (targetFOV - camera.FieldOfView) * math.clamp(config.FOVLerp * dt, 0, 1)

	local isMoving = movingEnough()
	local isGrounded = grounded()

	if isGrounded then
		if state.InAir then
			if lastYVelocity < config.LandingVelocityThreshold then
				landingOffset = Vector3.new(
					0,
					-math.clamp(math.abs(lastYVelocity) * 0.01, 0, config.LandingImpactStrength),
					0
				)
			end
			state.InAir = false
		end
	else
		state.InAir = true
	end

	local targetBob = Vector3.zero

	if isGrounded and isMoving and not state.Sliding then
		if state.Sprinting then
			cameraBobTime += dt * config.BobSprintSpeed
			targetBob = Vector3.new(
				math.sin(cameraBobTime) * config.BobSprintAmountX,
				math.abs(math.cos(cameraBobTime * 2)) * config.BobSprintAmountY,
				0
			)
		elseif state.Crouching then
			cameraBobTime += dt * config.BobCrouchSpeed
			targetBob = Vector3.new(
				math.sin(cameraBobTime) * config.BobCrouchAmountX,
				math.abs(math.cos(cameraBobTime * 2)) * config.BobCrouchAmountY,
				0
			)
		else
			cameraBobTime += dt * config.BobWalkSpeed
			targetBob = Vector3.new(
				math.sin(cameraBobTime) * config.BobWalkAmountX,
				math.abs(math.cos(cameraBobTime * 2)) * config.BobWalkAmountY,
				0
			)
		end
	end

	bobOffset = bobOffset:Lerp(targetBob, math.clamp(config.BobLerpSpeed * dt, 0, 1))
	landingOffset = landingOffset:Lerp(Vector3.zero, math.clamp(config.LandingRecoverSpeed * dt, 0, 1))

	local strafe = 0
	if isMoving then
		local right = rootPart.CFrame.RightVector
		strafe = right:Dot(humanoid.MoveDirection)
	end

	local targetTilt = -strafe * config.CameraTiltAmount
	tiltAngle = tiltAngle + (targetTilt - tiltAngle) * math.clamp(config.CameraTiltLerp * dt, 0, 1)

	humanoid.CameraOffset = crouchOffset + bobOffset + landingOffset
	camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, math.rad(tiltAngle))

	lastYVelocity = rootPart.AssemblyLinearVelocity.Y
end)
