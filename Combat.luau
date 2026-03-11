-- Very simple combat system made all in one script.
-- Handles attacking, combos, blocking, stun, cooldowns and hit detection server-side.

-- Services are fetched first so we can access shared storage and networking
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- RemoteEvent used by the client to tell the server when the player attacks or blocks
local CombatEvent = ReplicatedStorage:WaitForChild("CombatEvent")

--==================================================
-- CONFIG
--==================================================
-- These values control how the combat behaves. Keeping them here
-- makes it easier to adjust balance without touching the logic below.

local MAX_COMBO = 4                -- Maximum number of hits in one combo chain
local COMBO_RESET_TIME = 1.2       -- Time before combo resets if player stops attacking
local ATTACK_COOLDOWN = 0.35       -- Minimum delay between attacks
local BLOCK_DOT_THRESHOLD = 0.5    -- How precise the blocking direction must be
local DAMAGE = 10                  -- Damage applied per hit
local KNOCKBACK_FORCE = Vector3.new(0,10,40) -- Upward + forward push applied to enemies
local INVINCIBLE_TIME = 0.2        -- Reserved for future invincibility frames

--==================================================
-- STATE MACHINE CLASS
--==================================================
-- Small state system used to prevent actions from overlapping.
-- Example: a player shouldn't be able to attack while stunned.

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initial)

	-- Create a new table instance and attach StateMachine methods to it
	local self = setmetatable({}, StateMachine)

	-- Current state the character is in (Idle if nothing was provided)
	self.Current = initial or "Idle"

	-- When locked the state cannot be changed
	-- This is mainly used when a player is stunned
	self.Locked = false

	return self
end

-- Attempts to change the current state
function StateMachine:Change(newState, allowed)

	-- If the state machine is locked, ignore any state change attempts
	if self.Locked then return end

	-- Some transitions are restricted.
	-- If an allowed table is provided, we check if the current state
	-- is allowed to move into the new state.
	if allowed and not allowed[self.Current] then return end

	-- If the checks above pass, the state is updated
	self.Current = newState
end

-- Simple helper to check if the machine is currently in a certain state
function StateMachine:Is(state)
	return self.Current == state
end

-- Prevent any further state changes
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
-- Each player receives one Combat object.
-- These objects are stored in CombatRegistry so they can be accessed later.

local Combat = {}
Combat.__index = Combat

-- Table used to keep track of which player owns which combat object
local CombatRegistry = {}

--==================================================
-- CONSTRUCTOR
--==================================================
-- Runs when a player first gets their combat system

function Combat.new(player)

	-- Create a new combat instance
	local self = setmetatable({}, Combat)

	-- Store player reference
	self.Player = player

	-- Wait for character to exist if it hasn't loaded yet
	self.Character = player.Character or player.CharacterAdded:Wait()

	-- Grab important character components used later
	self.Humanoid = self.Character:WaitForChild("Humanoid")
	self.Root = self.Character:WaitForChild("HumanoidRootPart")

	-- Create the player's state machine starting in Idle
	self.StateMachine = StateMachine.new("Idle")

	-- Variables used for combo tracking
	self.Combo = 0
	self.LastAttackTime = 0

	-- Tables used to track cooldown timers
	self.Cooldowns = {}

	-- Stores when each target was last hit so we don't hit them too fast
	self.TargetHitCooldowns = {}

	-- Whether the player is currently blocking
	self.Blocking = false

	--==================================================
	-- Animation loading
	--==================================================

	self.Animations = {}

	-- Folder that contains the attack animations
	local animFolder = ReplicatedStorage:WaitForChild("CombatAnims")

	for i = 1, MAX_COMBO do

		-- Animations follow the naming pattern M1, M2, M3, etc
		local anim = animFolder:WaitForChild("M"..i)

		-- Load the animation onto the humanoid
		local track = self.Humanoid:LoadAnimation(anim)

		-- Set priority so attack overrides walking animations
		track.Priority = Enum.AnimationPriority.Action

		-- Store the track in the animations table
		self.Animations[i] = track
	end

	return self
end

--==================================================
-- STATE TRANSITIONS
--==================================================
-- Defines which states can transition into other states

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
-- Cooldowns use timestamps instead of waiting threads

function Combat:OnCooldown(action)

	-- Check if a cooldown exists for the action
	local endTime = self.Cooldowns[action]

	-- If the current time is still less than the stored end time,
	-- the action is still on cooldown
	return endTime and os.clock() < endTime
end

function Combat:SetCooldown(action, duration)

	-- Store the time when the cooldown should expire
	self.Cooldowns[action] = os.clock() + duration
end

-- Prevents hitting the same target too quickly
function Combat:CanHitTarget(target)

	-- Get the last time the target was hit
	local lastHit = self.TargetHitCooldowns[target]

	-- Allow hit if target has never been hit or enough time has passed
	return not lastHit or os.clock() - lastHit >= 0.2
end

function Combat:RecordTargetHit(target)

	-- Record current time so we know when the last hit occurred
	self.TargetHitCooldowns[target] = os.clock()
end

--==================================================
-- HITBOX SYSTEM
--==================================================
-- Uses spatial query instead of raycasts

function Combat:CreateHitbox(size, offset)

	-- Offset the hitbox forward relative to the player's root
	local cf = self.Root.CFrame * offset

	local params = OverlapParams.new()

	-- Ignore the attacking player's character
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {self.Character}

	-- Get all parts within the defined box
	local parts = workspace:GetPartBoundsInBox(cf, size, params)

	local hitCharacters = {}

	for _, part in ipairs(parts) do

		-- Move up the hierarchy to find the model that owns the part
		local model = part:FindFirstAncestorOfClass("Model")

		if model and model ~= self.Character then

			local humanoid = model:FindFirstChild("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")

			-- Only register characters that actually have a humanoid
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

	-- Player can only start blocking while idle
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

-- Determines if an attack direction falls within the defender's block angle
function Combat:IsBlocked(targetPlayer)

	local targetCombat = Combat.GetCombat(targetPlayer)

	if not targetCombat or not targetCombat.Blocking then return false end

	-- Vector pointing from defender to attacker
	local directionToAttacker = (self.Root.Position - targetCombat.Root.Position).Unit

	-- Direction the defender is facing
	local targetLook = targetCombat.Root.CFrame.LookVector

	-- Dot product measures alignment between the two directions
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

	-- Reset combo if too much time passed
	if os.clock() - self.LastAttackTime > COMBO_RESET_TIME then
		self.Combo = 0
	end

	-- Increase combo counter
	self.Combo += 1

	-- Loop combo if it exceeds max
	if self.Combo > MAX_COMBO then
		self.Combo = 1
	end

	self.LastAttackTime = os.clock()

	self:SetCooldown("Attack", ATTACK_COOLDOWN)

	self:ChangeState("Attacking")

	-- Play animation matching the combo index
	local track = self.Animations[self.Combo]

	if track then
		track:Play()
	end

	-- Delay hit detection slightly so it lines up with animation swing
	task.delay(0.15, function()

		if not self:Is("Attacking") then return end

		local hits = self:CreateHitbox(Vector3.new(5,5,5), CFrame.new(0,0,-3))

		for model, data in pairs(hits) do

			if self:CanHitTarget(model) then

				local blocked = false

				-- NPCs don't use the blocking system
				if not model:IsDescendantOf(workspace:WaitForChild("NPC")) then
					blocked = self:IsBlocked(model) or false
				end

				if not blocked then

					data.Humanoid:TakeDamage(DAMAGE)

					-- Apply velocity directly to the root part
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

	-- Return back to idle once attack animation should be finished
	task.delay(0.35, function()

		if self:Is("Attacking") then

			self:ChangeState("Idle")

			-- If this was the final combo hit, apply extra cooldown
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

	-- Lock state machine so player cannot override stun
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
-- Client sends action requests which the server validates

CombatEvent.OnServerEvent:Connect(function(player, action)

	-- Ensure the action parameter is valid
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
