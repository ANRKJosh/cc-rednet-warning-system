-- PoggishTown Server v2.0
-- Central server for message relay, user management, and app distribution
-- Handles both pogphone and pogalert protocols

local PHONE_PROTOCOL = "pogphone"
local SECURITY_PROTOCOL = "pogalert"
local SERVER_CONFIG_FILE = "pogserver_config"
local USERS_FILE = "pogserver_users"
local MESSAGES_FILE = "pogserver_messages"
local LOGS_FILE = "pogserver_logs"

-- Configuration
local config = {
    server_name = "PoggishTown Central",
    max_stored_messages = 1000,
    message_retention_days = 7,
    auto_relay_messages = true,
    require_ender_modem = true,
    log_all_activity = true,
    app_repository_enabled = true,
    security_monitoring = true,
    heartbeat_interval = 30,
    user_timeout = 300,  -- 5 minutes before marking user offline
    -- Security password management
    security_password = "poggishtown2025",  -- Master security password
    allow_password_requests = true,        -- Allow devices to request password verification
    -- Remote configuration
    allow_remote_config = true,            -- Allow pushing config to devices
    modem_detection_override = {},         -- Per-device modem type overrides
    apps = {
        ["poggishtown-security"] = {
            name = "PoggishTown Security",
            version = "2.0",
            url = "https://raw.githubusercontent.com/your-repo/poggishtown-security.lua",
            description = "Password-protected alarm system",
            compatible_devices = {"computer", "terminal"}
        },
        ["poggishtown-phone"] = {
            name = "PoggishTown Phone", 
            version = "2.0",
            url = "https://raw.githubusercontent.com/your-repo/poggishtown-phone.lua",
            description = "Modern messaging and communication",
            compatible_devices = {"terminal", "computer"}
        }
    }
}

-- Global state
local computer_id = os.getComputerID()
local modem_side = nil
local server_start_time = os.time()

local connected_users = {}  -- Currently online users
local stored_messages = {}  -- Messages for offline users
local security_nodes = {}   -- Security system nodes
local authenticated_users = {}  -- Users authenticated for security features
local active_security_alarms = {}  -- Track active alarms globally
local server_stats = {
    messages_relayed = 0,
    users_served = 0,
    uptime_start = os.time(),
    security_alerts = 0,
    password_requests = 0,
    config_pushes = 0
}

-- Logging system
local function log(message, level)
    level = level or "INFO"
    local timestamp = textutils.formatTime(os.time(), true)
    local log_entry = "[" .. timestamp .. "] [" .. level .. "] " .. message
    
    print(log_entry)
    
    if config.log_all_activity then
        local file = fs.open(LOGS_FILE, "a")
        if file then
            file.writeLine(log_entry)
            file.close()
        end
        
        -- Rotate log file if too large
        if fs.exists(LOGS_FILE) and fs.getSize(LOGS_FILE) > 50000 then
            -- Keep only last 100 lines
            local old_file = fs.open(LOGS_FILE, "r")
            local lines = {}
            if old_file then
                local line = old_file.readLine()
                while line do
                    table.insert(lines, line)
                    line = old_file.readLine()
                end
                old_file.close()
                
                local new_file = fs.open(LOGS_FILE, "w")
                if new_file then
                    local start = math.max(1, #lines - 99)
                    for i = start, #lines do
                        new_file.writeLine(lines[i])
                    end
                    new_file.close()
                end
            end
        end
    end
end

-- Data management
local function saveData()
    -- Save config
    local file = fs.open(SERVER_CONFIG_FILE, "w")
    if file then
        file.write(textutils.serialize(config))
        file.close()
    end
    
    -- Save users
    file = fs.open(USERS_FILE, "w")
    if file then
        file.write(textutils.serialize(connected_users))
        file.close()
    end
    
    -- Save messages (clean old ones first)
    local current_time = os.time()
    local cleaned_messages = {}
    for _, msg in ipairs(stored_messages) do
        if (current_time - msg.timestamp) < (config.message_retention_days * 24 * 3600) then
            table.insert(cleaned_messages, msg)
        end
    end
    stored_messages = cleaned_messages
    
    -- Keep only recent messages
    if #stored_messages > config.max_stored_messages then
        local recent_messages = {}
        local start = #stored_messages - config.max_stored_messages + 1
        for i = start, #stored_messages do
            table.insert(recent_messages, stored_messages[i])
        end
        stored_messages = recent_messages
    end
    
    file = fs.open(MESSAGES_FILE, "w")
    if file then
        file.write(textutils.serialize(stored_messages))
        file.close()
    end
end

local function loadData()
    -- Load config
    if fs.exists(SERVER_CONFIG_FILE) then
        local file = fs.open(SERVER_CONFIG_FILE, "r")
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
    
    -- Load stored messages
    if fs.exists(MESSAGES_FILE) then
        local file = fs.open(MESSAGES_FILE, "r")
        if file then
            local content = file.readAll()
            file.close()
            local success, data = pcall(textutils.unserialize, content)
            if success and data then
                stored_messages = data
            end
        end
    end
end

-- Modem detection
local function hasEnderModem()
    local modem = peripheral.wrap(modem_side)
    if modem then
        if modem.isWireless and not modem.isWireless() then
            return true
        end
        if not modem.isWireless then
            return true
        end
    end
    return false
end

local function initializeModem()
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            
            if config.require_ender_modem and not hasEnderModem() then
                log("WARNING: Ender modem required but not detected on " .. side, "WARN")
                if #peripheral.getNames() == 1 then
                    log("No other modems available, continuing anyway...", "WARN")
                    return true
                end
            else
                return true
            end
        end
    end
    return false
end

-- Security and authentication functions
local function hashPassword(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 1000000
    end
    return tostring(hash)
end

local function authenticateUser(user_id, password_hash)
    if hashPassword(config.security_password) == password_hash then
        authenticated_users[user_id] = {
            authenticated_time = os.time(),
            expires = os.time() + 3600  -- 1 hour authentication
        }
        server_stats.password_requests = server_stats.password_requests + 1
        log("User " .. user_id .. " authenticated for security features")
        return true
    end
    return false
end

local function isUserAuthenticated(user_id)
    local auth = authenticated_users[user_id]
    if auth and os.time() < auth.expires then
        return true
    end
    authenticated_users[user_id] = nil  -- Clean up expired auth
    return false
end

local function sendPasswordResponse(user_id, password_attempt)
    if not config.allow_password_requests then
        return
    end
    
    local is_correct = authenticateUser(user_id, password_attempt)
    
    local response = {
        type = "security_auth_response",
        authenticated = is_correct,
        expires = is_correct and (os.time() + 3600) or nil,
        server_name = config.server_name
    }
    
    rednet.send(user_id, response, PHONE_PROTOCOL)
    log("Password verification " .. (is_correct and "SUCCESS" or "FAILED") .. " for user " .. user_id)
end

-- Remote configuration functions
local function sendConfigUpdate(user_id, config_data)
    if not config.allow_remote_config then
        return false
    end
    
    local message = {
        type = "config_update",
        config_data = config_data,
        server_name = config.server_name,
        timestamp = os.time()
    }
    
    rednet.send(user_id, message, PHONE_PROTOCOL)
    server_stats.config_pushes = server_stats.config_pushes + 1
    log("Config update sent to user " .. user_id)
    return true
end

local function broadcastConfigUpdate(config_data)
    if not config.allow_remote_config then
        return 0
    end
    
    local count = 0
    for user_id, _ in pairs(connected_users) do
        if sendConfigUpdate(user_id, config_data) then
            count = count + 1
        end
    end
    
    log("Config update broadcast to " .. count .. " users")
    return count
end

local function setModemOverride(user_id, modem_type)
    config.modem_detection_override[user_id] = modem_type
    saveData()
    
    -- Send config update to specific user
    local config_data = {
        modem_type_override = modem_type,
        force_ender_modem = (modem_type == "ender")
    }
    
    sendConfigUpdate(user_id, config_data)
    log("Modem override set for user " .. user_id .. ": " .. modem_type)
end
-- User management
local function updateUserPresence(user_id, username, device_type)
    connected_users[user_id] = {
        username = username,
        device_type = device_type,
        last_seen = os.time(),
        first_connected = connected_users[user_id] and connected_users[user_id].first_connected or os.time()
    }
    
    if not connected_users[user_id].first_connected then
        server_stats.users_served = server_stats.users_served + 1
        log("New user connected: " .. username .. " (ID: " .. user_id .. ", Type: " .. device_type .. ")")
    end
end

local function cleanOfflineUsers()
    local current_time = os.time()
    local removed_users = {}
    
    for user_id, user_data in pairs(connected_users) do
        if (current_time - user_data.last_seen) > config.user_timeout then
            table.insert(removed_users, user_data.username)
            connected_users[user_id] = nil
        end
    end
    
    for _, username in ipairs(removed_users) do
        log("User timed out: " .. username)
    end
end

-- Message handling
local function storeMessage(from_id, to_id, content, msg_type)
    local message = {
        id = #stored_messages + 1,
        from_id = from_id,
        to_id = to_id,
        content = content,
        msg_type = msg_type or "direct",
        timestamp = os.time(),
        delivered = false
    }
    
    table.insert(stored_messages, message)
    saveData()
    return message
end

local function getStoredMessages(user_id)
    local user_messages = {}
    for _, msg in ipairs(stored_messages) do
        if msg.to_id == user_id and not msg.delivered then
            table.insert(user_messages, msg)
            msg.delivered = true  -- Mark as delivered
        end
    end
    return user_messages
end

local function relayMessage(original_sender, message)
    -- Relay direct messages to target user
    if message.type == "direct_message" and message.to_id then
        if connected_users[message.to_id] then
            -- User is online, relay immediately
            rednet.send(message.to_id, message, PHONE_PROTOCOL)
            server_stats.messages_relayed = server_stats.messages_relayed + 1
            log("Relayed message from " .. (connected_users[original_sender] and connected_users[original_sender].username or original_sender) .. 
                " to " .. (connected_users[message.to_id] and connected_users[message.to_id].username or message.to_id))
        else
            -- User is offline, store message
            storeMessage(message.from_id, message.to_id, message.content, "direct")
            log("Stored message for offline user " .. message.to_id)
        end
    end
    
    -- Broadcast user presence updates
    if message.type == "user_presence" then
        rednet.broadcast(message, PHONE_PROTOCOL)
    end
end

-- Security monitoring
local function handleSecurityMessage(sender_id, message)
    if not config.security_monitoring then return end
    
    if message.type == "security_alert" then
        server_stats.security_alerts = server_stats.security_alerts + 1
        log("SECURITY ALERT: " .. (message.action or "unknown") .. " " .. 
            (message.alarm_type or "") .. " from " .. 
            (message.source_name or sender_id), "ALERT")
        
        -- Track active alarms globally
        if message.action == "start" then
            active_security_alarms[sender_id] = {
                type = message.alarm_type or "general",
                source_name = message.source_name or ("Node-" .. sender_id),
                start_time = message.timestamp or os.time(),
                device_type = message.device_type or "unknown"
            }
            log("Active alarm added: " .. sender_id .. " (" .. (message.alarm_type or "general") .. ")")
        elseif message.action == "stop" then
            -- If it's a cancel from this specific device, clear just their alarm
            if active_security_alarms[sender_id] then
                active_security_alarms[sender_id] = nil
                log("Active alarm cleared: " .. sender_id)
            end
            -- If it's a global cancel, clear all alarms
            if message.alarm_type == nil or message.global_cancel then
                active_security_alarms = {}
                log("All active alarms cleared by " .. sender_id)
            end
        end
        
        -- Store security node info
        security_nodes[sender_id] = {
            last_seen = os.time(),
            device_name = message.source_name or ("Node-" .. sender_id),
            device_type = message.device_type or "unknown",
            last_action = message.action,
            alarm_type = message.alarm_type,
            alarm_active = (message.action == "start")
        }
        
        -- IMPORTANT: Relay security messages to other devices (except back to sender)
        if config.auto_relay_messages then
            log("Relaying security alert to network")
            
            -- Add relay information to prevent loops
            local relay_message = {}
            for key, value in pairs(message) do
                relay_message[key] = value
            end
            relay_message.relayed_by_server = computer_id
            relay_message.original_sender = sender_id
            
            -- Broadcast to everyone except the original sender
            for user_id, user_data in pairs(connected_users) do
                if user_id ~= sender_id then
                    rednet.send(user_id, relay_message, SECURITY_PROTOCOL)
                end
            end
            
            -- Also broadcast generally for any devices not in connected_users list
            rednet.broadcast(relay_message, SECURITY_PROTOCOL)
        end
        
    elseif message.type == "security_heartbeat" then
        security_nodes[sender_id] = {
            last_seen = os.time(),
            device_name = message.device_name or ("Node-" .. sender_id),
            device_type = message.device_type or "unknown",
            alarm_active = message.alarm_active,
            alarm_type = message.alarm_type
        }
        
        -- Send active alarms to newly connected devices
        if message.alarm_active == false and next(active_security_alarms) then
            -- Device is online but not alarming - send them current active alarms
            for alarm_source, alarm_data in pairs(active_security_alarms) do
                if alarm_source ~= sender_id then
                    local sync_message = {
                        type = "security_alert",
                        action = "start",
                        alarm_type = alarm_data.type,
                        source_id = alarm_source,
                        source_name = alarm_data.source_name,
                        timestamp = alarm_data.start_time,
                        device_type = alarm_data.device_type,
                        sync_message = true  -- Mark as sync to avoid loops
                    }
                    rednet.send(sender_id, sync_message, SECURITY_PROTOCOL)
                    log("Sent alarm sync to " .. sender_id .. " for alarm from " .. alarm_source)
                end
            end
        end
    end
end

-- App repository
local function handleAppRequest(sender_id, message)
    if not config.app_repository_enabled then return end
    
    if message.type == "app_list_request" then
        local app_list = {}
        for app_id, app_data in pairs(config.apps) do
            app_list[app_id] = {
                name = app_data.name,
                version = app_data.version,
                description = app_data.description,
                compatible_devices = app_data.compatible_devices
            }
        end
        
        local response = {
            type = "app_list_response",
            apps = app_list,
            server_name = config.server_name
        }
        
        rednet.send(sender_id, response, PHONE_PROTOCOL)
        log("Sent app list to " .. sender_id)
        
    elseif message.type == "app_download_request" then
        local app_id = message.app_id
        if config.apps[app_id] then
            local response = {
                type = "app_download_response",
                app_id = app_id,
                download_url = config.apps[app_id].url,
                name = config.apps[app_id].name,
                version = config.apps[app_id].version
            }
            
            rednet.send(sender_id, response, PHONE_PROTOCOL)
            log("Sent download info for " .. app_id .. " to " .. sender_id)
        end
    end
end

-- Server announcements
local function broadcastServerAnnouncement()
    local announcement = {
        type = "server_announcement",
        server_name = config.server_name,
        server_id = computer_id,
        capabilities = {
            message_relay = config.auto_relay_messages,
            app_repository = config.app_repository_enabled,
            security_monitoring = config.security_monitoring
        },
        uptime = os.time() - server_stats.uptime_start,
        connected_users = #connected_users
    }
    
    rednet.broadcast(announcement, PHONE_PROTOCOL)
end

local function sendUserList(requester_id)
    local user_list = {}
    for user_id, user_data in pairs(connected_users) do
        if user_id ~= requester_id then  -- Don't include the requester
            user_list[user_id] = {
                username = user_data.username,
                device_type = user_data.device_type,
                last_seen = user_data.last_seen
            }
        end
    end
    
    local response = {
        type = "user_list_response",
        users = user_list,
        server_name = config.server_name
    }
    
    rednet.send(requester_id, response, PHONE_PROTOCOL)
end

-- Message processing
local function handleMessage(sender_id, message, protocol)
    if protocol == PHONE_PROTOCOL then
        if message.type == "user_presence" then
            updateUserPresence(message.user_id, message.username, message.device_type)
            
            -- Send stored messages to newly connected user
            local stored = getStoredMessages(message.user_id)
            for _, stored_msg in ipairs(stored) do
                local delivery_msg = {
                    type = "direct_message",
                    from_id = stored_msg.from_id,
                    from_username = connected_users[stored_msg.from_id] and connected_users[stored_msg.from_id].username or ("User-" .. stored_msg.from_id),
                    to_id = stored_msg.to_id,
                    content = stored_msg.content,
                    timestamp = stored_msg.timestamp,
                    message_id = "stored_" .. stored_msg.id
                }
                rednet.send(message.user_id, delivery_msg, PHONE_PROTOCOL)
            end
            
            if #stored > 0 then
                log("Delivered " .. #stored .. " stored messages to " .. message.username)
            end
            
        elseif message.type == "direct_message" then
            if config.auto_relay_messages then
                relayMessage(sender_id, message)
            end
            
        elseif message.type == "user_list_request" then
            sendUserList(sender_id)
            
        elseif message.type == "security_auth_request" then
            -- Handle password verification requests
            if message.password_hash then
                sendPasswordResponse(sender_id, message.password_hash)
            end
            
        elseif message.type == "modem_detection_request" then
            -- Handle modem type detection requests
            local override = config.modem_detection_override[sender_id]
            local response = {
                type = "modem_detection_response",
                recommended_type = override or "auto",
                force_ender = override == "ender",
                server_recommendation = config.require_ender_modem and "ender" or "wireless"
            }
            rednet.send(sender_id, response, PHONE_PROTOCOL)
            
        else
            -- Handle app repository requests
            handleAppRequest(sender_id, message)
        end
        
    elseif protocol == SECURITY_PROTOCOL then
        handleSecurityMessage(sender_id, message)
    end
end

-- Helper function to count table entries
local function tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Status display
local function drawServerStatus()
    term.clear()
    term.setCursorPos(1, 1)
    
    local w, h = term.getSize()
    
    print("=== POGGISHTOWN SERVER ===")
    print("Server: " .. string.sub(config.server_name, 1, 20))
    print("ID: " .. computer_id .. " | Up: " .. math.floor((os.time() - server_stats.uptime_start) / 60) .. "m")
    print("")
    
    -- Show active security alarms prominently
    local active_alarm_count = tableCount(active_security_alarms)
    if active_alarm_count > 0 then
        term.setTextColor(colors.red)
        print("! ACTIVE ALARMS: " .. active_alarm_count .. " !")
        term.setTextColor(colors.white)
        for source_id, alarm_data in pairs(active_security_alarms) do
            print("  " .. alarm_data.source_name .. " (" .. alarm_data.type .. ")")
        end
        print("")
    end
    
    -- Network info (compact)
    print("Network: " .. (modem_side or "None") .. (hasEnderModem() and " (Ender)" or " (WiFi)"))
    print("")
    
    -- Statistics (compact)
    print("Stats:")
    print("  Users: " .. tableCount(connected_users) .. " | Messages: " .. server_stats.messages_relayed)
    print("  Alerts: " .. server_stats.security_alerts .. " | Stored: " .. #stored_messages)
    print("")
    
    -- Services status (compact)
    print("Services:")
    local relay_status = config.auto_relay_messages and "ON" or "OFF"
    local app_status = config.app_repository_enabled and "ON" or "OFF"
    local sec_status = config.security_monitoring and "ON" or "OFF"
    
    term.setTextColor(config.auto_relay_messages and colors.green or colors.red)
    print("  Relay:" .. relay_status)
    term.setTextColor(config.app_repository_enabled and colors.green or colors.red)
    print("  Apps:" .. app_status)
    term.setTextColor(config.security_monitoring and colors.green or colors.red)
    print("  Security:" .. sec_status)
    term.setTextColor(colors.white)
    print("")
    
    -- Connected users (compact)
    local user_count = tableCount(connected_users)
    if user_count > 0 then
        print("Users (" .. user_count .. "):")
        local shown = 0
        for user_id, user_data in pairs(connected_users) do
            if shown < 3 then
                local name = string.sub(user_data.username, 1, 12)
                local device = string.sub(user_data.device_type, 1, 1):upper()
                print("  [" .. device .. "] " .. name)
                shown = shown + 1
            end
        end
        if user_count > 3 then
            print("  +" .. (user_count - 3) .. " more")
        end
    else
        print("No users online")
    end
    
    print("")
    print("Keys: S-Status L-Logs U-Users")
    print("      A-Apps C-Config Q-Quit")
end

local function showDetailedLogs()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SERVER LOGS ===")
    
    if fs.exists(LOGS_FILE) then
        local file = fs.open(LOGS_FILE, "r")
        if file then
            local lines = {}
            local line = file.readLine()
            while line do
                table.insert(lines, line)
                line = file.readLine()
            end
            file.close()
            
            -- Show last 15 lines
            local start = math.max(1, #lines - 14)
            for i = start, #lines do
                -- Color code log levels
                local line_text = lines[i]
                if string.find(line_text, "%[ALERT%]") then
                    term.setTextColor(colors.red)
                elseif string.find(line_text, "%[WARN%]") then
                    term.setTextColor(colors.yellow)
                elseif string.find(line_text, "%[ERROR%]") then
                    term.setTextColor(colors.red)
                else
                    term.setTextColor(colors.white)
                end
                print(line_text)
            end
            term.setTextColor(colors.white)
        end
    else
        print("No log file found.")
    end
    
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
end

local function showUserDetails()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== CONNECTED USERS ===")
    
    if next(connected_users) == nil then
        print("No users currently connected.")
    else
        print("ID    | Username          | Device   | Last Seen")
        print("------|-------------------|----------|----------")
        
        local user_list = {}
        for user_id, user_data in pairs(connected_users) do
            table.insert(user_list, {id = user_id, data = user_data})
        end
        table.sort(user_list, function(a, b) return a.data.username < b.data.username end)
        
        for _, user in ipairs(user_list) do
            local last_seen = os.time() - user.data.last_seen
            local time_str = last_seen < 60 and (last_seen .. "s") or 
                           last_seen < 3600 and (math.floor(last_seen/60) .. "m") or
                           (math.floor(last_seen/3600) .. "h")
                           
            printf("%-5s | %-17s | %-8s | %s ago", 
                   tostring(user.id), 
                   string.sub(user.data.username, 1, 17),
                   string.sub(user.data.device_type, 1, 8),
                   time_str)
        end
    end
    
    print("")
    print("Security Nodes:")
    if next(security_nodes) == nil then
        print("No security nodes detected.")
    else
        for node_id, node_data in pairs(security_nodes) do
            local status = node_data.alarm_active and ("[ALARM: " .. (node_data.alarm_type or "unknown") .. "]") or "[OK]"
            local last_seen = os.time() - node_data.last_seen
            local time_str = last_seen < 60 and (last_seen .. "s") or (math.floor(last_seen/60) .. "m")
            
            if node_data.alarm_active then
                term.setTextColor(colors.red)
            else
                term.setTextColor(colors.green)
            end
            print("  " .. node_data.device_name .. " " .. status .. " (last: " .. time_str .. ")")
            term.setTextColor(colors.white)
        end
    end
    
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
end

local function showAppRepository()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== APP REPOSITORY ===")
    
    if not config.app_repository_enabled then
        print("App repository is DISABLED")
    else
        print("Available Apps:")
        print("")
        
        for app_id, app_data in pairs(config.apps) do
            print("ID: " .. app_id)
            print("Name: " .. app_data.name .. " v" .. app_data.version)
            print("Description: " .. app_data.description)
            print("Compatible: " .. table.concat(app_data.compatible_devices, ", "))
            print("URL: " .. app_data.url)
            print("")
        end
    end
    
    print("Press any key to return...")
    os.pullEvent("key")
end

local function configureServer()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SERVER CONFIGURATION ===")
    print("")
    print("1. Server Name: " .. config.server_name)
    print("2. Message Relay: " .. (config.auto_relay_messages and "ENABLED" or "DISABLED"))
    print("3. App Repository: " .. (config.app_repository_enabled and "ENABLED" or "DISABLED"))
    print("4. Security Monitoring: " .. (config.security_monitoring and "ENABLED" or "DISABLED"))
    print("5. Require Ender Modem: " .. (config.require_ender_modem and "YES" or "NO"))
    print("6. Message Retention: " .. config.message_retention_days .. " days")
    print("7. Max Stored Messages: " .. config.max_stored_messages)
    print("8. Security Password: " .. string.rep("*", #config.security_password))
    print("9. Remote Config: " .. (config.allow_remote_config and "ENABLED" or "DISABLED"))
    print("10. Set User Modem Override")
    print("11. Broadcast Config Update")
    print("")
    print("Enter option number to change, or 'B' to go back:")
    
    local input = read()
    
    if input == "1" then
        print("Enter new server name:")
        local new_name = read()
        if new_name and new_name ~= "" then
            config.server_name = new_name
            saveData()
            print("Server name updated!")
        end
    elseif input == "2" then
        config.auto_relay_messages = not config.auto_relay_messages
        saveData()
        print("Message relay " .. (config.auto_relay_messages and "enabled" or "disabled"))
    elseif input == "3" then
        config.app_repository_enabled = not config.app_repository_enabled
        saveData()
        print("App repository " .. (config.app_repository_enabled and "enabled" or "disabled"))
    elseif input == "4" then
        config.security_monitoring = not config.security_monitoring
        saveData()
        print("Security monitoring " .. (config.security_monitoring and "enabled" or "disabled"))
    elseif input == "5" then
        config.require_ender_modem = not config.require_ender_modem
        saveData()
        print("Ender modem requirement " .. (config.require_ender_modem and "enabled" or "disabled"))
    elseif input == "6" then
        print("Enter retention days (current: " .. config.message_retention_days .. "):")
        local days = tonumber(read())
        if days and days > 0 then
            config.message_retention_days = days
            saveData()
            print("Message retention updated!")
        end
    elseif input == "7" then
        print("Enter max messages (current: " .. config.max_stored_messages .. "):")
        local max_msgs = tonumber(read())
        if max_msgs and max_msgs > 0 then
            config.max_stored_messages = max_msgs
            saveData()
            print("Max stored messages updated!")
        end
    elseif input == "8" then
        print("Enter new security password:")
        local new_pass = read("*")
        if new_pass and new_pass ~= "" then
            config.security_password = new_pass
            saveData()
            print("Security password updated!")
            print("Note: Devices will need to re-authenticate")
        end
    elseif input == "9" then
        config.allow_remote_config = not config.allow_remote_config
        saveData()
        print("Remote configuration " .. (config.allow_remote_config and "enabled" or "disabled"))
    elseif input == "10" then
        print("Connected users:")
        local user_list = {}
        for user_id, user_data in pairs(connected_users) do
            table.insert(user_list, {id = user_id, data = user_data})
        end
        
        if #user_list == 0 then
            print("No users online")
        else
            for i, user in ipairs(user_list) do
                local override = config.modem_detection_override[user.id] or "auto"
                print(i .. ". " .. user.data.username .. " (ID:" .. user.id .. ") - Override: " .. override)
            end
            
            print("")
            print("Enter user number:")
            local user_num = tonumber(read())
            if user_num and user_num >= 1 and user_num <= #user_list then
                print("Modem type (ender/wireless/auto):")
                local modem_type = read()
                if modem_type and (modem_type == "ender" or modem_type == "wireless" or modem_type == "auto") then
                    setModemOverride(user_list[user_num].id, modem_type)
                    print("Modem override set!")
                end
            end
        end
    elseif input == "11" then
        print("Broadcast config update to all users? (y/n)")
        local confirm = read()
        if confirm:lower() == "y" then
            local count = broadcastConfigUpdate({
                server_name = config.server_name,
                require_ender_modem = config.require_ender_modem
            })
            print("Config update sent to " .. count .. " users!")
        end
    end
    
    if input ~= "b" and input ~= "B" then
        sleep(2)
    end
end

-- Helper function for formatted printing
function printf(format, ...)
    print(string.format(format, ...))
end

-- Main server loop
local function main()
    print("=== PoggishTown Server Starting ===")
    
    loadData()
    
    if not initializeModem() then
        print("ERROR: No suitable modem found!")
        if config.require_ender_modem then
            print("This server requires an ender modem.")
        end
        print("Please attach appropriate modem and restart.")
        return
    end
    
    log("PoggishTown Server starting...")
    log("Server: " .. config.server_name .. " (ID: " .. computer_id .. ")")
    log("Modem: " .. modem_side .. (hasEnderModem() and " (Ender)" or " (Wireless)"))
    log("Services: " .. 
        (config.auto_relay_messages and "Relay " or "") ..
        (config.app_repository_enabled and "Apps " or "") ..
        (config.security_monitoring and "Security " or ""))
    
    -- Send initial server announcement
    broadcastServerAnnouncement()
    
    -- Main event loop
    local announcement_timer = os.startTimer(60)  -- Announce every minute
    local cleanup_timer = os.startTimer(120)      -- Cleanup every 2 minutes
    local save_timer = os.startTimer(300)         -- Save every 5 minutes
    
    while true do
        drawServerStatus()
        
        -- Handle events with timeout
        local result = nil
        
        parallel.waitForAny(
            function()
                while true do
                    local event, param1, param2, param3 = os.pullEvent()
                    
                    if event == "key" then
                        local key = param1
                        if key == keys.s then
                            drawServerStatus()
                            result = "continue"
                            return
                        elseif key == keys.l then
                            showDetailedLogs()
                            result = "continue"
                            return
                        elseif key == keys.u then
                            showUserDetails()
                            result = "continue"
                            return
                        elseif key == keys.a then
                            showAppRepository()
                            result = "continue"
                            return
                        elseif key == keys.c then
                            configureServer()
                            result = "continue"
                            return
                        elseif key == keys.q then
                            result = "quit"
                            return
                        end
                        
                    elseif event == "rednet_message" then
                        local sender_id, message, protocol = param1, param2, param3
                        if protocol == PHONE_PROTOCOL or protocol == SECURITY_PROTOCOL then
                            handleMessage(sender_id, message, protocol)
                        end
                        
                    elseif event == "timer" then
                        local timer_id = param1
                        if timer_id == announcement_timer then
                            broadcastServerAnnouncement()
                            announcement_timer = os.startTimer(60)
                        elseif timer_id == cleanup_timer then
                            cleanOfflineUsers()
                            cleanup_timer = os.startTimer(120)
                        elseif timer_id == save_timer then
                            saveData()
                            save_timer = os.startTimer(300)
                        end
                    end
                end
            end,
            function()
                sleep(5)  -- Refresh screen every 5 seconds
            end
        )
        
        -- Check if quit was requested
        if result == "quit" then
            break
        end
    end
    
    log("Server shutting down...")
    saveData()
    
    -- Send shutdown announcement
    local shutdown_msg = {
        type = "server_shutdown",
        server_name = config.server_name,
        message = "Server shutting down for maintenance"
    }
    rednet.broadcast(shutdown_msg, PHONE_PROTOCOL)
    
    print("PoggishTown Server shutdown complete.")
end

-- Run the server
main()
