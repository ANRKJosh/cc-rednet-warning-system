-- PoggishTown Phone System v2.0
-- Modern messaging and communication system
-- Protocol: pogphone (separate from security system)

local PHONE_PROTOCOL = "pogphone"
local SECURITY_PROTOCOL = "pogalert"  -- Add security protocol
local CONFIG_FILE = "pogphone_config"
local CONTACTS_FILE = "pogphone_contacts"
local MESSAGES_FILE = "pogphone_messages"

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

-- Configuration
local config = {
    username = nil,
    server_id = nil,  -- Will auto-discover servers
    auto_connect = true,
    message_history_limit = 100,
    notification_sound = true,
    vibrate_on_message = true,
    compact_mode = false,
    update_url = "https://raw.githubusercontent.com/your-repo/poggishtown-phone.lua",
    -- Security integration
    security_password = "poggishtown2025",  -- Default security password
    allow_emergency_alerts = true           -- Allow sending emergency alerts
}

-- Global state
local computer_id = os.getComputerID()
local is_terminal = isWirelessTerminal()
local modem_side = nil
local speaker = peripheral.find("speaker")

local connected_servers = {}
local online_users = {}
local contacts = {}
local messages = {}
local unread_count = 0
local current_screen = "main"
local selected_contact = nil
local security_nodes = {}  -- Track security system nodes
local active_alarms = {}   -- Track active alarms

-- Data management
local function loadData()
    -- Load config
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
    
    -- Load contacts
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
    
    -- Load messages
    if fs.exists(MESSAGES_FILE) then
        local file = fs.open(MESSAGES_FILE, "r")
        if file then
            local content = file.readAll()
            file.close()
            local success, data = pcall(textutils.unserialize, content)
            if success and data then
                messages = data
                -- Count unread messages
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
    -- Save config
    local file = fs.open(CONFIG_FILE, "w")
    if file then
        file.write(textutils.serialize(config))
        file.close()
    end
    
    -- Save contacts
    file = fs.open(CONTACTS_FILE, "w")
    if file then
        file.write(textutils.serialize(contacts))
        file.close()
    end
    
    -- Save messages (keep only recent ones)
    local recent_messages = {}
    for i = math.max(1, #messages - config.message_history_limit + 1), #messages do
        table.insert(recent_messages, messages[i])
    end
    messages = recent_messages
    
    file = fs.open(MESSAGES_FILE, "w")
    if file then
        file.write(textutils.serialize(messages))
        file.close()
    end
end

-- Modem setup
local function initializeModem()
    -- Assume ender modem for terminals, find any modem for computers
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            return true
        end
    end
    return false
end

-- Security integration functions
local function hashPassword(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 1000000
    end
    return tostring(hash)
end

local function sendSecurityAlert(alarm_type)
    if not config.allow_emergency_alerts then
        return false, "Emergency alerts disabled"
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
        password_hash = hashPassword(config.security_password)
    }
    
    rednet.broadcast(message, SECURITY_PROTOCOL)
    return true, "Alert sent"
end

local function sendSecurityCancel()
    if not config.allow_emergency_alerts then
        return false, "Emergency alerts disabled"
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
        password_hash = hashPassword(config.security_password)
    }
    
    rednet.broadcast(message, SECURITY_PROTOCOL)
    return true, "Cancel sent"
end

-- Username management
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

local function setUsername()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Setup Username ===")
    print("Current: " .. getUsername())
    print("")
    print("Enter new username:")
    
    local new_name = read()
    if new_name and new_name ~= "" then
        config.username = new_name
        saveData()
        print("Username set to: " .. new_name)
    else
        print("Username unchanged.")
    end
    sleep(1)
end

-- Contact management
local function addContact(id, name)
    contacts[id] = {
        name = name,
        id = id,
        added_time = os.time()
    }
    saveData()
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

-- Message handling
local function addMessage(from_id, to_id, content, msg_type)
    msg_type = msg_type or "direct"
    local message = {
        id = #messages + 1,
        from_id = from_id,
        to_id = to_id,
        content = content,
        timestamp = os.time(),
        read = (from_id == computer_id),  -- Mark as read if we sent it
        msg_type = msg_type
    }
    
    table.insert(messages, message)
    
    if to_id == computer_id and from_id ~= computer_id then
        unread_count = unread_count + 1
        if config.notification_sound and speaker then
            speaker.playNote("pling", 1.0, 5)
        end
        if config.vibrate_on_message and is_terminal then
            -- Terminal "vibration" effect
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

local function markMessagesRead(user_id)
    local marked = 0
    for _, msg in ipairs(messages) do
        if msg.from_id == user_id and msg.to_id == computer_id and not msg.read then
            msg.read = true
            marked = marked + 1
        end
    end
    unread_count = math.max(0, unread_count - marked)
    saveData()
end

-- Network communication
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
end

local function requestUserList()
    local message = {
        type = "user_list_request",
        from_id = computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(message, PHONE_PROTOCOL)
end

-- Message processing
local function handleMessage(sender_id, message, protocol)
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
            
        elseif message.type == "app_update_notification" then
            if message.app_name and message.download_url then
                print("UPDATE AVAILABLE: " .. message.app_name)
                print("URL: " .. message.download_url)
            end
        end
        
    elseif protocol == SECURITY_PROTOCOL then
        -- Handle security system messages
        if message.type == "security_alert" then
            if message.password_hash == hashPassword(config.security_password) then
                if message.action == "start" then
                    active_alarms[message.source_id] = {
                        type = message.alarm_type or "general",
                        source_name = message.source_name or ("Node-" .. message.source_id),
                        start_time = message.timestamp or os.time()
                    }
                    
                    -- Notification for security alerts
                    if config.notification_sound and speaker then
                        speaker.playNote("pling", 3.0, 12)  -- High pitched alert
                    end
                    if config.vibrate_on_message and is_terminal then
                        -- More intense vibration for security alerts
                        local original_bg = term.getBackgroundColor()
                        for i = 1, 4 do
                            term.setBackgroundColor(colors.red)
                            term.clear()
                            sleep(0.05)
                            term.setBackgroundColor(original_bg)
                            term.clear()
                            sleep(0.05)
                        end
                    end
                    
                elseif message.action == "stop" then
                    active_alarms[message.source_id] = nil
                end
            end
            
        elseif message.type == "security_heartbeat" then
            if message.password_hash == hashPassword(config.security_password) then
                security_nodes[message.computer_id] = {
                    device_name = message.device_name or ("Node-" .. message.computer_id),
                    device_type = message.device_type or "computer",
                    last_seen = os.time(),
                    alarm_active = message.alarm_active,
                    alarm_type = message.alarm_type
                }
                
                -- Update active alarms from heartbeat
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
end

-- User interface screens
local function drawHeader()
    print("=== POGGISHTOWN PHONE ===")
    print("User: " .. getUsername() .. " | ID: " .. computer_id)
    if unread_count > 0 then
        term.setTextColor(colors.yellow)
        print("Unread: " .. unread_count .. " messages")
        term.setTextColor(colors.white)
    end
    print("")
end

local function drawMainScreen()
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    
    -- Show active alarms prominently
    local alarm_count = 0
    for _ in pairs(active_alarms) do alarm_count = alarm_count + 1 end
    
    if alarm_count > 0 then
        term.setTextColor(colors.red)
        print("!!! " .. alarm_count .. " ACTIVE ALARMS !!!")
        term.setTextColor(colors.white)
        print("")
    end
    
    print("Main Menu:")
    print("1. Messages (" .. unread_count .. " unread)")
    print("2. Contacts (" .. #contacts .. " saved)")
    print("3. Online Users")
    print("4. Emergency Alerts")  -- New option
    print("5. Settings")
    print("6. About")
    if is_terminal then
        print("Q. Quit")
    end
    print("")
    print("Enter choice:")
end

local function drawMessagesScreen()
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    
    if #messages == 0 then
        print("No messages yet.")
        print("")
        print("M. New Message | B. Back")
        return
    end
    
    -- Group messages by conversation
    local conversations = {}
    for _, msg in ipairs(messages) do
        local other_user = (msg.from_id == computer_id) and msg.to_id or msg.from_id
        if not conversations[other_user] then
            conversations[other_user] = {
                user_id = other_user,
                messages = {},
                last_message_time = 0,
                unread_count = 0
            }
        end
        table.insert(conversations[other_user].messages, msg)
        conversations[other_user].last_message_time = math.max(conversations[other_user].last_message_time, msg.timestamp)
        if msg.to_id == computer_id and not msg.read then
            conversations[other_user].unread_count = conversations[other_user].unread_count + 1
        end
    end
    
    -- Convert to sorted list
    local conv_list = {}
    for user_id, conv in pairs(conversations) do
        table.insert(conv_list, conv)
    end
    table.sort(conv_list, function(a, b) return a.last_message_time > b.last_message_time end)
    
    print("Conversations:")
    for i, conv in ipairs(conv_list) do
        local name = getContactName(conv.user_id)
        local unread_indicator = conv.unread_count > 0 and (" (" .. conv.unread_count .. ")") or ""
        local time_str = textutils.formatTime(conv.last_message_time, true)
        
        if conv.unread_count > 0 then
            term.setTextColor(colors.yellow)
        end
        print(i .. ". " .. name .. unread_indicator .. " - " .. time_str)
        term.setTextColor(colors.white)
    end
    
    print("")
    print("Enter number to open, M for new message, B to go back:")
end

local function drawEmergencyScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== EMERGENCY ALERTS ===")
    print("User: " .. getUsername())
    print("")
    
    -- Show active alarms
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
    
    if config.allow_emergency_alerts then
        print("Send Alert:")
        print("G - General Alert")
        print("E - Evacuation Alert")
        print("L - Lockdown Alert")
        if alarm_count > 0 then
            print("C - Cancel All Alarms")
        end
        print("")
    else
        term.setTextColor(colors.yellow)
        print("Emergency alerts disabled")
        term.setTextColor(colors.white)
        print("")
    end
    
    print("R - Refresh | B - Back")
end

local function handleEmergencyScreenInput()
    local input = read()
    
    if input:lower() == "b" then
        current_screen = "main"
    elseif input:lower() == "r" then
        -- Refresh by staying on same screen
        return
    elseif config.allow_emergency_alerts then
        if input:lower() == "g" then
            local success, message = sendSecurityAlert("general")
            print("")
            if success then
                print("GENERAL ALERT SENT!")
            else
                print("Failed: " .. message)
            end
            sleep(2)
        elseif input:lower() == "e" then
            local success, message = sendSecurityAlert("evacuation")
            print("")
            if success then
                print("EVACUATION ALERT SENT!")
            else
                print("Failed: " .. message)
            end
            sleep(2)
        elseif input:lower() == "l" then
            local success, message = sendSecurityAlert("lockdown")
            print("")
            if success then
                print("LOCKDOWN ALERT SENT!")
            else
                print("Failed: " .. message)
            end
            sleep(2)
        elseif input:lower() == "c" then
            local success, message = sendSecurityCancel()
            print("")
            if success then
                print("CANCEL SIGNAL SENT!")
            else
                print("Failed: " .. message)
            end
            sleep(2)
        end
    end
end

local function drawSettingsScreen()
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    
    print("Settings:")
    print("1. Username: " .. getUsername())
    print("2. Notifications: " .. (config.notification_sound and "ON" or "OFF"))
    print("3. Vibrate: " .. (config.vibrate_on_message and "ON" or "OFF"))
    print("4. Compact Mode: " .. (config.compact_mode and "ON" or "OFF"))
    print("5. Emergency Alerts: " .. (config.allow_emergency_alerts and "ON" or "OFF"))
    print("6. Security Password: " .. string.rep("*", #config.security_password))
    print("7. Clear All Messages")
    print("8. Export Contacts")
    print("B. Back")
    print("")
    print("Enter choice:")
end

-- Input handling functions
local function handleMainScreenInput()
    local input = read()
    
    if input == "1" then
        current_screen = "messages"
    elseif input == "2" then
        current_screen = "contacts"
    elseif input == "3" then
        current_screen = "online_users"
        requestUserList()
    elseif input == "4" then
        current_screen = "emergency"
    elseif input == "5" then
        current_screen = "settings"
    elseif input == "6" then
        current_screen = "about"
    elseif input:lower() == "q" and is_terminal then
        return false  -- Quit
    end
    return true
end

local function handleMessagesScreenInput()
    local input = read()
    
    if input:lower() == "b" then
        current_screen = "main"
    elseif input:lower() == "m" then
        -- New message
        current_screen = "new_message"
    elseif tonumber(input) then
        -- Open conversation
        local conv_num = tonumber(input)
        -- Implementation would need conversation selection logic
        current_screen = "conversation"
    end
end

local function sendNewMessage()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== NEW MESSAGE ===")
    print("")
    
    -- Show online users
    local user_list = {}
    for id, user in pairs(online_users) do
        if id ~= computer_id then
            table.insert(user_list, {id = id, data = user})
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
    
    print("")
    print("Enter user number:")
    local user_choice = tonumber(read())
    
    if user_choice and user_choice >= 1 and user_choice <= #user_list then
        local target_user = user_list[user_choice]
        print("")
        print("To: " .. target_user.data.username)
        print("Message:")
        local message_content = read()
        
        if message_content and message_content ~= "" then
            sendDirectMessage(target_user.id, message_content)
            print("")
            print("Message sent!")
            sleep(1)
        end
    end
end

local function addNewContact()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== ADD CONTACT ===")
    print("")
    print("Enter user ID:")
    local user_id = tonumber(read())
    
    if user_id then
        print("Enter display name:")
        local display_name = read()
        
        if display_name and display_name ~= "" then
            addContact(user_id, display_name)
            print("Contact added!")
            sleep(1)
        end
    end
end

-- Main application loop
local function main()
    if not initializeModem() then
        print("ERROR: No modem found!")
        print("Please attach a wireless modem.")
        return
    end
    
    loadData()
    
    -- Initial setup if no username
    if not config.username then
        setUsername()
    end
    
    print("PoggishTown Phone Starting...")
    print("User: " .. getUsername())
    print("Device: " .. (is_terminal and "Terminal" or "Computer"))
    sleep(1)
    
    -- Send initial presence
    broadcastPresence()
    
    -- Request user list from servers
    requestUserList()
    
    current_screen = "main"
    
    -- Main event loop
    local presence_timer = os.startTimer(30)  -- Send presence every 30 seconds
    
    while true do
        -- Draw current screen
        if current_screen == "main" then
            drawMainScreen()
            if not handleMainScreenInput() then
                break  -- Quit requested
            end
        elseif current_screen == "messages" then
            drawMessagesScreen()
            handleMessagesScreenInput()
        elseif current_screen == "emergency" then
            drawEmergencyScreen()
            handleEmergencyScreenInput()
        elseif current_screen == "contacts" then
            term.clear()
            term.setCursorPos(1, 1)
            drawHeader()
            
            if next(contacts) == nil then
                print("No contacts saved.")
                print("")
                print("A. Add Contact | B. Back")
            else
                print("Contacts:")
                local contact_list = {}
                for id, contact in pairs(contacts) do
                    table.insert(contact_list, contact)
                end
                table.sort(contact_list, function(a, b) return a.name < b.name end)
                
                for i, contact in ipairs(contact_list) do
                    local online_status = online_users[contact.id] and " (Online)" or " (Offline)"
                    print(i .. ". " .. contact.name .. online_status)
                end
                
                print("")
                print("Enter number to message, A to add contact, B to go back:")
            end
            
            local input = read()
            if input:lower() == "b" then
                current_screen = "main"
            elseif input:lower() == "a" then
                addNewContact()
                current_screen = "contacts"
            end
        elseif current_screen == "online_users" then
            term.clear()
            term.setCursorPos(1, 1)
            drawHeader()
            
            if next(online_users) == nil then
                print("No users online.")
                print("")
                print("R. Refresh | B. Back")
            else
                print("Online Users:")
                local user_list = {}
                for id, user in pairs(online_users) do
                    if id ~= computer_id then  -- Don't show ourselves
                        table.insert(user_list, {id = id, data = user})
                    end
                end
                table.sort(user_list, function(a, b) return a.data.username < b.data.username end)
                
                for i, user in ipairs(user_list) do
                    local device_icon = user.data.device_type == "terminal" and "[T]" or "[C]"
                    print(i .. ". " .. device_icon .. " " .. user.data.username)
                end
                
                print("")
                print("Enter number to message, R to refresh, B to go back:")
            end
            
            local input = read()
            if input:lower() == "b" then
                current_screen = "main"
            elseif input:lower() == "r" then
                requestUserList()
            elseif tonumber(input) then
                current_screen = "new_message"
            end
        elseif current_screen == "new_message" then
            sendNewMessage()
            current_screen = "messages"
        elseif current_screen == "settings" then
            drawSettingsScreen()
            local input = read()
            if input:lower() == "b" then
                current_screen = "main"
            elseif input == "1" then
                setUsername()
            elseif input == "2" then
                config.notification_sound = not config.notification_sound
                saveData()
            elseif input == "3" then
                config.vibrate_on_message = not config.vibrate_on_message
                saveData()
            elseif input == "4" then
                config.compact_mode = not config.compact_mode
                saveData()
            elseif input == "5" then
                config.allow_emergency_alerts = not config.allow_emergency_alerts
                saveData()
                print("")
                print("Emergency alerts " .. (config.allow_emergency_alerts and "enabled" or "disabled"))
                sleep(1)
            elseif input == "6" then
                print("")
                print("Enter new security password:")
                local new_pass = read("*")
                if new_pass and new_pass ~= "" then
                    config.security_password = new_pass
                    saveData()
                    print("Security password updated!")
                    sleep(1)
                end
            elseif input == "7" then
                messages = {}
                unread_count = 0
                saveData()
                print("All messages cleared!")
                sleep(1)
            end
        elseif current_screen == "about" then
            term.clear()
            term.setCursorPos(1, 1)
            print("=== ABOUT ===")
            print("PoggishTown Phone v2.0")
            print("Modern messaging system")
            print("")
            print("Features:")
            print("- Direct messaging")
            print("- Contact management")
            print("- Emergency alerts")
            print("- Security integration")
            print("- Server connectivity")
            print("")
            print("Emergency Features:")
            print("- Send security alerts")
            print("- Monitor alarm status")
            print("- Cancel active alarms")
            print("")
            print("Press any key to return...")
            os.pullEvent("key")
            current_screen = "main"
        end
        
        -- Handle background events
        parallel.waitForAny(
            function()
                while true do
                    local event, param1, param2, param3 = os.pullEvent()
                    
                    if event == "rednet_message" then
                        local sender_id, message, protocol = param1, param2, param3
                        if protocol == PHONE_PROTOCOL or protocol == SECURITY_PROTOCOL then
                            handleMessage(sender_id, message, protocol)
                        end
                    elseif event == "timer" and param1 == presence_timer then
                        broadcastPresence()
                        presence_timer = os.startTimer(30)
                    end
                end
            end,
            function()
                sleep(0.1)  -- Short sleep for responsiveness
            end
        )
    end
    
    print("PoggishTown Phone shutting down...")
    saveData()
end

-- Run the application
main()
