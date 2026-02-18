local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatEvent = ReplicatedStorage:WaitForChild("CombatEvent")

--==================================================
-- CONFIG
--==================================================
local MAX_COMBO = 4
local COMBO_RESET_TIME = 1.2
local ATTACK_COOLDOWN = 0.35
local BLOCK_DOT_THRESHOLD = 0.5
local DAMAGE = 10
local KNOCKBACK_FORCE = Vector3.new(0,10,40)
local INVINCIBLE_TIME = 0.2

--==================================================
-- STATE MACHINE CLASS
--==================================================
local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initial)
	local self = setmetatable({}, StateMachine)
	self.Current = initial or "Idle"
	self.Locked = false
	return self
end

function StateMachine:Change(newState, allowed)
	if self.Locked then return end
	if allowed and not allowed[self.Current] then return end
	self.Current = newState
end

function StateMachine:Is(state)
	return self.Current == state
end

function StateMachine:Lock()
	self.Locked = true
end

function StateMachine:Unlock()
	self.Locked = false
end

--==================================================
-- COMBAT CLASS
--==================================================
local Combat = {}
Combat.__index = Combat

-- Server-side combat registry
local CombatRegistry = {}

--==================================================
-- CONSTRUCTOR
--==================================================
function Combat.new(player)
	local self = setmetatable({}, Combat)
	
	self.Player = player
	self.Character = player.Character or player.CharacterAdded:Wait()
	self.Humanoid = self.Character:WaitForChild("Humanoid")
	self.Root = self.Character:WaitForChild("HumanoidRootPart")

	self.StateMachine = StateMachine.new("Idle")
	self.Combo = 0
	self.LastAttackTime = 0
	self.Cooldowns = {}
	self.TargetHitCooldowns = {}
	self.Blocking = false

	-- Load animations
	self.Animations = {}
	local animFolder = ReplicatedStorage:WaitForChild("CombatAnims")
	for i = 1, MAX_COMBO do
		local anim = animFolder:WaitForChild("M"..i)
		local track = self.Humanoid:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action
		self.Animations[i] = track
	end

	return self
end

--==================================================
-- STATE TRANSITIONS
--==================================================
local AllowedTransitions = {
	Idle = {Attacking = true, Blocking = true, Stunned = true},
	Attacking = {Idle = true, Stunned = true},
	Blocking = {Idle = true, Stunned = true},
	Stunned = {Idle = true}
}

function Combat:ChangeState(newState)
	self.StateMachine:Change(newState, AllowedTransitions)
end

function Combat:Is(state)
	return self.StateMachine:Is(state)
end

--==================================================
-- COOLDOWNS
--==================================================
function Combat:OnCooldown(action)
	return self.Cooldowns[action] and os.clock() < self.Cooldowns[action]
end

function Combat:SetCooldown(action, duration)
	self.Cooldowns[action] = os.clock() + duration
end

function Combat:CanHitTarget(target)
	local lastHit = self.TargetHitCooldowns[target]
	return not lastHit or os.clock() - lastHit >= 0.2
end

function Combat:RecordTargetHit(target)
	self.TargetHitCooldowns[target] = os.clock()
end

--==================================================
-- HITBOX SYSTEM
--==================================================
function Combat:CreateHitbox(size, offset)
	local cf = self.Root.CFrame * offset
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {self.Character}
	local parts = workspace:GetPartBoundsInBox(cf, size, params)

	local hitCharacters = {}
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model ~= self.Character then
			local humanoid = model:FindFirstChild("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				hitCharacters[model] = {Humanoid = humanoid, Root = root}
			end
		end
	end
	return hitCharacters
end

--==================================================
-- BLOCKING SYSTEM
--==================================================
function Combat:StartBlock()
	if not self:Is("Idle") then return end
	self:ChangeState("Blocking")
	self.Blocking = true
end

function Combat:StopBlock()
	if self:Is("Blocking") then
		self:ChangeState("Idle")
		self.Blocking = false
	end
end

function Combat:IsBlocked(targetPlayer)
	local targetCombat = self.GetCombat(targetPlayer)
	if not targetCombat or not targetCombat.Blocking then return false end
	local directionToAttacker = (self.Root.Position - targetCombat.Root.Position).Unit
	local targetLook = targetCombat.Root.CFrame.LookVector
	local dot = targetLook:Dot(directionToAttacker)
	return dot > BLOCK_DOT_THRESHOLD
end

--==================================================
-- ATTACK SYSTEM
--==================================================
function Combat:CanAttack()
	if self:OnCooldown("Attack") then return false end
	if not self:Is("Idle") then return false end
	return true
end

function Combat:Attack()
	if not self:CanAttack() then return end

	-- Combo logic
	if os.clock() - self.LastAttackTime > COMBO_RESET_TIME then
		self.Combo = 0
	end
	self.Combo += 1
	if self.Combo > MAX_COMBO then
		self.Combo = 1
	end
	self.LastAttackTime = os.clock()
	self:SetCooldown("Attack", ATTACK_COOLDOWN)

	self:ChangeState("Attacking")

	-- Play animation
	local track = self.Animations[self.Combo]
	if track then track:Play() end

	-- Hit delay
	task.delay(0.15, function()
		if not self:Is("Attacking") then return end

		local hits = self:CreateHitbox(Vector3.new(5,5,5), CFrame.new(0,0,-3))
		for model, data in pairs(hits) do
			if self:CanHitTarget(model) then

				local blocked = false
				if not model:IsDescendantOf(workspace:WaitForChild("NPC")) then
					blocked = self:IsBlocked(model) or false
				end

				if not blocked then
					data.Humanoid:TakeDamage(DAMAGE)
					if data.Root then
						data.Root.AssemblyLinearVelocity = self.Root.CFrame.LookVector * KNOCKBACK_FORCE.Z + Vector3.new(0, KNOCKBACK_FORCE.Y, 0)
					end

					if model then
						self:RecordTargetHit(model)
					end
				end
			end
		end
	end)

	-- Finish attack
	task.delay(0.35, function()
		if self:Is("Attacking") then
			self:ChangeState("Idle")
			
			if self.Combo == MAX_COMBO then
				self:SetCooldown("Attack", 0.5) 
			end
		end
	end)
end


--==================================================
-- STUN SYSTEM
--==================================================
function Combat:Stun(duration)
	self:ChangeState("Stunned")
	self.StateMachine:Lock()
	task.delay(duration, function()
		self.StateMachine:Unlock()
		if self:Is("Stunned") then
			self:ChangeState("Idle")
		end
	end)
end

--==================================================
-- SERVER-SIDE REGISTRY
--==================================================
function Combat.GetCombat(player)
	if not CombatRegistry[player] then
		CombatRegistry[player] = Combat.new(player)
	end
	return CombatRegistry[player]
end

function Combat.RemoveCombat(player)
	CombatRegistry[player] = nil
end

--==================================================
-- REMOTE EVENT HANDLING
--==================================================
CombatEvent.OnServerEvent:Connect(function(player, action)
	if typeof(action) ~= "string" then return end
	local combat = Combat.GetCombat(player)
	if not combat.Character or not combat.Humanoid or combat.Humanoid.Health <= 0 then return end

	if action == "Attack" then
		combat:Attack()
	elseif action == "BlockStart" then
		combat:StartBlock()
	elseif action == "BlockEnd" then
		combat:StopBlock()
	end
end)

return Combat
