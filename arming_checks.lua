-- This script runs custom arming checks for validations that are important
-- to some, but might need to be different depending on the vehicle or use case
-- so we don't want to bake them into the firmware. Requires SCR_ENABLE =1 so must 
-- be a higher end FC in order to be used. (minimum 2M flash and 1M RAM)
-- Thanks to @yuri_rage and Peter Barker for help with the Lua and Autotests

local SCRIPT_VERSION = "4.6.0"

local REFRESH_RATE      = 500
local INITIAL_DELAY	= 60000
local MAV_SEVERITY_ERROR = 3        --/* Indicates an error in secondary/redundant systems. | */
local MAV_SEVERITY_WARNING = 4      --/* Indicates about a possible future error if this is not resolved within a given timeframe. Example would be a low battery warning. | */
local MAV_SEVERITY_INFO = 6         --/* Normal operational messages. Useful for logging. No action is required for these messages. | */
local MAV_SEVERITY = {EMERGENCY=0, ALERT=1, CRITICAL=2, ERROR=3, WARNING=4, NOTICE=5, INFO=6, DEBUG=7}

-- These are the plane modes that autoenable the geofence
local PLANE_MODE_AUTO = 10
local PLANE_MODE_TAKEOFF = 13

local arm_auth_id = arming:get_aux_auth_id()

----  CLASS: Arming_Check  ----
local Arming_Check = {}
Arming_Check.__index = Arming_Check

setmetatable(Arming_Check, {
    __call = function(cls, func, pass_value, severity, text) -- constructor
        local self      = setmetatable({}, cls)
        self.func       = func             -- func() is called to validate arming
        self.pass_value = pass_value       -- if func() returns this arming is ok
        self.severity   = severity         -- is failure a warning or hard stop?
        self.text       = text
        self.passed     = nil
        self.changed    = true
        return self
    end
})

function Arming_Check:state()
    local passed_new = self.func() == self.pass_value
    if self.passed ~= passed_new then
        self.passed = passed_new
        self.changed = true
    end
    return self.passed
end

local FENCE_TYPE = Parameter("FENCE_TYPE")
local FENCE_TOTAL = Parameter("FENCE_TOTAL")
local FENCE_ENABLE = Parameter("FENCE_ENABLE")
local FENCE_AUTOENABLE = Parameter("FENCE_AUTOENABLE")
local RTL_ALTITUDE = Parameter("RTL_ALTITUDE")
local RTL_CLIMB = Parameter("RTL_CLIMB")

-- Logic proviced by Peter Barker - not tested 
-- Fences present if 
-- a. there are basic fences (assume this includes circle fences?) or 
-- b. there are polygon_fences with at least one side 
local function fence_present()
    local enabled_fences = FENCE_TYPE:get()
    local basic_fence = (enabled_fences & 0xB) ~= 0
    local polygon_fence = ((enabled_fences & 4) ~= 0) and FENCE_TOTAL:get() > 0
    return basic_fence or polygon_fence
end

local function geofence_enabled_armingcheck()
    --We fail if there is a no fence but FENCE_ENABLE is set - so we pass if NOT that
    --return not (not AC_Fence:present() and param:get('FENCE_ENABLE') == 1)

    -- gcs:send_text(MAV_SEVERITY.NOTICE, string.format("Fence Enable %d", FENCE_ENABLE:get()) )

    return not (not fence_present() and FENCE_ENABLE:get() == 1)
end
local function geofence_autoenabled_armingcheck()
    --We fail if there is a no fence but FENCE_AUTOENABLE is set - so we pass if NOT that
    --Plus we only fail this if in AUTO mode or TAKEOFF mode (on a plane)
    local vehicle_type = FWVersion:type()
    local mode = vehicle:get_mode()

    -- gcs:send_text(MAV_SEVERITY.INFO, string.format('AUTOENABLE: %d vehicle_type %d mode', vehicle_type, mode))

    -- If this check is useful for other vehicles they will need to add them later
    if (vehicle_type == 3 and (mode == PLANE_MODE_AUTO or mode == PLANE_MODE_TAKEOFF)) then

	-- gcs:send_text(MAV_SEVERITY.NOTICE, string.format("AutoEnable %d", FENCE_AUTOENABLE:get()) )

        return not (not fence_present() and FENCE_AUTOENABLE:get() > 0)
    end
    return true
end

local function motors_emergency_stopped()
    return not SRV_Channels:get_emergency_stop()
end

local function rtl_altitude_legal()
    if (RTL_ALTITUDE ~= nil and RTL_ALTITUDE:get() > 120) then
        return false
    end
    return true
end

local function rtl_climb()
    if (RTL_CLIMB ~= nil and RTL_CLIMB:get() > 120) then
        return false
    end
    return true
end

-- Arming checks can be deleted if not requried, 
-- or new arming checks added
local arming_checks = {
    GeoFence_Enabled = Arming_Check(geofence_enabled_armingcheck, 
                            true, MAV_SEVERITY.ERROR,
                            "FENCE_ENABLE = 1 but no fence present", true, false
                            ),
    GeoFence_AutoEnabled = Arming_Check(geofence_autoenabled_armingcheck, 
                            true, MAV_SEVERITY.ERROR,
                            "FENCE_AUTOENABLE > 0 but no fence present", true, false
                            ),
    MotorsEstopped = Arming_Check(motors_emergency_stopped,
                            true, MAV_SEVERITY.ERROR, 
                            "Motors Emergency Stopped"
                            ),
    RTLClimbLegal = Arming_Check(rtl_climb_legal,
                            true, MAV_SEVERITY.ERROR, 
                            "RTL Climb too high"
                            )
}

local function idle_while_armed()
    if not arming:is_armed() then return Validate, REFRESH_RATE end
    return idle_while_armed, REFRESH_RATE * 20
end

function Validate() -- this is the loop which periodically runs

    if arming:is_armed() then return idle_while_armed() end

    local validated = true

    for key, check in pairs(arming_checks) do
        local validate_check = check:state()
        if check.changed then
            -- gcs:send_text(MAV_SEVERITY.ERROR, string.format('ARMING: %s changed', check.text))
	    if check.passed then
	        gcs:send_text(MAV_SEVERITY.INFO, string.format('Cleared: %s', check.text))
	    elseif not check.passed then
	        -- gcs:send_text(MAV_SEVERITY.ERROR, string.format('ARMING: %s changed and failed', check.text))
	        if check.severity == MAV_SEVERITY.ERROR then
	            -- gcs:send_text(MAV_SEVERITY.ERROR, string.format('ARMING: %s failed check', check.text))
	            arming:set_aux_auth_failed(arm_auth_id, string.format('%s', check.text))
	        elseif check.severity == MAV_SEVERITY.WARNING then
	            gcs:send_text(MAV_SEVERITY_WARNING, check.text)
	        end
	    end
	    check.changed = false;
	end
	validated = validated and validate_check
    end

    if validated then
        arming:set_aux_auth_passed(arm_auth_id)
    end

    return Validate, REFRESH_RATE
end

gcs:send_text(MAV_SEVERITY.NOTICE, string.format("Scripted Arming checks %s loaded", SCRIPT_VERSION) )

return Validate(), INITIAL_DELAY -- run after a short delay to let everything settle before starting to reschedule
