-- Stamina Tuner (Build 42). All adjustments happen in one player update handler.
local StaminaTuner = {}
local previous = setmetatable({}, { __mode = "k" })
local BATCH_UPDATES = 15
local DIGGING_EXHAUSTION_THRESHOLD = 0.10
-- Build 42 movement base coefficients (before character-specific modifiers).
local DIGGING_DRAIN = {
    [2] = { activity = "Jogging", rate = 0.000052 },
    [3] = { activity = "Sprinting", rate = 0.000455 },
}

local function actionName(player)
    -- Lua timed actions expose Type; Java BaseAction instances are not a reliable
    -- source of Lua action names, so only use the active Lua queue here.
    if not ISTimedActionQueue then return "" end
    local queue = ISTimedActionQueue.getTimedActionQueue(player)
    local action = queue and queue.current
    return action and tostring(action.Type or "") or "", action
end

local function stateName(player)
    local state = player:getCurrentState()
    return state and getClassSimpleName(state) or ""
end

local function variable(player, key)
    return string.lower(tostring(player:getVariableString(key) or ""))
end

local function detect(player)
    local active = {}
    local state = stateName(player)
    local action = actionName(player)
    local performing = variable(player, "PerformingAction")
    local attack = variable(player, "AttackType")

    -- Running flags already describe the player's movement. isMoving() can
    -- lag behind them during animation transitions, so don't gate jogging on it.
    if player:isSneaking() and (player:IsRunning() or player:isSprinting()) then
        active.SneakJogging = true
    elseif player:isSprinting() then
        active.Sprinting = true
    elseif player:IsRunning() then
        active.Jogging = true
    end

    if state == "SwipeStatePlayer" or player:isAttacking() then
        if attack:find("stomp", 1, true) then
            active.Stomping = true
        elseif attack:find("shove", 1, true) or attack:find("push", 1, true) then
            active.Pushing = true
        else
            active.Melee = true
        end
    end

    if state == "ClimbOverFenceState" then
        active.Vaulting = true
    elseif state == "ClimbOverWallState" then
        active.TallFences = true
    elseif action == "ISClimbLadderAction"
        or (player.isClimbingLadder and player:isClimbingLadder())
        or (player.isClimbingDownLadder and player:isClimbingDownLadder())
        or state == "ClimbLadderState" or state == "ClimbDownLadderState" then
        active.Ladders = true
    elseif state == "ClimbState" or state == "ClimbDownState"
        or state == "ClimbSheetRopeState" or state == "ClimbDownSheetRopeState"
        or action == "ISClimbSheetRopeAction" then
        active.SheetRopes = true
    elseif state == "FitnessState" then
        active.Exercising = true
    end

    -- Time-based interactions may not have a distinctive Java movement state.
    if action == "ISChopTreeAction" or performing:find("choptree", 1, true) then
        active.ChoppingTrees = true
    end
    if action == "ISFitnessAction" or action == "ISFitnessUI" then
        active.Exercising = true
    end
    if player:isDraggingCorpse() or state == "PlayerDraggingCorpse" then
        active.DraggingCorpses = true
    end

    return active
end

local function hasActivity(active)
    for _ in pairs(active) do
        return true
    end
    return false
end

local function sandboxValue(options, name, default)
    local option = options:getOptionByName("StaminaTuner." .. name)
    if not option then return default end
    return tonumber(option:getValue()) or default
end

-- Grave digging uses a generic build action. Scale its vanilla duration once
-- when it is created, without changing any other construction actions.
require "BuildingObjects/TimedActions/ISBuildAction"

local originalBuildActionNew = ISBuildAction.new
function ISBuildAction:new(character, item, ...)
    local action = originalBuildActionNew(self, character, item, ...)
    -- Multiplayer construction duration is set by the server.
    if not isClient() and item and item.Type == "ISEmptyGraves"
        and action.maxTime > 1 and not character:isTimedActionInstant() then
        local options = getSandboxOptions()
        local percent = options and sandboxValue(options, "GraveDiggingDuration", 100) or 100
        if percent ~= 100 then
            action.maxTime = math.max(1, math.floor(action.maxTime * percent / 100 + 0.5))
        end
    end
    return action
end

local function multiplier(active)
    -- Read the live Java options rather than the SandboxVars Lua snapshot.
    local options = getSandboxOptions()
    if not options then return 1 end
    local mode = sandboxValue(options, "OverlapMode", 2)
    local result = nil
    for name in pairs(active) do
        local factor = sandboxValue(options, name, 100) / 100
        if result == nil then
            result = factor
        elseif mode == 1 then
            result = result * factor
        elseif mode == 3 then
            result = math.min(result, factor)
        else
            result = math.max(result, factor)
        end
    end
    return result or 1
end

-- Only charge the three supported digging actions once they have started,
-- not walking to them or unrelated actions using a shovel.
local function diggingAction(player)
    local name, action = actionName(player)
    if (name == "ISBuildAction" and action.item
            and action.item.Type == "ISEmptyGraves" and action.started)
        or name == "ISFillGrave" or name == "ISShovelGround" then
        if action:isStarted() then return action end
    end
end

local function applyDiggingDrain(player, stats, current, digging, recovered)
    if not digging then return current end
    local options = getSandboxOptions()
    local preset = options and DIGGING_DRAIN[sandboxValue(options, "GraveDiggingDrain", 1)]
    local factor = preset and sandboxValue(options, preset.activity, 100) / 100 or 0
    if current > DIGGING_EXHAUSTION_THRESHOLD and factor > 0 then
        -- Prevent stationary endurance recovery from cancelling the artificial
        -- movement drain. Use the game-time delta, including fast-forward.
        local drain = preset.rate * factor * getGameTime():getMultiplier()
        current = math.max(0, current - recovered - drain)
        stats:set(CharacterStat.ENDURANCE, current)
    end
    -- Check the stat directly so cancellation does not wait for the moodle update.
    if current <= DIGGING_EXHAUSTION_THRESHOLD then
        digging:forceStop()
    end
    return stats:get(CharacterStat.ENDURANCE)
end

local function onPlayerUpdate(player)
    if not player or player:isDead() then
        if player then previous[player] = nil end
        return
    end
    local stats = player:getStats()
    local current = stats:get(CharacterStat.ENDURANCE)
    local active = detect(player)
    local last = previous[player]
    local digging = diggingAction(player)
    local recovered = last and digging and last.digging == digging
        and math.max(0, current - last.endurance) or 0
    local correction = 0
    local updates = 0

    if last then
        correction = last.correction
        updates = last.updates
        if current < last.endurance then
            -- Attribute delayed animation costs to the preceding activity.
            local attributed = hasActivity(active) and active or last.active
            local scale = multiplier(attributed)
            correction = correction + (last.endurance - current) * (1 - scale)
        end

        if hasActivity(active) or hasActivity(last.active) or correction ~= 0 then
            updates = updates + 1
        end

        -- Flush a partial batch when tracked activity ends, including short actions.
        if updates >= BATCH_UPDATES or not hasActivity(active) then
            if correction ~= 0 then
                stats:set(CharacterStat.ENDURANCE, math.max(0, math.min(1, current + correction)))
                current = stats:get(CharacterStat.ENDURANCE)
            end
            correction = 0
            updates = 0
        end
    end

    -- Apply after vanilla corrections and store the resulting endurance so
    -- the next update cannot mistake synthetic drain for vanilla activity loss.
    current = applyDiggingDrain(player, stats, current, digging, recovered)

    previous[player] = {
        endurance = current,
        digging = digging,
        active = active,
        correction = correction,
        updates = updates,
    }
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
