-- Enhanced PoggishTown Warning System with iPhone-style Terminal GUI
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

-- Configuration
local config = {
    heartbeat_interval = 30,
    max_offline_time = 90,
    auto_stop_timeout = 300,
    volume_increment = 0.3,
    max_volume = 15.0,
    base_volume = 3.0,
    enable_relay = true,
    max_hops = 3,
    relay_delay = 0.2,
    update_url = "https://raw.githubusercontent.com/ANRKJosh/cc-rednet-warning-system/refs/heads/main/warning.lua",
    background_update_check = true,
    update_check_interval = 300,
    auto_apply_updates = false,
    allow_custom_names = true,
    custom_name = nil
}

-- Network state tracking
local network_nodes = {}
local computer_id = os.getComputerID()
local alarm_triggered_by = nil
local message_history = {}
local alarm_note_index = 1
local is_terminal = isWirelessTerminal()
local update_available = false
local last_update_check = 0
local background_update_running = false
local recent_messages = {}
local unread_message_count = 0

-- Terminal features
local terminal_features = {
    location_tracking = true,
    silent_mode = false,
    vibrate_alerts = true,
    compact_log = {},
    last_gps_coords = nil,
    connection_strength = 0,
    recent_messages = {}
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

-- Custom naming functions
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

-- Terminal functions
local function updateGPS()
    if is_terminal and terminal_features and terminal_features.location_tracking and gps then
        local x, y, z = gps.locate(2)
        if x and y and z then
            terminal_features.last_gps_coords = {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
            return terminal_features.last_gps_coords
        end
    end
    return terminal_features and terminal_features.last_gps_coords or nil
end

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

local function terminalLog(message)
    if not is_terminal or not terminal_features then return end
    local timestamp = textutils.formatTime(os.time(), true)
    local entry = "[" .. timestamp .. "] " .. message
    table.insert(terminal_features.compact_log, entry)
    while #terminal_features.compact_log > 20 do
        table.remove(terminal_features.compact_log, 1)
    end
end

local function terminalNotify(message, urgent)
    if not is_terminal or not terminal_features then return end
    if urgent and not terminal_features.silent_mode then
        terminalVibrate()
    end
    terminalLog(message)
end

-- GUI Functions for terminals
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
        write("🚨 " .. string.upper(current_alarm_type) .. " ALERT ACTIVE")
        term.setTextColor(colors.orange)
        term.setCursorPos(2, 6)
        if alarm_triggered_by then
            write("By: " .. (network_nodes[alarm_triggered_by] and network_nodes[alarm_triggered_by].display_name or ("ID:" .. alarm_triggered_by)))
        end
    else
        term.setTextColor(colors.green)
        write("✅ System Ready")
    end
    
    local icon_w, icon_h = 6, 3
    local start_x, start_y = 3, 8
    local spacing = 2
    
    -- Row 1
    local alarm_color = warning_active and colors.red or colors.orange
    drawAppIcon(start_x, start_y, icon_w, icon_h, alarm_color, colors.white, "🚨", "Alarm")
    
    local msg_color = unread_message_count > 0 and colors.lime or colors.blue
    local msg_icon = unread_message_count > 0 and ("💬" .. unread_message_count) or "💬"
    drawAppIcon(start_x + icon_w + spacing, start_y, icon_w, icon_h, msg_color, colors.white, msg_icon, "Messages")
    
    drawAppIcon(start_x + (icon_w + spacing) * 2, start_y, icon_w, icon_h, colors.gray, colors.white, "👥", "Contacts")
    
    -- Row 2
    start_y = start_y + icon_h + spacing + 1
    drawAppIcon(start_x, start_y, icon_w, icon_h, colors.gray, colors.white, "⚙️", "Settings")
    drawAppIcon(start_x + icon_w + spacing, start_y, icon_w, icon_h, colors.cyan, colors.white, "ℹ️", "Info")
    
    if terminal_features and terminal_features.silent_mode then
        term.setTextColor(colors.orange)
        term.setCursorPos(2, h - 1)
        write("🔇 Silent Mode")
    end
    
    if update_available then
        term.setTextColor(colors.yellow)
        term.setCursorPos(w - 8, h - 1)
        write("Update!")
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
        drawAppIcon(3, 10, 10, 4, colors.red, colors.white, "CANCEL", "Cancel Alarm")
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
        term.setCursorPos(2, y + 2)
        term.setTextColor(colors.gray)
        write(textutils.formatTime(msg.timestamp, true))
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
    
    local settings_y = 7
    
    term.setCursorPos(2, settings_y)
    write("Silent Mode")
    term.setCursorPos(w - 4, settings_y)
    if terminal_features and terminal_features.silent_mode then
        term.setTextColor(colors.green)
        write("ON")
    else
        term.setTextColor(colors.red)
        write("OFF")
    end
    
    settings_y = settings_y + 2
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, settings_y)
    write("Device Name")
    term.setTextColor(colors.blue)
    term.setCursorPos(w - 6, settings_y)
    write("Edit >")
    
    settings_y = settings_y + 2
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, settings_y)
    write("Check Updates")
    term.setTextColor(colors.blue)
    term.setCursorPos(w - 6, settings_y)
    write("Check >")
end

local function handleTouch(x, y)
    local w, h = term.getSize()
    
    if gui_state.current_screen == "home" then
        local icon_w, icon_h = 6, 3
        local start_x, start_y = 3, 8
        local spacing = 2
        
        if isInBounds(x, y, start_x, start_y, icon_w, icon_h) then
            gui_state.current_screen = "alarm_trigger"
            return true
        end
        
        if isInBounds(x, y, start_x + icon_w + spacing, start_y, icon_w, icon_h) then
            gui_state.current_screen = "messages"
            unread_message_count = 0
            return true
        end
        
        if isInBounds(x, y, start_x + (icon_w + spacing) * 2, start_y, icon_w, icon_h) then
            gui_state.current_screen = "contacts"
            return true
        end
        
        start_y = start_y + icon_h + spacing + 1
        if isInBounds(x, y, start_x, start_y, icon_w, icon_h) then
            gui_state.current_screen = "settings"
            return true
        end
        
    elseif gui_state.current_screen == "alarm_trigger" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        end
        
        if warning_active then
            if isInBounds(x, y, 3, 10, 10, 4) then
                stopAlarm()
                gui_state.current_screen = "home"
                return true
            end
        else
            if isInBounds(x, y, 3, 9, 10, 3) then
                startAlarm("general")
                gui_state.current_screen = "home"
                return true
            end
            
            if isInBounds(x, y, 3, 13, 10, 3) then
                startAlarm("evacuation")
                gui_state.current_screen = "home"
                return true
            end
        end
        
    elseif gui_state.current_screen == "messages" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        end
        
        if isInBounds(x, y, w - 6, 3, 6, 1) then
            gui_state.current_screen = "contacts"
            return true
        end
        
    elseif gui_state.current_screen == "contacts" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "messages"
            return true
        end
        
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
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        end
        
        if y == 7 then
            terminal_features.silent_mode = not terminal_features.silent_mode
            terminalLog("Silent mode " .. (terminal_features.silent_mode and "enabled" or "disabled"))
            return true
        end
        
        if y == 9 and x >= w - 6 then
            changeName()
            return true
        end
        
        if y == 11 and x >= w - 6 then
            checkForUpdates(true)
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

-- Utility functions
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

-- Main screen drawing function
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
        
        if update_available then
            print("")
            term.setTextColor(colors.yellow)
            print("UPDATE AVAILABLE! Press U to install")
            term.setTextColor(colors.white)
        end
    end
end

-- Logging system
local log_file = "warning_system.log"
local max_log_size = 10000

local function log(message)
    local timestamp = textutils.formatTime(os.time(), true)
    local device_type = is_terminal and "[TERMINAL]" or "[COMPUTER]"
    local entry = "[" .. timestamp .. "] " .. device_type .. " " .. message .. "\n"
    
    if fs.exists(log_file) and fs.getSize(log_file) > max_log_size then
        local old_file = fs.open(log_file, "r")
        local lines = {}
        if old_file then
            local line = old_file.readLine()
            while line do
                table.insert(lines, line)
                line = old_file.readLine()
            end
            old_file.close()
            
            local new_file = fs.open(log_file, "w")
            if new_file then
                local start = math.max(1, #lines - 49)
                for i = start, #lines do
                    new_file.writeLine(lines[i])
                end
                new_file.close()
            end
        end
    end
    
    local file = fs.open(log_file, "a")
    if file then
        file.write(entry)
        file.close()
    end
end

-- Network functions
local function hasEnderModem()
    local modem = peripheral.wrap(modem_side)
    if modem then
        if modem.isWireless and not modem.isWireless() then
            return true
        end
        if not modem.isWireless then
            return true
        end
        local modem_type = peripheral.getType(modem_side)
        if modem_type == "modem" then
            local success, result = pcall(function() return modem.isWireless() end)
            if not success or not result then
                return true
            end
        end
    end
    return false
end

local function relayMessage(msg)
    if not config.enable_relay then return end
    if not msg.hops then msg.hops = 0 end
    if msg.hops >= config.max_hops then return end
    
    if msg.origin_id == computer_id then return end
    if msg.message_id and isMessageSeen(msg.message_id) then return end
    
    if hasEnderModem() then
        if msg.hops > 1 then return end
    end
    
    sleep(config.relay_delay)
    
    msg.hops = msg.hops + 1
    msg.relayed_by = computer_id
    
    rednet.broadcast(msg, protocol)
    
    if msg.message_id then
        markMessageSeen(msg.message_id)
    end
end

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
