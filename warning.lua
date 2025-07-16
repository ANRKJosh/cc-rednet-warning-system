-- Enhanced PoggishTown Warning System (works with wireless terminals better)
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
    update_url = "https://raw.githubusercontent.com/ANRKJosh/cc-rednet-warning-system/refs/heads/main/warning.lua"
}

-- Network state tracking
local network_nodes = {}
local last_heartbeat = 0
local computer_id = os.getComputerID()
local alarm_triggered_by = nil
local message_history = {}  -- Track recent messages to prevent loops
local alarm_note_index = 1  -- Track which note we're currently playing
local is_terminal = isWirelessTerminal()

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

-- Auto-update system
local function checkForUpdates(auto_mode)
    -- Different file names for different device types
    local filename = is_terminal and "pogalert" or "startup"
    
    if not auto_mode then
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
            if auto_mode then
                print("Auto-update: New version found! Downloading...")
                log("Auto-update: Downloading new version to " .. filename)
            else
                print("Update available! Downloading...")
            end
            
            local file = fs.open(filename, "w")
            if file then
                file.write(remote_content)
                file.close()
                
                if auto_mode then
                    if is_terminal then
                        print("Terminal alert system updated!")
                        print("Restart this program to apply changes.")
                        log("Auto-update: Update downloaded to " .. filename)
                        sleep(2)
                    else
                        print("Auto-update: Update downloaded! Restarting in 3 seconds...")
                        log("Auto-update: Update downloaded, restarting")
                        sleep(3)
                        os.reboot()
                    end
                else
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
                end
            else
                print("Failed to write update file.")
            end
        else
            if not auto_mode then
                print("Already up to date!")
            end
        end
    else
        if not auto_mode then
            print("Failed to check for updates (no internet?)")
        end
    end
    
    if not auto_mode then
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

-- Draw enhanced status UI with terminal-optimized layout
local function drawScreen()
    term.clear()
    term.setCursorPos(1, 1)
    
    if is_terminal then
        -- Compact terminal layout
        print("=============================")
        print("= POGGISHTOWN ALERT TERM   =")
        print("=============================")
        
        -- Device info (compact)
        term.setCursorPos(1, 4)
        print("ID: " .. computer_id .. " | Nodes: " .. getActiveNodeCount())
        
        -- Status (compact)
        term.setCursorPos(1, 6)
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
        term.setCursorPos(1, 14)
        print("Terminal Controls:")
        print("G - General | E - Evacuation")
        print("C - Cancel  | S - Status")
        print("U - Update  | I - Terminal Info")
        print("M - Silent Mode | Q - Quit")
        
        -- Terminal-specific status
        term.setCursorPos(1, 20)
        term.setTextColor(colors.cyan)
        
        -- Battery indicator
        local battery = checkBattery()
        if battery then
            local bat_color = battery < 10 and colors.red or battery < 30 and colors.yellow or colors.green
            term.setTextColor(bat_color)
            print("Bat: " .. battery .. "%")
        else
            print("Bat: OK")
        end
        
        -- GPS and other status
        term.setTextColor(colors.cyan)
        local coords = terminal_features.last_gps_coords
        if coords then
            print("GPS: " .. coords.x .. "," .. coords.y .. "," .. coords.z)
        else
            print("GPS: Searching...")
        end
        
        print("Signal: " .. string.rep("▐", terminal_features.connection_strength) .. string.rep("▁", 5 - terminal_features.connection_strength))
        
        if terminal_features.silent_mode then
            term.setTextColor(colors.orange)
            print("SILENT MODE")
        end
        
        term.setTextColor(colors.white)
    else
        -- Full computer layout
        print("===============================")
        print("= PoggishTown Warning System  =")
        print("===============================")
        
        -- Computer info
        term.setCursorPos(1, 4)
        print("ID: " .. computer_id .. " | Nodes: " .. getActiveNodeCount())
        
        -- Status
        term.setCursorPos(1, 6)
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
        else
            term.setTextColor(colors.green)
            print("STATUS: System Ready")
        end
        
        term.setTextColor(colors.white)
        term.setCursorPos(1, 16)
        print("Controls:")
        print("Any key - General alarm")
        print("E - Evacuation alarm")
        print("C - Cancel alarm")
        print("S - Status | L - Logs | T - Test | U - Update")
    end
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
        print("  Computer " .. id .. ": " .. status .. hop_info .. " (last seen: " .. math.floor(current_time - node.last_seen) .. "s ago)")
    end
    
    print("\nMessage History: " .. #message_history .. " recent messages")
    
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
            device_type = msg.device_type or "computer"
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
        
        -- Update connection strength for terminals
        if is_terminal then
            terminal_features.connection_strength = math.min(5, math.max(1, terminal_features.connection_strength))
        end
        
        -- Only update screen if we're on the main screen
        if term.getCursorPos() == 1 then
            drawScreen()
        end
    end
end

-- Modem check and initialization
local function init()
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
    checkForUpdates(true) -- true = auto mode
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
    
    -- Terminal-specific timers
    if is_terminal then
        gps_timer = os.startTimer(60) -- Update GPS every minute
        battery_timer = os.startTimer(300) -- Check battery every 5 minutes
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
                checkForUpdates(false) -- false = manual mode
                drawScreen()
            elseif keyCode == keys.g and is_terminal then
                -- G key for general alarm on terminals
                startAlarm("general")
            elseif keyCode == keys.i and is_terminal then
                -- I key for terminal info
                showTerminalInfo()
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
            elseif timer_id == battery_timer and is_terminal then
                local battery = checkBattery()
                if battery and battery < terminal_features.battery_warning_threshold then
                    terminalNotify("LOW BATTERY: " .. battery .. "%", true)
                end
                battery_timer = os.startTimer(300)
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
