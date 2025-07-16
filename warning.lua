-- Enhanced PoggishTown Warning System with iPhone-style Terminal GUI (V2 Phone)
-- Computers: Traditional keyboard interface
-- Terminals: Touch-friendly GUI interface

local protocol = "poggishtown_warning"
local warning_active = false
local modem_side = nil
local speaker = peripheral.find("speaker")
local alarm_start_time = nil
local redstone_output_side = "back"
local computer_id = os.getComputerID()

-- Configuration
local config = {
    heartbeat_interval = 30,
    max_offline_time = 90,
    auto_stop_timeout = 300,Update warning.lua
    volume_increment = 0.3,
    max_volume = 15.0,
    base_volume = 3.0,
    enable_relay = true,
    max_hops = 3,
    relay_delay = 0.2,
    update_url = "https://raw.githubusercontent.com/ANRKJosh/cc-rednet-warning-system/refs/heads/main/warning.lua",
    allow_custom_names = true,
    custom_name = nil
}

-- Check if device is a wireless terminal
local function isWirelessTerminal()
    if pocket then return true end
    
    local label = os.getComputerLabel()
    if label and (string.find(label:lower(), "terminal") or string.find(label:lower(), "pocket")) then
        return true
    end
    
    local peripherals = peripheral.getNames()
    if #peripherals == 0 then return true end
    
    local has_only_modem = true
    for _, side in pairs(peripherals) do
        if peripheral.getType(side) ~= "modem" then
            has_only_modem = false
            break
        end
    end
    
    return has_only_modem and #peripherals == 1
end

local is_terminal = isWirelessTerminal()

-- Global state variables
local network_nodes = {}
local alarm_triggered_by = nil
local message_history = {}
local alarm_note_index = 1
local recent_messages = {}
local unread_message_count = 0

-- Terminal features
local terminal_features = {
    silent_mode = false,
    vibrate_alerts = true,
    compact_log = {},
    last_gps_coords = nil,
    connection_strength = 0
}

-- GUI state for terminals
local gui_state = {
    current_screen = "home",
    selected_contact = nil,
    typing_mode = false,
    message_input = ""
}

-- Alarm patterns
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

-- Utility functions
local function getDisplayName()
    if config.custom_name then
        return config.custom_name
    end
    local label = os.getComputerLabel()
    if label then
        return label
    end
    return tostring(computer_id)
end

local function setCustomName(name)
    if not config.allow_custom_names then return false end
    if name and name ~= "" then
        config.custom_name = name
        local file = fs.open("poggish_config", "w")
        if file then
            file.write(textutils.serialize({custom_name = name}))
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
            local success, data = pcall(textutils.unserialize, content)
            if success and data and data.custom_name then
                config.custom_name = data.custom_name
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

local function isMessageSeen(msg_id)
    return message_history[msg_id] ~= nil
end

local function markMessageSeen(msg_id)
    message_history[msg_id] = os.time()
    for id, timestamp in pairs(message_history) do
        if (os.time() - timestamp) > 300 then
            message_history[id] = nil
        end
    end
end

-- Terminal functions
local function terminalVibrate()
    if not is_terminal or not terminal_features.vibrate_alerts then return end
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

local function terminalLog(message)
    if not is_terminal then return end
    local timestamp = textutils.formatTime(os.time(), true)
    local entry = "[" .. timestamp .. "] " .. message
    table.insert(terminal_features.compact_log, entry)
    while #terminal_features.compact_log > 20 do
        table.remove(terminal_features.compact_log, 1)
    end
end

local function terminalNotify(message, urgent)
    if not is_terminal then return end
    if urgent and not terminal_features.silent_mode then
        terminalVibrate()
    end
    terminalLog(message)
end

-- Messaging functions
local function sendDirectMessage(target_id, message_text)
    if not is_terminal then return end
    
    local message = {
        type = "direct_message",
        target_id = target_id,
        sender_id = computer_id,
        sender_name = getDisplayName(),
        message_text = message_text,
        timestamp = os.time(),
        message_id = generateMessageId()
    }
    
    rednet.broadcast(message, protocol)
    markMessageSeen(message.message_id)
    
    table.insert(recent_messages, {
        from_id = computer_id,
        from_name = getDisplayName(),
        to_id = target_id,
        message = message_text,
        timestamp = os.time(),
        direction = "sent"
    })
    
    while #recent_messages > 10 do
        table.remove(recent_messages, 1)
    end
end

-- GUI Drawing Functions
local function drawStatusBar()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clearLine()
    
    local time_str = textutils.formatTime(os.time(), true)
    term.setCursorPos(2, 1)
    write(time_str)
    
    local name = getDisplayName()
    if #name > 8 then name = name:sub(1, 8) .. "." end
    local w, h = term.getSize()
    local center_pos = math.floor((w - #name) / 2)
    term.setCursorPos(center_pos, 1)
    write(name)
    
    local signal_strength = terminal_features.connection_strength or 0
    local signal_text = string.rep("▪", signal_strength) .. string.rep("▫", 5 - signal_strength)
    term.setCursorPos(w - 6, 1)
    write(signal_text)
end

local function drawAppIcon(x, y, w, h, color, text_color, icon, label)
    term.setBackgroundColor(color)
    for i = 0, h - 1 do
        term.setCursorPos(x, y + i)
        write(string.rep(" ", w))
    end
    
    term.setTextColor(text_color)
    local icon_y = y + math.floor(h / 2) - 1
    local icon_x = x + math.floor((w - #icon) / 2)
    term.setCursorPos(icon_x, icon_y)
    write(icon)
    
    if label then
        local label_y = y + h - 1
        local label_x = x + math.floor((w - #label) / 2)
        if label_x < x then label_x = x end
        if label_x + #label > x + w then 
            label = label:sub(1, w)
            label_x = x
        end
        term.setCursorPos(label_x, label_y)
        write(label)
    end
    
    term.setBackgroundColor(colors.black)
end

local function isInBounds(click_x, click_y, x, y, w, h)
    return click_x >= x and click_x < x + w and click_y >= y and click_y < y + h
end

local function drawHomeScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    
    drawStatusBar()
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 3)
    write("PoggishTown Security")
    
    term.setCursorPos(2, 5)
    if warning_active then
        term.setTextColor(colors.red)
        write("🚨 " .. string.upper(current_alarm_type) .. " ALERT")
    else
        term.setTextColor(colors.green)
        write("✅ System Ready")
    end
    
    local icon_w, icon_h = 6, 3
    local start_x, start_y = 3, 8
    local spacing = 2
    
    -- Row 1 - Alarm, Messages, Contacts
    local alarm_color = warning_active and colors.red or colors.orange
    drawAppIcon(start_x, start_y, icon_w, icon_h, alarm_color, colors.white, "🚨", "Alarm")
    
    local msg_color = unread_message_count > 0 and colors.lime or colors.blue
    local msg_icon = unread_message_count > 0 and ("💬" .. unread_message_count) or "💬"
    drawAppIcon(start_x + icon_w + spacing, start_y, icon_w, icon_h, msg_color, colors.white, msg_icon, "Messages")
    
    drawAppIcon(start_x + (icon_w + spacing) * 2, start_y, icon_w, icon_h, colors.gray, colors.white, "👥", "Contacts")
    
    -- Row 2 - Settings, Info
    start_y = start_y + icon_h + spacing + 1
    drawAppIcon(start_x, start_y, icon_w, icon_h, colors.gray, colors.white, "⚙️", "Settings")
    drawAppIcon(start_x + icon_w + spacing, start_y, icon_w, icon_h, colors.cyan, colors.white, "ℹ️", "Info")
    
    if terminal_features.silent_mode then
        term.setTextColor(colors.orange)
        term.setCursorPos(2, h - 1)
        write("🔇 Silent Mode")
    end
end

local function drawAlarmScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    
    drawStatusBar()
    
    term.setTextColor(colors.blue)
    term.setCursorPos(2, 3)
    write("← Back")
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("Emergency Alert")
    
    if warning_active then
        term.setTextColor(colors.red)
        term.setCursorPos(2, 7)
        write("ALARM ACTIVE: " .. string.upper(current_alarm_type))
        drawAppIcon(3, 10, 10, 4, colors.red, colors.white, "CANCEL", "")
    else
        term.setTextColor(colors.white)
        term.setCursorPos(2, 7)
        write("Select alert type:")
        drawAppIcon(3, 9, 10, 3, colors.orange, colors.white, "⚠️ GENERAL", "")
        drawAppIcon(3, 13, 10, 3, colors.red, colors.white, "🚨 EVACUATION", "")
    end
end

local function drawMessagesScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    
    drawStatusBar()
    
    term.setTextColor(colors.blue)
    term.setCursorPos(2, 3)
    write("← Back")
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("Messages")
    
    term.setTextColor(colors.blue)
    term.setCursorPos(w - 6, 3)
    write("New +")
    
    if #recent_messages == 0 then
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 8)
        write("No messages")
        return
    end
    
    local start_y = 7
    local msg_height = 3
    
    for i = math.max(1, #recent_messages - 3), #recent_messages do
        local msg = recent_messages[i]
        local y = start_y + (i - math.max(1, #recent_messages - 3)) * msg_height
        
        if y > h - 2 then break end
        
        local bg_color = msg.direction == "sent" and colors.blue or colors.gray
        term.setBackgroundColor(bg_color)
        term.setTextColor(colors.white)
        
        term.setCursorPos(2, y)
        local sender = msg.direction == "sent" and "You" or msg.from_name
        write(" " .. sender .. " ")
        
        term.setCursorPos(2, y + 1)
        local display_msg = msg.message
        if #display_msg > w - 4 then
            display_msg = display_msg:sub(1, w - 7) .. "..."
        end
        write(" " .. display_msg .. " ")
        
        term.setBackgroundColor(colors.black)
    end
end

local function drawContactsScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    
    drawStatusBar()
    
    term.setTextColor(colors.blue)
    term.setCursorPos(2, 3)
    write("← Back")
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("Online Terminals")
    
    local current_time = os.time()
    local online_terminals = {}
    
    for id, node in pairs(network_nodes) do
        if (current_time - node.last_seen) <= config.max_offline_time and 
           node.device_type == "terminal" and 
           id ~= computer_id then
            table.insert(online_terminals, {id = id, name = node.display_name or ("Terminal " .. id)})
        end
    end
    
    if #online_terminals == 0 then
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 8)
        write("No terminals online")
        return
    end
    
    local start_y = 7
    for i, terminal in ipairs(online_terminals) do
        local y = start_y + i
        if y > h - 2 then break end
        
        term.setTextColor(colors.green)
        term.setCursorPos(2, y)
        write("● ")
        term.setTextColor(colors.white)
        write(terminal.name)
        
        term.setTextColor(colors.blue)
        term.setCursorPos(w - 6, y)
        write("Msg >")
    end
end

local function drawSettingsScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    
    drawStatusBar()
    
    term.setTextColor(colors.blue)
    term.setCursorPos(2, 3)
    write("← Back")
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("Settings")
    
    term.setCursorPos(2, 7)
    write("Silent Mode")
    term.setCursorPos(w - 4, 7)
    if terminal_features.silent_mode then
        term.setTextColor(colors.green)
        write("ON")
    else
        term.setTextColor(colors.red)
        write("OFF")
    end
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 9)
    write("Device Name")
    term.setTextColor(colors.blue)
    term.setCursorPos(w - 6, 9)
    write("Edit >")
end

local function handleTouch(x, y)
    local w, h = term.getSize()
    
    if gui_state.current_screen == "home" then
        local icon_w, icon_h = 6, 3
        local start_x, start_y = 3, 8
        local spacing = 2
        
        -- Alarm app
        if isInBounds(x, y, start_x, start_y, icon_w, icon_h) then
            gui_state.current_screen = "alarm_trigger"
            return true
        end
        
        -- Messages app
        if isInBounds(x, y, start_x + icon_w + spacing, start_y, icon_w, icon_h) then
            gui_state.current_screen = "messages"
            unread_message_count = 0
            return true
        end
        
        -- Contacts app
        if isInBounds(x, y, start_x + (icon_w + spacing) * 2, start_y, icon_w, icon_h) then
            gui_state.current_screen = "contacts"
            return true
        end
        
        -- Settings app (row 2)
        start_y = start_y + icon_h + spacing + 1
        if isInBounds(x, y, start_x, start_y, icon_w, icon_h) then
            gui_state.current_screen = "settings"
            return true
        end
        
    elseif gui_state.current_screen == "alarm_trigger" then
        -- Back button
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        end
        
        if warning_active then
            -- Cancel alarm
            if isInBounds(x, y, 3, 10, 10, 4) then
                stopAlarm()
                gui_state.current_screen = "home"
                return true
            end
        else
            -- General alarm
            if isInBounds(x, y, 3, 9, 10, 3) then
                startAlarm("general")
                gui_state.current_screen = "home"
                return true
            end
            
            -- Evacuation alarm
            if isInBounds(x, y, 3, 13, 10, 3) then
                startAlarm("evacuation")
                gui_state.current_screen = "home"
                return true
            end
        end
        
    elseif gui_state.current_screen == "messages" then
        -- Back button
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        end
        
        -- New message button
        if isInBounds(x, y, w - 6, 3, 6, 1) then
            gui_state.current_screen = "contacts"
            return true
        end
        
    elseif gui_state.current_screen == "contacts" then
        -- Back button
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "messages"
            return true
        end
        
        -- Contact message buttons
        local current_time = os.time()
        local online_terminals = {}
        
        for id, node in pairs(network_nodes) do
            if (current_time - node.last_seen) <= config.max_offline_time and 
               node.device_type == "terminal" and 
               id ~= computer_id then
                table.insert(online_terminals, {id = id, name = node.display_name or ("Terminal " .. id)})
            end
        end
        
        local start_y = 7
        for i, terminal in ipairs(online_terminals) do
            local contact_y = start_y + i
            if y == contact_y and x >= w - 6 then
                gui_state.selected_contact = terminal
                gui_state.typing_mode = true
                gui_state.message_input = ""
                return true
            end
        end
        
    elseif gui_state.current_screen == "settings" then
        -- Back button
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        end
        
        -- Silent mode toggle
        if y == 7 then
            terminal_features.silent_mode = not terminal_features.silent_mode
            terminalLog("Silent mode " .. (terminal_features.silent_mode and "enabled" or "disabled"))
            return true
        end
        
        -- Change name
        if y == 9 and x >= w - 6 then
            changeName()
            return true
        end
    end
    
    return false
end

local function drawGUIScreen()
    if gui_state.typing_mode and gui_state.selected_contact then
        local w, h = term.getSize()
        term.setBackgroundColor(colors.black)
        term.clear()
        
        drawStatusBar()
        
        term.setTextColor(colors.blue)
        term.setCursorPos(2, 3)
        write("← Cancel")
        
        term.setTextColor(colors.white)
        term.setCursorPos(2, 5)
        write("To: " .. gui_state.selected_contact.name)
        
        term.setCursorPos(2, 7)
        write("Message:")
        term.setCursorPos(2, 8)
        write("> " .. gui_state.message_input)
        
        term.setTextColor(colors.gray)
        term.setCursorPos(2, h - 2)
        write("Enter to send, Esc to cancel")
        
    elseif gui_state.current_screen == "home" then
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
        -- Computer interface
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
            if alarm_start_time then
                local t = textutils.formatTime(alarm_start_time, true)
                print("Started: " .. t)
            end
            if alarm_triggered_by then
                print("By: Computer " .. alarm_triggered_by)
            end
            
            if alarm_start_time then
                local elapsed = os.time() - alarm_start_time
                local remaining = config.auto_stop_timeout - elapsed
                if remaining > 0 then
                    print("Auto-stop: " .. math.floor(remaining) .. "s")
                end
            end
            
            print("")
            print("")
            print("")
        else
            term.setTextColor(colors.green)
            print("STATUS: System Ready")
            
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
    end
end

-- Logging
local log_file = "warning_system.log"

local function log(message)
    local timestamp = textutils.formatTime(os.time(), true)
    local device_type = is_terminal and "[TERMINAL]" or "[COMPUTER]"
    local entry = "[" .. timestamp .. "] " .. device_type .. " " .. message .. "\n"
    
    local file = fs.open(log_file, "a")
    if file then
        file.write(entry)
        file.close()
    end
end

-- Network functions
local function broadcast(action, alarm_type, source_id)
    local message = {
        type = "warning",
        action = action,
        alarm_type = alarm_type or current_alarm_type,
        source_id = source_id or computer_id,
        origin_id = computer_id,
        timestamp = os.time(),
        message_id = generateMessageId(),
        hops = 0,
        device_type = is_terminal and "terminal" or "computer"
    }
    rednet.broadcast(message, protocol)
    markMessageSeen(message.message_id)
    log("Broadcast: " .. action .. " (" .. (alarm_type or "general") .. ") from " .. (source_id or computer_id))
end

local function sendHeartbeat()
    local message = {
        type = "heartbeat",
        computer_id = computer_id,
        origin_id = computer_id,
        timestamp = os.time(),
        message_id = generateMessageId(),
        hops = 0,
        device_type = is_terminal and "terminal" or "computer",
        display_name = getDisplayName(),
        alarm_active = warning_active,
        alarm_type = current_alarm_type,
        alarm_start_time = alarm_start_time,
        alarm_triggered_by = alarm_triggered_by
    }
    rednet.broadcast(message, protocol)
    markMessageSeen(message.message_id)
end

local function startAlarm(alarm_type)
    alarm_type = alarm_type or "general"
    if not warning_active then
        warning_active = true
        current_alarm_type = alarm_type
        alarm_start_time = os.time()
        alarm_triggered_by = computer_id
        alarm_note_index = 1
        
        if not is_terminal then
            redstone.setOutput(redstone_output_side, true)
        else
            terminalNotify("ALARM TRIGGERED: " .. string.upper(alarm_type), true)
        end
        
        drawScreen()
        broadcast("start", alarm_type, computer_id)
        log("Alarm started: " .. alarm_type .. " by " .. (is_terminal and "terminal" or "computer") .. " " .. computer_id)
    end
end

local function stopAlarm()
    if warning_active then
        warning_active = false
        alarm_note_index = 1
        
        if not is_terminal then
            redstone.setOutput(redstone_output_side, false)
        else
            terminalNotify("ALARM CANCELLED", false)
        end
        
        drawScreen()
        broadcast("stop", current_alarm_type, computer_id)
        log("Alarm stopped by " .. (is_terminal and "terminal" or "computer") .. " " .. computer_id)
        alarm_triggered_by = nil
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
    if warning_active then
        print("Alarm Type: " .. current_alarm_type)
        print("Triggered by: " .. (alarm_triggered_by or "Unknown"))
    end
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

local function showLogs()
    if is_terminal then return end
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

local function testNetwork()
    if is_terminal then return end
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Network Test ===")
    print("Computer ID: " .. computer_id)
    print("Protocol: " .. protocol)
    
    print("\nSending test broadcast...")
    local test_msg = {
        type = "test",
        from = computer_id,
        message = "Hello from computer " .. computer_id,
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
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

local function handleMessage(msg)
    log("Processing message type: " .. (msg.type or "unknown"))
    
    if msg.type == "test" and msg.from ~= computer_id and msg.message and not string.find(msg.message, "Response from") then
        local response = {
            type = "test",
            from = computer_id,
            message = "Response from " .. (is_terminal and "terminal" or "computer") .. " " .. computer_id,
            timestamp = os.time()
        }
        rednet.broadcast(response, protocol)
        return
    end
    
    if msg.type == "test" and msg.message and string.find(msg.message, "Response from") then
        return
    end
    
    if msg.origin_id and msg.origin_id == computer_id then 
        return 
    end
    
    if msg.message_id and isMessageSeen(msg.message_id) then 
        return 
    end
    
    if msg.message_id and msg.type ~= "test" then
        markMessageSeen(msg.message_id)
    end
    
    if msg.type == "warning" then
        if msg.action == "start" and not warning_active then
            warning_active = true
            current_alarm_type = msg.alarm_type or "general"
            alarm_start_time = os.time()
            alarm_triggered_by = msg.source_id
            
            if not is_terminal then
                redstone.setOutput(redstone_output_side, true)
            else
                terminalNotify("NETWORK ALARM: " .. string.upper(current_alarm_type), true)
            end
            
            drawScreen()
            log("Alarm started remotely by computer " .. msg.source_id)
        elseif msg.action == "stop" and warning_active then
            warning_active = false
            
            if not is_terminal then
                redstone.setOutput(redstone_output_side, false)
            else
                terminalNotify("ALARM CANCELLED BY NETWORK", false)
            end
            
            drawScreen()
            log("Alarm stopped remotely by computer " .. msg.source_id)
            alarm_triggered_by = nil
        end
    elseif msg.type == "direct_message" then
        if msg.target_id == computer_id and is_terminal then
            log("Received message from " .. msg.sender_name)
            
            table.insert(recent_messages, {
                from_id = msg.sender_id,
                from_name = msg.sender_name,
                to_id = computer_id,
                message = msg.message_text,
                timestamp = msg.timestamp,
                direction = "received"
            })
            
            while #recent_messages > 10 do
                table.remove(recent_messages, 1)
            end
            
            unread_message_count = unread_message_count + 1
            terminalNotify("Message from " .. msg.sender_name, true)
            drawScreen()
        end
    elseif msg.type == "heartbeat" then
        network_nodes[msg.computer_id] = {
            last_seen = os.time(),
            computer_id = msg.computer_id,
            hops = msg.hops or 0,
            device_type = msg.device_type or "computer",
            display_name = msg.display_name or tostring(msg.computer_id)
        }
        
        if msg.alarm_active and not warning_active and msg.computer_id ~= computer_id then
            warning_active = true
            current_alarm_type = msg.alarm_type or "general"
            alarm_start_time = msg.alarm_start_time or os.time()
            alarm_triggered_by = msg.alarm_triggered_by
            alarm_note_index = 1
            
            if not is_terminal then
                redstone.setOutput(redstone_output_side, true)
            else
                terminalNotify("JOINING ACTIVE ALARM: " .. string.upper(current_alarm_type), true)
            end
            
            drawScreen()
        end
        
        if is_terminal then
            terminal_features.connection_strength = math.min(5, terminal_features.connection_strength + 1)
        end
    end
end

local function init()
    loadCustomName()
    
    if is_terminal then
        print("Running on wireless terminal")
        log("System started on wireless terminal")
    else
        print("Running on computer")
        log("System started on computer")
    end
    
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
    print("Protocol: " .. protocol)
    
    sleep(1)
    print("Sending initial heartbeat...")
    sendHeartbeat()
    
    sleep(1)
    print("Starting system...")
end

local function main()
    init()
    drawScreen()
    
    log("System started")
    
    local heartbeat_timer = os.startTimer(config.heartbeat_interval)
    local alarm_timer = nil
    
    while true do
        local event, param1, param2, param3 = os.pullEvent()
        
        if event == "key" then
            local keyCode = param1
            
            -- Handle typing mode for terminals
            if is_terminal and gui_state.typing_mode then
                if keyCode == keys.enter then
                    if gui_state.message_input ~= "" and gui_state.selected_contact then
                        sendDirectMessage(gui_state.selected_contact.id, gui_state.message_input)
                    end
                    gui_state.typing_mode = false
                    gui_state.selected_contact = nil
                    gui_state.message_input = ""
                    gui_state.current_screen = "messages"
                    drawScreen()
                elseif keyCode == keys.backspace then
                    gui_state.message_input = gui_state.message_input:sub(1, -2)
                    drawScreen()
                elseif keyCode == keys.delete then
                    gui_state.typing_mode = false
                    gui_state.selected_contact = nil
                    gui_state.message_input = ""
                    gui_state.current_screen = "contacts"
                    drawScreen()
                end
            else
                -- Regular key handling
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
                elseif keyCode == keys.n then
                    changeName()
                elseif keyCode == keys.q and is_terminal then
                    print("Terminal shutting down...")
                    break
                elseif not warning_active and not is_terminal then
                    startAlarm("general")
                end
            end
            
        elseif event == "char" then
            if is_terminal and gui_state.typing_mode then
                local char = param1
                gui_state.message_input = gui_state.message_input .. char
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
                
                if is_terminal then
                    terminal_features.connection_strength = math.max(0, terminal_features.connection_strength - 1)
                end
            elseif timer_id == alarm_timer then
                if warning_active and (not is_terminal or speaker) then
                    local pattern = alarm_patterns[current_alarm_type]
                    local volume = config.base_volume + (config.volume_increment * math.min(30, (os.time() - (alarm_start_time or 0))))
                    volume = math.min(config.max_volume, volume)
                    
                    if speaker and pattern[alarm_note_index] then
                        local sound = pattern[alarm_note_index]
                        speaker.playNote("bass", volume, sound.note)
                        
                        alarm_note_index = alarm_note_index + 1
                        if alarm_note_index > #pattern then
                            alarm_note_index = 1
                        end
                        
                        local next_delay = math.max(sound.duration, 0.1)
                        alarm_timer = os.startTimer(next_delay)
                    else
                        alarm_timer = os.startTimer(0.2)
                        alarm_note_index = 1
                    end
                    
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
        
        -- Start alarm timer when needed
        if warning_active and not alarm_timer and (not is_terminal or speaker) then
            alarm_timer = os.startTimer(0.05)
        end
    end
end

main()Screen()
end

local function changeName()
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
        print("Custom name cleared. Using default: " .. getDisplayName())
    else
        if setCustomName(new_name) then
            print("Name changed to: " .. getDisplayName())
        else
            print("Failed to set name")
        end
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    draw
