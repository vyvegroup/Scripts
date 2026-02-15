local Players = game:GetService("Players")
local Run = game:GetService("RunService")
local Replicated = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local throwStartRemote = Replicated.Remotes:WaitForChild("ThrowStart")
local throwHitRemote = Replicated.Remotes:WaitForChild("ThrowHit")
local shootRemote = Replicated.Remotes:WaitForChild("ShootGun")
local WEAPON_TYPE = { gun = "Gun_Equip", knife = "Knife_Equip" }

local localPlayer = Players.LocalPlayer
local lock = { gun = false, knife = false }
local enemyCache = {}

-- ═══════════════════════════════════════════
-- CẤU HÌNH SPAM
-- ═══════════════════════════════════════════
local SPAM_AMOUNT = 8             -- số lần fire mỗi enemy mỗi frame
local SPAM_THREADS = 3            -- số thread song song spam cùng lúc
local CACHE_UPDATE_INTERVAL = 0.2
local EQUIP_COOLDOWN = 0.4

-- ═══════════════════════════════════════════
-- ANTI-DESYNC
-- ═══════════════════════════════════════════
local lastCacheUpdate = 0
local lastEquipTime = 0
local isEquipping = false
local lastPosition = nil
local stuckFrames = 0
local STUCK_THRESHOLD = 90
local isRecovering = false

-- ═══════════════════════════════════════════
-- RANDOM OFFSET - Mỗi lần fire data khác nhau để server không gộp
-- ═══════════════════════════════════════════
local rng = Random.new()
local function randomOffset()
	return Vector3.new(
		rng:NextNumber(-0.05, 0.05),
		rng:NextNumber(-0.05, 0.05),
		rng:NextNumber(-0.05, 0.05)
	)
end

-- ═══════════════════════════════════════════
-- VALIDATION
-- ═══════════════════════════════════════════
local function isValidEnemy(enemy)
	if not enemy or enemy == localPlayer then return false end
	if not enemy.Parent then return false end
	if not enemy.Team or enemy.Team == localPlayer.Team then return false end
	local char = enemy.Character
	if not char or char.Parent ~= Workspace then return false end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp.Parent then return false end
	return true
end

-- ═══════════════════════════════════════════
-- CACHE
-- ═══════════════════════════════════════════
local function updateCache()
	local now = tick()
	if now - lastCacheUpdate < CACHE_UPDATE_INTERVAL then return end
	lastCacheUpdate = now
	local newCache = {}
	for _, enemy in ipairs(Players:GetPlayers()) do
		if isValidEnemy(enemy) then
			newCache[enemy] = enemy.Character.HumanoidRootPart
		end
	end
	enemyCache = newCache
end

-- ═══════════════════════════════════════════
-- EQUIP
-- ═══════════════════════════════════════════
local function hasWeaponEquipped(weaponType)
	local char = localPlayer.Character
	if not char then return false end
	local tool = char:FindFirstChildOfClass("Tool")
	return tool and tool:GetAttribute("EquipAnimation") == weaponType
end

local function equipWeapon(weaponType)
	if hasWeaponEquipped(weaponType) then return true end
	local now = tick()
	if now - lastEquipTime < EQUIP_COOLDOWN then return false end
	local backpack = localPlayer.Backpack
	local character = localPlayer.Character
	if not character or not backpack then return false end
	for _, tool in ipairs(backpack:GetChildren()) do
		if tool:GetAttribute("EquipAnimation") == weaponType then
			isEquipping = true
			character.Humanoid:EquipTool(tool)
			lastEquipTime = now
			task.delay(0.25, function()
				isEquipping = false
			end)
			return true
		end
	end
	return false
end

-- ═══════════════════════════════════════════
-- SPAM KILL KNIFE - Mỗi lần fire data khác nhau + multi thread
-- ═══════════════════════════════════════════
local function spamKillKnife()
	if isRecovering or isEquipping then return end
	local character = localPlayer.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	for enemy, part in pairs(enemyCache) do
		if part and part.Parent and isValidEnemy(enemy) then
			for i = 1, SPAM_AMOUNT do
				task.spawn(function()
					local offset = randomOffset()
					local origin = hrp.Position + offset
					local targetPos = part.Position + randomOffset()
					local direction = (targetPos - origin).Unit

					throwStartRemote:FireServer(origin, direction)
					throwHitRemote:FireServer(part, targetPos)
				end)
			end
		end
	end
end

-- ═══════════════════════════════════════════
-- SPAM KILL GUN - Mỗi lần fire data khác nhau + multi thread
-- ═══════════════════════════════════════════
local function spamKillGun()
	if isRecovering or isEquipping then return end
	local character = localPlayer.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	for enemy, part in pairs(enemyCache) do
		if part and part.Parent and isValidEnemy(enemy) then
			for i = 1, SPAM_AMOUNT do
				task.spawn(function()
					local offset = randomOffset()
					local origin = hrp.Position + offset
					local targetPos = part.Position + randomOffset()

					shootRemote:FireServer(origin, targetPos, part, targetPos)
				end)
			end
		end
	end
end

-- ═══════════════════════════════════════════
-- ANTI-DESYNC
-- ═══════════════════════════════════════════
local function antiDesync()
	local char = localPlayer.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	if hrp.Anchored and not lock.gun and not lock.knife then
		hrp.Anchored = false
	end
	if hrp.AssemblyLinearVelocity.Magnitude > 500 then
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
end

local function checkAndRecover()
	local char = localPlayer.Character
	if not char then
		stuckFrames = 0
		lastPosition = nil
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local currentPos = hrp.Position
	if lastPosition then
		local dist = (currentPos - lastPosition).Magnitude
		if dist < 0.01 and not hrp.Anchored and humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
			stuckFrames += 1
		else
			stuckFrames = 0
		end

		if stuckFrames >= STUCK_THRESHOLD and not isRecovering then
			warn("[KillScript] Desync detected! Pausing...")
			isRecovering = true
			stuckFrames = 0
			hrp.Anchored = false
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			pcall(function()
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end)
			task.delay(3, function()
				isRecovering = false
				stuckFrames = 0
				warn("[KillScript] Resumed!")
			end)
		end
	end
	lastPosition = currentPos
end

-- ═══════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════
if localPlayer.Character then
	lastCacheUpdate = 0
	updateCache()
end

local Connections = {}

-- ═══════════════════════════════════════════
-- KILL BUTTON
-- ═══════════════════════════════════════════
Connections[0] = Run.Heartbeat:Connect(function()
	if getgenv().killButton and getgenv().killButton.knife then
		getgenv().killButton.knife = false
		equipWeapon(WEAPON_TYPE.knife)
		task.wait(0.15)
		-- Spam nhiều đợt khi nhấn button
		for wave = 1, 3 do
			spamKillKnife()
			task.wait(0.05)
		end
	end
	if getgenv().killButton and getgenv().killButton.gun then
		getgenv().killButton.gun = false
		equipWeapon(WEAPON_TYPE.gun)
		task.wait(0.15)
		for wave = 1, 3 do
			spamKillGun()
			task.wait(0.05)
		end
	end
end)

-- ═══════════════════════════════════════════
-- CACHE
-- ═══════════════════════════════════════════
Connections[1] = Run.Heartbeat:Connect(updateCache)

-- ═══════════════════════════════════════════
-- ANTI-DESYNC
-- ═══════════════════════════════════════════
Connections["antiDesync"] = Run.Heartbeat:Connect(function()
	antiDesync()
	checkAndRecover()
end)

-- ═══════════════════════════════════════════
-- KILL LOOP - RenderStepped (mỗi frame render)
-- ═══════════════════════════════════════════
Connections[2] = Run.RenderStepped:Connect(function()
	if isRecovering then return end
	local char = localPlayer.Character
	if not char or isEquipping then return end

	if getgenv().killLoop and getgenv().killLoop.gun and not lock.gun then
		if not hasWeaponEquipped(WEAPON_TYPE.gun) then
			equipWeapon(WEAPON_TYPE.gun)
			return
		end
		spamKillGun()
	end

	if getgenv().killLoop and getgenv().killLoop.knife and not lock.knife then
		if not hasWeaponEquipped(WEAPON_TYPE.knife) then
			equipWeapon(WEAPON_TYPE.knife)
			return
		end
		spamKillKnife()
	end
end)

-- ═══════════════════════════════════════════
-- EXTRA SPAM LAYERS - Chạy thêm nhiều loop để tăng tần suất
-- ═══════════════════════════════════════════
for t = 1, SPAM_THREADS do
	Connections["spam_hb_" .. t] = Run.Heartbeat:Connect(function()
		if isRecovering or isEquipping then return end
		local char = localPlayer.Character
		if not char then return end

		if getgenv().killLoop and getgenv().killLoop.gun and not lock.gun then
			if hasWeaponEquipped(WEAPON_TYPE.gun) then
				spamKillGun()
			end
		end

		if getgenv().killLoop and getgenv().killLoop.knife and not lock.knife then
			if hasWeaponEquipped(WEAPON_TYPE.knife) then
				spamKillKnife()
			end
		end
	end)
end

-- ═══════════════════════════════════════════
-- EXTRA SPAM - Stepped (thêm 1 event loop nữa)
-- ═══════════════════════════════════════════
Connections["spam_stepped"] = Run.Stepped:Connect(function()
	if isRecovering or isEquipping then return end
	local char = localPlayer.Character
	if not char then return end

	if getgenv().killLoop and getgenv().killLoop.gun and not lock.gun then
		if hasWeaponEquipped(WEAPON_TYPE.gun) then
			spamKillGun()
		end
	end

	if getgenv().killLoop and getgenv().killLoop.knife and not lock.knife then
		if hasWeaponEquipped(WEAPON_TYPE.knife) then
			spamKillKnife()
		end
	end
end)

-- ═══════════════════════════════════════════
-- CHARACTER RESPAWN
-- ═══════════════════════════════════════════
Connections[3] = localPlayer.CharacterAdded:Connect(function(character)
	lock.gun = true
	lock.knife = true
	isEquipping = false
	isRecovering = false
	stuckFrames = 0
	lastPosition = nil

	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not hrp or not humanoid then return end

	task.wait(0.5)
	lastCacheUpdate = 0
	updateCache()

	if not localPlayer:GetAttribute("Match") then
		lock.gun = false
		lock.knife = false
		return
	end

	if getgenv().killLoop then
		if getgenv().killLoop.gun then
			task.wait(0.3)
			equipWeapon(WEAPON_TYPE.gun)
		elseif getgenv().killLoop.knife then
			task.wait(0.3)
			equipWeapon(WEAPON_TYPE.knife)
		end
	end

	local anchoredConnection
	local timeout = task.delay(5, function()
		lock.gun = false
		lock.knife = false
		if anchoredConnection then
			anchoredConnection:Disconnect()
			anchoredConnection = nil
		end
	end)

	anchoredConnection = hrp:GetPropertyChangedSignal("Anchored"):Connect(function()
		if not hrp.Anchored then
			task.wait(0.2)
			lock.gun = false
			lock.knife = false
			if anchoredConnection then
				anchoredConnection:Disconnect()
				anchoredConnection = nil
			end
			if timeout then task.cancel(timeout) end
		end
	end)
end)

-- ═══════════════════════════════════════════
-- CLEANUP
-- ═══════════════════════════════════════════
Connections["playerRemoving"] = Players.PlayerRemoving:Connect(function(player)
	enemyCache[player] = nil
end)

return Connections