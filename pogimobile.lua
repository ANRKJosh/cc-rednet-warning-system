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

-- App store functions
local function requestAppList()
    local message = {
        type = "app_list_request",
        from_id = computer_id,
        device_type = is_terminal and "terminal" or "computer",
        timestamp = os.time()
    }
    rednet.broadcast(message, PHONE_PROTOCOL)
end

local function downloadApp(app_id)
    local message = {
        type = "app_download_request",
        app_id = app_id,
        from_id = computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(message, PHONE_PROTOCOL)
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
        elseif message.type == "app_update_notification" then
            -- Show update notification
            if message.app_name then
                print("\n[UPDATE] " .. message.app_name .. " v" .. message.new_version .. " available!")
                print("Check App Store for updates")
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
    print("7. App Store")
    print("8. About")
    
    if is_terminal then
        print("Q. Quit")
    end
    print("")
    print("Enter choice:")
end

-- Simple App Store screen
local function drawAppStoreScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== APP STORE ===")
    print("Device: " .. (is_terminal and "Terminal" or "Computer"))
    if isSecurityAuthenticated() then
        term.setTextColor(colors.green)
        print("Security: AUTHENTICATED")
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.red)
        print("Security: NOT AUTHENTICATED")
        term.setTextColor(colors.white)
    end
    print("")
    
    -- Request app list
    print("Requesting apps from server...")
    requestAppList()
    
    local apps_received = {}
    local start_time = os.clock()
    
    -- Wait for response
    while (os.clock() - start_time) < 5 do
        local sender_id, response, protocol = rednet.receive(nil, 0.5)
        
        if sender_id and protocol == PHONE_PROTOCOL then
            if response.type == "app_list_response" then
                apps_received = response.apps or {}
                break
            end
        end
    end
    
    term.clear()
    term.setCursorPos(1, 1)
    print("=== AVAILABLE APPS ===")
    print("")
    
    local app_count = 0
    local app_list = {}
    
    for app_id, app_data in pairs(apps_received) do
        app_count = app_count + 1
        table.insert(app_list, {id = app_id, data = app_data})
    end
    
    if app_count == 0 then
        term.setTextColor(colors.red)
        print("No apps available for your device")
        term.setTextColor(colors.white)
        print("")
        if is_terminal then
            print("Terminals can typically access:")
            print("- Communication apps (like this phone)")
            print("- Admin tools (requires authentication)")
        else
            print("Computers can access:")
            print("- Security apps (requires authentication)")
        end
    else
        print("Available Apps:")
        print("")
        
        for i, app in ipairs(app_list) do
            local category = app.data.category or "general"
            
            if category == "security" then
                term.setTextColor(colors.red)
            elseif category == "communication" then
                term.setTextColor(colors.blue)
            elseif category == "admin" then
                term.setTextColor(colors.yellow)
            else
                term.setTextColor(colors.white)
            end
            
            print(i .. ". " .. app.data.name .. " v" .. app.data.version)
            term.setTextColor(colors.lightGray)
            print("   " .. app.data.description)
            term.setTextColor(colors.white)
        end
        
        print("")
        print("Enter app number to get download info:")
        local choice = read()
        local app_num = tonumber(choice)
        
        if app_num and app_num >= 1 and app_num <= #app_list then
            local selected_app = app_list[app_num]
            
            print("")
            print("Getting download info for " .. selected_app.data.name .. "...")
            downloadApp(selected_app.id)
            
            -- Wait for download response
            local download_start = os.clock()
            while (os.clock() - download_start) < 10 do
                local sender_id, response, protocol = rednet.receive(nil, 0.5)
                
                if sender_id and protocol == PHONE_PROTOCOL then
                    if response.type == "app_download_response" and response.app_id == selected_app.id then
                        print("")
                        term.setTextColor(colors.green)
                        print("[OK] Download info received!")
                        term.setTextColor(colors.white)
                        print("")
                        print("App: " .. response.name .. " v" .. response.version)
                        print("Install as: " .. response.install_name)
                        print("")
                        print("Download command:")
                        term.setTextColor(colors.yellow)
                        print("wget " .. response.download_url .. " " .. response.install_name)
                        term.setTextColor(colors.white)
                        print("")
                        print("Then run: " .. response.install_name)
                        break
                        
                    elseif response.type == "app_download_error" and response.app_id == selected_app.id then
                        print("")
                        term.setTextColor(colors.red)
                        print("[FAIL] " .. response.error)
                        term.setTextColor(colors.white)
                        if response.reason == "authentication_required" then
                            print("You need security authentication first")
                            print("Go to Emergency Alerts > Login")
                        end
                        break
                    end
                end
            end
        end
    end
    
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
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
        drawAppStoreScreen()
    elseif input == "8" then
        current_screen = "about"
    elseif input:lower() == "q" and is_terminal then
        return false
    end
    return true
end

-- Simple placeholder screens for now
local function showSimpleScreen(title, message)
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    print("=== " .. title .. " ===")
    print("")
    print(message)
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
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
            showSimpleScreen("MESSAGES", "Messages feature coming soon!\nFull messaging interface will be available.")
            current_screen = "main"
        elseif current_screen == "send_message" then
            showSimpleScreen("SEND MESSAGE", "Send message feature coming soon!\nDirect messaging interface will be available.")
            current_screen = "main"
        elseif current_screen == "contacts" then
            showSimpleScreen("CONTACTS", "Contacts feature coming soon!\nContact management interface will be available.")
            current_screen = "main"
        elseif current_screen == "online_users" then
            showSimpleScreen("ONLINE USERS", "Online users feature coming soon!\nUser directory will be available.")
            current_screen = "main"
        elseif current_screen == "emergency" then
            showSimpleScreen("EMERGENCY ALERTS", "Emergency alerts feature coming soon!\nSecurity integration will be available.")
            current_screen = "main"
        elseif current_screen == "settings" then
            showSimpleScreen("SETTINGS", "Settings feature coming soon!\nConfiguration options will be available.")
            current_screen = "main"
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
            print("- App Store integration")
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
