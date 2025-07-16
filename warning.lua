-- Enhanced PoggishTown Warning System with Terminal GUI
-- Clean version to fix all syntax errors

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
    message_input = ""
}

-- Configuration
local config = {
    heartbeat_interval = 30,
    max_offline_time = 90,
    auto_stop_timeout = 300,
    custom_name = nil
}

-- Utility functions
local function getDisplayName()
    if config.custom_name then return config.custom_name end
    local label = os.getComputerLabel()
    if label then return label end
    return tostring(computer_id)
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
            config.custom_name = file.readAll()
            file.close()
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

-- Terminal GUI functions
local function drawStatusBar()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clearLine()
    local time_str = textutils.formatTime(os.time(), true)
    term.setCursorPos(2, 1)
    write(time_str)
    local name = getDisplayName()
    if #name > 8 then name = name:sub(1, 8) end
    local w = term.getSize()
    local center_pos = math.floor((w - #name) / 2)
    term.setCursorPos(center_pos, 1)
    write(name)
end

local function drawAppIcon(x, y, w, h, color, text_color, icon)
    term.setBackgroundColor(color)
    for i = 0, h - 1 do
        term.setCursorPos(x, y + i)
        write(string.rep(" ", w))
    end
    term.setTextColor(text_color)
    local icon_y = y + 1
    local icon_x = x + 1
    term.setCursorPos(icon_x, icon_y)
    write(icon)
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
        write("ALERT ACTIVE")
    else
        term.setTextColor(colors.green)
        write("System Ready")
    end
    
    -- App icons
    local alarm_color = warning_active and colors.red or colors.orange
    drawAppIcon(3, 8, 6, 3, alarm_color, colors.white, "ALARM")
    
    local msg_color = unread_message_count > 0 and colors.lime or colors.blue
    drawAppIcon(11, 8, 6, 3, msg_color, colors.white, "MSG")
    
    drawAppIcon(19, 8, 6, 3, colors.gray, colors.white, "SET")
    
    if terminal_features.silent_mode then
        term.setTextColor(colors.orange)
        term.setCursorPos(2, h - 1)
        write("Silent Mode")
    end
end

local function drawAlarmScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    term.setTextColor(colors.blue)
    term.setCursorPos(2, 3)
    write("< Back")
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("Emergency Alert")
    
    if warning_active then
        term.setTextColor(colors.red)
        term.setCursorPos(2, 7)
        write("ALARM ACTIVE")
        drawAppIcon(3, 10, 10, 3, colors.red, colors.white, "CANCEL")
    else
        drawAppIcon(3, 9, 10, 3, colors.orange, colors.white, "GENERAL")
        drawAppIcon(3, 13, 10, 3, colors.red, colors.white, "EVACUATION")
    end
end

local function drawMessagesScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    term.setTextColor(colors.blue)
    term.setCursorPos(2, 3)
    write("< Back")
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("Messages")
    
    if #recent_messages == 0 then
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 8)
        write("No messages")
    else
        local y = 7
        for i = math.max(1, #recent_messages - 3), #recent_messages do
            local msg = recent_messages[i]
            local bg_color = msg.direction == "sent" and colors.blue or colors.gray
            term.setBackgroundColor(bg_color)
            term.setTextColor(colors.white)
            term.setCursorPos(2, y)
            local sender = msg.direction == "sent" and "You" or msg.from_name
            write(" " .. sender .. ": " .. msg.message .. " ")
            term.setBackgroundColor(colors.black)
            y = y + 2
        end
    end
end

local function drawSettingsScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    term.setTextColor(colors.blue)
    term.setCursorPos(2, 3)
    write("< Back")
    
    term.setTextColor(colors.white)
    term.setCursorPos(2, 5)
    write("Settings")
    
    term.setCursorPos(2, 7)
    write("Silent Mode")
    local w = term.getSize()
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
    if gui_state.current_screen == "home" then
        if isInBounds(x, y, 3, 8, 6, 3) then
            gui_state.current_screen = "alarm_trigger"
            return true
        elseif isInBounds(x, y, 11, 8, 6, 3) then
            gui_state.current_screen = "messages"
            unread_message_count = 0
            return true
        elseif isInBounds(x, y, 19, 8, 6, 3) then
            gui_state.current_screen = "settings"
            return true
        end
    elseif gui_state.current_screen == "alarm_trigger" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        elseif warning_active and isInBounds(x, y, 3, 10, 10, 3) then
            stopAlarm()
            gui_state.current_screen = "home"
            return true
        elseif not warning_active then
            if isInBounds(x, y, 3, 9, 10, 3) then
                startAlarm("general")
                gui_state.current_screen = "home"
                return true
            elseif isInBounds(x, y, 3, 13, 10, 3) then
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
    elseif gui_state.current_screen == "settings" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        elseif y == 7 then
            terminal_features.silent_mode = not terminal_features.silent_mode
            return true
        elseif y == 9 then
            changeName()
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
    end
end

-- Network functions
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

local function startAlarm(alarm_type)
    alarm_type = alarm_type or "general"
    if not warning_active then
        warning_active = true
        current_alarm_type = alarm_type
        alarm_start_time = os.time()
        alarm_triggered_by = computer_id
        
        if not is_terminal then
            redstone.setOutput(redstone_output_side, true)
        end
        
        drawScreen()
        broadcast("start", alarm_type)
    end
end

local function stopAlarm()
    if warning_active then
        warning_active = false
        
        if not is_terminal then
            redstone.setOutput(redstone_output_side, false)
        end
        
        drawScreen()
        broadcast("stop", current_alarm_type)
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
            elseif keyCode == keys.e then
                startAlarm("evacuation")
            elseif keyCode == keys.s then
                showStatus()
            elseif keyCode == keys.n then
                changeName()
            elseif keyCode == keys.q and is_terminal then
                print("Terminal shutting down...")
                break
            elseif not warning_active and not is_terminal then
                startAlarm("general")
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
            end
        end
    end
end

main()
