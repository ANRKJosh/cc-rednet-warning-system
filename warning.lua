-- Enhanced PoggishTown Warning System (actually version 33 apparently)
-- Speaker + Modem required (expected on left/right)
-- Redstone output on BACK when alarm is active

local protocol = "poggishtown_warning"
local warning_active = false
local modem_side = nil
local speaker = peripheral.find("speaker")
local alarm_start_time = nil
local redstone_output_side = "back"

-- Check if we're running on a wireless terminal
local function isWirelessTerminal()
    -- Check if we have pocket computer API
    if pocket then
        return true
    end
    
    -- Check computer label for terminal indicators
    local label = os.getComputerLabel()
    if label and (string.find(label:lower(), "terminal") or string.find(label:lower(), "pocket")) then
        return true
    end
    
    -- Check if we have no attached peripherals (common for terminals)
    local peripherals = peripheral.getNames()
    if #peripherals == 0 then
        return true
    end
    
    -- Check if we only have built-in modem (terminals often have built-in wireless)
    local has_only_modem = true
    for _, side in pairs(peripherals) do
        if peripheral.getType(side) ~= "modem" then
            has_only_modem = false
            break
        end
    end
    
    return has_only_modem and #peripherals == 1
end

-- Configuration
local config = {
    heartbeat_interval = 30,    -- seconds between heartbeats
    max_offline_time = 90,      -- seconds before marking node as offline
    auto_stop_timeout = 300,    -- seconds to auto-stop alarm (5 minutes)
    volume_increment = 0.3,     -- Increased from 0.2
    max_volume = 15.0,          -- Increased from 10.0 - very very loud!
    base_volume = 3.0,          -- Increased from 2.0
    enable_relay = true,        -- enable message relaying
    max_hops = 3,              -- Reduced from 8 - ender modems have infinite range
    relay_delay = 0.2,         -- Increased from 0.05 to reduce spam
    -- Single update URL - program adapts based on device type
    update_url = "https://raw.githubusercontent.com/ANRKJosh/cc-rednet-warning-system/refs/heads/main/warning.lua",
    -- Background update checking
    background_update_check = true,  -- Enable background update checking
    update_check_interval = 300,     -- 5 minutes between background checks
    auto_apply_updates = false,      -- Only auto-apply on computers, not terminals
    -- Custom naming
    allow_custom_names = true,       -- Allow custom device names
    custom_name = nil               -- Custom name (will be set if configured)
}

-- Get display name for this device
local function getDisplayName()
    if config.custom_name then
        return config.custom_name
    end
    
    -- Check if computer has a label
    local label = os.getComputerLabel()
    if label then
        return label
    end
    
    -- Default to ID
    return tostring(computer_id)
end

-- Set custom name
local function setCustomName(name)
    if not config.allow_custom_names then return false end
    
    if name and name ~= "" then
        config.custom_name = name
        -- Save to file
        local file = fs.open("poggish_config", "w")
        if file then
            file.write(textutils.serialize({custom_name = name}))
            file.close()
        end
        return true
    else
        config.custom_name = nil
        -- Remove config file
        if fs.exists("poggish_config") then
            fs.delete("poggish_config")
        end
        return true
    end
end

-- Load custom name from file
local function loadCustomName()
    if fs.exists("poggish_config") then
        local file = fs.open("poggish_config", "r")
        if file then
            local content = file.readAll()
            file.close()
            local success, data = pcall(textutils.unserialize, content)
            if success and data and data.custom_name then
                config.custom_name = data.custom_name
            end
        end
    end
end

-- Network state tracking
local network_nodes = {}
local last_heartbeat = 0
local computer_id = os.getComputerID()
local alarm_triggered_by = nil
local message_history = {}  -- Track recent messages to prevent loops
local alarm_note_index = 1  -- Track which note we're currently playing
local is_terminal = isWirelessTerminal()
local update_available = false  -- Track if update is available
local last_update_check = 0     -- Last time we checked for updates
local background_update_running = false  -- Prevent multiple simultaneous checks

-- Terminal-specific features (always defined, even for computers)
local terminal_features = {
    location_tracking = true,       -- Track GPS coordinates if available
    silent_mode = false,           -- Silent mode for stealth operations
    vibrate_alerts = true,         -- Use screen flashing as "vibration"
    compact_log = {},              -- In-memory compact log for terminals
    last_gps_coords = nil,         -- Last known coordinates
    connection_strength = 0        -- Signal strength indicator
}

-- Format time string

-- Alarm patterns (different sounds for different alert types)
local alarm_patterns = {
    general = {
        {note = 3, duration = 0.2},
        {note = 6, duration = 0.2},
        {note = 9, duration = 0.4}
    },
    evacuation = {
        {note = 12, duration = 0.15},
        {note = 15, duration = 0.15},
        {note = 18, duration = 0.15},
        {note = 15, duration = 0.15}
    }
}

local current_alarm_type = "general"

-- Terminal GPS tracking
local function updateGPS()
    if is_terminal and terminal_features and terminal_features.location_tracking and gps then
        local x, y, z = gps.locate(2) -- 2 second timeout
        if x and y and z then
            terminal_features.last_gps_coords = {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
            return terminal_features.last_gps_coords
        end
    end
    return terminal_features and terminal_features.last_gps_coords or nil
end

-- Terminal "vibrate" effect (screen flash)
local function terminalVibrate()
    if not is_terminal or not terminal_features or not terminal_features.vibrate_alerts then return end
    
    local original_bg = term.getBackgroundColor()
    for i = 1, 3 do
        term.setBackgroundColor(colors.white)
        term.clear()
        sleep(0.1)
        term.setBackgroundColor(original_bg)
        term.clear()
        sleep(0.1)
    end
end

-- Terminal compact logging (keeps last 20 entries in memory)
local function terminalLog(message)
    if not is_terminal or not terminal_features then return end
    
    local timestamp = textutils.formatTime(os.time(), true)
    local entry = "[" .. timestamp .. "] " .. message
    
    table.insert(terminal_features.compact_log, entry)
    
    -- Keep only last 20 entries
    while #terminal_features.compact_log > 20 do
        table.remove(terminal_features.compact_log, 1)
    end
end

-- Show terminal-specific status
local function showTerminalInfo()
    if not is_terminal then return end
    
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Terminal Info ===")
    
    -- GPS coordinates
    local coords = updateGPS()
    if coords then
        print("Location: " .. coords.x .. ", " .. coords.y .. ", " .. coords.z)
    else
        print("Location: GPS unavailable")
    end
    
    -- Connection info
    if terminal_features then
        print("Signal: " .. terminal_features.connection_strength .. "/5")
        print("Silent Mode: " .. (terminal_features.silent_mode and "ON" or "OFF"))
        print("Vibrate: " .. (terminal_features.vibrate_alerts and "ON" or "OFF"))
    end
    print("Audio: " .. (speaker and "Available" or "Not Available"))
    
    -- Device info
    print("Device Type: Wireless Terminal")
    print("Computer ID: " .. computer_id)
    
    -- Compact log
    if terminal_features and terminal_features.compact_log then
        print("\n=== Recent Activity ===")
        local start = math.max(1, #terminal_features.compact_log - 8)
        for i = start, #terminal_features.compact_log do
            print(terminal_features.compact_log[i])
        end
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    -- Don't call drawScreen here - let the main loop handle screen updates
end

-- Terminal notification with vibration
local function terminalNotify(message, urgent)
    if not is_terminal or not terminal_features then return end
    
    if urgent and not terminal_features.silent_mode then
        terminalVibrate()
    end
    
    terminalLog(message)
    
    -- Don't increment connection strength for local actions
    -- Only increment for actual network messages received
    -- terminal_features.connection_strength = math.min(5, terminal_features.connection_strength + 1)
end

-- Get active node count (must be defined before drawScreen)
local function getActiveNodeCount()
    local count = 0
    local current_time = os.time()
    for id, node in pairs(network_nodes) do
        if (current_time - node.last_seen) <= config.max_offline_time then
            count = count + 1
        end
    end
    return count
end

-- Draw enhanced status UI with terminal-optimized layout
local function drawScreen()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    
-- Draw enhanced status UI with terminal-optimized layout
local function drawScreen()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    
    if is_terminal then
        -- Compact terminal layout - ensure clean title display
        term.clear() -- Extra clear to ensure clean state
        term.setCursorPos(1, 1)
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        
        -- Print title as individual characters to avoid wrapping issues
        local title_lines = {
            "=============================",
            "= POGGISHTOWN ALERT TERM   =", 
            "============================="
        }
        
        for _, line in ipairs(title_lines) do
            print(line)
        end
        
        -- Show silent mode right after title if enabled
        if terminal_features and terminal_features.silent_mode then
            term.setTextColor(colors.orange)
            print("         SILENT MODE")
            term.setTextColor(colors.white)
            print("") -- Add blank line after silent mode
        else
            print("") -- Add blank line after title
        end
        
        -- Device info (compact)
        print("Name: " .. getDisplayName() .. " | Nodes: " .. getActiveNodeCount())
        print("") -- Add blank line
        
        -- Status (compact)
        if warning_active then
            term.setTextColor(colors.red)
            print("ALERT: " .. string.upper(current_alarm_type))
            term.setTextColor(colors.white)
            if alarm_start_time then
                local t = textutils.formatTime(alarm_start_time, true)
                print("Start: " .. t)
            end
            if alarm_triggered_by then
                print("By: #" .. alarm_triggered_by)
            end
            
            -- Auto-stop countdown
            if alarm_start_time then
                local elapsed = os.time() - alarm_start_time
                local remaining = config.auto_stop_timeout - elapsed
                if remaining > 0 then
                    print("Stop: " .. math.floor(remaining) .. "s")
                end
            end
        else
            term.setTextColor(colors.green)
            print("STATUS: Ready")
        end
        
        term.setTextColor(colors.white)
        print("") -- Add blank line
        print("Terminal Controls:")
        print("G - General | E - Evacuation")
        print("C - Cancel  | S - Status")
        print("U - Update  | I - Terminal Info")
        print("N - Change Name | M - Silent Mode")
        print("Q - Quit")
        
        -- Show update indicator for terminals
        if update_available then
            print("")
            term.setTextColor(colors.yellow)
            print("UPDATE READY! Press U")
            term.setTextColor(colors.white)
        end
        
        -- Terminal-specific status (only show if we have actual data)
        local coords = terminal_features and terminal_features.last_gps_coords or nil
        local signal_strength = terminal_features and terminal_features.connection_strength or 0
        
        -- Only show status section if we have GPS coordinates OR meaningful network signal (3+)
        if coords or signal_strength >= 3 then
            print("")
            term.setTextColor(colors.cyan)
            
            -- Only show GPS if we actually have coordinates
            if coords then
                print("GPS: " .. coords.x .. "," .. coords.y .. "," .. coords.z)
            end
            
            -- Only show signal if we have strong signal (3+ bars from actual network activity)
            if signal_strength >= 3 then
                print("Signal: " .. string.rep("▐", signal_strength) .. string.rep("▁", 5 - signal_strength))
            end
            
            term.setTextColor(colors.white)
        end
        
    else
        -- Full computer layout with fixed spacing
        print("===============================")
        print("= PoggishTown Warning System  =")
        print("===============================")
        print("")
        
        -- Computer info
        print("Name: " .. getDisplayName() .. " | Nodes: " .. getActiveNodeCount())
        print("")
        
        -- Status with consistent positioning
        if warning_active then
            term.setTextColor(colors.red)
            print("STATUS: !! WARNING ACTIVE !!")
            term.setTextColor(colors.yellow)
            print("Type: " .. string.upper(current_alarm_type))
            term.setTextColor(colors.white)
            if alarm_start_time then
                local t = textutils.formatTime(alarm_start_time, true)
                print("Started: " .. t)
            end
            if alarm_triggered_by then
                print("By: Computer " .. alarm_triggered_by)
            end
            
            -- Auto-stop countdown
            if alarm_start_time then
                local elapsed = os.time() - alarm_start_time
                local remaining = config.auto_stop_timeout - elapsed
                if remaining > 0 then
                    print("Auto-stop: " .. math.floor(remaining) .. "s")
                end
            end
            
            -- Add spacing to push controls to consistent position
            print("")
            print("")
            print("")
        else
            term.setTextColor(colors.green)
            print("STATUS: System Ready")
            
            -- Add spacing to keep controls in same position when no alarm
            print("")
            print("")
            print("")
            print("")
            print("")
            print("")
        end
        
        term.setTextColor(colors.white)
        print("Controls:")
        print("Any key - General alarm")
        print("E - Evacuation alarm")
        print("C - Cancel alarm")
        print("S - Status | L - Logs | T - Test")
        print("U - Update | N - Change Name")
        
        -- Show update indicator
        if update_available then
            print("")
            term.setTextColor(colors.yellow)
            print("UPDATE AVAILABLE! Press U to install")
            term.setTextColor(colors.white)
        end
    end
end

-- Logging system with rotation
local log_file = "warning_system.log"
local max_log_size = 10000  -- Max log file size in bytes

local function log(message)
    local timestamp = textutils.formatTime(os.time(), true)
    local device_type = is_terminal and "[TERMINAL]" or "[COMPUTER]"
    local entry = "[" .. timestamp .. "] " .. device_type .. " " .. message .. "\n"
    
    -- Check if log file is too large and rotate it
    if fs.exists(log_file) and fs.getSize(log_file) > max_log_size then
        -- Keep only the last 50 lines
        local old_file = fs.open(log_file, "r")
        local lines = {}
        if old_file then
            local line = old_file.readLine()
            while line do
                table.insert(lines, line)
                line = old_file.readLine()
            end
            old_file.close()
            
            -- Write back only the last 50 lines
            local new_file = fs.open(log_file, "w")
            if new_file then
                local start = math.max(1, #lines - 49)  -- Keep 49 old + 1 new = 50 total
                for i = start, #lines do
                    new_file.writeLine(lines[i])
                end
                new_file.close()
            end
        end
    end
    
    -- Append the new log entry
    local file = fs.open(log_file, "a")
    if file then
        file.write(entry)
        file.close()
    end
end

-- Play alarm with current pattern (non-blocking version)
local function playAlarmStep()
    if not warning_active then return end
    
    -- Skip audio on terminals unless they specifically have speakers
    if is_terminal and not speaker then
        return
    end
    
    local pattern = alarm_patterns[current_alarm_type]
    local volume = config.base_volume + (config.volume_increment * math.min(30, (os.time() - (alarm_start_time or 0))))
    volume = math.min(config.max_volume, volume)
    
    for _, sound in ipairs(pattern) do
        if not warning_active then break end
        if speaker then
            speaker.playNote("bass", volume, sound.note)
        end
        sleep(sound.duration)
    end
    
    -- Check for auto-timeout
    if alarm_start_time and (os.time() - alarm_start_time) > config.auto_stop_timeout then
        log("Auto-stopping alarm due to timeout")
        stopAlarm()
    end
end

-- Generate unique message ID
local function generateMessageId()
    return computer_id .. "_" .. os.time() .. "_" .. math.random(1000, 9999)
end

-- Check if we've seen this message before
local function isMessageSeen(msg_id)
    return message_history[msg_id] ~= nil
end

-- Mark message as seen
local function markMessageSeen(msg_id)
    message_history[msg_id] = os.time()
    -- Clean up old messages (older than 5 minutes)
    for id, timestamp in pairs(message_history) do
        if (os.time() - timestamp) > 300 then
            message_history[id] = nil
        end
    end
end

-- Check if this computer has an ender modem
local function hasEnderModem()
    local modem = peripheral.wrap(modem_side)
    if modem then
        -- Try multiple detection methods for ender modems
        -- Method 1: Check if isWireless method exists but returns false
        if modem.isWireless and not modem.isWireless() then
            return true
        end
        -- Method 2: Check if isWireless method doesn't exist (some ender modem versions)
        if not modem.isWireless then
            return true
        end
        -- Method 3: Check peripheral name (ender modems often show as just "modem")
        local modem_type = peripheral.getType(modem_side)
        if modem_type == "modem" then
            -- Try to call a wireless-specific method to see if it fails
            local success, result = pcall(function() return modem.isWireless() end)
            if not success or not result then
                return true
            end
        end
    end
    return false
end

-- Relay message to other nodes
local function relayMessage(msg)
    if not config.enable_relay then return end
    if not msg.hops then msg.hops = 0 end
    if msg.hops >= config.max_hops then return end
    
    -- Don't relay our own messages
    if msg.origin_id == computer_id then return end
    
    -- Don't relay if we've already seen this message
    if msg.message_id and isMessageSeen(msg.message_id) then return end
    
    -- Check if we're using ender modems - if so, be more conservative with relaying
    if hasEnderModem() then
        -- This is an ender modem - reduce relaying since range is infinite
        if msg.hops > 1 then return end -- Only relay once for ender modems
    end
    
    -- Add delay to prevent network spam
    sleep(config.relay_delay)
    
    -- Increment hop count and relay
    msg.hops = msg.hops + 1
    msg.relayed_by = computer_id
    
    rednet.broadcast(msg, protocol)
    
    if msg.message_id then
        markMessageSeen(msg.message_id)
    end
end

-- Background update checker (non-blocking)
local function backgroundUpdateCheck()
    if not config.background_update_check then return end
    if background_update_running then return end
    if (os.time() - last_update_check) < config.update_check_interval then return end
    
    background_update_running = true
    last_update_check = os.time()
    
    -- Use parallel API to make it non-blocking
    parallel.waitForAny(
        function()
            -- Background HTTP request with timeout
            local success, request = pcall(function()
                return http.get(config.update_url, nil, nil, 3) -- 3 second timeout
            end)
            
            if success and request then
                local remote_content = request.readAll()
                request.close()
                
                -- Read current file
                local filename = is_terminal and "pogalert" or "startup"
                local current_content = ""
                if fs.exists(filename) then
                    local file = fs.open(filename, "r")
                    if file then
                        current_content = file.readAll()
                        file.close()
                    end
                end
                
                -- Check if update is available
                if remote_content ~= current_content then
                    update_available = true
                    log("Background update check: New version available")
                    
                    -- Auto-apply for computers only, and only if not during alarm
                    if not is_terminal and not warning_active and config.auto_apply_updates then
                        local file = fs.open(filename, "w")
                        if file then
                            file.write(remote_content)
                            file.close()
                            log("Background update: Auto-applied new version")
                            update_available = false
                        end
                    end
                else
                    update_available = false
                end
            end
            
            background_update_running = false
        end,
        function()
            -- Timeout fallback (5 seconds max)
            sleep(5)
            background_update_running = false
        end
    )
end

-- Manual update check (blocking, with user feedback)
local function checkForUpdates(manual_mode)
    -- Different file names for different device types
    local filename = is_terminal and "pogalert" or "startup"
    
    if manual_mode then
        print("Checking for updates...")
        print("Device type: " .. (is_terminal and "Terminal" or "Computer"))
        print("File: " .. filename)
        print("Update URL: " .. config.update_url)
    end
    
    local request = http.get(config.update_url)
    if request then
        local remote_content = request.readAll()
        request.close()
        
        -- Read current file
        local current_content = ""
        if fs.exists(filename) then
            local file = fs.open(filename, "r")
            if file then
                current_content = file.readAll()
                file.close()
            end
        end
        
        -- Compare content
        if remote_content ~= current_content then
            update_available = true
            
            if manual_mode then
                print("Update available! Downloading...")
            end
            
            local file = fs.open(filename, "w")
            if file then
                file.write(remote_content)
                file.close()
                update_available = false
                
                if manual_mode then
                    print("Update downloaded!")
                    if is_terminal then
                        print("Restart this program to apply changes.")
                        print("Press any key to continue...")
                    else
                        print("Press U to restart now, or any other key to continue...")
                    end
                    local _, key = os.pullEvent("key")
                    if key == keys.u and not is_terminal then
                        print("Restarting...")
                        os.reboot()
                    end
                else
                    log("Manual update: Downloaded new version to " .. filename)
                end
            else
                if manual_mode then
                    print("Failed to write update file.")
                end
            end
        else
            update_available = false
            if manual_mode then
                print("Already up to date!")
            end
        end
    else
        if manual_mode then
            print("Failed to check for updates (no internet?)")
        end
    end
    
    if manual_mode then
        sleep(2)
    end
end

local function getActiveNodeCount()
    local count = 0
    local current_time = os.time()
    for id, node in pairs(network_nodes) do
        if (current_time - node.last_seen) <= config.max_offline_time then
            count = count + 1
        end
    end
    return count
end

-- Rest of your existing functions (broadcast, sendHeartbeat, startAlarm, stopAlarm, etc.)
-- would go here unchanged...

-- Broadcast over network with source ID and relay support
local function broadcast(action, alarm_type, source_id)
    local message = {
        type = "warning",
        action = action,
        alarm_type = alarm_type or current_alarm_type,
        source_id = source_id or computer_id,
        origin_id = computer_id,  -- Original sender
        timestamp = os.time(),
        message_id = generateMessageId(),
        hops = 0,
        device_type = is_terminal and "terminal" or "computer"
    }
    rednet.broadcast(message, protocol)
    markMessageSeen(message.message_id)
    log("Broadcast: " .. action .. " (" .. (alarm_type or "general") .. ") from " .. (source_id or computer_id))
end

-- Send heartbeat with relay support and current alarm status
local function sendHeartbeat()
    local message = {
        type = "heartbeat",
        computer_id = computer_id,
        origin_id = computer_id,
        timestamp = os.time(),
        message_id = generateMessageId(),
        hops = 0,
        device_type = is_terminal and "terminal" or "computer",
        display_name = getDisplayName(), -- Include display name
        -- Include current alarm status for new computers
        alarm_active = warning_active,
        alarm_type = current_alarm_type,
        alarm_start_time = alarm_start_time,
        alarm_triggered_by = alarm_triggered_by
    }
    rednet.broadcast(message, protocol)
    markMessageSeen(message.message_id)
end

-- Start alarm
local function startAlarm(alarm_type)
    alarm_type = alarm_type or "general"
    if not warning_active then
        warning_active = true
        current_alarm_type = alarm_type
        alarm_start_time = os.time()
        alarm_triggered_by = computer_id
        alarm_note_index = 1  -- Reset note index
        
        -- Only set redstone output if we're not a terminal
        if not is_terminal then
            redstone.setOutput(redstone_output_side, true)
        else
            -- Terminal-specific alarm behavior
            terminalNotify("ALARM TRIGGERED: " .. string.upper(alarm_type), true)
            if not terminal_features.silent_mode then
                terminalVibrate()
            end
        end
        
        drawScreen()
        broadcast("start", alarm_type, computer_id)
        log("Alarm started: " .. alarm_type .. " by " .. (is_terminal and "terminal" or "computer") .. " " .. computer_id)
    end
end

-- Stop the alarm
local function stopAlarm()
    if warning_active then
        warning_active = false
        alarm_note_index = 1  -- Reset note index
        
        -- Only control redstone if we're not a terminal
        if not is_terminal then
            redstone.setOutput(redstone_output_side, false)
        else
            -- Terminal-specific stop behavior
            terminalNotify("ALARM CANCELLED", false)
        end
        
        drawScreen()
        broadcast("stop", current_alarm_type, computer_id)
        log("Alarm stopped by " .. (is_terminal and "terminal" or "computer") .. " " .. computer_id)
        alarm_triggered_by = nil
    end
end

-- Show system status
local function showStatus()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== System Status ===")
    print("Device Type: " .. (is_terminal and "Terminal" or "Computer"))
    print("Display Name: " .. getDisplayName())
    print("Computer ID: " .. computer_id)
    print("Relay Mode: " .. (config.enable_relay and "ENABLED" or "DISABLED"))
    print("Max Hops: " .. config.max_hops)
    print("Audio: " .. (speaker and "Available" or "Not Available"))
    print("Redstone: " .. (is_terminal and "Disabled (Terminal)" or "Enabled"))
    print("Alarm Active: " .. tostring(warning_active))
    if warning_active then
        print("Alarm Type: " .. current_alarm_type)
        print("Triggered by: " .. (alarm_triggered_by or "Unknown"))
    end
    print("\nNetwork Nodes:")
    
    local current_time = os.time()
    for id, node in pairs(network_nodes) do
        local status = (current_time - node.last_seen) <= config.max_offline_time and "ONLINE" or "OFFLINE"
        local hop_info = node.hops and (" (via " .. node.hops .. " hops)") or ""
        local name_info = node.display_name and (" [" .. node.display_name .. "]") or ""
        print("  Computer " .. id .. name_info .. ": " .. status .. hop_info .. " (last seen: " .. math.floor(current_time - node.last_seen) .. "s ago)")
    end
    
    print("\nMessage History: " .. #message_history .. " recent messages")
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

-- Change device name
local function changeName()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Change Device Name ===")
    print("Current name: " .. getDisplayName())
    print("Computer ID: " .. computer_id)
    print("")
    print("Enter new name (or press Enter to clear custom name):")
    
    local new_name = read()
    
    if new_name == "" then
        setCustomName(nil)
        print("Custom name cleared. Using default: " .. getDisplayName())
    else
        if setCustomName(new_name) then
            print("Name changed to: " .. getDisplayName())
        else
            print("Failed to set name (custom names disabled)")
        end
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

-- Test network connectivity
local function testNetwork()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Network Test ===")
    print("Device Type: " .. (is_terminal and "Terminal" or "Computer"))
    print("Computer ID: " .. computer_id)
    print("Protocol: " .. protocol)
    print("Modem side: " .. modem_side)
    
    -- Check modem type
    local modem = peripheral.wrap(modem_side)
    if modem and modem.isWireless then
        print("Modem type: Wireless")
    else
        print("Modem type: Wired (THIS WON'T WORK!)")
    end
    
    print("\nSending test broadcast...")
    local test_msg = {
        type = "test",
        from = computer_id,
        message = "Hello from " .. (is_terminal and "terminal" or "computer") .. " " .. computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(test_msg, protocol)
    
    print("Listening for responses (5 seconds)...")
    local responses = 0
    local start_time = os.clock()
    
    while (os.clock() - start_time) < 5 do
        local sender_id, message, proto = rednet.receive(protocol, 1)
        if sender_id and message and message.type == "test" and message.from ~= computer_id then
            print("Response from Computer " .. message.from)
            responses = responses + 1
        end
    end
    
    print("\nTest complete. Received " .. responses .. " responses.")
    if responses == 0 then
        print("No responses - check:")
        print("1. Other computers running?")
        print("2. Using wireless modems?")
        print("3. Same protocol name?")
        print("4. Within range? (64 blocks/infinite for ender)")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

local function showLogs()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Recent Logs ===")
    
    if fs.exists(log_file) then
        local file = fs.open(log_file, "r")
        if file then
            local lines = {}
            local line = file.readLine()
            while line do
                table.insert(lines, line)
                line = file.readLine()
            end
            file.close()
            
            -- Show last 15 lines
            local start = math.max(1, #lines - 14)
            for i = start, #lines do
                print(lines[i])
            end
        end
    else
        print("No log file found.")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

-- Handle network message with relay support
local function handleMessage(msg)
    -- Debug: Log what we're processing
    log("Processing message type: " .. (msg.type or "unknown") .. " from: " .. (msg.from or msg.computer_id or msg.origin_id or "unknown"))
    
    -- Handle test messages first - only respond to original test messages, not responses
    if msg.type == "test" and msg.from ~= computer_id and msg.message and not string.find(msg.message, "Response from") then
        log("Responding to test message from " .. msg.from)
        local response = {
            type = "test",
            from = computer_id,
            message = "Response from " .. (is_terminal and "terminal" or "computer") .. " " .. computer_id,
            timestamp = os.time()
        }
        rednet.broadcast(response, protocol)
        return
    end
    
    -- Skip test responses (don't relay or process further)
    if msg.type == "test" and msg.message and string.find(msg.message, "Response from") then
        return
    end
    
    -- For relay messages, skip our own messages
    if msg.origin_id and msg.origin_id == computer_id then 
        log("Skipping own message")
        return 
    end
    
    -- Skip duplicate messages (only for messages that have message_id)
    if msg.message_id and isMessageSeen(msg.message_id) then 
        log("Skipping duplicate message")
        return 
    end
    
    -- Mark as seen and relay if appropriate (only for relay-enabled messages, NOT test messages)
    if msg.message_id and msg.type ~= "test" then
        markMessageSeen(msg.message_id)
        relayMessage(msg)
    end
    
    if msg.type == "warning" then
        log("Processing warning message: " .. msg.action)
        if msg.action == "start" and not warning_active then
            warning_active = true
            current_alarm_type = msg.alarm_type or "general"
            alarm_start_time = os.time()
            alarm_triggered_by = msg.source_id
            
            -- Only set redstone output if we're not a terminal
            if not is_terminal then
                redstone.setOutput(redstone_output_side, true)
            else
                -- Terminal notification with vibration
                terminalNotify("NETWORK ALARM: " .. string.upper(current_alarm_type), true)
            end
            
            drawScreen()
            log("Alarm started remotely: " .. current_alarm_type .. " by computer " .. msg.source_id)
        elseif msg.action == "stop" and warning_active then
            warning_active = false
            
            -- Only control redstone if we're not a terminal
            if not is_terminal then
                redstone.setOutput(redstone_output_side, false)
            else
                terminalNotify("ALARM CANCELLED BY NETWORK", false)
            end
            
            drawScreen()
            log("Alarm stopped remotely by computer " .. msg.source_id)
            alarm_triggered_by = nil
        end
    elseif msg.type == "heartbeat" then
        log("Processing heartbeat from " .. msg.computer_id)
        network_nodes[msg.computer_id] = {
            last_seen = os.time(),
            computer_id = msg.computer_id,
            hops = msg.hops or 0,
            device_type = msg.device_type or "computer",
            display_name = msg.display_name or tostring(msg.computer_id)
        }
        
        -- New computer joining during active alarm - sync alarm state
        if msg.alarm_active and not warning_active and msg.computer_id ~= computer_id then
            log("New computer detected during active alarm - syncing alarm state")
            warning_active = true
            current_alarm_type = msg.alarm_type or "general"
            alarm_start_time = msg.alarm_start_time or os.time()
            alarm_triggered_by = msg.alarm_triggered_by
            alarm_note_index = 1  -- Start from beginning of pattern
            
            -- Only set redstone output if we're not a terminal
            if not is_terminal then
                redstone.setOutput(redstone_output_side, true)
            else
                terminalNotify("JOINING ACTIVE ALARM: " .. string.upper(current_alarm_type), true)
            end
            
            drawScreen()
        end
        
        -- Update connection strength for terminals when receiving actual network messages
        if is_terminal then
            terminal_features.connection_strength = math.min(5, terminal_features.connection_strength + 1)
        end
        
        -- Only update screen if we're on the main screen
        if term.getCursorPos() == 1 then
            drawScreen()
        end
    end
end

-- Modem check and initialization
local function init()
    -- Load custom name first
    loadCustomName()
    
    -- Check if we're on a terminal first
    if is_terminal then
        print("Running on wireless terminal")
        log("System started on wireless terminal")
        
        -- Terminals typically have built-in wireless modems
        for _, side in pairs(peripheral.getNames()) do
            if peripheral.getType(side) == "modem" then
                local modem = peripheral.wrap(side)
                if modem and modem.isWireless and modem.isWireless() then
                    modem_side = side
                    rednet.open(side)
                    print("Built-in wireless modem found")
                    break
                end
            end
        end
        
        -- If no wireless modem found, check for any modem
        if not modem_side then
            for _, side in pairs(peripheral.getNames()) do
                if peripheral.getType(side) == "modem" then
                    modem_side = side
                    rednet.open(side)
                    print("Modem found on " .. side)
                    break
                end
            end
        end
    else
        -- Regular computer logic
        for _, side in pairs(peripheral.getNames()) do
            if peripheral.getType(side) == "modem" then
                modem_side = side
                rednet.open(side)
                print("Modem found on " .. side)
                log("System started - Modem found on " .. side)
                break
            end
        end
    end

    if not modem_side then
        error("No modem found. Please attach one or enable wireless.")
    end
    
    if not speaker and not is_terminal then
        print("Warning: No speaker found. Audio will not play.")
        log("Warning: No speaker found. Audio will not play.")
    elseif is_terminal and not speaker then
        print("Terminal mode: Audio disabled (no speaker)")
        log("Terminal mode: Audio disabled (no speaker)")
    end
    
    -- Debug: Check if rednet is actually open
    print("Rednet open on side: " .. modem_side)
    print("Computer ID: " .. computer_id)
    print("Protocol: " .. protocol)
    
    -- Check what type of modem we have
    local modem = peripheral.wrap(modem_side)
    local is_ender = hasEnderModem()
    
    if is_ender then
        print("Ender modem detected (infinite range)")
        print("Relay settings optimized for ender modems")
        log("Ender modem detected - using optimized relay settings")
    else
        print("Regular wireless modem detected")
        print("Range: 64 blocks, relaying enabled")
        log("Regular wireless modem detected")
    end
    
    -- Wait a moment then send initial heartbeat
    sleep(1)
    print("Sending initial heartbeat...")
    sendHeartbeat()
    
    -- Wait a moment for any responses
    sleep(2)
    print("Starting system...")
    
    -- Auto-check for updates on startup
    print("Auto-checking for updates...")
    print("Running on: " .. (is_terminal and "Terminal" or "Computer"))
    checkForUpdates(false) -- false = startup mode (no manual user feedback)
end

-- Main loop
local function main()
    init()
    drawScreen()
    
    log("Starting unified event handler...")
    
    -- Start heartbeat timer and alarm timer
    local heartbeat_timer = os.startTimer(config.heartbeat_interval)
    local alarm_timer = nil
    local gps_timer = nil
    local battery_timer = nil
    local update_check_timer = nil
    
    -- Terminal-specific timers
    if is_terminal then
        gps_timer = os.startTimer(60) -- Update GPS every minute
    end
    
    -- Background update check timer
    if config.background_update_check then
        update_check_timer = os.startTimer(config.update_check_interval)
    end
    
    -- Unified event loop with responsive input handling
    while true do
        -- Check for input with short timeout to keep system responsive
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        
        if event == "key" then
            local keyCode = param1
            if keyCode == keys.c then
                stopAlarm()
            elseif keyCode == keys.e then
                startAlarm("evacuation")
            elseif keyCode == keys.s then
                showStatus()
            elseif keyCode == keys.l and not is_terminal then
                showLogs()
            elseif keyCode == keys.t and not is_terminal then
                testNetwork()
            elseif keyCode == keys.u then
                checkForUpdates(true) -- true = manual mode
                drawScreen()
            elseif keyCode == keys.n then
                -- N key for changing name
                changeName()
            elseif keyCode == keys.g and is_terminal then
                -- G key for general alarm on terminals
                startAlarm("general")
            elseif keyCode == keys.i and is_terminal then
                -- I key for terminal info
                showTerminalInfo()
                drawScreen() -- Redraw main screen after terminal info
            elseif keyCode == keys.m and is_terminal then
                -- M key to toggle silent mode
                terminal_features.silent_mode = not terminal_features.silent_mode
                terminalLog("Silent mode " .. (terminal_features.silent_mode and "enabled" or "disabled"))
                drawScreen()
            elseif keyCode == keys.q and is_terminal then
                -- Q key to quit on terminals
                print("Terminal shutting down...")
                break
            elseif not warning_active and not is_terminal then
                -- Any other key starts general alarm (computers only)
                startAlarm("general")
            end
            
        elseif event == "rednet_message" then
            local sender_id, message, proto = param1, param2, param3
            if proto == protocol then
                log("Raw message received: " .. textutils.serialize(message))
                handleMessage(message)
            end
            
        elseif event == "timer" then
            local timer_id = param1
            if timer_id == heartbeat_timer then
                sendHeartbeat()
                heartbeat_timer = os.startTimer(config.heartbeat_interval)
                
                -- Decay connection strength for terminals
                if is_terminal then
                    terminal_features.connection_strength = math.max(0, terminal_features.connection_strength - 1)
                end
            elseif timer_id == gps_timer and is_terminal then
                updateGPS()
                gps_timer = os.startTimer(60)
            elseif timer_id == update_check_timer then
                -- Background update check (non-blocking)
                backgroundUpdateCheck()
                if config.background_update_check then
                    update_check_timer = os.startTimer(config.update_check_interval)
                end
            elseif timer_id == alarm_timer then
                -- Time to play next alarm note (only if not a terminal or if terminal has speaker)
                if warning_active and (not is_terminal or speaker) then
                    local pattern = alarm_patterns[current_alarm_type]
                    local volume = config.base_volume + (config.volume_increment * math.min(30, (os.time() - (alarm_start_time or 0))))
                    volume = math.min(config.max_volume, volume)
                    
                    -- Play current note
                    if speaker and pattern[alarm_note_index] then
                        local sound = pattern[alarm_note_index]
                        speaker.playNote("bass", volume, sound.note)
                        
                        -- Move to next note
                        alarm_note_index = alarm_note_index + 1
                        if alarm_note_index > #pattern then
                            alarm_note_index = 1  -- Loop back to start
                        end
                        
                        -- Set timer for next note based on current note's duration
                        -- Add minimum delay to ensure timer fires even during lag
                        local next_delay = math.max(sound.duration, 0.1)
                        alarm_timer = os.startTimer(next_delay)
                    else
                        -- Fallback timer if something goes wrong
                        alarm_timer = os.startTimer(0.2)
                        alarm_note_index = 1  -- Reset to start
                    end
                    
                    -- Check for auto-timeout
                    if alarm_start_time and (os.time() - alarm_start_time) > config.auto_stop_timeout then
                        log("Auto-stopping alarm due to timeout")
                        stopAlarm()
                        alarm_timer = nil
                    end
                else
                    alarm_timer = nil
                end
            end
        end
        
        -- Start alarm timer when alarm becomes active (only for devices with speakers)
        if warning_active and not alarm_timer and (not is_terminal or speaker) then
            alarm_timer = os.startTimer(0.05) -- Start very quickly
        end
        
        -- Backup alarm restart mechanism during server lag
        if warning_active and not alarm_timer and (not is_terminal or speaker) then
            -- If somehow the alarm timer got lost during lag, restart it
            log("Alarm timer lost during lag - restarting")
            alarm_note_index = 1
            alarm_timer = os.startTimer(0.1)
        end
    end
end

main()
