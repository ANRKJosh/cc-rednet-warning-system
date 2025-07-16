-- Enhanced PoggishTown Warning System with Terminal GUI
-- Fixed version with better visuals and proper function order

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
    
    -- Device name centered
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
    -- Draw icon background with border
    term.setBackgroundColor(color)
    for i = 0, h - 1 do
        term.setCursorPos(x, y + i)
        if i == 0 or i == h - 1 then
            -- Top and bottom borders
            write("+" .. string.rep("-", w - 2) .. "+")
        else
            -- Side borders
            write("|" .. string.rep(" ", w - 2) .. "|")
        end
    end
    
    -- Draw icon
    term.setTextColor(text_color)
    local icon_y = y + 1
    local icon_x = x + math.floor((w - #icon) / 2)
    term.setCursorPos(icon_x, icon_y)
    write(icon)
    
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
    
    -- Main title with decorative border
    term.setTextColor(colors.cyan)
    term.setCursorPos(2, 3)
    write("=======================")
    term.setCursorPos(2, 4)
    write("  PoggishTown Security")
    term.setCursorPos(2, 5)
    write("=======================")
    
    -- Status indicator
    term.setCursorPos(2, 7)
    if warning_active then
        term.setTextColor(colors.red)
        write(">> ALERT ACTIVE <<")
        term.setCursorPos(2, 8)
        term.setTextColor(colors.yellow)
        write("Type: " .. string.upper(current_alarm_type))
    else
        term.setTextColor(colors.green)
        write(">> System Ready <<")
        term.setCursorPos(2, 8)
        term.setTextColor(colors.white)
        write("All systems normal")
    end
    
    -- App icons with better spacing
    local alarm_color = warning_active and colors.red or colors.orange
    local alarm_icon = warning_active and "!!" or "/\\"
    drawAppIcon(3, 11, 10, 4, alarm_color, colors.white, alarm_icon, "ALARM")
    
    local msg_color = unread_message_count > 0 and colors.lime or colors.blue
    local msg_icon = unread_message_count > 0 and "[" .. unread_message_count .. "]" or "MSG"
    drawAppIcon(15, 11, 10, 4, msg_color, colors.white, msg_icon, "MESSAGES")
    
    drawAppIcon(3, 16, 10, 4, colors.gray, colors.white, "SET", "SETTINGS")
    
    -- Additional status info
    if terminal_features.silent_mode then
        term.setTextColor(colors.orange)
        term.setCursorPos(2, h - 1)
        write("[SILENT MODE ACTIVE]")
    end
    
    -- Network status
    term.setTextColor(colors.white)
    term.setCursorPos(2, h - 2)
    write("Network: " .. getActiveNodeCount() .. " nodes connected")
end

local function drawAlarmScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    drawStatusBar()
    
    -- Back button
    term.setTextColor(colors.cyan)
    term.setCursorPos(2, 3)
    write("< BACK")
    
    -- Title with decorative elements
    term.setTextColor(colors.red)
    term.setCursorPos(2, 5)
    write("!!! EMERGENCY ALERT !!!")
    
    if warning_active then
        term.setTextColor(colors.red)
        term.setCursorPos(2, 7)
        write(">> ALARM ACTIVE <<")
        term.setTextColor(colors.yellow)
        term.setCursorPos(2, 8)
        write("Type: " .. string.upper(current_alarm_type))
        
        -- Time since alarm started
        if alarm_start_time then
            local elapsed = os.time() - alarm_start_time
            term.setCursorPos(2, 9)
            write("Active for: " .. math.floor(elapsed) .. " seconds")
        end
        
        -- Cancel button
        drawAppIcon(3, 12, 15, 4, colors.red, colors.white, "CANCEL", "STOP ALARM")
    else
        term.setTextColor(colors.white)
        term.setCursorPos(2, 7)
        write("Select alarm type:")
        
        -- Alarm type buttons
        drawAppIcon(3, 10, 15, 4, colors.orange, colors.black, "/\\", "GENERAL ALERT")
        drawAppIcon(3, 15, 15, 4, colors.red, colors.white, "!!", "EVACUATION")
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
    write("=== MESSAGES ===")
    
    if #recent_messages == 0 then
        term.setTextColor(colors.gray)
        term.setCursorPos(2, 8)
        write("[ No messages ]")
    else
        local y = 7
        for i = math.max(1, #recent_messages - 4), #recent_messages do
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
    write("=== SETTINGS ===")
    
    -- Silent Mode toggle
    term.setCursorPos(2, 8)
    write("Silent Mode:")
    local w = term.getSize()
    term.setCursorPos(w - 8, 8)
    if terminal_features.silent_mode then
        term.setTextColor(colors.green)
        write("[ ON ]")
    else
        term.setTextColor(colors.red)
        write("[ OFF ]")
    end
    
    -- Device Name
    term.setTextColor(colors.white)
    term.setCursorPos(2, 10)
    write("Device Name:")
    term.setTextColor(colors.cyan)
    term.setCursorPos(w - 8, 10)
    write("[ EDIT ]")
    
    -- Device info box
    term.setTextColor(colors.gray)
    term.setCursorPos(2, 13)
    write("+-----------------+")
    term.setCursorPos(2, 14)
    write("| ID: " .. string.format("%-11s", computer_id) .. "|")
    term.setCursorPos(2, 15)
    local device_type = is_terminal and "Terminal" or "Computer"
    write("| Type: " .. string.format("%-9s", device_type) .. "|")
    term.setCursorPos(2, 16)
    write("+-----------------+")
end

local function handleTouch(x, y)
    if gui_state.current_screen == "home" then
        if isInBounds(x, y, 3, 11, 10, 4) then
            gui_state.current_screen = "alarm_trigger"
            return true
        elseif isInBounds(x, y, 15, 11, 10, 4) then
            gui_state.current_screen = "messages"
            unread_message_count = 0
            return true
        elseif isInBounds(x, y, 3, 16, 10, 4) then
            gui_state.current_screen = "settings"
            return true
        end
    elseif gui_state.current_screen == "alarm_trigger" then
        if isInBounds(x, y, 2, 3, 6, 1) then
            gui_state.current_screen = "home"
            return true
        elseif warning_active and isInBounds(x, y, 3, 12, 15, 4) then
            stopAlarm()
            gui_state.current_screen = "home"
            return true
        elseif not warning_active then
            if isInBounds(x, y, 3, 10, 15, 4) then
                startAlarm("general")
                gui_state.current_screen = "home"
                return true
            elseif isInBounds(x, y, 3, 15, 15, 4) then
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
        elseif y == 8 then
            terminal_features.silent_mode = not terminal_features.silent_mode
            return true
        elseif y == 10 then
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
                drawScreen()
            elseif keyCode == keys.e then
                startAlarm("evacuation")
                drawScreen()
            elseif keyCode == keys.s then
                showStatus()
            elseif keyCode == keys.n then
                changeName()
            elseif keyCode == keys.q and is_terminal then
                print("Terminal shutting down...")
                break
            elseif not warning_active and not is_terminal then
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
            end
        end
    end
end

main()
