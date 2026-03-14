-- Very simple combat system made all in one script.
-- Handles attacking, combos, blocking, stun, cooldowns and hit detection server-side.

--And i spend some time on the comments and changed some stuff to use more Roblox APIs.

--==================================================
-- SERVICES
--==================================================

-- ReplicatedStorage is used to access shared assets such as
-- RemoteEvents and animation folders that both the client
-- and server need access to.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Debris automatically removes temporary instances after
-- a set duration. This is useful for physics objects such
-- as VectorForces so we don't leave unnecessary objects
-- inside the workspace.
local Debris = game:GetService("Debris")

-- CollectionService allows objects to be tagged with labels.
-- In this system NPCs can be tagged as "NPC" instead of
-- relying on folder structure checks.
local CollectionService = game:GetService("CollectionService")

--==================================================
-- REMOTE EVENT
--==================================================

-- The client uses this RemoteEvent to send input actions
-- such as attacking or starting to block.
--
-- The server still validates every action before executing it.
local CombatEvent = ReplicatedStorage:WaitForChild("CombatEvent")

--==================================================
-- CONFIGURATION
--==================================================

-- Maximum number of chained attacks in a combo.
local MAX_COMBO = 4

-- Time before the combo resets if the player stops attacking.
local COMBO_RESET_TIME = 1.2

-- Prevents players from triggering attacks too quickly.
local ATTACK_COOLDOWN = 0.35

-- Dot product threshold used to determine if an attack
-- is within the defender's blocking direction.
local BLOCK_DOT_THRESHOLD = 0.5

-- Base damage applied by each attack.
local DAMAGE = 10

-- Force values used for physics knockback.
local KNOCKBACK_FORCE = Vector3.new(0,3000,5000)

-- Prevents hitting the same target multiple times in a single swing.
local TARGET_HIT_COOLDOWN = 0.2

-- If a defender begins blocking shortly before impact,
-- the attack becomes a perfect block (parry).
local PARRY_WINDOW = 0.25

--==================================================
-- STATE MACHINE
--==================================================

-- The state machine controls what actions a character
-- is currently allowed to perform.

-- Without this system a player could attempt to attack,
-- block, and perform other actions simultaneously which
-- would cause animation conflicts and inconsistent logic.

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initialState)

	local self = setmetatable({},StateMachine)

	self.Current = initialState or "Idle"

	-- When locked the state cannot change.
	-- This is mainly used during stun effects.
	self.Locked = false

	return self

end

function StateMachine:Change(newState,allowed)

	-- If the state machine is locked, ignore changes.
	if self.Locked then return end

	-- Some transitions are restricted. For example,
	-- we do not want a player switching directly from
	-- Stunned to Attacking.
	if allowed and not allowed[self.Current] then
		return
	end

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
-- Each player receives a Combat object which stores
-- their individual combat data.

local Combat = {}
Combat.__index = Combat

-- Registry used to look up a player's Combat object.
local CombatRegistry = {}

--==================================================
-- STATE TRANSITIONS
--==================================================

-- Defines which states can move to other states.

local AllowedTransitions = {

	Idle = {Attacking = true, Blocking = true, Stunned = true},
	Attacking = {Idle = true, Stunned = true},
	Blocking = {Idle = true, Stunned = true},
	Stunned = {Idle = true}

}

--==================================================
-- CONSTRUCTOR
--==================================================

function Combat.new(player)

	local self = setmetatable({},Combat)

	self.Player = player

	-- Ensure character is loaded before accessing components.
	self.Character = player.Character or player.CharacterAdded:Wait()

	self.Humanoid = self.Character:WaitForChild("Humanoid")
	self.Root = self.Character:WaitForChild("HumanoidRootPart")

	self.StateMachine = StateMachine.new("Idle")

	-- Tracks combo progression.
	self.Combo = 0
	self.LastAttackTime = 0

	-- Cooldown storage.
	self.Cooldowns = {}

	-- Used to prevent repeatedly damaging the same
	-- target during a single swing.
	self.TargetHitCooldowns = {}

	self.Blocking = false
	self.LastBlockTime = 0

	-- Attribute allows other scripts to easily detect stun state.
	self.Character:SetAttribute("Stunned",false)

	--==================================================
	-- ANIMATION LOADING
	--==================================================

	self.Animations = {}

	local animFolder = ReplicatedStorage:WaitForChild("CombatAnims")

	for i = 1,MAX_COMBO do

		local anim = animFolder:WaitForChild("M"..i)

		-- AnimationTrack controls playback.
		local track = self.Humanoid:LoadAnimation(anim)

		-- Action priority overrides walking animations.
		track.Priority = Enum.AnimationPriority.Action

		self.Animations[i] = track

	end

	return self

end

--==================================================
-- COOLDOWN SYSTEM
--==================================================

function Combat:OnCooldown(action)

	local endTime = self.Cooldowns[action]

	return endTime and os.clock() < endTime

end

function Combat:SetCooldown(action,duration)

	self.Cooldowns[action] = os.clock() + duration

end

--==================================================
-- HITBOX SYSTEM
--==================================================

function Combat:CreateHitbox(size,offset)

	local cf = self.Root.CFrame * offset

	local params = OverlapParams.new()

	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {self.Character}

	local parts = workspace:GetPartBoundsInBox(cf,size,params)

	local hitCharacters = {}

	for _,part in ipairs(parts) do

		local model = part:FindFirstAncestorOfClass("Model")

		if model and model ~= self.Character then

			local humanoid = model:FindFirstChild("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")

			if humanoid and root and humanoid.Health > 0 then

				hitCharacters[model] = {
					Humanoid = humanoid,
					Root = root
				}

			end

		end

	end

	return hitCharacters

end

--==================================================
-- BLOCKING LOGIC
--==================================================

function Combat:IsBlocked(targetModel)

	local targetPlayer = game.Players:GetPlayerFromCharacter(targetModel)

	if not targetPlayer then return false end

	local targetCombat = Combat.GetCombat(targetPlayer)

	if not targetCombat or not targetCombat.Blocking then
		return false
	end

	local directionToAttacker = (self.Root.Position - targetCombat.Root.Position).Unit

	local targetLook = targetCombat.Root.CFrame.LookVector

	local dot = targetLook:Dot(directionToAttacker)

	return dot > BLOCK_DOT_THRESHOLD

end

--==================================================
-- KNOCKBACK SYSTEM
--==================================================

function Combat:ApplyKnockback(targetRoot)

	local attachment = Instance.new("Attachment")
	attachment.Parent = targetRoot

	local force = Instance.new("VectorForce")

	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World

	local direction = self.Root.CFrame.LookVector

	force.Force = direction * KNOCKBACK_FORCE.Z + Vector3.new(0,KNOCKBACK_FORCE.Y,0)

	force.Parent = targetRoot

	Debris:AddItem(force,0.15)
	Debris:AddItem(attachment,0.15)

end

--==================================================
-- STUN SYSTEM (NEW)
--==================================================
-- This system allows characters to be temporarily stunned.
-- When stunned the state machine is locked so no actions
-- such as attacking or blocking can occur.

function Combat:Stun(duration)

	if self.StateMachine:Is("Stunned") then return end

	self.StateMachine:Change("Stunned",AllowedTransitions)

	self.StateMachine:Lock()

	self.Character:SetAttribute("Stunned",true)

	task.delay(duration,function()

		self.Character:SetAttribute("Stunned",false)

		self.StateMachine:Unlock()

		self.StateMachine:Change("Idle",AllowedTransitions)

	end)

end

--==================================================
-- BLOCK SYSTEM (NEW)
--==================================================
-- Players can hold block which changes their state.
-- This allows directional block detection during attacks.

function Combat:StartBlock()

	if not self.StateMachine:Is("Idle") then return end

	self.Blocking = true
	self.LastBlockTime = os.clock()

	self.StateMachine:Change("Blocking",AllowedTransitions)

end

function Combat:StopBlock()

	if not self.StateMachine:Is("Blocking") then return end

	self.Blocking = false

	self.StateMachine:Change("Idle",AllowedTransitions)

end

--==================================================
-- ATTACK SYSTEM
--==================================================

function Combat:Attack()

	if self:OnCooldown("Attack") then return end
	if not self.StateMachine:Is("Idle") then return end

	if os.clock() - self.LastAttackTime > COMBO_RESET_TIME then
		self.Combo = 0
	end

	self.Combo += 1

	if self.Combo > MAX_COMBO then
		self.Combo = 1
	end

	self.LastAttackTime = os.clock()

	self:SetCooldown("Attack",ATTACK_COOLDOWN)

	self.StateMachine:Change("Attacking",AllowedTransitions)

	local track = self.Animations[self.Combo]

	if track then
		track:Play()
	end

	task.delay(0.15,function()

		local hits = self:CreateHitbox(Vector3.new(5,5,5),CFrame.new(0,0,-3))

		for model,data in pairs(hits) do

			-- NEW: check if the attack is blocked
			if not self:IsBlocked(model) then

				data.Humanoid:TakeDamage(DAMAGE)

				self:ApplyKnockback(data.Root)

				-- NEW: final combo hit applies stun
				if self.Combo == MAX_COMBO then

					local targetPlayer = game.Players:GetPlayerFromCharacter(model)

					if targetPlayer then

						local targetCombat = Combat.GetCombat(targetPlayer)

						if targetCombat then
							targetCombat:Stun(1)
						end

					end

				end

			end

		end

	end)

end

--==================================================
-- REGISTRY
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
-- PLAYER SETUP SYSTEM (NEW)
--==================================================
-- This automatically creates combat objects for players
-- when their character spawns and removes them when they leave.

game.Players.PlayerAdded:Connect(function(player)

	player.CharacterAdded:Connect(function()

		Combat.CreateCombat(player)

	end)

end)

game.Players.PlayerRemoving:Connect(function(player)

	Combat.RemoveCombat(player)

end)

--==================================================
-- REMOTE EVENT HANDLER
--==================================================

CombatEvent.OnServerEvent:Connect(function(player,action)

	if typeof(action) ~= "string" then return end

	local combat = Combat.GetCombat(player)

	if not combat then return end
	if combat.Humanoid.Health <= 0 then return end

	if action == "Attack" then
		combat:Attack()
	end

	-- NEW: block input handling
	if action == "BlockStart" then
		combat:StartBlock()
	end

	if action == "BlockStop" then
		combat:StopBlock()
	end

end)

return Combat
