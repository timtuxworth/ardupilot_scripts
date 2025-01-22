--[[

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.

   Terrain follow in Copter
   This script enables terrain following in copter. It's a bit of a hack. It works by fudging
   the FOLL_OFS_Z value (without actually saving it). To get this to work set the following parameters:
   SCR_ENABLE = 1
   SCR_HEAP_SIZE = 300000
   SCR_VM_I_COUNT = 200000
   TERRAIN_ENABLE = 1
   FOLL_ALT_TYPE = 3 (yes this is an invalid value - you will have to enter it manually, its not in the dropdown)
   also set the FOLL_OFS values as you want them to be including 
   FOLL_OFS_Z - e.g. if set to -5 will be 5 meters ABOVE the terrain height of the lead copter

   The script will throw and error and not run if loaded on a copter or if TERRAIN_ENABLE = 0 or FOLL_ALT_TYPE != 3 
--]]

SCRIPT_VERSION = "4.7.0-002"
SCRIPT_NAME = "Copter Follow Terrain"
SCRIPT_NAME_SHORT = "CFollTerr"

REFRESH_RATE = 0.05   -- in seconds, so 20Hz

-- FOLL_ALT_TYPE and Mavlink FRAME use different values 
ALT_FRAME = { GLOBAL = 0, RELATIVE = 1, TERRAIN = 3}

MAV_SEVERITY = {EMERGENCY=0, ALERT=1, CRITICAL=2, ERROR=3, WARNING=4, NOTICE=5, INFO=6, DEBUG=7}
MAV_FRAME = {GLOBAL = 0, GLOBAL_RELATIVE_ALT = 3,  GLOBAL_TERRAIN_ALT = 10}
MAV_CMD_INT = { ATTITUDE = 30, GLOBAL_POSITION_INT = 33, 
                  DO_SET_MODE = 176, DO_CHANGE_SPEED = 178, DO_REPOSITION = 192,
                  CMD_SET_MESSAGE_INTERVAL = 511, CMD_REQUEST_MESSAGE = 512,
                  GUIDED_CHANGE_SPEED = 43000, GUIDED_CHANGE_ALTITUDE = 43001, GUIDED_CHANGE_HEADING = 43002 }
MAV_SPEED_TYPE = { AIRSPEED = 0, GROUNDSPEED = 1, CLIMB_SPEED = 2, DESCENT_SPEED = 3 }
MAV_HEADING_TYPE = { COG = 0, HEADING = 1, DEFAULT = 2} -- COG = Course over Ground, i.e. where you want to go, HEADING = which way the vehicle points 

-- FLIGHT_MODE = {AUTO=10, RTL=11, LOITER=12, GUIDED=15, QHOVER=18, QLOITER=19, QRTL=21}
FLIGHT_MODE = {STABILIZE = 0, ALT_HOLD = 2, AUTO = 3, GUIDED = 4, LOITER = 5, RTL = 6, CIRCLE = 7, LAND = 9, FOLLOW = 23 }

local now = millis():tofloat() * 0.001
local now_display = now
local mode = vehicle:get_mode()

local PARAM_TABLE_KEY = 121
local PARAM_TABLE_PREFIX = "ZCT_"

-- add a parameter and bind it to a variable
local function bind_add_param(name, idx, default_value)
   assert(param:add_param(PARAM_TABLE_KEY, idx, name, default_value), string.format('could not add param %s', name))
   return Parameter(PARAM_TABLE_PREFIX .. name)
end
-- setup follow mode specific parameters
assert(param:add_table(PARAM_TABLE_KEY, PARAM_TABLE_PREFIX, 20), 'could not add param table')

TERRAIN_ENABLE = Parameter("TERRAIN_ENABLE")
local terrain_enable = TERRAIN_ENABLE:get() or 0
FOLL_ALT_TYPE = Parameter("FOLL_ALT_TYPE")
local foll_alt_type = FOLL_ALT_TYPE:get() or 0
FOLL_OFS_Z = Parameter("FOLL_OFS_Z")
local foll_ofs_z = FOLL_OFS_Z:get() or 0

local function calculate_ofs_z()

    -- only do this if the FOLL_ALT_TYPE = TERRAIN (a non standard value but the same as AltFrame)
    -- need to recalculate the Z offset based on the target vehicle altitude
    local target_location, target_velocity = follow:get_target_location_and_velocity()
    local current_location = ahrs:get_location()
    local target_terrain_height_m = terrain:height_amsl(target_location, true)
    local target_terrain_alt_m = target_location:alt() * .01 - target_terrain_height_m
    local current_terrain_height_m = terrain:height_amsl(current_location, true)
    if current_location ~= nil then
        current_location:change_alt_frame(ALT_FRAME.TERRAIN)
        local current_terrain_alt_m = current_location:alt() * .01

        local new_foll_ofs_z = -(target_terrain_alt_m - current_terrain_alt_m - foll_ofs_z)
        if (now - now_display) > 5 then
            gcs:send_text(MAV_SEVERITY.NOTICE, string.format("alt target %.0f current %.0f foll_ofs_z %.0f new %.0f",
                                                            target_terrain_alt_m, current_terrain_alt_m,
                                                            foll_ofs_z, new_foll_ofs_z
                                                        ))
            now_display = now
        end
        param:set("FOLL_OFS_Z", new_foll_ofs_z)
    end

end
-- main update function
local function update()
    now = millis():tofloat() * 0.001
    mode = vehicle:get_mode()
    foll_alt_type = FOLL_ALT_TYPE:get() or 0

    if mode == FLIGHT_MODE.FOLLOW and follow:have_target() and foll_alt_type == 3 then
        calculate_ofs_z()
    end
end

-- wrapper around update(). This calls update() at 1/REFRESH_RATE Hz
-- and if update faults then an error is displayed, but the script is not
-- stopped
local function protected_wrapper()
    local success, err = pcall(update)

    if not success then
       gcs:send_text(MAV_SEVERITY.ALERT, SCRIPT_NAME_SHORT .. "Internal Error: " .. err)
       -- when we fault we run the update function again after 1s, slowing it
       -- down a bit so we don't flood the console with errors
       return protected_wrapper, 1000
    end
    return protected_wrapper, 1000 * REFRESH_RATE
end

local function delayed_start()
    gcs:send_text(MAV_SEVERITY.INFO, string.format("%s %s script loaded", SCRIPT_NAME, SCRIPT_VERSION) )
    return protected_wrapper()
end

-- start running update loop - waiting 20s for the AP to initialize
if FWVersion:type() == 2 and terrain_enable and foll_alt_type == 3 then
    return delayed_start, 20000
else
    gcs:send_text(MAV_SEVERITY.ERROR, string.format("%s: must run on Copter with terrain enabled", SCRIPT_NAME_SHORT))
end
