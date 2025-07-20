-- PogiMobile v2.1 - Complete Communication System
-- Fixed messaging system with proper background processing

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

-- Helper function to count table entries
local function tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
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
                    term.setTextColor(colors.green)
                    print("[OK] Authentication successful!")
                    term.setTextColor(colors.white)
                    return true
                else
                    term.setTextColor(colors.red)
                    print("[FAIL] Authentication failed!")
                    term.setTextColor(colors.white)
                    return false
                end
                
            elseif response.type == "server_announcement" and response.auth_result_for_user == computer_id then
                addDebugLog("Received disguised auth response: " .. tostring(response.auth_success))
                
                if response.auth_success then
                    authenticated = true
                    auth_expires = response.auth_expires or (os.time() + 3600)
                    term.setTextColor(colors.green)
                    print("[OK] Authentication successful!")
                    term.setTextColor(colors.white)
                    return true
                else
                    term.setTextColor(colors.red)
                    print("[FAIL] Authentication failed!")
                    term.setTextColor(colors.white)
                    return false
                end
            end
        end
        
        print("Waiting... " .. math.floor(os.clock() - start_time) .. "s")
    end
    
    term.setTextColor(colors.red)
    print("[TIMEOUT] Authentication timeout")
    term.setTextColor(colors.white)
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
        addDebugLog("RECEIVED_MSG: From " .. from_id .. " - " .. content)
        
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
    
    addDebugLog("SEND: Broadcasting message to " .. to_id .. ": " .. content)
    addDebugLog("SEND: Message ID: " .. message.message_id)
    
    rednet.broadcast(message, PHONE_PROTOCOL)
    addMessage(computer_id, to_id, content, "direct")
    addDebugLog("SEND: Message sent and stored locally")
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

-- FIXED: Continuous background message processing
local function handleMessage(sender_id, message, protocol)
    addDebugLog("RCV: " .. protocol .. "/" .. (message.type or "unknown") .. " from " .. sender_id)
    
    if protocol == PHONE_PROTOCOL then
        if message.type == "user_presence" then
            online_users[message.user_id] = {
                username = message.username,
                device_type = message.device_type,
                last_seen = os.time()
            }
            
        elseif message.type == "direct_message" then
            addDebugLog("MSG: Processing direct_message")
            addDebugLog("MSG: From " .. message.from_id .. " To " .. message.to_id .. " My ID " .. computer_id)
            addDebugLog("MSG: Content: " .. message.content)
            
            if message.to_id == computer_id then
                addDebugLog("MSG: Message is for me!")
                if message.from_id ~= computer_id then
                    addDebugLog("MSG: Not from myself - adding message")
                    addMessage(message.from_id, message.to_id, message.content, "direct")
                    -- Show immediate notification without emoji
                    print("\n[NEW] Message from " .. getContactName(message.from_id) .. "!")
                    if config.notification_sound and speaker then
                        speaker.playNote("pling", 1.0, 10)
                    end
                else
                    addDebugLog("MSG: Ignoring - message from myself")
                end
            else
                addDebugLog("MSG: Not for me - ignoring (for " .. message.to_id .. ")")
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
        else
            addDebugLog("RCV: Unhandled phone message: " .. (message.type or "unknown"))
        end
        
    elseif protocol == SECURITY_PROTOCOL then
        addDebugLog("SECURITY: Processing " .. (message.type or "unknown") .. " action=" .. (message.action or "none"))
        
        -- Skip our own messages
        if message.original_sender == computer_id then
            addDebugLog("SECURITY: Skipping - originally from us")
            return
        end
        
        if sender_id == computer_id and not message.relayed_by_server then
            addDebugLog("SECURITY: Skipping - direct loop from ourselves")
            return
        end
        
        if message.type == "security_alert" then
            if message.action == "start" then
                local source_id = message.source_id or message.original_sender or sender_id
                addDebugLog("SECURITY: Adding alarm from " .. source_id)
                
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
    else
        addDebugLog("RCV: Unknown protocol: " .. protocol)
    end
end

-- UI Screens
local function showMainMenu()
    term.clear()
    term.setCursorPos(1, 1)
    
    print("=== POGIMOBILE v2.1 ===")
    print("User: " .. getUsername() .. " | ID: " .. computer_id)
    
    if unread_count > 0 then
        term.setTextColor(colors.yellow)
        print("[NEW] " .. unread_count .. " unread messages")
        term.setTextColor(colors.white)
    end
    
    local alarm_count = tableCount(active_alarms)
    
    if alarm_count > 0 then
        term.setTextColor(colors.red)
        print("[ALERT] " .. alarm_count .. " ACTIVE ALARMS")
        term.setTextColor(colors.white)
    end
    
    print("\nMain Menu:")
    
    -- Messages with unread indicator
    if unread_count > 0 then
        term.setTextColor(colors.yellow)
        print("1. Messages (" .. unread_count .. " unread) [NEW]")
        term.setTextColor(colors.white)
    else
        print("1. Messages (" .. unread_count .. " unread)")
    end
    
    print("2. Send Message")
    print("3. Contacts")
    print("4. Online Users")
    
    -- Emergency alerts with status
    if alarm_count > 0 then
        term.setTextColor(colors.red)
        print("5. Emergency Alerts [" .. alarm_count .. " ACTIVE]")
        term.setTextColor(colors.white)
    elseif isAuthenticated() then
        term.setTextColor(colors.green)
        print("5. Emergency Alerts [AUTHENTICATED]")
        term.setTextColor(colors.white)
    else
        print("5. Emergency Alerts")
    end
    
    print("6. Settings")
    print("D. Debug Info")
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
        term.setTextColor(colors.gray)
        print("No messages yet")
        term.setTextColor(colors.white)
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end
    
    -- Show recent messages (last 12)
    local recent_messages = {}
    for i = math.max(1, #messages - 11), #messages do
        table.insert(recent_messages, messages[i])
    end
    
    print("Recent Messages:")
    print("================")
    
    for _, msg in ipairs(recent_messages) do
        local time_str = textutils.formatTime(msg.timestamp, true)
        local from_name = getContactName(msg.from_id)
        local to_name = getContactName(msg.to_id)
        
        if msg.from_id == computer_id then
            -- Message sent by us
            term.setTextColor(colors.lightBlue)
            print("[" .. time_str .. "] [SENT] To " .. to_name)
            term.setTextColor(colors.white)
            print("  " .. msg.content)
        else
            -- Message received
            if not msg.read then
                term.setTextColor(colors.yellow)
                print("[" .. time_str .. "] [NEW] From " .. from_name)
                term.setTextColor(colors.white)
                msg.read = true
                unread_count = math.max(0, unread_count - 1)
            else
                term.setTextColor(colors.green)
                print("[" .. time_str .. "] [RECEIVED] From " .. from_name)
                term.setTextColor(colors.white)
            end
            print("  " .. msg.content)
        end
        print("")
    end
    
    if #messages > 12 then
        term.setTextColor(colors.gray)
        print("(" .. (#messages - 12) .. " older messages not shown)")
        term.setTextColor(colors.white)
    end
    
    saveData() -- Save read status
    print("\nPress any key to return...")
    os.pullEvent("key")
end

local function sendNewMessage()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SEND MESSAGE ===")
    
    -- Show contacts first
    local contact_count = tableCount(contacts)
    
    if contact_count > 0 then
        print("Contacts:")
        local contact_list = {}
        for id, contact in pairs(contacts) do
            table.insert(contact_list, {id = id, contact = contact})
        end
        
        for i, item in ipairs(contact_list) do
            if online_users[item.id] then
                term.setTextColor(colors.green)
                print("C" .. i .. ". [ONLINE] " .. item.contact.name)
            else
                term.setTextColor(colors.red)
                print("C" .. i .. ". [OFFLINE] " .. item.contact.name)
            end
            term.setTextColor(colors.white)
        end
        print("")
    end
    
    -- Get online users
    local user_list = {}
    for id, user in pairs(online_users) do
        if id ~= computer_id then
            table.insert(user_list, {id = id, data = user})
        end
    end
    
    if #user_list == 0 then
        print("Getting online users...")
        requestUserList()
        
        local start_time = os.clock()
        while (os.clock() - start_time) < 3 do
            local sender_id, message, protocol = rednet.receive(nil, 0.5)
            if sender_id then
                handleMessage(sender_id, message, protocol)
            end
        end
        
        user_list = {}
        for id, user in pairs(online_users) do
            if id ~= computer_id then
                table.insert(user_list, {id = id, data = user})
            end
        end
    end
    
    if #user_list > 0 then
        print("Online Users:")
        for i, user in ipairs(user_list) do
            term.setTextColor(colors.green)
            print("U" .. i .. ". [ONLINE] " .. user.data.username)
            term.setTextColor(colors.white)
        end
        print("")
    end
    
    if contact_count == 0 and #user_list == 0 then
        term.setTextColor(colors.red)
        print("No contacts or online users found.")
        term.setTextColor(colors.white)
        print("Add contacts first or wait for users to come online.")
        print("\nPress any key to return...")
        os.pullEvent("key")
        return
    end
    
    print("Enter choice (C1-C" .. contact_count .. " for contacts, U1-U" .. #user_list .. " for online users):")
    print("Or B to go back")
    local choice = read()
    
    if choice:lower() == "b" then
        return
    end
    
    local target_id = nil
    local target_name = nil
    
    -- Parse contact choice
    if choice:sub(1,1):lower() == "c" then
        local contact_num = tonumber(choice:sub(2))
        if contact_num then
            local contact_list = {}
            for id, contact in pairs(contacts) do
                table.insert(contact_list, {id = id, contact = contact})
            end
            
            if contact_num >= 1 and contact_num <= #contact_list then
                target_id = contact_list[contact_num].id
                target_name = contact_list[contact_num].contact.name
            end
        end
    end
    
    -- Parse online user choice
    if choice:sub(1,1):lower() == "u" then
        local user_num = tonumber(choice:sub(2))
        if user_num and user_num >= 1 and user_num <= #user_list then
            target_id = user_list[user_num].id
            target_name = user_list[user_num].data.username
        end
    end
    
    if target_id and target_name then
        print("\nTo: " .. target_name)
        print("Message:")
        local message_content = read()
        
        if message_content and message_content ~= "" then
            sendDirectMessage(target_id, message_content)
            term.setTextColor(colors.green)
            print("[OK] Message sent!")
            term.setTextColor(colors.white)
            if not online_users[target_id] then
                term.setTextColor(colors.yellow)
                print("(Recipient is offline - message will be delivered when they come online)")
                term.setTextColor(colors.white)
            end
            sleep(2)
        end
    else
        term.setTextColor(colors.red)
        print("Invalid choice")
        term.setTextColor(colors.white)
        sleep(1)
    end
end

local function showContacts()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== CONTACTS ===")
    
    local contact_count = tableCount(contacts)
    
    if contact_count == 0 then
        term.setTextColor(colors.gray)
        print("No contacts saved.")
        term.setTextColor(colors.white)
        print("")
        print("A - Add Contact | B - Back")
    else
        print("Saved Contacts:")
        local contact_list = {}
        for id, contact in pairs(contacts) do
            table.insert(contact_list, {id = id, contact = contact})
        end
        
        for i, item in ipairs(contact_list) do
            if online_users[item.id] then
                term.setTextColor(colors.green)
                print(i .. ". " .. item.contact.name .. " (ID: " .. item.id .. ") [ONLINE]")
            else
                term.setTextColor(colors.red)
                print(i .. ". " .. item.contact.name .. " (ID: " .. item.id .. ") [OFFLINE]")
            end
            term.setTextColor(colors.white)
        end
        
        print("")
        print("1-" .. #contact_list .. " - Message Contact")
        print("A - Add Contact | D - Delete Contact | B - Back")
    end
    
    print("\nEnter choice:")
    local input = read()
    
    if input:lower() == "b" then
        return
    elseif input:lower() == "a" then
        -- Add contact
        print("\nAdd Contact")
        print("Enter contact's computer ID:")
        local contact_id = tonumber(read())
        
        if contact_id and contact_id ~= computer_id then
            print("Enter contact name:")
            local contact_name = read()
            
            if contact_name and contact_name ~= "" then
                contacts[contact_id] = {
                    name = contact_name,
                    id = contact_id,
                    added_time = os.time()
                }
                saveData()
                term.setTextColor(colors.green)
                print("[OK] Contact added!")
                term.setTextColor(colors.white)
                sleep(1)
            end
        else
            term.setTextColor(colors.red)
            print("Invalid ID")
            term.setTextColor(colors.white)
            sleep(1)
        end
        
    elseif input:lower() == "d" and contact_count > 0 then
        -- Delete contact
        print("\nDelete Contact")
        print("Enter contact number to delete:")
        local contact_num = tonumber(read())
        
        if contact_num and contact_num >= 1 and contact_num <= contact_count then
            local contact_list = {}
            for id, contact in pairs(contacts) do
                table.insert(contact_list, {id = id, contact = contact})
            end
            
            local to_delete = contact_list[contact_num]
            contacts[to_delete.id] = nil
            saveData()
            term.setTextColor(colors.green)
            print("[OK] Contact deleted!")
            term.setTextColor(colors.white)
            sleep(1)
        end
        
    else
        -- Try to message contact
        local contact_num = tonumber(input)
        if contact_num and contact_count > 0 then
            local contact_list = {}
            for id, contact in pairs(contacts) do
                table.insert(contact_list, {id = id, contact = contact})
            end
            
            if contact_num >= 1 and contact_num <= #contact_list then
                local target_contact = contact_list[contact_num]
                print("\nTo: " .. target_contact.contact.name)
                print("Message:")
                local message_content = read()
                
                if message_content and message_content ~= "" then
                    sendDirectMessage(target_contact.id, message_content)
                    term.setTextColor(colors.green)
                    print("[OK] Message sent to " .. target_contact.contact.name .. "!")
                    term.setTextColor(colors.white)
                    if not online_users[target_contact.id] then
                        term.setTextColor(colors.yellow)
                        print("(Contact is offline - message will be delivered when they come online)")
                        term.setTextColor(colors.white)
                    end
                    sleep(2)
                end
            end
        end
    end
end

local function showEmergencyAlerts()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== EMERGENCY ALERTS ===")
    print("User: " .. getUsername())
    if isAuthenticated() then
        term.setTextColor(colors.green)
        print("Auth: AUTHENTICATED")
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.red)
        print("Auth: NOT AUTHENTICATED")
        term.setTextColor(colors.white)
    end
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
    local node_count = tableCount(security_nodes)
    
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

local function showOnlineUsers()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== ONLINE USERS ===")
    
    requestUserList()
    print("Requesting user list...")
    
    local start_time = os.clock()
    while (os.clock() - start_time) < 3 do
        local sender_id, message, protocol = rednet.receive(nil, 0.5)
        if sender_id then
            handleMessage(sender_id, message, protocol)
        end
    end
    
    local count = 0
    for user_id, user_data in pairs(online_users) do
        if user_id ~= computer_id then
            count = count + 1
            local time_ago = os.time() - user_data.last_seen
            local contact_name = contacts[user_id] and (" (" .. contacts[user_id].name .. ")") or ""
            
            if user_data.device_type == "terminal" then
                term.setTextColor(colors.cyan)
                print("[T] " .. user_data.username .. contact_name .. " - " .. time_ago .. "s ago")
            else
                term.setTextColor(colors.blue)
                print("[C] " .. user_data.username .. contact_name .. " - " .. time_ago .. "s ago")
            end
            term.setTextColor(colors.white)
        end
    end
    
    if count == 0 then
        term.setTextColor(colors.gray)
        print("No other users online")
        term.setTextColor(colors.white)
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
end

local function showSettings()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SETTINGS ===")
    print("")
    print("User Settings:")
    print("1. Username: " .. getUsername())
    print("2. Notifications: " .. (config.notification_sound and "ON" or "OFF"))
    print("3. Vibrate: " .. (config.vibrate_on_message and "ON" or "OFF"))
    print("")
    print("Security:")
    if isAuthenticated() then
        term.setTextColor(colors.green)
        print("4. Emergency Auth: AUTHENTICATED")
        term.setTextColor(colors.white)
        local remaining = auth_expires - os.time()
        print("   Expires: " .. math.floor(remaining / 60) .. " minutes")
    else
        term.setTextColor(colors.red)
        print("4. Emergency Auth: NOT AUTHENTICATED")
        term.setTextColor(colors.white)
    end
    print("")
    print("Data:")
    print("5. Clear Messages")
    print("6. Debug Info")
    print("")
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
            term.setTextColor(colors.green)
            print("[OK] Username updated!")
            term.setTextColor(colors.white)
        end
        sleep(1)
    elseif input == "2" then
        config.notification_sound = not config.notification_sound
        saveData()
        term.setTextColor(colors.green)
        print("\n[OK] Notifications " .. (config.notification_sound and "enabled" or "disabled"))
        term.setTextColor(colors.white)
        sleep(1)
    elseif input == "3" then
        config.vibrate_on_message = not config.vibrate_on_message
        saveData()
        term.setTextColor(colors.green)
        print("\n[OK] Vibrate " .. (config.vibrate_on_message and "enabled" or "disabled"))
        term.setTextColor(colors.white)
        sleep(1)
    elseif input == "4" then
        if isAuthenticated() then
            print("\nOptions:")
            print("L - Logout")
            print("Any other key to cancel")
            local auth_input = read()
            if auth_input:lower() == "l" then
                authenticated = false
                auth_expires = 0
                term.setTextColor(colors.green)
                print("[OK] Logged out of emergency system")
                term.setTextColor(colors.white)
                sleep(1)
            end
        else
            print("\nEnter emergency system password:")
            local password = read("*")
            if password and password ~= "" then
                if authenticate(password) then
                    term.setTextColor(colors.green)
                    print("[OK] Emergency authentication successful!")
                    term.setTextColor(colors.white)
                else
                    term.setTextColor(colors.red)
                    print("[FAIL] Authentication failed!")
                    term.setTextColor(colors.white)
                end
                sleep(2)
            end
        end
    elseif input == "5" then
        print("\nClear all messages? (y/N)")
        local confirm = read()
        if confirm:lower() == "y" then
            messages = {}
            unread_count = 0
            saveData()
            term.setTextColor(colors.green)
            print("[OK] All messages cleared!")
            term.setTextColor(colors.white)
        else
            print("Cancelled")
        end
        sleep(1)
    elseif input == "6" then
        showDebugInfo()
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
    print("Active Alarms: " .. tableCount(active_alarms))
    print("Online Users: " .. tableCount(online_users))
    print("Stored Messages: " .. #messages)
    print("")
    
    print("Recent Debug Log:")
    if #debug_log > 0 then
        for _, entry in ipairs(debug_log) do
            print("  " .. entry)
        end
    else
        print("  No debug entries")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
end

-- FIXED: Main program with proper background message handling
local function main()
    print("PogiMobile v2.1 Starting...")
    
    if not initModem() then
        return
    end
    
    loadData()
    
    -- Send initial presence
    broadcastPresence()
    
    local last_presence = os.clock()
    
    while true do
        -- Show main menu
        showMainMenu()
        
        -- Handle user input with background message processing
        local choice = nil
        
        -- Use parallel to handle both user input and background messages
        parallel.waitForAny(
            function()
                choice = read()
            end,
            function()
                while choice == nil do
                    -- Continuously process background messages
                    local sender_id, message, protocol = rednet.receive(nil, 0.1)
                    if sender_id then
                        handleMessage(sender_id, message, protocol)
                    end
                    
                    -- Send presence every 30 seconds
                    if os.clock() - last_presence > 30 then
                        broadcastPresence()
                        last_presence = os.clock()
                    end
                end
            end
        )
        
        -- Handle menu choice
        if choice == "1" then
            showMessages()
        elseif choice == "2" then
            sendNewMessage()
        elseif choice == "3" then
            showContacts()
        elseif choice == "4" then
            showOnlineUsers()
        elseif choice == "5" then
            showEmergencyAlerts()
        elseif choice == "6" then
            showSettings()
        elseif choice:lower() == "d" then
            showDebugInfo()
        elseif choice:lower() == "q" and is_terminal then
            break
        end
    end
    
    print("PogiMobile v2.1 shutting down...")
    saveData()
end

-- Run the app
main()
