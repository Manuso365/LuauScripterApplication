-- Very simple combat system made all in one script.
-- Handles attacking, combos, blocking, stun, cooldowns and hit detection server-side.
-- And added more detailed explanation as asked.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatEvent = ReplicatedStorage:WaitForChild("CombatEvent")

--==================================================
-- CONFIG
--==================================================
-- All combat tuning values are kept here for easy balancing.

local MAX_COMBO = 4                -- Maximum number of hits in one combo chain
local COMBO_RESET_TIME = 1.2       -- If player waits longer than this, combo resets
local ATTACK_COOLDOWN = 0.35       -- Minimum time between attack inputs
local BLOCK_DOT_THRESHOLD = 0.5    -- Determines how accurate a block angle must be
local DAMAGE = 10                  -- Damage dealt per successful hit
local KNOCKBACK_FORCE = Vector3.new(0,10,40) -- Vertical + forward knockback
local INVINCIBLE_TIME = 0.2        -- Reserved for future invincibility frames

--==================================================
-- STATE MACHINE CLASS
--==================================================
-- Simple state controller to prevent conflicting actions
-- (Example: cannot attack while stunned)

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initial)
	local self = setmetatable({}, StateMachine)

	-- Current state (Idle by default)
	self.Current = initial or "Idle"

	-- When locked, state cannot be changed (used during stun)
	self.Locked = false

	return self
end

-- Changes state only if:
-- 1. Machine is not locked
-- 2. Transition is allowed from current state
function StateMachine:Change(newState, allowed)
	if self.Locked then return end
	if allowed and not allowed[self.Current] then return end
	self.Current = newState
end

-- Checks current state
function StateMachine:Is(state)
	return self.Current == state
end

-- Prevent state changes
function StateMachine:Lock()
	self.Locked = true
end

-- Allow state changes again
function StateMachine:Unlock()
	self.Locked = false
end

--==================================================
-- COMBAT CLASS
--==================================================
-- Each player gets one Combat object stored in CombatRegistry

local Combat = {}
Combat.__index = Combat

-- Stores combat instances for each player
local CombatRegistry = {}

--==================================================
-- CONSTRUCTOR
--==================================================
-- Called when a player joins or combat is initialized

function Combat.new(player)
	local self = setmetatable({}, Combat)
	
	-- Store references to character components
	self.Player = player
	self.Character = player.Character or player.CharacterAdded:Wait()
	self.Humanoid = self.Character:WaitForChild("Humanoid")
	self.Root = self.Character:WaitForChild("HumanoidRootPart")

	-- Initialize state machine
	self.StateMachine = StateMachine.new("Idle")

	-- Combo tracking
	self.Combo = 0
	self.LastAttackTime = 0

	-- Cooldown tracking tables
	self.Cooldowns = {}
	self.TargetHitCooldowns = {}

	self.Blocking = false

	-- Load attack animations
	self.Animations = {}
	local animFolder = ReplicatedStorage:WaitForChild("CombatAnims")

	for i = 1, MAX_COMBO do
		-- Animations are expected to be named M1, M2, M3, etc.
		local anim = animFolder:WaitForChild("M"..i)
		local track = self.Humanoid:LoadAnimation(anim)

		-- Set high priority so it overrides walk/idle
		track.Priority = Enum.AnimationPriority.Action

		self.Animations[i] = track
	end

	return self
end

--==================================================
-- STATE TRANSITIONS
--==================================================
-- Defines which states are allowed to transition into others

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
-- Uses os.clock() timestamps to track ability usage

function Combat:OnCooldown(action)
	return self.Cooldowns[action] and os.clock() < self.Cooldowns[action]
end

function Combat:SetCooldown(action, duration)
	self.Cooldowns[action] = os.clock() + duration
end

-- Prevents hitting the same target multiple times instantly
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
-- Uses GetPartBoundsInBox to detect characters in front of attacker

function Combat:CreateHitbox(size, offset)
	-- Position hitbox relative to player's root
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

			-- Only register valid alive humanoids
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

-- Checks if attack direction is within defender's forward angle
function Combat:IsBlocked(targetPlayer)
	local targetCombat = self.GetCombat(targetPlayer)
	if not targetCombat or not targetCombat.Blocking then return false end

	local directionToAttacker = (self.Root.Position - targetCombat.Root.Position).Unit
	local targetLook = targetCombat.Root.CFrame.LookVector

	-- Dot product measures how aligned two directions are
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

	-- Reset combo if player waited too long
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

	-- Play corresponding combo animation
	local track = self.Animations[self.Combo]
	if track then track:Play() end

	-- Delay hit detection to sync with animation timing
	task.delay(0.15, function()
		if not self:Is("Attacking") then return end

		local hits = self:CreateHitbox(Vector3.new(5,5,5), CFrame.new(0,0,-3))

		for model, data in pairs(hits) do
			if self:CanHitTarget(model) then

				local blocked = false

				-- Skip block logic for NPCs
				if not model:IsDescendantOf(workspace:WaitForChild("NPC")) then
					blocked = self:IsBlocked(model) or false
				end

				if not blocked then
					data.Humanoid:TakeDamage(DAMAGE)

					-- Apply knockback force
					if data.Root then
						data.Root.AssemblyLinearVelocity =
							self.Root.CFrame.LookVector * KNOCKBACK_FORCE.Z
							+ Vector3.new(0, KNOCKBACK_FORCE.Y, 0)
					end

					self:RecordTargetHit(model)
				end
			end
		end
	end)

	-- Return to idle after attack finishes
	task.delay(0.35, function()
		if self:Is("Attacking") then
			self:ChangeState("Idle")

			-- Extra cooldown at end of full combo
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

	-- Lock state so player cannot override stun
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
-- Used to manage all active combat instances

function Combat.CreateCombat(player)
	CombatRegistry[player] = Combat.new(player)
end

function Combat.GetCombat(player)
	return CombatRegistry[player]
end

function Combat.RemoveCombat(player)
	CombatRegistry[player] = nil
end

--==================================================
-- REMOTE EVENT HANDLING
--==================================================
-- Handles client combat requests securely on the server

CombatEvent.OnServerEvent:Connect(function(player, action)
	if typeof(action) ~= "string" then return end

	local combat = Combat.GetCombat(player)
	if not combat then return end
	if not combat.Character or not combat.Humanoid then return end
	if combat.Humanoid.Health <= 0 then return end

	if action == "Attack" then
		combat:Attack()

	elseif action == "BlockStart" then
		combat:StartBlock()

	elseif action == "BlockEnd" then
		combat:StopBlock()
	end
end)

return Combat
