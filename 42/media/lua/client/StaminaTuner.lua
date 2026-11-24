-- Stamina Tuner (Build 42). All adjustments happen in one player update handler.
local StaminaTuner = {}
local previous = setmetatable({}, { __mode = "k" })

local function actionName(player)
    -- Lua timed actions expose Type; Java BaseAction instances are not a reliable
    -- source of Lua action names, so only use the active Lua queue here.
    if not ISTimedActionQueue then return "" end
    local queue = ISTimedActionQueue.getTimedActionQueue(player)
    local action = queue and queue.current
    return action and tostring(action.Type or "") or ""
end

local function stateName(player)
    local state = player:getCurrentState()
    return state and tostring(state:getClass():getSimpleName()) or ""
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
    if player:isMoving() and player:getInventoryWeight() >= player:getMaxWeight() * 1.5 then
        active.OverloadedWalking = true
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
    elseif state == "ClimbSheetRopeState" or state == "ClimbDownSheetRopeState" then
        active.SheetRopes = true
    elseif state == "ClimbLadderState" or state == "ClimbDownLadderState" then
        active.Ladders = true
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
    if action:find("Dig", 1, true) or action:find("Shovel", 1, true)
        or performing:find("dig", 1, true) or performing:find("shovel", 1, true) then
        active.Digging = true
    end
    if action:find("DragCorpse", 1, true) or action:find("MoveCorpse", 1, true)
        or variable(player, "DraggingCorpse") == "true" then
        active.DraggingCorpses = true
    end

    return active
end

local function multiplier(active)
    local config = SandboxVars and SandboxVars.StaminaTuner
    if not config then return 1 end
    local mode = tonumber(config.OverlapMode) or 2
    local result = nil
    for name in pairs(active) do
        local factor = (tonumber(config[name]) or 100) / 100
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

local function onPlayerUpdate(player)
    if not player or player:isDead() then
        if player then previous[player] = nil end
        return
    end
    local stats = player:getStats()
    local current = stats:get(CharacterStat.ENDURANCE)
    local active = detect(player)
    local last = previous[player]

    if last and current < last.endurance then
        -- Some animation transitions end before their endurance cost is posted.
        -- On such an update, attribute the drain to the preceding activity.
        local attributed = next(active) and active or last.active
        local scale = multiplier(attributed)
        if scale ~= 1 then
            local drained = last.endurance - current
            current = math.max(0, math.min(1, last.endurance - drained * scale))
            stats:set(CharacterStat.ENDURANCE, current)
        end
    end

    previous[player] = { endurance = current, active = active }
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
