-- PogiMobile v2.0 - Complete Communication System
-- Built from working minimal authentication

local PHONE_PROTOCOL = "pogphone"
local SECURITY_PROTOCOL = "pogalert"
local CONFIG_FILE = "pogimobile_config"
local CONTACTS_FILE = "pogimobile_contacts"
local MESSAGES_FILE = "pogimobile_messages"

-- Device detection
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

-- Global state
local computer_id = os.getComputerID()
local is_terminal = isWirelessTerminal()
local speaker = peripheral.find("speaker")

-- Configuration
local config = {
    username = nil,
    notification_sound = true,
    vibrate_on_message = true,
    message_history_limit = 100
}

-- State
local authenticated = false
local auth_expires = 0
local contacts = {}
local messages = {}
local online_users = {}
local active_alarms = {}
local security_nodes = {}
local connected_servers = {}
local unread_count = 0

-- Debug
local debug_log = {}

local function addDebugLog(message)
    table.insert(debug_log, textutils.formatTime(os.time(), true) .. " " .. message)
    if #debug_log > 10 then
        table.remove(debug_log, 1)
    end
end

-- Data management
local function loadData()
    if fs.exists(CONFIG_FILE) then
        local file = fs.open(CONFIG_FILE, "r")
        if file then
            local content = file.readAll()
            file.close()
            local success, data = pcall(textutils.unserialize, content)
            if success and data then
                for key, value in pairs(data) do
                    if config[key] ~= nil then
                        config[key] = value
                    end
                end
            end
        end
    end
    
    if fs.exists(CONTACTS_FILE) then
        local file = fs.open(CONTACTS_FILE, "r")
        if file then
            local content = file.readAll()
            file.close()
            local success, data = pcall(textutils.unserialize, content)
            if success and data then
                contacts = data
            end
        end
    end
    
    if fs.exists(MESSAGES_FILE) then
        local file = fs.open(MESSAGES_FILE, "r")
        if file then
            local content = file.readAll()
            file.close()
            local success, data = pcall(textutils.unserialize, content)
            if success and data then
                messages = data
                unread_count = 0
                for _, msg in ipairs(messages) do
                    if not msg.read and msg.to_id == computer_id then
                        unread_count = unread_count + 1
                    end
                end
            end
        end
    end
end

local function saveData()
    local file = fs.open(CONFIG_FILE, "w")
    if file then
        file.write(textutils.serialize(config))
        file.close()
    end
    
    local file2 = fs.open(CONTACTS_FILE, "w")
    if file2 then
        file2.write(textutils.serialize(contacts))
        file2.close()
    end
    
    local recent_messages = {}
    for i = math.max(1, #messages - config.message_history_limit + 1), #messages do
        table.insert(recent_messages, messages[i])
    end
    messages = recent_messages
    
    local file3 = fs.open(MESSAGES_FILE, "w")
    if file3 then
        file3.write(textutils.serialize(messages))
        file3.close()
    end
end

-- Utility functions
local function hashPassword(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 1000000
    end
    return tostring(hash)
end

local function getUsername()
    if config.username then
        return config.username
    end
    local label = os.getComputerLabel()
    if label then
        return label
    end
    return (is_terminal and "Terminal-" or "Computer-") .. computer_id
end

local function isAuthenticated()
    return authenticated and os.time() < auth_expires
end

local function getContactName(id)
    if contacts[id] then
        return contacts[id].name
    end
    if online_users[id] then
        return online_users[id].username
    end
    return "User-" .. id
end

-- Initialize modem
local function initModem()
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            addDebugLog("Modem opened on " .. side)
            return true
        end
    end
    print("ERROR: No modem found!")
    return false
end

-- Authentication
local function authenticate(password)
    addDebugLog("Sending auth request for user " .. computer_id)
    
    local message = {
        type = "security_auth_request",
        password_hash = hashPassword(password),
        user_id = computer_id,
        username = getUsername(),
        timestamp = os.time()
    }
    
    rednet.broadcast(message, PHONE_PROTOCOL)
    
    print("Waiting for server response...")
    local start_time = os.clock()
    
    while (os.clock() - start_time) < 10 do
        local sender_id, response, protocol = rednet.receive(nil, 1)
        
        if sender_id and protocol == PHONE_PROTOCOL then
            if response.type == "security_auth_response" and response.target_user_id == computer_id then
                addDebugLog("Received auth response: " .. tostring(response.authenticated))
                
                if response.authenticated then
                    authenticated = true
                    auth_expires = response.expires or (os.time() + 3600)
                    print("✓ Authentication successful!")
                    return true
                else
                    print("✗ Authentication failed!")
                    return false
                end
                
            elseif response.type == "server_announcement" and response.auth_result_for_user == computer_id then
                addDebugLog("Received disguised auth response: " .. tostring(response.auth_success))
                
                if response.auth_success then
                    authenticated = true
                    auth_expires = response.auth_expires or (os.time() + 3600)
                    print("✓ Authentication successful!")
                    return true
                else
                    print("✗ Authentication failed!")
                    return false
                end
            end
        end
        
        print("Waiting... " .. math.floor(os.clock() - start_time) .. "s")
    end
    
    print("✗ Authentication timeout")
    return false
end

-- Messaging
local function addMessage(from_id, to_id, content, msg_type)
    msg_type = msg_type or "direct"
    local message = {
        id = #messages + 1,
        from_id = from_id,
        to_id = to_id,
        content = content,
        timestamp = os.time(),
        read = (from_id == computer_id),
        msg_type = msg_type
    }
    
    table.insert(messages, message)
    
    if to_id == computer_id and from_id ~= computer_id then
        unread_count = unread_count + 1
        if config.notification_sound and speaker then
            speaker.playNote("pling", 1.0, 5)
        end
        if config.vibrate_on_message and is_terminal then
            local original_bg = term.getBackgroundColor()
            for i = 1, 2 do
                term.setBackgroundColor(colors.white)
                term.clear()
                sleep(0.1)
                term.setBackgroundColor(original_bg)
                term.clear()
                sleep(0.1)
            end
        end
    end
    
    saveData()
    return message
end

local function sendDirectMessage(to_id, content)
    local message = {
        type = "direct_message",
        from_id = computer_id,
        from_username = getUsername(),
        to_id = to_id,
        content = content,
        timestamp = os.time(),
        message_id = computer_id .. "_" .. os.time() .. "_" .. math.random(1000, 9999)
    }
    
    rednet.broadcast(message, PHONE_PROTOCOL)
    addMessage(computer_id, to_id, content, "direct")
    addDebugLog("Sent message to user " .. to_id)
end

-- Emergency alerts
local function sendSecurityAlert(alarm_type)
    if not isAuthenticated() then
        return false, "Not authenticated"
    end
    
    local message = {
        type = "security_alert",
        action = "start",
        alarm_type = alarm_type,
        source_id = computer_id,
        source_name = getUsername(),
        origin_id = computer_id,
        timestamp = os.time(),
        message_id = computer_id .. "_" .. os.time() .. "_" .. math.random(1000, 9999),
        hops = 0,
        device_type = is_terminal and "terminal" or "computer",
        authenticated_user = true
    }
    
    rednet.broadcast(message, SECURITY_PROTOCOL)
    
    active_alarms[computer_id] = {
        type = alarm_type,
        source_name = getUsername(),
        start_time = os.time()
    }
    
    addDebugLog("Sent " .. alarm_type .. " alert")
    return true, "Alert sent"
end

local function sendSecurityCancel()
    if not isAuthenticated() then
        return false, "Not authenticated"
    end
    
    local message = {
        type = "security_alert",
        action = "stop",
        source_id = computer_id,
        source_name = getUsername(),
        origin_id = computer_id,
        timestamp = os.time(),
        message_id = computer_id .. "_" .. os.time() .. "_" .. math.random(1000, 9999),
        hops = 0,
        device_type = is_terminal and "terminal" or "computer",
        authenticated_user = true
    }
    
    rednet.broadcast(message, SECURITY_PROTOCOL)
    active_alarms = {}
    addDebugLog("Sent cancel signal")
    return true, "Cancel sent"
end

-- Network functions
local function broadcastPresence()
    local message = {
        type = "user_presence",
        user_id = computer_id,
        username = getUsername(),
        device_type = is_terminal and "terminal" or "computer",
        timestamp = os.time()
    }
    rednet.broadcast(message, PHONE_PROTOCOL)
end

local function requestUserList()
    local message = {
        type = "user_list_request",
        from_id = computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(message, PHONE_PROTOCOL)
end

-- Process background messages (non-blocking)
local function processBackgroundMessages()
    local sender_id, message, protocol = rednet.receive(nil, 0.1) -- 0.1 second timeout
    
    if not sender_id then
        return -- No message
    end
    
    addDebugLog("Received: " .. protocol .. "/" .. (message.type or "unknown") .. " from " .. sender_id)
    
    if protocol == PHONE_PROTOCOL then
        if message.type == "user_presence" then
            online_users[message.user_id] = {
                username = message.username,
                device_type = message.device_type,
                last_seen = os.time()
            }
            
        elseif message.type == "direct_message" then
            if message.to_id == computer_id and message.from_id ~= computer_id then
                addMessage(message.from_id, message.to_id, message.content, "direct")
            end
            
        elseif message.type == "server_announcement" then
            connected_servers[sender_id] = {
                name = message.server_name or "Server-" .. sender_id,
                last_seen = os.time(),
                capabilities = message.capabilities or {}
            }
            
        elseif message.type == "user_list_response" then
            if message.users then
                for user_id, user_data in pairs(message.users) do
                    online_users[user_id] = user_data
                end
            end
        end
        
    elseif protocol == SECURITY_PROTOCOL then
        -- Skip our own messages
        if message.original_sender == computer_id or (sender_id == computer_id and not message.relayed_by_server) then
            return
        end
        
        if message.type == "security_alert" then
            if message.action == "start" then
                local source_id = message.source_id or message.original_sender or sender_id
                active_alarms[source_id] = {
                    type = message.alarm_type or "general",
                    source_name = message.source_name or ("Node-" .. source_id),
                    start_time = message.timestamp or os.time()
                }
                
                if config.notification_sound and speaker then
                    speaker.playNote("pling", 3.0, 12)
                end
                if config.vibrate_on_message and is_terminal then
                    local original_bg = term.getBackgroundColor()
                    for i = 1, 3 do
                        term.setBackgroundColor(colors.red)
                        term.clear()
                        sleep(0.05)
                        term.setBackgroundColor(original_bg)
                        term.clear()
                        sleep(0.05)
                    end
                end
                
            elseif message.action == "stop" then
                if message.global_cancel then
                    active_alarms = {}
                else
                    local source_id = message.source_id or message.original_sender or sender_id
                    active_alarms[source_id] = nil
                end
            end
            
        elseif message.type == "security_heartbeat" then
            security_nodes[message.computer_id] = {
                device_name = message.device_name or ("Node-" .. message.computer_id),
                device_type = message.device_type or "computer",
                last_seen = os.time(),
                alarm_active = message.alarm_active,
                alarm_type = message.alarm_type
            }
            
            if message.alarm_active then
                active_alarms[message.computer_id] = {
                    type = message.alarm_type or "general",
                    source_name = message.device_name or ("Node-" .. message.computer_id),
                    start_time = message.alarm_start_time or os.time()
                }
            else
                active_alarms[message.computer_id] = nil
            end
        end
    end
end

-- UI Screens
local function showMainMenu()
    term.clear()
    term.setCursorPos(1, 1)
    
    print("=== POGIMOBILE v2.0 ===")
    print("User: " .. getUsername() .. " | ID: " .. computer_id)
    
    if unread_count > 0 then
        term.setTextColor(colors.yellow)
        print("Unread: " .. unread_count .. " messages")
        term.setTextColor(colors.white)
    end
    
    local alarm_count = 0
    for _ in pairs(active_alarms) do alarm_count = alarm_count + 1 end
    
    if alarm_count > 0 then
        term.setTextColor(colors.red)
        print("!!! " .. alarm_count .. " ACTIVE ALARMS !!!")
        term.setTextColor(colors.white)
    end
    
    print("\nStatus: " .. (isAuthenticated() and "AUTHENTICATED" or "NOT AUTHENTICATED"))
    if isAuthenticated() then
        local remaining = auth_expires - os.time()
        print("Expires: " .. math.floor(remaining / 60) .. " minutes")
    end
    
    print("\nMain Menu:")
    print("1. Messages (" .. unread_count .. " unread)")
    print("2. Send Message")
    print("3. Online Users")
    print("4. Emergency Alerts" .. (alarm_count > 0 and " (!)" or ""))
    print("5. Authenticate")
    print("6. Settings")
    print("7. Debug Info")
    if is_terminal then
        print("Q. Quit")
    end
    print("\nEnter choice:")
end

local function showMessages()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== MESSAGES ===")
    
    if #messages == 0 then
        print("No messages")
    else
        local recent_messages = {}
        for i = math.max(1, #messages - 9), #messages do
            table.insert(recent_messages, messages[i])
        end
        
        for _, msg in ipairs(recent_messages) do
            local time_str = textutils.formatTime(msg.timestamp, true)
            local from_name = getContactName(msg.from_id)
            local to_name = getContactName(msg.to_id)
            
            if msg.from_id == computer_id then
                print("[" .. time_str .. "] To " .. to_name .. ": " .. msg.content)
            else
                if not msg.read then
                    term.setTextColor(colors.yellow)
                    print("[" .. time_str .. "] " .. from_name .. ": " .. msg.content .. " (NEW)")
                    term.setTextColor(colors.white)
                    msg.read = true
                    unread_count = math.max(0, unread_count - 1)
                else
                    print("[" .. time_str .. "] " .. from_name .. ": " .. msg.content)
                end
            end
        end
        saveData()
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
end

local function sendNewMessage()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SEND MESSAGE ===")
    
    local user_list = {}
    for id, user in pairs(online_users) do
        if id ~= computer_id then
            table.insert(user_list, {id = id, data = user})
        end
    end
    
    if #user_list == 0 then
        print("No users online. Requesting user list...")
        requestUserList()
        print("Waiting for user list...")
        
        local start_time = os.clock()
        while (os.clock() - start_time) < 5 do
            processBackgroundMessages()
        end
        
        user_list = {}
        for id, user in pairs(online_users) do
            if id ~= computer_id then
                table.insert(user_list, {id = id, data = user})
            end
        end
    end
    
    if #user_list == 0 then
        print("No users online.")
        print("Press any key to return...")
        os.pullEvent("key")
        return
    end
    
    print("Online Users:")
    for i, user in ipairs(user_list) do
        print(i .. ". " .. user.data.username)
    end
    
    print("\nEnter user number:")
    local user_choice = tonumber(read())
    
    if user_choice and user_choice >= 1 and user_choice <= #user_list then
        local target_user = user_list[user_choice]
        print("To: " .. target_user.data.username)
        print("Message:")
        local message_content = read()
        
        if message_content and message_content ~= "" then
            sendDirectMessage(target_user.id, message_content)
            print("Message sent!")
            sleep(1)
        end
    end
end

local function showOnlineUsers()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== ONLINE USERS ===")
    
    requestUserList()
    print("Requesting user list...")
    
    local start_time = os.clock()
    while (os.clock() - start_time) < 3 do
        processBackgroundMessages()
    end
    
    local count = 0
    for user_id, user_data in pairs(online_users) do
        if user_id ~= computer_id then
            count = count + 1
            local time_ago = os.time() - user_data.last_seen
            print(user_data.username .. " (" .. user_data.device_type .. ") - " .. time_ago .. "s ago")
        end
    end
    
    if count == 0 then
        print("No other users online")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
end

local function showEmergencyAlerts()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== EMERGENCY ALERTS ===")
    print("User: " .. getUsername())
    print("Auth: " .. (isAuthenticated() and "YES" or "NO"))
    print("")
    
    local alarm_count = 0
    for source_id, alarm_data in pairs(active_alarms) do
        alarm_count = alarm_count + 1
        term.setTextColor(colors.red)
        print("ACTIVE: " .. string.upper(alarm_data.type))
        term.setTextColor(colors.white)
        print("  From: " .. alarm_data.source_name)
        print("  Time: " .. textutils.formatTime(alarm_data.start_time, true))
        print("")
    end
    
    if alarm_count == 0 then
        term.setTextColor(colors.green)
        print("All Clear - No Active Alarms")
        term.setTextColor(colors.white)
        print("")
    end
    
    -- Show security nodes
    local node_count = 0
    for _ in pairs(security_nodes) do node_count = node_count + 1 end
    
    if node_count > 0 then
        print("Security Nodes (" .. node_count .. "):")
        for node_id, node_data in pairs(security_nodes) do
            local status = node_data.alarm_active and "[ALARM]" or "[OK]"
            local time_ago = os.time() - node_data.last_seen
            if time_ago < 60 then
                if node_data.alarm_active then
                    term.setTextColor(colors.red)
                else
                    term.setTextColor(colors.green)
                end
                print("  " .. node_data.device_name .. " " .. status)
                term.setTextColor(colors.white)
            end
        end
        print("")
    end
    
    if isAuthenticated() then
        print("Send Alert:")
        print("G - General | E - Evacuation | L - Lockdown")
        if alarm_count > 0 then
            print("C - Cancel All Alarms")
        end
        print("O - Logout")
    else
        print("I - Login to Send Alerts")
    end
    
    print("B - Back")
    print("\nEnter choice:")
    
    local input = read()
    
    if input:lower() == "b" then
        return
    elseif input:lower() == "i" and not isAuthenticated() then
        print("\nEnter password:")
        local password = read("*")
        if password and password ~= "" then
            authenticate(password)
        end
    elseif input:lower() == "o" and isAuthenticated() then
        authenticated = false
        auth_expires = 0
        print("\nLogged out")
        sleep(1)
    elseif isAuthenticated() then
        if input:lower() == "g" then
            local success, message = sendSecurityAlert("general")
            print("\n" .. (success and "GENERAL ALERT SENT!" or ("Failed: " .. message)))
            sleep(2)
        elseif input:lower() == "e" then
            local success, message = sendSecurityAlert("evacuation")
            print("\n" .. (success and "EVACUATION ALERT SENT!" or ("Failed: " .. message)))
            sleep(2)
        elseif input:lower() == "l" then
            local success, message = sendSecurityAlert("lockdown")
            print("\n" .. (success and "LOCKDOWN ALERT SENT!" or ("Failed: " .. message)))
            sleep(2)
        elseif input:lower() == "c" then
            local success, message = sendSecurityCancel()
            print("\n" .. (success and "CANCEL SIGNAL SENT!" or ("Failed: " .. message)))
            sleep(2)
        end
    end
end

local function showSettings()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SETTINGS ===")
    print("")
    print("1. Username: " .. getUsername())
    print("2. Notifications: " .. (config.notification_sound and "ON" or "OFF"))
    print("3. Vibrate: " .. (config.vibrate_on_message and "ON" or "OFF"))
    print("4. Clear Messages")
    print("B. Back")
    print("\nEnter choice:")
    
    local input = read()
    
    if input:lower() == "b" then
        return
    elseif input == "1" then
        print("\nEnter new username:")
        local new_name = read()
        if new_name and new_name ~= "" then
            config.username = new_name
            saveData()
            print("Username updated!")
        end
        sleep(1)
    elseif input == "2" then
        config.notification_sound = not config.notification_sound
        saveData()
        print("\nNotifications " .. (config.notification_sound and "enabled" or "disabled"))
        sleep(1)
    elseif input == "3" then
        config.vibrate_on_message = not config.vibrate_on_message
        saveData()
        print("\nVibrate " .. (config.vibrate_on_message and "enabled" or "disabled"))
        sleep(1)
    elseif input == "4" then
        messages = {}
        unread_count = 0
        saveData()
        print("\nAll messages cleared!")
        sleep(1)
    end
end

local function showDebugInfo()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== DEBUG INFO ===")
    print("Computer ID: " .. computer_id)
    print("Device Type: " .. (is_terminal and "Terminal" or "Computer"))
    print("Username: " .. getUsername())
    print("Authenticated: " .. tostring(isAuthenticated()))
    print("Active Alarms: " .. #active_alarms)
    print("Online Users: " .. #online_users)
    print("Stored Messages: " .. #messages)
    print("")
    
    print("Recent Debug Log:")
    for _, entry in ipairs(debug_log) do
        print("  " .. entry)
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
end

-- Main program
local function main()
    print("PogiMobile Starting...")
    
    if not initModem() then
        return
    end
    
    loadData()
    
    -- Send initial presence
    broadcastPresence()
    
    local last_presence = os.clock()
    
    while true do
        -- Process background messages
        processBackgroundMessages()
        
        -- Send presence every 30 seconds
        if os.clock() - last_presence > 30 then
            broadcastPresence()
            last_presence = os.clock()
        end
        
        showMainMenu()
        local choice = read()
        
        if choice == "1" then
            showMessages()
        elseif choice == "2" then
            sendNewMessage()
        elseif choice == "3" then
            showOnlineUsers()
        elseif choice == "4" then
            showEmergencyAlerts()
        elseif choice == "5" then
            print("\nEnter password:")
            local password = read("*")
            if password and password ~= "" then
                authenticate(password)
                sleep(2)
            end
        elseif choice == "6" then
            showSettings()
        elseif choice == "7" then
            showDebugInfo()
        elseif choice:lower() == "q" and is_terminal then
            break
        end
    end
    
    print("PogiMobile shutting down...")
    saveData()
end

-- Run the app
main()
