-- Shared duration hooks for Build 42 timed digging actions.
require "TimedActions/ISFillGrave"
require "BuildingObjects/TimedActions/ISShovelGround"

local function scaleDuration(action, duration, name)
    if duration <= 1 or action.character:isTimedActionInstant() then
        return duration
    end
    local options = getSandboxOptions()
    local option = options and options:getOptionByName("StaminaTuner." .. name)
    local percent = option and tonumber(option:getValue()) or 100
    if percent == 100 then return duration end
    return math.max(1, math.floor(duration * percent / 100 + 0.5))
end

-- Both vanilla constructors call getDuration(); the server can also use
-- that method when calculating the authoritative timed action duration.
local originalFillGraveDuration = ISFillGrave.getDuration
function ISFillGrave:getDuration()
    return scaleDuration(self, originalFillGraveDuration(self), "GraveFillingDuration")
end

local originalShovelGroundDuration = ISShovelGround.getDuration
function ISShovelGround:getDuration()
    return scaleDuration(self, originalShovelGroundDuration(self), "GroundCollectionDuration")
end
