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
-- COOLDOWN SYSTEM - Tránh bị server throttle
-- ═══════════════════════════════════════════
local KILL_COOLDOWN = 0.15 -- giây giữa mỗi lần kill (điều chỉnh: thấp hơn = nhanh hơn nhưng rủi ro hơn)
local CACHE_UPDATE_INTERVAL = 0.25 -- giây giữa mỗi lần update cache
local EQUIP_COOLDOWN = 0.5 -- giây chờ sau khi equip

local lastKillTime = { gun = 0, knife = 0 }
local lastCacheUpdate = 0
local lastEquipTime = 0
local isEquipping = false

-- ═══════════════════════════════════════════
-- ANTI-DESYNC: Giữ character luôn được replicate
-- ═══════════════════════════════════════════
local function antiDesync()
	local char = localPlayer.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- Nếu HRP bị anchored bất thường thì unanchor
	if hrp.Anchored and not lock.gun and not lock.knife then
		hrp.Anchored = false
	end

	-- Giữ velocity không bị freeze - di chuyển nhẹ để server biết bạn vẫn active
	if humanoid.MoveDirection.Magnitude == 0 then
		-- Gửi tiny movement để tránh server nghĩ bạn AFK/desync
		humanoid:Move(Vector3.new(0, 0, 0.001))
		task.defer(function()
			if humanoid and humanoid.Parent then
				humanoid:Move(Vector3.zero)
			end
		end)
	end
end

-- ═══════════════════════════════════════════
-- CACHE SYSTEM - Cải tiến với validation
-- ═══════════════════════════════════════════
local function isValidEnemy(enemy)
	if not enemy or enemy == localPlayer then return false end
	if not enemy.Parent then return false end -- đã rời game
	if not enemy.Team or enemy.Team == localPlayer.Team then return false end

	local char = enemy.Character
	if not char or char.Parent ~= Workspace then return false end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end

	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp.Parent then return false end

	return true
end

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
-- EQUIP SYSTEM - Với cooldown để tránh spam
-- ═══════════════════════════════════════════
local function equipWeapon(weaponType)
	local now = tick()
	if now - lastEquipTime < EQUIP_COOLDOWN then return false end

	local backpack = localPlayer.Backpack
	local character = localPlayer.Character
	if not character or not backpack then return false end

	-- Kiểm tra đã cầm đúng weapon chưa
	local currentTool = character:FindFirstChildOfClass("Tool")
	if currentTool and currentTool:GetAttribute("EquipAnimation") == weaponType then
		return true -- đã cầm rồi
	end

	for _, tool in ipairs(backpack:GetChildren()) do
		if tool:GetAttribute("EquipAnimation") == weaponType then
			isEquipping = true
			character.Humanoid:EquipTool(tool)
			lastEquipTime = now
			task.delay(0.2, function()
				isEquipping = false
			end)
			return true
		end
	end
	return false
end

local function hasWeaponEquipped(weaponType)
	local char = localPlayer.Character
	if not char then return false end
	local tool = char:FindFirstChildOfClass("Tool")
	return tool and tool:GetAttribute("EquipAnimation") == weaponType
end

-- ═══════════════════════════════════════════
-- KILL FUNCTIONS - Với rate limiting
-- ═══════════════════════════════════════════
local function killAllKnife()
	local now = tick()
	if now - lastKillTime.knife < KILL_COOLDOWN then return end
	if isEquipping then return end

	local character = localPlayer.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local killed = false
	for enemy, part in pairs(enemyCache) do
		if part and part.Parent and isValidEnemy(enemy) then
			local origin = hrp.Position
			local direction = (part.Position - origin).Unit
			throwStartRemote:FireServer(origin, direction)
			throwHitRemote:FireServer(part, part.Position)
			killed = true
		end
	end

	if killed then
		lastKillTime.knife = now
	end
end

local function killAllGun()
	local now = tick()
	if now - lastKillTime.gun < KILL_COOLDOWN then return end
	if isEquipping then return end

	local character = localPlayer.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local killed = false
	for enemy, part in pairs(enemyCache) do
		if part and part.Parent and isValidEnemy(enemy) then
			shootRemote:FireServer(hrp.Position, part.Position, part, part.Position)
			killed = true
		end
	end

	if killed then
		lastKillTime.gun = now
	end
end

-- ═══════════════════════════════════════════
-- BATCH KILL - Gửi theo đợt thay vì tất cả cùng lúc
-- ═══════════════════════════════════════════
local killQueue = { gun = {}, knife = {} }
local BATCH_SIZE = 3 -- số enemy xử lý mỗi frame (giảm nếu vẫn lag/desync)
local BATCH_DELAY = 0.05 -- delay giữa mỗi batch

local function batchKillKnife()
	local character = localPlayer.Character
	if not character or isEquipping then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local count = 0
	for enemy, part in pairs(enemyCache) do
		if count >= BATCH_SIZE then
			task.wait(BATCH_DELAY)
			count = 0
		end
		if part and part.Parent and isValidEnemy(enemy) then
			local origin = hrp.Position
			local direction = (part.Position - origin).Unit
			throwStartRemote:FireServer(origin, direction)
			throwHitRemote:FireServer(part, part.Position)
			count += 1
		end
	end
end

local function batchKillGun()
	local character = localPlayer.Character
	if not character or isEquipping then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local count = 0
	for enemy, part in pairs(enemyCache) do
		if count >= BATCH_SIZE then
			task.wait(BATCH_DELAY)
			count = 0
		end
		if part and part.Parent and isValidEnemy(enemy) then
			shootRemote:FireServer(hrp.Position, part.Position, part, part.Position)
			count += 1
		end
	end
end

-- ═══════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════
if localPlayer.Character then
	lastCacheUpdate = 0 -- force update
	updateCache()
end

local Connections = {}

-- ═══════════════════════════════════════════
-- ONE-TIME KILL BUTTONS
-- ═══════════════════════════════════════════
Connections[0] = Run.Heartbeat:Connect(function()
	if getgenv().killButton and getgenv().killButton.knife then
		getgenv().killButton.knife = false -- set false TRƯỚC để tránh spam
		if equipWeapon(WEAPON_TYPE.knife) then
			task.wait(0.15) -- chờ equip animation
			batchKillKnife()
		end
	end

	if getgenv().killButton and getgenv().killButton.gun then
		getgenv().killButton.gun = false
		if equipWeapon(WEAPON_TYPE.gun) then
			task.wait(0.15)
			batchKillGun()
		end
	end
end)

-- ═══════════════════════════════════════════
-- CACHE UPDATE - Tách riêng, chạy ít hơn
-- ═══════════════════════════════════════════
Connections[1] = Run.Heartbeat:Connect(function()
	updateCache()
end)

-- ═══════════════════════════════════════════
-- ANTI-DESYNC LOOP
-- ═══════════════════════════════════════════
Connections["antiDesync"] = Run.Heartbeat:Connect(function()
	antiDesync()
end)

-- ═══════════════════════════════════════════
-- KILL LOOP - Với throttle thông minh
-- ═══════════════════════════════════════════
Connections[2] = Run.Heartbeat:Connect(function()
	local char = localPlayer.Character
	if not char then return end
	if isEquipping then return end

	-- GUN LOOP
	if getgenv().killLoop and getgenv().killLoop.gun and not lock.gun then
		-- Equip chỉ khi chưa cầm
		if not hasWeaponEquipped(WEAPON_TYPE.gun) then
			equipWeapon(WEAPON_TYPE.gun)
			return -- chờ frame sau mới kill
		end
		killAllGun()
	end

	-- KNIFE LOOP
	if getgenv().killLoop and getgenv().killLoop.knife and not lock.knife then
		if not hasWeaponEquipped(WEAPON_TYPE.knife) then
			equipWeapon(WEAPON_TYPE.knife)
			return
		end
		killAllKnife()
	end
end)

-- ═══════════════════════════════════════════
-- CHARACTER RESPAWN HANDLER
-- ═══════════════════════════════════════════
Connections[3] = localPlayer.CharacterAdded:Connect(function(character)
	lock.gun = true
	lock.knife = true
	isEquipping = false

	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not hrp or not humanoid then return end

	-- Chờ character load hoàn tất
	task.wait(0.5)

	-- Force update cache sau khi respawn
	lastCacheUpdate = 0
	updateCache()

	if not localPlayer:GetAttribute("Match") then
		lock.gun = false
		lock.knife = false
		return
	end

	-- Equip weapon sau khi respawn
	if getgenv().killLoop and getgenv().killLoop.gun then
		task.wait(0.3)
		equipWeapon(WEAPON_TYPE.gun)
	elseif getgenv().killLoop and getgenv().killLoop.knife then
		task.wait(0.3)
		equipWeapon(WEAPON_TYPE.knife)
	end

	-- Chờ unanchor
	local anchoredConnection
	local timeout = task.delay(5, function() -- timeout 5 giây
		lock.gun = false
		lock.knife = false
		if anchoredConnection then
			anchoredConnection:Disconnect()
			anchoredConnection = nil
		end
	end)

	anchoredConnection = hrp:GetPropertyChangedSignal("Anchored"):Connect(function()
		if not hrp.Anchored then
			task.wait(0.2) -- chờ thêm chút sau unanchor
			lock.gun = false
			lock.knife = false
			if anchoredConnection then
				anchoredConnection:Disconnect()
				anchoredConnection = nil
			end
			if timeout then
				task.cancel(timeout)
			end
		end
	end)
end)

-- ═══════════════════════════════════════════
-- CLEANUP: Xóa cache khi player rời game
-- ═══════════════════════════════════════════
Connections["playerRemoving"] = Players.PlayerRemoving:Connect(function(player)
	enemyCache[player] = nil
end)

-- ═══════════════════════════════════════════
-- RECOVERY SYSTEM: Tự phục hồi khi phát hiện desync
-- ═══════════════════════════════════════════
local lastPosition = nil
local stuckFrames = 0
local STUCK_THRESHOLD = 120 -- ~2 giây ở 60fps

Connections["recovery"] = Run.Heartbeat:Connect(function()
	local char = localPlayer.Character
	if not char then
		stuckFrames = 0
		lastPosition = nil
		return
	end

	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local currentPos = hrp.Position

	if lastPosition then
		local dist = (currentPos - lastPosition).Magnitude
		if dist < 0.01 and not hrp.Anchored then
			stuckFrames += 1
		else
			stuckFrames = 0
		end

		-- Phát hiện bị stuck/desync
		if stuckFrames >= STUCK_THRESHOLD then
			warn("[KillScript] Phát hiện desync! Đang tự phục hồi...")
			stuckFrames = 0

			-- Tạm dừng kill loop
			local wasGunLoop = getgenv().killLoop and getgenv().killLoop.gun
			local wasKnifeLoop = getgenv().killLoop and getgenv().killLoop.knife

			if getgenv().killLoop then
				getgenv().killLoop.gun = false
				getgenv().killLoop.knife = false
			end

			-- Unanchor nếu bị anchor
			if hrp.Anchored then
				hrp.Anchored = false
			end

			-- Reset velocity
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero

			-- Chờ một chút rồi bật lại
			task.delay(2, function()
				if getgenv().killLoop then
					if wasGunLoop then getgenv().killLoop.gun = true end
					if wasKnifeLoop then getgenv().killLoop.knife = true end
				end
				warn("[KillScript] Đã phục hồi, tiếp tục kill loop")
			end)
		end
	end

	lastPosition = currentPos
end)

return Connections