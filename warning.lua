-- Enhanced PoggishTown Warning System with Terminal GUI
-- please once again

local protocol = "poggishtown_warning"
local warning_active = false
local modem_side = nil
local speaker = peripheral.find("speaker")
local alarm_start_time = nil
local redstone_output_side = "back"
local computer_id = os.getComputerID()

-- Check if device is wireless terminal
local function isWirelessTerminal()
    if pocket then return true end
    local label = os.getComputerLabel()
    if label and string.find(label:lower(), "terminal") then return true end
    local peripherals = peripheral.getNames()
    return #peripherals <= 1
end

local is_terminal = isWirelessTerminal()

-- Global variables
local network_nodes = {}
local alarm_triggered_by = nil
local message_history = {}
local recent_messages = {}
local unread_message_count = 0
local current_alarm_type = "general"

-- Terminal features
local terminal_features = {
    silent_mode = false,
    connection_strength = 0
}

-- GUI state for terminals
local gui_state = {
    current_screen = "home",
    selected_contact = nil,
    typing_mode = false,
    message_input = "",
    selected_node_id = nil
}

-- Configuration
local config = {
    heartbeat_interval = 30, -- seconds between heartbeats
    max_offline_time = 90, -- seconds before marking node as offline
    auto_stop_timeout = 300, -- seconds to auto-stop alarm (5 minutes)
    volume_increment = 0.3, -- Increased from 0.2
    max_volume = 15.0, -- Increased from 10.0 - very very loud!
    base_volume = 3.0, -- Increased from 2.0
    enable_relay = true, -- enable message relaying
    max_hops = 3, -- Reduced from 8 - ender modems have infinite range
    relay_delay = 0.2, -- Increased from 0.05 to reduce spam
    update_url = "https://raw.githubusercontent.com/ANRKJosh/cc-rednet-warning-system/refs/heads/main/warning.lua",
    update_check_interval = 300, -- 5 minutes
    custom_name = nil
}

-- Alarm patterns (different sounds for different alert types)
local alarm_patterns = {
    general = {
        {note = 3, duration = 0.2, volume = 3.0},
        {note = 6, duration = 0.2, volume = 5.0}, 
        {note = 9, duration = 0.4, volume = 7.0}
    },
    evacuation = {
        {note = 12, duration = 0.15, volume = 8.0},
        {note = 15, duration = 0.15, volume = 10.0},
        {note = 18, duration = 0.15, volume = 12.0},
        {note = 15, duration = 0.15, volume = 10.0}
    }
}

-- Utility functions
local function getDisplayName()
    if config.custom_name then return config.custom_name end
    local label = os.getComputerLabel()
    if label then return label end
    return "Node-" .. computer_id
end

local function setCustomName(name)
    if name and name ~= "" then
        config.custom_name = name
        local file = fs.open("poggish_config", "w")
        if file then
            file.write(name)
            file.close()
        end
        return true
    else
        config.custom_name = nil
        if fs.exists("poggish_config") then
            fs.delete("poggish_config")
        end
        return true
    end
end

local function loadCustomName()
    if fs.exists("poggish_config") then
        local file = fs.open("poggish_config", "r")
        if file then
            local content = file.readAll()
            file.close()
            if content and content ~= "" then
                config.custom_name = content
            end
        end
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

local function generateMessageId()
    return computer_id .. "_" .. os.time() .. "_" .. math.random(1000, 9999)
end

-- Network functions (moved before GUI functions that use them)
local function broadcast(action, alarm_type)
    local message = {
        type = "warning",
        action = action,
        alarm_type = alarm_type or current_alarm_type,
        source_id = computer_id,
        timestamp = os.time(),
        message_id = generateMessageId(),
        device_type = is_terminal and "terminal" or "computer"
    }
    rednet.broadcast(message, protocol)
end

local function sendMessage(target_id, message_text)
    local message = {
        type = "chat",
        message = message_text,
        from_id = computer_id,
        from_name = getDisplayName(),
        timestamp = os.time(),
        message_id = generateMessageId(),
        device_type = is_terminal and "terminal" or "computer"
    }
    
    if target_id == "broadcast" then
        rednet.broadcast(message, protocol)
    else
        rednet.send(target_id, message, protocol)
    end
    
    -- Add to our own message history
    table.insert(recent_messages, {
        message = message_text,
        from_name = getDisplayName(),
        from_id = computer_id,
        direction = "sent",
        timestamp = os.time()
    })
end

local function sendHeartbeat()
    local message = {
        type = "heartbeat",
        computer_id = computer_id,
        timestamp = os.time(),
        message_id = generateMessageId(),
        device_type = is_terminal and "terminal" or "computer",
        display_name = getDisplayName(),
        alarm_active = warning_active,
        alarm_type = current_alarm_type,
        alarm_triggered_by = alarm_triggered_by
    }
    rednet.broadcast(message, protocol)
end

local function playAlarmSound(alarm_type)
    if speaker and not terminal_features.silent_mode then
        local pattern = alarm_patterns[alarm_type] or alarm_patterns.general
        
        -- Play pattern multiple times to make it more noticeable
        for repeat_count = 1, 3 do
            for i, sound in ipairs(pattern) do
                local volume = sound.volume or config.base_volume
                -- Ensure volume doesn't exceed max
                volume = math.min(volume, config.max_volume)
                
                speaker.playNote("harp", volume, sound.note)
                sleep(sound.duration)
            end
            
            -- Short pause between repetitions
            if repeat_count < 3 then
                sleep(0.3)
            end
        end
    end
end

local function startAlarm(alarm_type)
    alarm_type = alarm_type or "general"
    if not warning_active then
        warning_active = true
        current_alarm_type = alarm_type
        alarm_start_time = os.time()
        alarm_triggered_by = computer_id
        
        -- Play appropriate alarm sound
        playAlarmSound(alarm_type)
        
        if not is_terminal then
            redstone.setOutput(redstone_output_side, true)
        end
        
        broadcast("start", alarm_type)
    end
end

local function stopAlarm()
    if warning_active then
        warning_active = false
        
        if not is_terminal then
            redstone.setOutput(redstone_output_side, false)
        end
        
        broadcast("stop", current_alarm_type)
        alarm_triggered_by = nil
    end
end

-- Terminal GUI functions with enhanced visuals
local function drawStatusBar()
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clearLine()
    
    -- Time
    local time_str = textutils.formatTime(os.time(), true)
    term.setCursorPos(2, 1)
    write(time_str)
    
    -- Device name centered (fix the display issue)
    local name = getDisplayName()
    if #name > 12 then name = name:sub(1, 9) .. "..." end
    local w = term.getSize()
    local center_pos = math.floor((w - #name) / 2)
    term.setCursorPos(center_pos, 1)
    write(name)
    
    -- Network indicator
    local nodes = getActiveNodeCount()
    term.setCursorPos(w - 3, 1)
    write("N:" .. nodes)
end

local function drawAppIcon(x, y, w, h, color, text_color, icon, label)
    -- Draw solid background
    term.setBackgroundColor(color)
    for i = 0, h - 1 do
        term.setCursorPos(x, y + i)
        write(string.rep(" ", w))
    end
    
    -- Draw icon (handle both string and number)
    term.setTextColor(text_color)
    local icon_text = tostring(icon)
    local icon_y = y + 1
    local icon_x = x + math.floor((w - #icon_text) / 2)
    term.setCursorPos(icon_x, icon_y)
    write(icon_text)
    
    -- Draw label
    if label then
        local label_y = y + 2
        local label_x = x + math.floor((w - #label) / 2)
        term.setCursorPos(label_x, label_y)
        write(label)
    end
    
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function isInBounds(click_x, click_y, x, y, w, h)
    return click_x >= x and click_x < x + w and click_y >= y and click_y < y + h
end

local function drawHomeScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    -- Main title
    term.setTextColor(colors.cyan)
    term.setCursorPos(2, 3)
    write("PoggishTown Security")
    
    -- Status indicator
    term.setCursorPos(2, 5)
    if warning_active then
        term.setTextColor(colors.red)
        write(">> ALERT ACTIVE <<")
        term.setCursorPos(2, 6)
        term.setTextColor(colors.yellow)
        write("Type: " .. string.upper(current_alarm_type))
    else
        term.setTextColor(colors.green)
        write(">> System Ready <<")
        term.setCursorPos(2, 6)
        term.setTextColor(colors.white)
        write("All systems normal")
    end
    
    -- App icons with proper spacing
    local alarm_color = warning_active and colors.red or colors.orange
    local alarm_icon = warning_active and "!!" or "/\\"
    drawAppIcon(2, 9, 8, 3, alarm_color, colors.white, alarm_icon, "ALARM")
    
    local msg_color = unread_message_count > 0 and colors.lime or colors.blue
    local msg_text = unread_message_count > 0 and ("(" .. unread_message_count .. ")") or "MSG"
    drawAppIcon(12, 9, 8, 3, msg_color, colors.white, msg_text, "MSGS")
    
    drawAppIcon(2, 14, 8, 3, colors.gray, colors.white, "SET", "CONFIG")
    
    -- Status info at bottom
    term.setTextColor(colors.white)
    term.setCursorPos(2, h - 2)
    write("Network: " .. getActiveNodeCount() .. " nodes")
    
    if terminal_features.silent_mode then
        term.setTextColor(colors.orange)
        term.setCursorPos(2, h - 1)
        write("Silent Mode Active")
    end
end

local function drawAlarmScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    -- Back button
    term.setTextColor(colors.cyan)
    term.setCursorPos(2, 3)
    write("< BACK")
    
    -- Title
    term.setTextColor(colors.red)
    term.setCursorPos(2, 5)
    write("EMERGENCY ALERT")
    
    if warning_active then
        term.setTextColor(colors.red)
        term.setCursorPos(2, 7)
        write("ALARM ACTIVE")
        term.setTextColor(colors.yellow)
        term.setCursorPos(2, 8)
        write("Type: " .. string.upper(current_alarm_type))
        
        -- Time since alarm started
        if alarm_start_time then
            local elapsed = os.time() - alarm_start_time
            term.setCursorPos(2, 9)
            write("Duration: " .. math.floor(elapsed) .. "s")
        end
        
        -- Cancel button
        drawAppIcon(2, 12, 12, 3, colors.red, colors.white, "CANCEL", "STOP")
    else
        term.setTextColor(colors.white)
        term.setCursorPos(2, 7)
        write("Select alarm type:")
        
        -- Alarm type buttons
        drawAppIcon(2, 10, 12, 3, colors.orange, colors.black, "GENERAL", "ALERT")
        drawAppIcon(2, 15, 12, 3, colors.red, colors.white, "EVAC", "URGENT")
    end
end

local function drawMessagesScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    -- Back button
    term.setTextColor(colors.cyan)
    term.setCursorPos(2, 3)
    write("< BACK")
    
    -- Title
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("MESSAGES")
    
    if gui_state.typing_mode then
        -- Message composition mode
        term.setTextColor(colors.yellow)
        term.setCursorPos(2, 7)
        write("Send to: " .. (gui_state.selected_node_id == "broadcast" and "ALL" or gui_state.selected_node_id))
        
        term.setTextColor(colors.white)
        term.setCursorPos(2, 9)
        write("Message:")
        term.setCursorPos(2, 10)
        write("> " .. gui_state.message_input .. "_")
        
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 12)
        write("Press ENTER to send")
        term.setCursorPos(2, 13)
        write("Press ESC to cancel")
    else
        -- Show recent messages
        if #recent_messages == 0 then
            term.setTextColor(colors.gray)
            term.setCursorPos(2, 8)
            write("No messages")
        else
            local y = 7
            for i = math.max(1, #recent_messages - 3), #recent_messages do
                local msg = recent_messages[i]
                local bg_color = msg.direction == "sent" and colors.blue or colors.gray
                local icon = msg.direction == "sent" and ">" or "<"
                
                term.setBackgroundColor(bg_color)
                term.setTextColor(colors.white)
                term.setCursorPos(2, y)
                local sender = msg.direction == "sent" and "You" or msg.from_name
                local display = icon .. " " .. sender .. ": " .. msg.message
                if #display > 24 then display = display:sub(1, 21) .. "..." end
                write(" " .. display .. " ")
                term.setBackgroundColor(colors.black)
                y = y + 2
            end
        end
        
        -- Send message button
        drawAppIcon(2, 15, 10, 3, colors.green, colors.white, "SEND", "MSG")
    end
end

local function drawContactsScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    -- Back button
    term.setTextColor(colors.cyan)
    term.setCursorPos(2, 3)
    write("< BACK")
    
    -- Title
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("SELECT RECIPIENT")
    
    -- Broadcast option
    drawAppIcon(2, 8, 12, 3, colors.orange, colors.white, "ALL", "BROADCAST")
    
    -- Available nodes
    local y = 13
    local current_time = os.time()
    local node_count = 0
    
    for id, node in pairs(network_nodes) do
        if (current_time - node.last_seen) <= config.max_offline_time and node_count < 2 then
            local color = colors.blue
            local name = node.display_name or ("Node " .. id)
            if #name > 8 then name = name:sub(1, 8) end
            
            drawAppIcon(2, y, 12, 3, color, colors.white, tostring(id), name)
            y = y + 4
            node_count = node_count + 1
        end
    end
    
    if node_count == 0 then
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 13)
        write("No other nodes online")
    end
end

local function drawSettingsScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    -- Back button
    term.setTextColor(colors.cyan)
    term.setCursorPos(2, 3)
    write("< BACK")
    
    -- Title
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("SETTINGS")
    
    -- Silent Mode toggle
    term.setCursorPos(2, 8)
    write("Silent Mode:")
    term.setCursorPos(15, 8)
    if terminal_features.silent_mode then
        term.setTextColor(colors.green)
        write("ON")
    else
        term.setTextColor(colors.red)
        write("OFF")
    end
    
    -- Volume control
    term.setTextColor(colors.white)
    term.setCursorPos(2, 9)
    write("Alarm Volume:")
    term.setCursorPos(15, 9)
    if config.base_volume >= 10 then
        term.setTextColor(colors.red)
        write("LOUD")
    elseif config.base_volume >= 5 then
        term.setTextColor(colors.yellow)
        write("MED")
    else
        term.setTextColor(colors.green)
        write("LOW")
    end
    
    -- Device Name (for terminals show in settings)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 11)
    write("Device Name:")
    term.setTextColor(colors.cyan)
    term.setCursorPos(15, 11)
    write("EDIT")
    
    -- Update button
    term.setTextColor(colors.white)
    term.setCursorPos(2, 13)
    write("Check Updates:")
    term.setTextColor(colors.lime)
    term.setCursorPos(17, 13)
    write("UPDATE")
    
    -- Device info
    term.setTextColor(colors.gray)
    term.setCursorPos(2, 16)
    write("Device Info:")
    term.setCursorPos(2, 17)
    write("ID: " .. computer_id)
    term.setCursorPos(2, 18)
    local device_type = is_terminal and "Terminal" or "Computer"
    write("Type: " .. device_type)
    term.setCursorPos(2, 19)
    write("Name: " .. getDisplayName())
end

local function handleTouch(x, y)
    if gui_state.current_screen == "home" then
        if isInBounds(x, y, 2, 9, 8, 3) then
            gui_state.current_screen = "alarm_trigger"
            return true
        elseif isInBounds(x, y, 12, 9, 8, 3) then
            gui_state.current_screen = "messages"
            unread_message_count = 0
            return true
        elseif isInBounds(x, y, 2, 14, 8, 3) then
            gui_state.current_screen = "settings"
            return true
        end
    elseif gui_state.current_screen == "alarm_trigger" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        elseif warning_active and isInBounds(x, y, 2, 12, 12, 3) then
            stopAlarm()
            gui_state.current_screen = "home"
            return true
        elseif not warning_active then
            if isInBounds(x, y, 2, 10, 12, 3) then
                startAlarm("general")
                gui_state.current_screen = "home"
                return true
            elseif isInBounds(x, y, 2, 15, 12, 3) then
                startAlarm("evacuation")
                gui_state.current_screen = "home"
                return true
            end
        end
    elseif gui_state.current_screen == "messages" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        elseif not gui_state.typing_mode and isInBounds(x, y, 2, 15, 10, 3) then
            gui_state.current_screen = "contacts"
            return true
        end
    elseif gui_state.current_screen == "contacts" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "messages"
            return true
        elseif isInBounds(x, y, 2, 8, 12, 3) then
            -- Broadcast selected
            gui_state.selected_node_id = "broadcast"
            gui_state.current_screen = "messages"
            gui_state.typing_mode = true
            gui_state.message_input = ""
            return true
        else
            -- Check for node selection
            local y_pos = 13
            local current_time = os.time()
            local node_count = 0
            
            for id, node in pairs(network_nodes) do
                if (current_time - node.last_seen) <= config.max_offline_time and node_count < 2 then
                    if isInBounds(x, y, 2, y_pos, 12, 3) then
                        gui_state.selected_node_id = id
                        gui_state.current_screen = "messages"
                        gui_state.typing_mode = true
                        gui_state.message_input = ""
                        return true
                    end
                    y_pos = y_pos + 4
                    node_count = node_count + 1
                end
            end
        end
    elseif gui_state.current_screen == "settings" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        elseif y == 8 then
            terminal_features.silent_mode = not terminal_features.silent_mode
            return true
        elseif y == 9 then
            adjustVolume()
            return true
        elseif y == 11 then
            changeName()
            return true
        elseif y == 13 then
            checkForUpdates()
            return true
        end
    end
    return false
end

local function drawGUIScreen()
    if gui_state.current_screen == "home" then
        drawHomeScreen()
    elseif gui_state.current_screen == "alarm_trigger" then
        drawAlarmScreen()
    elseif gui_state.current_screen == "messages" then
        drawMessagesScreen()
    elseif gui_state.current_screen == "contacts" then
        drawContactsScreen()
    elseif gui_state.current_screen == "settings" then
        drawSettingsScreen()
    end
end

-- Main drawing function
local function drawScreen()
    if is_terminal then
        drawGUIScreen()
    else
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        
        print("===============================")
        print("= PoggishTown Warning System  =")
        print("===============================")
        print("")
        print("Name: " .. getDisplayName() .. " | Nodes: " .. getActiveNodeCount())
        print("")
        
        if warning_active then
            term.setTextColor(colors.red)
            print("STATUS: !! WARNING ACTIVE !!")
            term.setTextColor(colors.yellow)
            print("Type: " .. string.upper(current_alarm_type))
            term.setTextColor(colors.white)
        else
            term.setTextColor(colors.green)
            print("STATUS: System Ready")
            term.setTextColor(colors.white)
        end
        
        print("")
        print("Controls:")
        print("Any key - General alarm")
        print("E - Evacuation alarm")
        print("C - Cancel alarm")
        print("S - Status | N - Change Name")
        print("U - Check for updates | V - Volume")
    end
end

local function showStatus()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== System Status ===")
    print("Device Type: " .. (is_terminal and "Terminal" or "Computer"))
    print("Display Name: " .. getDisplayName())
    print("Computer ID: " .. computer_id)
    print("Alarm Active: " .. tostring(warning_active))
    
    print("\nNetwork Nodes:")
    local current_time = os.time()
    for id, node in pairs(network_nodes) do
        local status = (current_time - node.last_seen) <= config.max_offline_time and "ONLINE" or "OFFLINE"
        local name_info = node.display_name and (" [" .. node.display_name .. "]") or ""
        print("  Computer " .. id .. name_info .. ": " .. status)
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

local function changeName()
    if is_terminal then
        -- Terminal-friendly name change
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.white)
        print("Change Device Name")
        print("Current: " .. getDisplayName())
        print("")
        print("Enter new name:")
        
        local new_name = read()
        
        if new_name == "" then
            setCustomName(nil)
            print("Name cleared.")
        else
            setCustomName(new_name)
            print("Name set to: " .. getDisplayName())
        end
        
        print("\nPress any key...")
        os.pullEvent("key")
        drawScreen()
    else
        -- Computer version
        term.clear()
        term.setCursorPos(1, 1)
        print("=== Change Device Name ===")
        print("Current name: " .. getDisplayName())
        print("Computer ID: " .. computer_id)
        print("")
        print("Enter new name (or press Enter to clear):")
        
        local new_name = read()
        
        if new_name == "" then
            setCustomName(nil)
            print("Custom name cleared.")
        else
            setCustomName(new_name)
            print("Name changed to: " .. getDisplayName())
        end
        
        print("\nPress any key to return...")
        os.pullEvent("key")
        drawScreen()
    end
end

local function adjustVolume()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Volume Control ===")
    print("Current volume: " .. config.base_volume)
    print("Max volume: " .. config.max_volume)
    print("")
    print("1 - Low (3.0)")
    print("2 - Medium (6.0)")
    print("3 - High (9.0)")
    print("4 - Very Loud (12.0)")
    print("5 - Maximum (15.0)")
    print("")
    print("Choose volume level (1-5):")
    
    local choice = read()
    local volumes = {3.0, 6.0, 9.0, 12.0, 15.0}
    local volume_num = tonumber(choice)
    
    if volume_num and volume_num >= 1 and volume_num <= 5 then
        config.base_volume = volumes[volume_num]
        -- Update alarm patterns with new base volume
        for alarm_type, pattern in pairs(alarm_patterns) do
            for i, sound in ipairs(pattern) do
                sound.volume = config.base_volume + (i * config.volume_increment)
            end
        end
        print("Volume set to: " .. config.base_volume)
    else
        print("Invalid choice")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

local function checkForUpdates()
    term.clear()
    term.setCursorPos(1, 1)
    print("Checking for updates...")
    print("This feature is not yet implemented.")
    print("Would check GitHub for latest version.")
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
    drawScreen()
end

local function handleMessage(msg)
    if msg.type == "warning" then
        if msg.action == "start" and not warning_active then
            warning_active = true
            current_alarm_type = msg.alarm_type or "general"
            alarm_start_time = os.time()
            alarm_triggered_by = msg.source_id
            
            if not is_terminal then
                redstone.setOutput(redstone_output_side, true)
            end
            
            drawScreen()
        elseif msg.action == "stop" and warning_active then
            warning_active = false
            
            if not is_terminal then
                redstone.setOutput(redstone_output_side, false)
            end
            
            drawScreen()
            alarm_triggered_by = nil
        end
    elseif msg.type == "chat" and msg.from_id ~= computer_id then
        -- Received a chat message
        table.insert(recent_messages, {
            message = msg.message,
            from_name = msg.from_name,
            from_id = msg.from_id,
            direction = "received",
            timestamp = msg.timestamp
        })
        unread_message_count = unread_message_count + 1
        drawScreen()
    elseif msg.type == "heartbeat" then
        network_nodes[msg.computer_id] = {
            last_seen = os.time(),
            computer_id = msg.computer_id,
            device_type = msg.device_type or "computer",
            display_name = msg.display_name or tostring(msg.computer_id)
        }
        
        if msg.alarm_active and not warning_active and msg.computer_id ~= computer_id then
            warning_active = true
            current_alarm_type = msg.alarm_type or "general"
            alarm_start_time = os.time()
            alarm_triggered_by = msg.alarm_triggered_by
            
            if not is_terminal then
                redstone.setOutput(redstone_output_side, true)
            end
            
            drawScreen()
        end
    end
end

local function init()
    loadCustomName()
    
    -- Find modem
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            print("Modem found on " .. side)
            break
        end
    end
    
    if not modem_side then
        error("No modem found. Please attach one.")
    end
    
    print("Computer ID: " .. computer_id)
    print("Starting system...")
    
    sleep(1)
    sendHeartbeat()
    sleep(1)
end

local function main()
    init()
    drawScreen()
    
    local heartbeat_timer = os.startTimer(config.heartbeat_interval)
    
    while true do
        local event, param1, param2, param3 = os.pullEvent()
        
        if event == "key" then
            local keyCode = param1
            
            if keyCode == keys.c then
                stopAlarm()
                drawScreen()
            elseif keyCode == keys.e then
                startAlarm("evacuation")
                drawScreen()
            elseif keyCode == keys.s then
                showStatus()
            elseif keyCode == keys.n then
                changeName()
            elseif keyCode == keys.u then
                checkForUpdates()
            elseif keyCode == keys.v then
                adjustVolume()
            elseif keyCode == keys.q and is_terminal then
                print("Terminal shutting down...")
                break
            elseif not warning_active and not is_terminal and not gui_state.typing_mode then
                -- Only trigger alarm on non-terminals when not in typing mode
                startAlarm("general")
                drawScreen()
            end
            
        elseif event == "mouse_click" then
            if is_terminal then
                local button, x, y = param1, param2, param3
                if button == 1 then
                    if handleTouch(x, y) then
                        drawScreen()
                    end
                end
            end
            
        elseif event == "rednet_message" then
            local sender_id, message, proto = param1, param2, param3
            if proto == protocol then
                handleMessage(message)
            end
            
        elseif event == "timer" then
            local timer_id = param1
            if timer_id == heartbeat_timer then
                sendHeartbeat()
                heartbeat_timer = os.startTimer(config.heartbeat_interval)
            elseif timer_id == update_timer then
                -- Auto-check for updates (silent)
                update_timer = os.startTimer(config.update_check_interval)
            end
        end
    end
end

main()
