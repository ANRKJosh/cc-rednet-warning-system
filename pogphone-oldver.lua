-- PoggishTown Phone System v2.1 - Complete
-- Modern messaging and communication system with server-based authentication
-- Protocol: pogphone (separate from security system)

local PHONE_PROTOCOL = "pogphone"
local SECURITY_PROTOCOL = "pogalert"
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
    server_id = nil,
    auto_connect = true,
    message_history_limit = 100,
    notification_sound = true,
    vibrate_on_message = true,
    compact_mode = false,
    update_url = "https://raw.githubusercontent.com/your-repo/poggishtown-phone.lua",
    -- Security integration (no hardcoded password)
    security_authenticated = false,
    security_auth_expires = 0,
    allow_emergency_alerts = false,
    -- Modem configuration
    modem_type_override = "auto",
    force_ender_modem = false
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
local selected_conversation = nil
local security_nodes = {}
local active_alarms = {}

-- Authentication state
local auth_request_pending = false
local auth_request_start_time = 0
local auth_last_result = nil

-- Debug logging
debug_log = debug_log or {}

local function addDebugLog(message)
    if not debug_log then debug_log = {} end
    
    -- Limit debug log size and reduce spam from heartbeats
    if not string.find(message, "HB:") or auth_request_pending then
        table.insert(debug_log, textutils.formatTime(os.time(), true) .. " " .. message)
        if #debug_log > 5 then  -- Keep only last 5 entries
            table.remove(debug_log, 1)
        end
    end
end

-- Helper functions
local function getUsernameById(user_id)
    if contacts[user_id] then
        return contacts[user_id].name
    end
    if online_users[user_id] then
        return online_users[user_id].username
    end
    return "User-" .. user_id
end

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
                addDebugLog("Config loaded OK, user=" .. tostring(config.username))
            else
                addDebugLog("Config parse failed")
            end
        else
            addDebugLog("Config file open failed")
        end
    else
        addDebugLog("Config file missing")
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
    -- Save config first
    local file = fs.open(CONFIG_FILE, "w")
    if file then
        file.write(textutils.serialize(config))
        file.close()
        addDebugLog("Config saved, user=" .. tostring(config.username))
    else
        addDebugLog("Config save failed")
    end
    
    -- Save contacts
    local file2 = fs.open(CONTACTS_FILE, "w")
    if file2 then
        file2.write(textutils.serialize(contacts))
        file2.close()
    end
    
    -- Save messages
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

-- Modem setup with configuration support
local function initializeModem()
    if config.modem_type_override ~= "auto" then
        for _, side in pairs(peripheral.getNames()) do
            if peripheral.getType(side) == "modem" then
                local modem = peripheral.wrap(side)
                if config.modem_type_override == "ender" then
                    if modem and ((modem.isWireless and not modem.isWireless()) or not modem.isWireless) then
                        modem_side = side
                        rednet.open(side)
                        return true
                    end
                elseif config.modem_type_override == "wireless" then
                    if modem and modem.isWireless and modem.isWireless() then
                        modem_side = side
                        rednet.open(side)
                        return true
                    end
                end
            end
        end
    end
    
    -- Auto-detection fallback
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            return true
        end
    end
    return false
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
    local current = getUsername()
    print("Current: " .. current)
    print("")
    print("Enter new username (or press Enter to keep current):")
    
    local new_name = read()
    if new_name and new_name ~= "" then
        config.username = new_name
        saveData()
        print("Username set to: " .. new_name)
        sleep(1)
    else
        -- Save the current username if not already saved
        if not config.username then
            config.username = current
            saveData()
            print("Username saved as: " .. current)
        else
            print("Username unchanged: " .. current)
        end
        sleep(1)
    end
end

-- Authentication functions
local function hashPassword(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 1000000
    end
    return tostring(hash)
end

local function requestServerAuthentication(password)
    addDebugLog("AUTH: Function called with password length " .. #password)
    
    local hash = hashPassword(password)
    addDebugLog("AUTH: Generated hash " .. hash)
    
    local message = {
        type = "security_auth_request",
        password_hash = hash,
        user_id = computer_id,
        username = getUsername(),
        timestamp = os.time()
    }
    
    addDebugLog("AUTH: Message constructed - type=" .. message.type .. " user=" .. message.user_id)
    addDebugLog("AUTH: About to broadcast on protocol '" .. PHONE_PROTOCOL .. "'")
    
    -- Test the broadcast with error handling
    local success, error_msg = pcall(function()
        rednet.broadcast(message, PHONE_PROTOCOL)
    end)
    
    if success then
        addDebugLog("AUTH: Broadcast call succeeded")
    else
        addDebugLog("AUTH: Broadcast failed - " .. tostring(error_msg))
    end
    
    -- Set pending state
    auth_request_pending = true
    auth_request_start_time = os.clock()  -- Use os.clock() for elapsed time
    auth_last_result = nil
    
    addDebugLog("AUTH: Request complete, pending=" .. tostring(auth_request_pending))
    
    return true
end

local function requestModemConfiguration()
    local message = {
        type = "modem_detection_request",
        user_id = computer_id,
        current_type = config.modem_type_override,
        timestamp = os.time()
    }
    
    addDebugLog("CONFIG: Sending modem detection request on protocol " .. PHONE_PROTOCOL)
    rednet.broadcast(message, PHONE_PROTOCOL)
end

local function isSecurityAuthenticated()
    return config.security_authenticated and os.time() < config.security_auth_expires
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

-- Get conversations (grouped by contact)
local function getConversations()
    local conversations = {}
    local conversation_order = {}
    
    for _, msg in ipairs(messages) do
        local contact_id = nil
        local contact_name = nil
        
        if msg.from_id == computer_id then
            -- Outgoing message
            contact_id = msg.to_id
            contact_name = getContactName(msg.to_id)
        else
            -- Incoming message
            contact_id = msg.from_id
            contact_name = getContactName(msg.from_id)
        end
        
        if not conversations[contact_id] then
            conversations[contact_id] = {
                contact_id = contact_id,
                contact_name = contact_name,
                messages = {},
                last_message_time = 0,
                unread_count = 0
            }
            table.insert(conversation_order, contact_id)
        end
        
        table.insert(conversations[contact_id].messages, msg)
        conversations[contact_id].last_message_time = math.max(conversations[contact_id].last_message_time, msg.timestamp)
        
        if not msg.read and msg.to_id == computer_id then
            conversations[contact_id].unread_count = conversations[contact_id].unread_count + 1
        end
    end
    
    -- Sort conversations by last message time
    table.sort(conversation_order, function(a, b)
        return conversations[a].last_message_time > conversations[b].last_message_time
    end)
    
    return conversations, conversation_order
end

-- Mark conversation as read
local function markConversationRead(contact_id)
    local read_count = 0
    for _, msg in ipairs(messages) do
        if msg.from_id == contact_id and msg.to_id == computer_id and not msg.read then
            msg.read = true
            read_count = read_count + 1
        end
    end
    unread_count = unread_count - read_count
    saveData()
end

-- Security alert functions
local function sendSecurityAlert(alarm_type)
    if not config.allow_emergency_alerts or not isSecurityAuthenticated() then
        return false, "Not authenticated for emergency alerts"
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
    
    -- Also add the alarm to our own active alarms immediately
    active_alarms[computer_id] = {
        type = alarm_type,
        source_name = getUsername(),
        start_time = os.time()
    }
    
    return true, "Alert sent"
end

local function sendSecurityCancel()
    if not config.allow_emergency_alerts or not isSecurityAuthenticated() then
        return false, "Not authenticated for emergency alerts"
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
    return true, "Cancel sent"
end

local function requestAlarmSync()
    -- Send a heartbeat to trigger alarm sync from server
    local message = {
        type = "security_heartbeat",
        computer_id = computer_id,
        device_name = getUsername(),
        timestamp = os.time(),
        alarm_active = false,  -- We're not alarming, trigger sync
        device_type = is_terminal and "terminal" or "computer"
    }
    rednet.broadcast(message, SECURITY_PROTOCOL)
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

-- Network test function
local function performNetworkTest()
    print("=== NETWORK TEST ===")
    print("Testing basic network connectivity...")
    print("")
    
    local test_message = {
        type = "network_test",
        from_user = computer_id,
        test_data = "Hello from " .. getUsername(),
        timestamp = os.time()
    }
    
    addDebugLog("NET_TEST: Sending network test on " .. PHONE_PROTOCOL)
    
    -- Test rednet.broadcast with error handling
    local success, error_msg = pcall(function()
        rednet.broadcast(test_message, PHONE_PROTOCOL)
    end)
    
    if success then
        addDebugLog("NET_TEST: Broadcast call succeeded")
        term.setTextColor(colors.green)
        print("[OK] Broadcast call succeeded")
        term.setTextColor(colors.white)
    else
        addDebugLog("NET_TEST: Broadcast failed - " .. tostring(error_msg))
        term.setTextColor(colors.red)
        print("[FAIL] Broadcast failed: " .. tostring(error_msg))
        term.setTextColor(colors.white)
    end
    
    print("")
    print("Network Information:")
    print("PHONE_PROTOCOL = '" .. PHONE_PROTOCOL .. "'")
    print("SECURITY_PROTOCOL = '" .. SECURITY_PROTOCOL .. "'")
    print("Computer ID = " .. computer_id)
    print("Modem side = " .. (modem_side or "none"))
    
    -- Test if rednet is open
    if modem_side then
        local modem = peripheral.wrap(modem_side)
        if modem then
            print("Modem type = " .. (modem.isWireless and (modem.isWireless() and "wireless" or "ender") or "unknown"))
            print("Rednet open = " .. (rednet.isOpen(modem_side) and "YES" or "NO"))
        else
            print("Modem = NOT FOUND")
        end
    else
        print("Modem = NO SIDE SET")
    end
    
    print("")
    print("Check server logs for received test message.")
    print("Press any key to continue...")
    os.pullEvent("key")
end

-- Message processing
local function handleMessage(sender_id, message, protocol)
    -- Debug: Log ALL messages with full details when auth is pending
    if auth_request_pending then
        addDebugLog("MSG: " .. protocol .. "/" .. (message.type or "?") .. " from " .. sender_id)
        
        -- Log the entire message structure for auth-related messages
        if message.type == "security_auth_response" or message.type == "auth_test" then
            addDebugLog("FULL_MSG: " .. textutils.serialize(message))
        end
        
        -- Also log if it's the right protocol
        if protocol == PHONE_PROTOCOL then
            addDebugLog("PHONE_PROTO: Correct protocol match")
        else
            addDebugLog("OTHER_PROTO: Protocol mismatch - got " .. protocol .. " expected " .. PHONE_PROTOCOL)
        end
    end
    
    if protocol == PHONE_PROTOCOL then
        -- Add debug for all phone protocol messages when auth is pending
        if auth_request_pending and message.type then
            addDebugLog("PHONE: Received " .. message.type .. " from " .. sender_id)
        end
        
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
            
        elseif message.type == "auth_test" then
            addDebugLog("TEST: Received auth_test - target=" .. tostring(message.target_user_id) .. " my_id=" .. computer_id)
            if message.target_user_id == computer_id then
                addDebugLog("TEST: Auth test message received successfully! authenticated=" .. tostring(message.authenticated))
            end
            
        elseif message.type == "security_auth_response" then
            addDebugLog("AUTH: Got response - target=" .. tostring(message.target_user_id) .. " my_id=" .. computer_id)
            
            -- Only process if this response is for us
            if message.target_user_id == computer_id then
                addDebugLog("AUTH: Processing response - authenticated=" .. tostring(message.authenticated))
                
                -- Clear pending auth request
                auth_request_pending = false
                
                if message.authenticated then
                    config.security_authenticated = true
                    config.security_auth_expires = message.expires or (os.time() + 3600)
                    config.allow_emergency_alerts = true
                    auth_last_result = "success"
                    addDebugLog("AUTH: Success - authenticated until " .. config.security_auth_expires)
                    saveData()
                else
                    config.security_authenticated = false
                    config.allow_emergency_alerts = false
                    auth_last_result = "failed"
                    addDebugLog("AUTH: Failed - incorrect password")
                    saveData()
                end
            else
                addDebugLog("AUTH: Ignoring response for user " .. (message.target_user_id or "unknown"))
            end
            
        elseif message.type == "modem_detection_response" then
            addDebugLog("CONFIG: Received modem detection response")
            if message.recommended_type and message.recommended_type ~= "auto" then
                config.modem_type_override = message.recommended_type
                config.force_ender_modem = message.force_ender or false
                saveData()
                addDebugLog("CONFIG: Updated modem type to " .. message.recommended_type)
            end
            
        elseif message.type == "network_test_response" then
            addDebugLog("NET_TEST: Received network test response from server")
            
        elseif message.type == "config_update" then
            if message.config_data then
                local updated = false
                for key, value in pairs(message.config_data) do
                    if config[key] ~= nil then
                        config[key] = value
                        updated = true
                    end
                end
                if updated then
                    saveData()
                end
            end
        else
            -- Log any unhandled phone protocol messages when auth is pending
            if auth_request_pending then
                addDebugLog("UNHANDLED: " .. (message.type or "unknown_type") .. " from " .. sender_id)
            end
        end
        
    elseif protocol == SECURITY_PROTOCOL then
        -- Debug: Log all security messages received with details
        addDebugLog("RCV: " .. sender_id .. " -> " .. (message.type or "?") .. "/" .. (message.action or "?") .. " orig:" .. (message.original_sender or "none"))
        
        -- Only skip if this message originally came from us
        if message.original_sender == computer_id then
            addDebugLog("SKIP: Message originally from us")
            return
        end
        
        -- Also skip if sender is us and no relay info (direct loop)
        if sender_id == computer_id and not message.relayed_by_server then
            addDebugLog("SKIP: Direct loop from ourselves")
            return
        end
        
        -- Always process security messages regardless of authentication for cancel messages
        if message.type == "security_alert" then
            if message.action == "start" and isSecurityAuthenticated() then
                local source_id = message.source_id or message.original_sender or sender_id
                addDebugLog("START: Adding alarm from " .. source_id)
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
                addDebugLog("STOP: Processing cancel")
                -- Process cancel messages regardless of authentication
                if message.global_cancel then
                    -- Global cancel - clear all alarms
                    active_alarms = {}
                    addDebugLog("STOP: Cleared all alarms")
                else
                    -- Specific device cancel - clear just that alarm
                    local source_id = message.source_id or message.original_sender or sender_id
                    active_alarms[source_id] = nil
                    addDebugLog("STOP: Cleared alarm from " .. source_id)
                end
            elseif message.action == "start" and not isSecurityAuthenticated() then
                addDebugLog("SKIP: Not authenticated for security")
            end
            
        elseif message.type == "security_heartbeat" and isSecurityAuthenticated() then
            addDebugLog("HB: Processing heartbeat from " .. message.computer_id)
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
                addDebugLog("HB: Added alarm from " .. message.computer_id)
            else
                active_alarms[message.computer_id] = nil
            end
        end
    end
end

-- User interface screens
local function drawHeader()
    print("=== POGGISHTOWN PHONE v2.1 ===")
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
    
    -- Count active alarms (even if not authenticated)
    local alarm_count = 0
    for _ in pairs(active_alarms) do alarm_count = alarm_count + 1 end
    
    if isSecurityAuthenticated() and alarm_count > 0 then
        term.setTextColor(colors.red)
        print("!!! " .. alarm_count .. " ACTIVE ALARMS !!!")
        term.setTextColor(colors.white)
        print("")
    end
    
    print("Main Menu:")
    
    -- Messages with unread indicator
    if unread_count > 0 then
        term.setTextColor(colors.yellow)
        print("1. Messages (" .. unread_count .. " unread) [NEW]")
        term.setTextColor(colors.white)
    else
        print("1. Messages (" .. unread_count .. " unread)")
    end
    
    print("2. Send Message")
    
    -- Contacts with count
    local contact_count = 0
    for _ in pairs(contacts) do contact_count = contact_count + 1 end
    print("3. Contacts (" .. contact_count .. " saved)")
    
    print("4. Online Users")
    
    -- Emergency Alerts with alarm status
    if alarm_count > 0 then
        term.setTextColor(colors.red)
        print("5. Emergency Alerts [" .. alarm_count .. " ACTIVE]")
        term.setTextColor(colors.white)
    elseif isSecurityAuthenticated() then
        term.setTextColor(colors.green)
        print("5. Emergency Alerts [AUTHENTICATED]")
        term.setTextColor(colors.white)
    else
        print("5. Emergency Alerts")
    end
    
    print("6. Settings")
    print("7. About")
    
    if is_terminal then
        print("Q. Quit")
    end
    print("")
    print("Enter choice:")
end

-- MESSAGES SCREEN - Now properly implemented
local function drawMessagesScreen()
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    
    local conversations, conversation_order = getConversations()
    
    if #conversation_order == 0 then
        print("No messages yet.")
        print("Send your first message from the main menu!")
        print("")
        print("B. Back to main menu")
        return
    end
    
    print("Conversations:")
    print("")
    
    for i, contact_id in ipairs(conversation_order) do
        local conv = conversations[contact_id]
        local preview = ""
        if #conv.messages > 0 then
            local last_msg = conv.messages[#conv.messages]
            preview = string.sub(last_msg.content, 1, 30)
            if #last_msg.content > 30 then
                preview = preview .. "..."
            end
        end
        
        local unread_indicator = conv.unread_count > 0 and (" (" .. conv.unread_count .. ")") or ""
        local time_str = textutils.formatTime(conv.last_message_time, true)
        
        if conv.unread_count > 0 then
            term.setTextColor(colors.yellow)
            print(i .. ". " .. conv.contact_name .. unread_indicator .. " [NEW]")
        else
            term.setTextColor(colors.white)
            print(i .. ". " .. conv.contact_name .. unread_indicator)
        end
        
        term.setTextColor(colors.lightGray)
        print("   " .. preview .. " - " .. time_str)
        term.setTextColor(colors.white)
        print("")
    end
    
    print("Enter conversation number to open, or B to go back:")
end

-- CONVERSATION SCREEN - Now properly implemented
local function drawConversationScreen(contact_id)
    term.clear()
    term.setCursorPos(1, 1)
    
    local contact_name = getContactName(contact_id)
    print("=== CONVERSATION WITH " .. string.upper(contact_name) .. " ===")
    print("")
    
    -- Mark conversation as read when opened
    markConversationRead(contact_id)
    
    -- Get messages for this conversation
    local conversation_messages = {}
    for _, msg in ipairs(messages) do
        if (msg.from_id == contact_id and msg.to_id == computer_id) or 
           (msg.from_id == computer_id and msg.to_id == contact_id) then
            table.insert(conversation_messages, msg)
        end
    end
    
    if #conversation_messages == 0 then
        print("No messages in this conversation yet.")
    else
        -- Show last 10 messages
        local start_index = math.max(1, #conversation_messages - 9)
        
        for i = start_index, #conversation_messages do
            local msg = conversation_messages[i]
            local time_str = textutils.formatTime(msg.timestamp, true)
            local sender_name = (msg.from_id == computer_id) and "You" or contact_name
            
            if msg.from_id == computer_id then
                term.setTextColor(colors.lightBlue)
                print("[" .. time_str .. "] You: " .. msg.content)
            else
                term.setTextColor(colors.white)
                print("[" .. time_str .. "] " .. sender_name .. ": " .. msg.content)
            end
        end
        
        if #conversation_messages > 10 then
            term.setTextColor(colors.lightGray)
            print("(" .. (#conversation_messages - 10) .. " older messages)")
        end
    end
    
    term.setTextColor(colors.white)
    print("")
    print("Options:")
    print("R. Reply to this conversation")
    print("A. Add contact (save " .. contact_name .. ")")
    print("B. Back to messages")
end

-- SEND MESSAGE SCREEN - Now properly implemented
local function drawSendMessageScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SEND MESSAGE ===")
    print("")
    
    local user_list = {}
    for id, user in pairs(online_users) do
        if id ~= computer_id then
            table.insert(user_list, {id = id, data = user})
        end
    end
    
    -- Add contacts who might not be online
    for id, contact in pairs(contacts) do
        local found = false
        for _, user in ipairs(user_list) do
            if user.id == id then
                found = true
                break
            end
        end
        if not found then
            table.insert(user_list, {id = id, data = {username = contact.name, device_type = "offline"}})
        end
    end
    
    if #user_list == 0 then
        print("No users available.")
        print("Make sure people are online or add some contacts first.")
        print("")
        print("Press any key to return...")
        os.pullEvent("key")
        return
    end
    
    print("Available recipients:")
    for i, user in ipairs(user_list) do
        local is_online = user.data.device_type ~= "offline"
        
        if is_online then
            term.setTextColor(colors.green)
            print(i .. ". " .. user.data.username .. " [ONLINE]")
        else
            term.setTextColor(colors.red)
            print(i .. ". " .. user.data.username .. " [OFFLINE]")
        end
        term.setTextColor(colors.white)
    end
    
    print("")
    print("Enter recipient number:")
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

-- CONTACTS SCREEN - Now properly implemented
local function drawContactsScreen()
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    
    if next(contacts) == nil then
        print("No contacts saved yet.")
        print("")
        print("You can add contacts by:")
        print("- Messaging someone and then adding them")
        print("- Adding online users manually")
        print("")
        print("A. Add contact manually")
        print("B. Back to main menu")
        return
    end
    
    print("Saved Contacts:")
    print("")
    
    local contact_list = {}
    for id, contact in pairs(contacts) do
        table.insert(contact_list, {id = id, data = contact})
    end
    table.sort(contact_list, function(a, b) return a.data.name < b.data.name end)
    
    for i, contact in ipairs(contact_list) do
        local is_online = online_users[contact.id] ~= nil
        if is_online then
            term.setTextColor(colors.green)
            print(i .. ". " .. contact.data.name .. " [ONLINE]")
        else
            term.setTextColor(colors.red)
            print(i .. ". " .. contact.data.name .. " [OFFLINE]")
        end
        term.setTextColor(colors.lightGray)
        print("   ID: " .. contact.id)
        term.setTextColor(colors.white)
    end
    
    print("")
    print("Options:")
    print("A. Add contact manually")
    print("M. Message a contact")
    print("D. Delete a contact")
    print("B. Back to main menu")
end

-- ONLINE USERS SCREEN - Now properly implemented
local function drawOnlineUsersScreen()
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    
    if next(online_users) == nil then
        print("No users online currently.")
        print("Try refreshing the user list.")
        print("")
        print("R. Refresh")
        print("B. Back to main menu")
        return
    end
    
    print("Online Users:")
    print("")
    
    local user_list = {}
    for id, user in pairs(online_users) do
        if id ~= computer_id then
            table.insert(user_list, {id = id, data = user})
        end
    end
    table.sort(user_list, function(a, b) return a.data.username < b.data.username end)
    
    for i, user in ipairs(user_list) do
        local device_icon = user.data.device_type == "terminal" and "[T]" or "[C]"
        
        if user.data.device_type == "terminal" then
            term.setTextColor(colors.cyan)
        else
            term.setTextColor(colors.blue)
        end
        
        print(i .. ". " .. device_icon .. " " .. user.data.username)
        
        if contacts[user.id] then
            term.setTextColor(colors.yellow)
            print("   [SAVED CONTACT]")
        end
        
        term.setTextColor(colors.lightGray)
        print("   ID: " .. user.id)
        term.setTextColor(colors.white)
    end
    
    print("")
    print("Options:")
    print("M. Message a user")
    print("A. Add user as contact")
    print("R. Refresh list")
    print("B. Back to main menu")
end

local function drawSecurityLoginScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SECURITY LOGIN ===")
    print("User: " .. getUsername())
    print("")
    
    if isSecurityAuthenticated() then
        term.setTextColor(colors.green)
        print("Status: AUTHENTICATED")
        term.setTextColor(colors.white)
        local expires_in = config.security_auth_expires - os.time()
        print("Expires in: " .. math.floor(expires_in / 60) .. " minutes")
        print("")
        print("Emergency alerts are enabled.")
        print("")
        print("L - Logout | B - Back")
    elseif auth_request_pending then
        -- Show waiting state
        term.setTextColor(colors.yellow)
        print("Status: AUTHENTICATING...")
        term.setTextColor(colors.white)
        print("")
        print("Contacting server for authentication...")
        local elapsed = os.clock() - auth_request_start_time
        print("Elapsed: " .. math.floor(elapsed) .. " seconds")
        
        -- Check for timeout (10 seconds)
        if elapsed > 10 then
            auth_request_pending = false
            auth_last_result = "timeout"
        end
        
        print("")
        print("Please wait or press B to cancel...")
        
        -- Show more prominent debug info during auth
        print("")
        print("=== DEBUG INFO ===")
        print("My ID: " .. computer_id)
        print("Auth pending: " .. tostring(auth_request_pending))
        if debug_log and #debug_log > 0 then
            -- Show the last 3 debug entries for better visibility
            local start_idx = math.max(1, #debug_log - 2)
            for i = start_idx, #debug_log do
                print("  " .. debug_log[i])
            end
        else
            print("  No debug messages yet")
        end
    elseif auth_last_result then
        -- Show result of last attempt
        if auth_last_result == "success" then
            term.setTextColor(colors.green)
            print("Authentication successful!")
            term.setTextColor(colors.white)
            print("")
            print("Press any key to continue...")
            auth_last_result = nil  -- Clear result
        elseif auth_last_result == "failed" then
            term.setTextColor(colors.red)
            print("Authentication failed!")
            term.setTextColor(colors.white)
            print("Incorrect password.")
            print("")
            print("Press any key to try again...")
            auth_last_result = nil  -- Clear result
        elseif auth_last_result == "timeout" then
            term.setTextColor(colors.red)
            print("Authentication timeout!")
            term.setTextColor(colors.white)
            print("No response from server.")
            print("Check server connection and try again.")
            print("")
            print("Press any key to continue...")
            auth_last_result = nil  -- Clear result
        end
    else
        term.setTextColor(colors.red)
        print("Status: NOT AUTHENTICATED")
        term.setTextColor(colors.white)
        print("")
        print("Enter security password to access")
        print("emergency alert features:")
        print("")
        print("Password:")
        
        local password = read("*")
        if password and password ~= "" then
            addDebugLog("LOGIN: Password entered, length=" .. #password)
            addDebugLog("LOGIN: Calling requestServerAuthentication")
            requestServerAuthentication(password)
            addDebugLog("LOGIN: requestServerAuthentication returned")
            -- Don't wait here - just return and let the main loop handle it
        else
            addDebugLog("LOGIN: No password entered")
            print("")
            print("B - Back")
        end
    end
end

local function drawEmergencyScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== EMERGENCY ALERTS ===")
    print("User: " .. getUsername())
    print("")
    
    -- Always show active alarms (even if not authenticated)
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
    
    -- Always show security nodes (even if not authenticated, but limited info)
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
    
    -- Authentication status and controls
    if auth_request_pending then
        term.setTextColor(colors.yellow)
        print("Status: AUTHENTICATING...")
        term.setTextColor(colors.white)
        local elapsed = os.clock() - auth_request_start_time
        print("Elapsed: " .. math.floor(elapsed) .. " seconds")
        print("")
        print("Please wait...")
        print("")
    elseif auth_last_result == "success" then
        term.setTextColor(colors.green)
        print("Status: AUTHENTICATION SUCCESS!")
        term.setTextColor(colors.white)
        print("You are now logged in.")
        print("")
        auth_last_result = nil  -- Clear the result
    elseif auth_last_result == "failed" then
        term.setTextColor(colors.red)
        print("Status: AUTHENTICATION FAILED!")
        term.setTextColor(colors.white)
        print("Incorrect password.")
        print("")
        auth_last_result = nil  -- Clear the result
    elseif auth_last_result == "timeout" then
        term.setTextColor(colors.red)
        print("Status: AUTHENTICATION TIMEOUT!")
        term.setTextColor(colors.white)
        print("No response from server.")
        print("")
        auth_last_result = nil  -- Clear the result
    elseif isSecurityAuthenticated() then
        term.setTextColor(colors.green)
        print("Status: AUTHENTICATED")
        term.setTextColor(colors.white)
        local expires_in = config.security_auth_expires - os.time()
        print("Expires: " .. math.floor(expires_in / 60) .. " minutes")
        print("")
        
        print("Send Alert:")
        print("G - General Alert")
        print("E - Evacuation Alert")
        print("L - Lockdown Alert")
        if alarm_count > 0 then
            print("C - Cancel All Alarms")
        end
        print("O - Logout")
    else
        term.setTextColor(colors.yellow)
        print("Status: NOT AUTHENTICATED")
        term.setTextColor(colors.white)
        print("Login required to send alerts")
        print("")
        print("I - Login to Send Alerts")
    end
    
    print("")
    print("R - Refresh | B - Back")
    
    -- Show debug log
    if debug_log and #debug_log > 0 then
        print("")
        print("Debug Log:")
        for _, entry in ipairs(debug_log) do
            print("  " .. entry)
        end
    end
end

local function handleEmergencyScreenInput()
    local input = read()
    
    if input:lower() == "b" then
        current_screen = "main"
    elseif input:lower() == "r" then
        return -- Just refresh the screen
    elseif input:lower() == "i" and not isSecurityAuthenticated() then
        -- Login option
        print("")
        print("Enter security password:")
        local password = read("*")
        if password and password ~= "" then
            addDebugLog("EMERGENCY: Password entered, length=" .. #password)
            addDebugLog("EMERGENCY: Calling requestServerAuthentication")
            requestServerAuthentication(password)
            addDebugLog("EMERGENCY: requestServerAuthentication returned")
            print("")
            print("Authentication request sent...")
            print("Check status in Emergency Alerts menu")
            sleep(2)
        else
            addDebugLog("EMERGENCY: No password entered")
        end
    elseif input:lower() == "o" and isSecurityAuthenticated() then
        -- Logout option
        config.security_authenticated = false
        config.allow_emergency_alerts = false
        saveData()
        print("")
        print("Logged out of security features")
        sleep(1)
    elseif isSecurityAuthenticated() and config.allow_emergency_alerts then
        -- Alert sending options (only if authenticated)
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
                -- Force clear our own alarm immediately
                active_alarms = {}
            else
                print("Failed: " .. message)
            end
            sleep(2)
        end
    end
end

local function showDebugLog()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== DEBUG LOG ===")
    print("Config Username: " .. tostring(config.username))
    print("Current Username: " .. getUsername())
    print("Security Auth: " .. tostring(isSecurityAuthenticated()))
    
    -- Count active alarms
    local alarm_count = 0
    for _ in pairs(active_alarms) do alarm_count = alarm_count + 1 end
    print("Active Alarms: " .. alarm_count)
    print("")
    
    print("Security Message Log:")
    if debug_log and #debug_log > 0 then
        for _, entry in ipairs(debug_log) do
            print("  " .. entry)
        end
    else
        print("  No messages logged yet")
    end
    
    print("")
    print("Files:")
    print("  " .. CONFIG_FILE .. ": " .. (fs.exists(CONFIG_FILE) and "EXISTS" or "MISSING"))
    print("  " .. CONTACTS_FILE .. ": " .. (fs.exists(CONTACTS_FILE) and "EXISTS" or "MISSING"))
    print("  " .. MESSAGES_FILE .. ": " .. (fs.exists(MESSAGES_FILE) and "EXISTS" or "MISSING"))
    
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
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
    print("5. Modem Type: " .. config.modem_type_override)
    print("6. Request Server Config")
    print("7. Clear All Messages")
    print("8. Debug Log")
    print("9. Test Auth Status")
    print("0. Network Test")
    
    if isSecurityAuthenticated() then
        print("10. Security Logout")
    end
    
    print("B. Back")
    print("")
    print("Enter choice:")
end

-- Input handling
local function handleMainScreenInput()
    local input = read()
    
    if input == "1" then
        current_screen = "messages"
    elseif input == "2" then
        current_screen = "send_message"
    elseif input == "3" then
        current_screen = "contacts"
    elseif input == "4" then
        current_screen = "online_users"
        requestUserList()
    elseif input == "5" then
        current_screen = "emergency"
    elseif input == "6" then
        current_screen = "settings"
    elseif input == "7" then
        current_screen = "about"
    elseif input:lower() == "q" and is_terminal then
        return false
    end
    return true
end

-- Handle messages screen input
local function handleMessagesScreenInput()
    local input = read()
    
    if input:lower() == "b" then
        current_screen = "main"
        return
    end
    
    local choice = tonumber(input)
    if choice then
        local conversations, conversation_order = getConversations()
        if choice >= 1 and choice <= #conversation_order then
            selected_conversation = conversation_order[choice]
            current_screen = "conversation"
        end
    end
end

-- Handle conversation screen input
local function handleConversationScreenInput()
    local input = read()
    
    if input:lower() == "b" then
        current_screen = "messages"
        selected_conversation = nil
    elseif input:lower() == "r" then
        -- Reply - send a message to the current conversation contact
        print("")
        print("Reply to " .. getContactName(selected_conversation) .. ":")
        local message_content = read()
        
        if message_content and message_content ~= "" then
            sendDirectMessage(selected_conversation, message_content)
            print("")
            print("Message sent!")
            sleep(1)
            -- Refresh conversation screen
        end
    elseif input:lower() == "a" then
        -- Add contact
        print("")
        print("Save contact name for " .. getContactName(selected_conversation) .. ":")
        local contact_name = read()
        
        if contact_name and contact_name ~= "" then
            addContact(selected_conversation, contact_name)
            print("")
            print("Contact saved!")
            sleep(1)
        end
    end
end

-- Handle contacts screen input
local function handleContactsScreenInput()
    local input = read()
    
    if input:lower() == "b" then
        current_screen = "main"
    elseif input:lower() == "a" then
        print("")
        print("Enter contact name:")
        local name = read()
        if name and name ~= "" then
            print("Enter contact ID:")
            local id = tonumber(read())
            if id then
                addContact(id, name)
                print("")
                print("Contact added!")
                sleep(1)
            end
        end
    elseif input:lower() == "m" then
        print("")
        print("Enter contact number to message:")
        local contact_num = tonumber(read())
        if contact_num then
            local contact_list = {}
            for id, contact in pairs(contacts) do
                table.insert(contact_list, {id = id, data = contact})
            end
            table.sort(contact_list, function(a, b) return a.data.name < b.data.name end)
            
            if contact_num >= 1 and contact_num <= #contact_list then
                local contact = contact_list[contact_num]
                print("")
                print("Message to " .. contact.data.name .. ":")
                local message_content = read()
                
                if message_content and message_content ~= "" then
                    sendDirectMessage(contact.id, message_content)
                    print("")
                    print("Message sent!")
                    sleep(1)
                end
            end
        end
    elseif input:lower() == "d" then
        print("")
        print("Enter contact number to delete:")
        local contact_num = tonumber(read())
        if contact_num then
            local contact_list = {}
            for id, contact in pairs(contacts) do
                table.insert(contact_list, {id = id, data = contact})
            end
            table.sort(contact_list, function(a, b) return a.data.name < b.data.name end)
            
            if contact_num >= 1 and contact_num <= #contact_list then
                local contact = contact_list[contact_num]
                print("Delete " .. contact.data.name .. "? (y/n)")
                local confirm = read()
                if confirm:lower() == "y" then
                    contacts[contact.id] = nil
                    saveData()
                    print("Contact deleted!")
                    sleep(1)
                end
            end
        end
    end
end

-- Handle online users screen input
local function handleOnlineUsersScreenInput()
    local input = read()
    
    if input:lower() == "b" then
        current_screen = "main"
    elseif input:lower() == "r" then
        requestUserList()
    elseif input:lower() == "m" then
        print("")
        print("Enter user number to message:")
        local user_num = tonumber(read())
        if user_num then
            local user_list = {}
            for id, user in pairs(online_users) do
                if id ~= computer_id then
                    table.insert(user_list, {id = id, data = user})
                end
            end
            table.sort(user_list, function(a, b) return a.data.username < b.data.username end)
            
            if user_num >= 1 and user_num <= #user_list then
                local user = user_list[user_num]
                print("")
                print("Message to " .. user.data.username .. ":")
                local message_content = read()
                
                if message_content and message_content ~= "" then
                    sendDirectMessage(user.id, message_content)
                    print("")
                    print("Message sent!")
                    sleep(1)
                end
            end
        end
    elseif input:lower() == "a" then
        print("")
        print("Enter user number to add as contact:")
        local user_num = tonumber(read())
        if user_num then
            local user_list = {}
            for id, user in pairs(online_users) do
                if id ~= computer_id then
                    table.insert(user_list, {id = id, data = user})
                end
            end
            table.sort(user_list, function(a, b) return a.data.username < b.data.username end)
            
            if user_num >= 1 and user_num <= #user_list then
                local user = user_list[user_num]
                addContact(user.id, user.data.username)
                print("")
                print("Contact added!")
                sleep(1)
            end
        end
    end
end

-- Main application loop
local function main()
    -- Initialize debug log if not already initialized
    if not debug_log then
        debug_log = {}
    end
    
    -- Validate protocol constants
    addDebugLog("INIT: PHONE_PROTOCOL='" .. PHONE_PROTOCOL .. "' SECURITY_PROTOCOL='" .. SECURITY_PROTOCOL .. "'")
    
    if not initializeModem() then
        print("ERROR: No modem found!")
        print("Please attach a wireless modem.")
        return
    end
    
    loadData()
    
    print("PoggishTown Phone v2.1 Starting...")
    print("User: " .. getUsername())
    print("Device: " .. (is_terminal and "Terminal" or "Computer"))
    print("Modem: " .. (modem_side or "None") .. " (" .. config.modem_type_override .. ")")
    sleep(1)
    
    broadcastPresence()
    requestUserList()
    
    -- Request alarm sync if authenticated
    if isSecurityAuthenticated() then
        requestAlarmSync()
        print("Requesting alarm sync...")
        sleep(1)
    end
    
    current_screen = "main"
    local presence_timer = os.startTimer(30)
    local refresh_timer = os.startTimer(1)
    
    while true do
        if current_screen == "main" then
            drawMainScreen()
            if not handleMainScreenInput() then
                break
            end
        elseif current_screen == "messages" then
            drawMessagesScreen()
            handleMessagesScreenInput()
        elseif current_screen == "conversation" then
            if selected_conversation then
                drawConversationScreen(selected_conversation)
                handleConversationScreenInput()
            else
                current_screen = "messages"
            end
        elseif current_screen == "send_message" then
            drawSendMessageScreen()
            current_screen = "main"
        elseif current_screen == "contacts" then
            drawContactsScreen()
            handleContactsScreenInput()
        elseif current_screen == "online_users" then
            drawOnlineUsersScreen()
            handleOnlineUsersScreenInput()
        elseif current_screen == "security_login" then
            drawSecurityLoginScreen()
            
            -- Always handle input, even when auth is pending
            if auth_request_pending then
                -- Check for timeout first
                local elapsed = os.clock() - auth_request_start_time
                if elapsed > 10 then
                    auth_request_pending = false
                    auth_last_result = "timeout"
                    addDebugLog("AUTH: Timeout after " .. math.floor(elapsed) .. " seconds")
                end
                -- DON'T block here - let the main event loop continue to process rednet messages
            elseif auth_last_result then
                -- Wait for any key when showing result
                os.pullEvent("key")
                current_screen = "main"  -- Go back to main after showing result
            else
                local input = read()
                if input:lower() == "b" then
                    current_screen = "main"
                elseif input:lower() == "l" and isSecurityAuthenticated() then
                    config.security_authenticated = false
                    config.allow_emergency_alerts = false
                    saveData()
                    current_screen = "main"
                end
            end
        elseif current_screen == "emergency" then
            drawEmergencyScreen()
            
            -- Don't block if auth is pending - let background processing continue
            if not auth_request_pending then
                handleEmergencyScreenInput()
            end
        elseif current_screen == "settings" then
            drawSettingsScreen()
            local input = read()
            if input:lower() == "b" then
                current_screen = "main"
            elseif input == "0" then
                -- Network test
                performNetworkTest()
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
                print("")
                print("Modem type (auto/ender/wireless):")
                local modem_type = read()
                if modem_type and (modem_type == "auto" or modem_type == "ender" or modem_type == "wireless") then
                    config.modem_type_override = modem_type
                    config.force_ender_modem = (modem_type == "ender")
                    saveData()
                    print("Modem type set to: " .. modem_type)
                    print("Restart to apply changes")
                    sleep(2)
                end
            elseif input == "6" then
                print("")
                print("Requesting configuration from server...")
                requestModemConfiguration()
                sleep(2)
            elseif input == "7" then
                messages = {}
                unread_count = 0
                saveData()
                print("All messages cleared!")
                sleep(1)
            elseif input == "8" then
                showDebugLog()
            elseif input == "9" then
                -- Test auth status
                print("")
                print("=== AUTH STATUS TEST ===")
                print("Computer ID: " .. computer_id)
                print("Auth pending: " .. tostring(auth_request_pending))
                print("Auth result: " .. tostring(auth_last_result))
                print("Is authenticated: " .. tostring(isSecurityAuthenticated()))
                print("Config auth: " .. tostring(config.security_authenticated))
                print("Auth expires: " .. tostring(config.security_auth_expires))
                print("Current time: " .. tostring(os.time()))
                print("Allow emergency: " .. tostring(config.allow_emergency_alerts))
                print("")
                print("Press any key to continue...")
                os.pullEvent("key")
            elseif input == "10" and isSecurityAuthenticated() then
                config.security_authenticated = false
                config.allow_emergency_alerts = false
                saveData()
                print("")
                print("Logged out of security features")
                sleep(1)
            end
        elseif current_screen == "about" then
            term.clear()
            term.setCursorPos(1, 1)
            print("=== ABOUT ===")
            print("PoggishTown Phone v2.1")
            print("Modern messaging with security integration")
            print("")
            print("Features:")
            print("- Server-based message relay")
            print("- Real-time messaging and delivery")
            print("- Contact management")
            print("- Conversation threading")
            print("- Emergency alert system")
            print("- Configurable notifications")
            print("")
            print("Fixed in v2.1:")
            print("- Complete messaging interface")
            print("- Proper message viewing and sending")
            print("- Conversation threading")
            print("- Contact management UI")
            print("- Improved server reliability")
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
                        
                        -- Debug: Log all rednet events when auth is pending
                        if auth_request_pending then
                            addDebugLog("REDNET_EVENT: " .. protocol .. " from " .. sender_id)
                        end
                        
                        if protocol == PHONE_PROTOCOL or protocol == SECURITY_PROTOCOL then
                            handleMessage(sender_id, message, protocol)
                        else
                            if auth_request_pending then
                                addDebugLog("UNKNOWN_PROTO: " .. protocol .. " from " .. sender_id)
                            end
                        end
                    elseif event == "timer" and param1 == presence_timer then
                        broadcastPresence()
                        presence_timer = os.startTimer(30)
                    elseif event == "timer" and param1 == refresh_timer then
                        refresh_timer = os.startTimer(1)  -- Standard 1 second refresh
                    end
                end
            end,
            function()
                sleep(0.1)  -- Keep this short to ensure responsiveness
            end
        )
    end
    
    print("PoggishTown Phone v2.1 shutting down...")
    saveData()
end

-- Run the application
main()
