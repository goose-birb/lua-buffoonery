-- This file is licensed under the Creative Commons Attribution 4.0 International License. See https://creativecommons.org/licenses/by/4.0/legalcode.txt for details.
local Replicated = game:GetService("ReplicatedStorage")
local Collection = game:GetService("CollectionService")
local Tween = game:GetService("TweenService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Run = game:GetService("RunService")

--[[ Uncomment this paragraph if you want to use the script standalone
getgenv().aimConfig = {
	MAX_DISTANCE = 250,
	MAX_VELOCITY = 40,
	VISIBLE_PARTS = 4,
	CAMERA_CAST = true,
	FOV_CHECK = true,
	REACTION_TIME = 0.18,
	ACTION_TIME = 0.32,
	AUTO_EQUIP = true,
	EQUIP_LOOP = 0.3,
	NATIVE_UI = true,
	DEVIATION_ENABLED = true,
	BASE_DEVIATION = 2.05,
	DISTANCE_FACTOR = 0.6,
	VELOCITY_FACTOR = 0.9,
	ACCURACY_BUILDUP = 0.14,
	MIN_DEVIATION = 1,
	RAYCAST_DISTANCE = 1000,
}
--]]

local WEAPON_TYPE = { GUN = "Gun_Equip", KNIFE = "Knife_Equip" }
local FOV_ANGLE = math.cos(math.rad(45))
local MAX_SQUARE = getgenv().aimConfig.MAX_DISTANCE * getgenv().aimConfig.MAX_DISTANCE

local camera = Workspace.CurrentCamera
local player = Players.LocalPlayer
local animations = Replicated.Animations
local remotes = Replicated.Remotes
local modules = Replicated.Modules

local shootAnim = animations:WaitForChild("Shoot")
local throwAnim = animations:WaitForChild("Throw")
local shootRemote = remotes:WaitForChild("ShootGun")
local throwStartRemote = remotes:WaitForChild("ThrowStart")
local throwHitRemote = remotes:WaitForChild("ThrowHit")
local bulletRenderer = require(modules:WaitForChild("BulletRenderer"))
local knifeController = require(modules:WaitForChild("KnifeProjectileController"))

getgenv().controller = {}
getgenv().controller.lock = { gun = false, knife = false, general = false }
getgenv().controller.gunCooldown = 0
local progressTween

local raycastParams = RaycastParams.new()
raycastParams.IgnoreWater = true
raycastParams.FilterType = Enum.RaycastFilterType.Blacklist

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Blacklist

local misfireRayParams = RaycastParams.new()
misfireRayParams.IgnoreWater = true
misfireRayParams.FilterType = Enum.RaycastFilterType.Blacklist

local deviationSeed = math.random(1, 1000000)
local targetAcceleration = 0
local equipTimer = 0
local shotCount = 0
local accuracyBonus = 0
local lastShotTime = 0

local playerCache = {}
local function initializePlayer()
	local char = player.Character
	if not char or not char.Parent then
		playerCache = {}
		return
	end

	local hrp = char:WaitForChild("HumanoidRootPart")
	local hum = char:WaitForChild("Humanoid")
	local animator = hum and hum:WaitForChild("Animator")

	playerCache = { char, hrp, hum, animator }
end

local function normalRandom()
	local u1, u2 = math.random(), math.random()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

local function applyAimDeviation(originalPos, muzzlePos, targetChar)
	if not getgenv().aimConfig.DEVIATION_ENABLED then
		return originalPos, nil
	end

	shotCount = shotCount + 1
	math.randomseed(deviationSeed + shotCount)

	local currentTime = tick()
	local timeSinceLastShot = currentTime - lastShotTime
	lastShotTime = currentTime

	if timeSinceLastShot < 2 then
		accuracyBonus = math.min(accuracyBonus + getgenv().aimConfig.ACCURACY_BUILDUP, 1.0)
	else
		accuracyBonus = math.max(accuracyBonus - 0.1, 0)
	end

	local direction = (originalPos - muzzlePos).Unit
	local distance = (originalPos - muzzlePos).Magnitude

	if distance <= 0 then
		return originalPos, nil
	end

	local distanceFactor = (distance / getgenv().aimConfig.MAX_DISTANCE) * getgenv().aimConfig.DISTANCE_FACTOR

	local velocityFactor = 0
	if targetChar then
		local humanoid = targetChar:FindFirstChildOfClass("Humanoid")
		local hrp = targetChar:FindFirstChild("HumanoidRootPart")
		if humanoid and hrp then
			local horizontalVelocity = Vector3.new(hrp.Velocity.X, 0, hrp.Velocity.Z).Magnitude
			velocityFactor = (horizontalVelocity / getgenv().aimConfig.MAX_VELOCITY)
				* getgenv().aimConfig.VELOCITY_FACTOR
		end
	end

	local baseDeviation = getgenv().aimConfig.BASE_DEVIATION
	local totalDeviation = baseDeviation + distanceFactor + velocityFactor - accuracyBonus
	totalDeviation = math.max(totalDeviation, getgenv().aimConfig.MIN_DEVIATION)

	local maxDeviationRadians = math.rad(totalDeviation)
	local horizontalDeviation = normalRandom() * maxDeviationRadians * 0.6
	local verticalDeviation = normalRandom() * maxDeviationRadians * 0.4

	local right = Vector3.new(-direction.Z, 0, direction.X)
	if right.Magnitude < 0.001 then
		right = Vector3.new(1, 0, 0)
		if math.abs(direction.X) > 0.9 then
			right = Vector3.new(0, 0, 1)
		end
	else
		right = right.Unit
	end
	local up = direction:Cross(right).Unit

	local cosH, sinH = math.cos(horizontalDeviation), math.sin(horizontalDeviation)
	local cosV, sinV = math.cos(verticalDeviation), math.sin(verticalDeviation)

	local tempDir = direction * cosH + right * sinH
	local deviatedDirection = (tempDir * cosV + up * sinV).Unit

	local safeFilterList = {}
	if playerCache[1] and playerCache[1].Parent then
		table.insert(safeFilterList, playerCache[1])
	end

	misfireRayParams.FilterDescendantsInstances = safeFilterList

	local rayResult =
		Workspace:Raycast(muzzlePos, deviatedDirection * getgenv().aimConfig.RAYCAST_DISTANCE, misfireRayParams)

	if shotCount >= 1000 then
		shotCount = 0
		deviationSeed = math.random(1, 1000000)
	end

	return rayResult and rayResult.Position or originalPos, rayResult and rayResult.Instance
end

local function predictTargetPoint(targetHrp)
	local currentPos = targetHrp.Position
	local rayOrigin = Vector3.new(currentPos.X, currentPos.Y + 15, currentPos.Z)

	groundRayParams.FilterDescendantsInstances = { targetHrp.Parent, playerCache[1] }
	local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -80, 0), groundRayParams)

	if rayResult then
		local heightAboveGround = currentPos.Y - rayResult.Position.Y
		if heightAboveGround < 15 then
			return currentPos
		end
	end
	return currentPos
end

local function isValidTarget(targetPlayer, localHrp)
	if not targetPlayer or targetPlayer == player then
		return false
	end

	local char = targetPlayer.Character
	if not char or char.Parent ~= Workspace then
		return false
	end

	if not targetPlayer.Team or targetPlayer.Team == player.Team then
		return false
	end

	if Collection:HasTag(char, "Invulnerable") or Collection:HasTag(char, "SpeedTrail") then
		return false
	end

	local hum = char:FindFirstChild("Humanoid")
	local head = char:FindFirstChild("Head")
	local hrp = char:FindFirstChild("HumanoidRootPart")

	if
		not hum
		or hum.Health <= 0
		or not head
		or not hrp
		or hrp.Velocity.Magnitude >= getgenv().aimConfig.MAX_VELOCITY
	then
		return false
	end

	local distanceVec = head.Position - localHrp.Position
	if distanceVec:Dot(distanceVec) > MAX_SQUARE then
		return false
	end

	local toTarget = (hrp.Position - camera.CFrame.Position).Unit
	local isInFov = camera.CFrame.LookVector:Dot(toTarget) >= FOV_ANGLE
	return not getgenv().aimConfig.FOV_CHECK or isInFov
end

local function getVisibleParts(targetChar, localHrp)
	if not targetChar.Parent or not playerCache[1] or not playerCache[1].Parent then
		return {}
	end

	local visibleParts = {}
	local cameraPos = camera.CFrame.Position
	raycastParams.FilterDescendantsInstances = { playerCache[1], targetChar }

	for _, part in ipairs(targetChar:GetChildren()) do
		if part:IsA("BasePart") then
			local partPos = part.Position
			local directionFromHRP = partPos - localHrp.Position
			local distanceFromHRP = directionFromHRP.Magnitude

			if distanceFromHRP > 0 then
				local resultFromHRP =
					Workspace:Raycast(localHrp.Position, directionFromHRP.Unit * distanceFromHRP, raycastParams)
				local visibleFromHRP = not resultFromHRP
				local _, onScreen = camera:WorldToViewportPoint(partPos)

				if visibleFromHRP and (not getgenv().aimConfig.FOV_CHECK or onScreen) then
					if not getgenv().aimConfig.CAMERA_CAST then
						table.insert(visibleParts, part)
					else
						local directionFromCamera = partPos - cameraPos
						local distanceFromCamera = directionFromCamera.Magnitude

						if distanceFromCamera > 0 then
							local resultFromCamera = Workspace:Raycast(
								cameraPos,
								directionFromCamera.Unit * distanceFromCamera,
								raycastParams
							)
							if not resultFromCamera then
								table.insert(visibleParts, part)
							end
						end
					end
				end
			end
		end
	end

	return visibleParts
end

local function getWeapon(weaponType)
	if not playerCache[1] or not playerCache[1].Parent then
		return
	end

	for _, tool in ipairs(playerCache[1]:GetChildren()) do
		if tool:IsA("Tool") and (not weaponType or tool:GetAttribute("EquipAnimation") == weaponType) then
			return tool
		end
	end
end

local function findBestTarget(localHrp)
	local bestTarget, bestPart, bestKnifeTarget, bestKnifePoint = nil, nil, nil, nil
	local closestDist = getgenv().aimConfig.MAX_DISTANCE + 1

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if isValidTarget(targetPlayer, localHrp) then
			local targetChar = targetPlayer.Character
			local visible = getVisibleParts(targetChar, localHrp)

			if #visible >= getgenv().aimConfig.VISIBLE_PARTS then
				local hrp = targetChar:FindFirstChild("HumanoidRootPart")
				if hrp then
					local dist = (hrp.Position - localHrp.Position).Magnitude

					if dist < closestDist then
						closestDist = dist
						bestTarget = targetPlayer

						local priorityPart = nil
						for _, part in ipairs(visible) do
							local partName = part.Name:lower()
							if partName:find("uppertorso") or partName:find("humanoidrootpart") then
								priorityPart = part
								break
							end
						end
						bestPart = priorityPart or visible[1]
						bestKnifeTarget = targetPlayer
						bestKnifePoint = predictTargetPoint(hrp)
					end
				end
			end
		end
	end

	return bestTarget, bestPart, bestKnifeTarget, bestKnifePoint
end

local function updateUIHighlight(tool)
	if not getgenv().aimConfig.NATIVE_UI or not tool then
		return
	end

	local success, backpackUi = pcall(function()
		return player:WaitForChild("PlayerGui"):WaitForChild("Backpack")
	end)
	if not success or not backpackUi then
		return
	end

	local buttonFrame = backpackUi.Container and backpackUi.Container.ButtonFrame
	if not buttonFrame then
		return
	end

	for _, button in ipairs(buttonFrame:GetChildren()) do
		if button:IsA("TextButton") then
			button.UIStroke.Enabled = (button.Container.Icon.Image == tool.TextureId)
		end
	end
end

local function renderCooldown(tool)
	if not tool or not getgenv().aimConfig.NATIVE_UI then
		return
	end

	local success, backpack = pcall(function()
		return player.PlayerGui:WaitForChild("Backpack")
	end)
	if not success then
		return
	end

	local cooldown = tool:GetAttribute("Cooldown")
	local buttonFrame = backpack.Container and backpack.Container.ButtonFrame
	if not buttonFrame then
		return
	end

	for _, button in ipairs(buttonFrame:GetChildren()) do
		if button:IsA("TextButton") and button.Container.Icon.Image == tool.TextureId then
			local cooldownBar = button:FindFirstChild("CooldownBar")
			local gradient = cooldownBar and cooldownBar.Bar and cooldownBar.Bar:FindFirstChild("UIGradient")

			if cooldownBar and gradient then
				gradient.Offset = Vector2.new(0, 0)
				cooldownBar.Visible = true

				progressTween = Tween:Create(
					gradient,
					TweenInfo.new(cooldown, Enum.EasingStyle.Linear),
					{ Offset = Vector2.new(-1, 0) }
				)

				progressTween.Completed:Connect(function()
					cooldownBar.Visible = false
				end)
				progressTween:Play()
			end
			break
		end
	end
end

local function fireGun(targetPos, hitPart, localHrp, animator)
	if getgenv().controller.lock.gun then
		return
	end
	getgenv().controller.lock.gun = true

	local gun = getWeapon(WEAPON_TYPE.GUN)
	if not gun then
		getgenv().controller.lock.gun = false
		return
	end

	local cooldown = gun:GetAttribute("Cooldown") or 2.5
	if tick() - getgenv().controller.gunCooldown < cooldown then
		getgenv().controller.lock.gun = false
		return
	end

	local muzzle = gun:FindFirstChild("Muzzle", true)
	if not muzzle then
		getgenv().controller.lock.gun = false
		return
	end

	local targetChar = hitPart and hitPart.Parent
	if targetChar then
		local visibleParts = getVisibleParts(targetChar, localHrp)
		if #visibleParts >= getgenv().aimConfig.VISIBLE_PARTS then
			for _, part in ipairs(visibleParts) do
				local lowerName = part.Name:lower()
				if lowerName:find("uppertorso") or lowerName:find("humanoidrootpart") then
					hitPart = part
					targetPos = part.Position
					break
				end
			end
		end
	end

	local muzzlePos = muzzle.WorldPosition
	local finalPos, actualHitPart = applyAimDeviation(targetPos, muzzlePos, targetChar)

	local animTrack = animator:LoadAnimation(shootAnim)
	animTrack:Play()

	local sound = gun:FindFirstChild("Fire")
	if sound then
		sound:Play()
	end

	bulletRenderer(muzzlePos, finalPos, "Default")
	shootRemote:FireServer(muzzlePos, finalPos, actualHitPart or hitPart, finalPos)

	getgenv().controller.gunCooldown = tick()
	renderCooldown(gun)

	task.wait(animTrack.Length or 0.5)
	getgenv().controller.lock.gun = false
end

local function throwKnife(targetPos, hitPart, localHrp, animator)
	if getgenv().controller.lock.knife then
		return
	end
	getgenv().controller.lock.knife = true

	local knife = getWeapon(WEAPON_TYPE.KNIFE)
	if not knife then
		getgenv().controller.lock.knife = false
		return
	end

	local handle = knife:FindFirstChild("RightHandle")
	if not handle then
		getgenv().controller.lock.knife = false
		return
	end

	local finalPos = applyAimDeviation(targetPos, localHrp.Position)
	local direction = (finalPos - localHrp.Position).Unit

	local animTrack = animator:LoadAnimation(throwAnim)
	animTrack:Play()

	local sound = knife:FindFirstChild("ThrowSound")
	if sound then
		sound:Play()
	end

	throwStartRemote:FireServer(localHrp.Position, direction)
	knifeController({
		Speed = knife:GetAttribute("ThrowSpeed") or 150,
		KnifeProjectile = handle:Clone(),
		Direction = direction,
		Origin = localHrp.Position,
		IgnoreCharacter = playerCache[1],
	}, function(result)
		if result and result.Instance then
			throwHitRemote:FireServer(result.Instance, result.Position)
		end
		task.wait(1)
		getgenv().controller.lock.knife = false
	end)
end

local function equipWeapon(weaponType, callback)
	if not playerCache[1] then
		if callback then
			callback(false, "No character")
		end
		return
	end

	local humanoid = playerCache[3]
	if not humanoid then
		if callback then
			callback(false, "No humanoid")
		end
		return
	end

	local currentTool = getWeapon()
	local targetTool = getWeapon(weaponType)

	if not targetTool and player.Backpack then
		for _, tool in ipairs(player.Backpack:GetChildren()) do
			if tool:IsA("Tool") and tool:GetAttribute("EquipAnimation") == weaponType then
				targetTool = tool
				break
			end
		end
	end

	if not targetTool then
		if callback then
			callback(false, "Tool not found")
		end
		return
	end

	if currentTool == targetTool then
		if callback then
			callback(true, targetTool)
		end
		return
	end

	if
		Collection:HasTag(playerCache[1], "Invulnerable")
		or Collection:HasTag(playerCache[1], "CombatDisabled")
		or Collection:HasTag(playerCache[1], "SpeedTrail")
	then
		return
	end

	if currentTool then
		humanoid:UnequipTools()
		getgenv().controller.lock.general = true
		task.wait(getgenv().aimConfig.ACTION_TIME)
		if targetTool.Parent ~= player.Backpack then
			getgenv().controller.lock.general = false
			if callback then
				callback(false, "Tool no longer available")
			end
			return
		end
		humanoid:EquipTool(targetTool)
		task.wait(getgenv().aimConfig.ACTION_TIME)
		getgenv().controller.lock.general = false
		if callback then
			callback(true, targetTool)
		end
	else
		humanoid:EquipTool(targetTool)
		getgenv().controller.lock.general = true
		task.wait(getgenv().aimConfig.ACTION_TIME)
		getgenv().controller.lock.general = false
		if callback then
			callback(true, targetTool)
		end
	end
end

local function handleAutoEquip()
	if not getgenv().aimConfig.AUTO_EQUIP then
		return
	end

	if tick() - equipTimer < getgenv().aimConfig.EQUIP_LOOP then
		return
	end
	equipTimer = tick()

	if getgenv().controller.lock.general then
		return
	end

	if not playerCache[1] or not playerCache[1].Parent then
		return
	end

	if
		Collection:HasTag(playerCache[1], "Invulnerable")
		or Collection:HasTag(playerCache[1], "CombatDisabled")
		or Collection:HasTag(playerCache[1], "SpeedTrail")
	then
		return
	end

	local gunEquipped = getWeapon(WEAPON_TYPE.GUN)
	local gunInBackpack = nil
	if player.Backpack then
		for _, tool in ipairs(player.Backpack:GetChildren()) do
			if tool:IsA("Tool") and tool:GetAttribute("EquipAnimation") == WEAPON_TYPE.GUN then
				gunInBackpack = tool
				break
			end
		end
	end

	local gunAvailable = gunEquipped or gunInBackpack
	local gunReady = gunAvailable
		and not getgenv().controller.lock.gun
		and (
			tick() - getgenv().controller.gunCooldown
			>= ((gunEquipped or gunInBackpack):GetAttribute("Cooldown") or 2.5)
		)

	local knifeEquipped = getWeapon(WEAPON_TYPE.KNIFE)
	local knifeInBackpack = nil
	if player.Backpack then
		for _, tool in ipairs(player.Backpack:GetChildren()) do
			if tool:IsA("Tool") and tool:GetAttribute("EquipAnimation") == WEAPON_TYPE.KNIFE then
				knifeInBackpack = tool
				break
			end
		end
	end

	local knifeAvailable = (knifeEquipped or knifeInBackpack) and not getgenv().controller.lock.knife

	if gunReady and not gunEquipped then
		equipWeapon(WEAPON_TYPE.GUN, function(success, gun)
			if success then
				updateUIHighlight(gun)
			end
		end)
	elseif knifeAvailable and not knifeEquipped and not gunReady then
		equipWeapon(WEAPON_TYPE.KNIFE, function(success, knife)
			if success then
				updateUIHighlight(knife)
			end
		end)
	end
end

local function handleCombat()
	local char, hrp, humanoid, animator = playerCache[1], playerCache[2], playerCache[3], playerCache[4]
	if not char or not hrp or not humanoid or not animator then
		return
	end

	if
		Collection:HasTag(char, "Invulnerable")
		or Collection:HasTag(char, "CombatDisabled")
		or Collection:HasTag(char, "SpeedTrail")
	then
		humanoid:UnequipTools()
		return
	end

	local bestTarget, bestPart, bestKnifeTarget, bestKnifePoint = findBestTarget(hrp)
	if not bestTarget or not bestPart then
		return
	end

	local weapon = getWeapon()
	if not weapon then
		return
	end

	task.wait(getgenv().aimConfig.REACTION_TIME)
	if not isValidTarget(bestTarget, hrp) then
		return
	end

	local equipType = weapon:GetAttribute("EquipAnimation")
	if equipType == WEAPON_TYPE.GUN then
		local gunReady = not getgenv().controller.lock.gun
			and (tick() - getgenv().controller.gunCooldown >= (weapon:GetAttribute("Cooldown") or 2.5))
		if gunReady and bestPart and bestPart.Parent then
			fireGun(bestPart.Position, bestPart, hrp, animator)
		end
	elseif equipType == WEAPON_TYPE.KNIFE then
		if
			not getgenv().controller.lock.knife
			and bestKnifeTarget
			and bestKnifePoint
			and isValidTarget(bestKnifeTarget, hrp)
		then
			local targetHrp = bestKnifeTarget.Character:FindFirstChild("HumanoidRootPart")
			if targetHrp then
				throwKnife(bestKnifePoint, targetHrp, hrp, animator)
			end
		end
	end
end

if player.Character then
	initializePlayer()
end

local Connections = {}
Connections[0] = Run.RenderStepped:Connect(handleCombat)
Connections[1] = Run.Heartbeat:Connect(handleAutoEquip)
Connections[2] = player.CharacterAdded:Connect(initializePlayer)

return Connections
