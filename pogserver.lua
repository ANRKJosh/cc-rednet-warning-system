-- PoggishTown Server v2.1 - Fixed Version
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
        ["poggishtown-phone"] = {
            name = "PoggishTown Phone", 
            version = "2.1",
            url = "https://raw.githubusercontent.com/your-repo/poggishtown-phone.lua",
            description = "Modern messaging and communication system",
            compatible_devices = {"terminal"},
            device_restrictions = {"terminal"},
            requires_auth = false,
            category = "communication",
            install_name = "pogphone"
        },
        ["poggishtown-admin"] = {
            name = "PoggishTown Admin",
            version = "2.1",
            url = "https://raw.githubusercontent.com/your-repo/poggishtown-admin.lua", 
            description = "Server administration and network monitoring tools",
            compatible_devices = {"terminal"},
            device_restrictions = {"terminal"},
            requires_auth = true,
            category = "admin",
            install_name = "pogadmin"
        },
        ["poggishtown-security"] = {
            name = "PoggishTown Security",
            version = "2.1", 
            url = "https://raw.githubusercontent.com/your-repo/poggishtown-security.lua",
            description = "Dedicated alarm and security monitoring system",
            compatible_devices = {"computer"},
            device_restrictions = {"computer"},
            requires_auth = true,
            category = "security",
            install_name = "pogsecurity"
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
    config_pushes = 0,
    network_errors = 0,
    messages_stored = 0,
    messages_delivered = 0
}

-- Helper function to count table entries
local function tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Helper function for formatted printing
function printf(format, ...)
    print(string.format(format, ...))
end

-- Enhanced logging system with error handling
local function log(message, level)
    level = level or "INFO"
    local timestamp = textutils.formatTime(os.time(), true)
    local log_entry = "[" .. timestamp .. "] [" .. level .. "] " .. message
    
    print(log_entry)
    
    if config.log_all_activity then
        local success, error_msg = pcall(function()
            local file = fs.open(LOGS_FILE, "a")
            if file then
                file.writeLine(log_entry)
                file.close()
            end
            
            -- Enhanced log rotation
            if fs.exists(LOGS_FILE) and fs.getSize(LOGS_FILE) > 50000 then
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
        end)
        
        if not success then
            print("Warning: Failed to write to log file: " .. tostring(error_msg))
        end
    end
end

-- Data management with enhanced error handling
local function saveData()
    local success, error_msg = pcall(function()
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
    end)
    
    if not success then
        log("Error saving data: " .. tostring(error_msg), "ERROR")
    end
end

local function loadData()
    local success, error_msg = pcall(function()
        -- Load config
        if fs.exists(SERVER_CONFIG_FILE) then
            local file = fs.open(SERVER_CONFIG_FILE, "r")
            if file then
                local content = file.readAll()
                file.close()
                local data_success, data = pcall(textutils.unserialize, content)
                if data_success and data then
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
                local data_success, data = pcall(textutils.unserialize, content)
                if data_success and data then
                    stored_messages = data
                end
            end
        end
    end)
    
    if not success then
        log("Error loading data (using defaults): " .. tostring(error_msg), "WARN")
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

-- Enhanced security and authentication functions
local function hashPassword(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 1000000
    end
    return tostring(hash)
end

-- Enhanced user authentication with better security tracking
local function authenticateUser(user_id, password_hash)
    if hashPassword(config.security_password) == password_hash then
        authenticated_users[user_id] = {
            authenticated_time = os.time(),
            expires = os.time() + 3600,  -- 1 hour authentication
            login_count = (authenticated_users[user_id] and authenticated_users[user_id].login_count or 0) + 1
        }
        server_stats.password_requests = server_stats.password_requests + 1
        log("User " .. user_id .. " authenticated for security features (login #" .. authenticated_users[user_id].login_count .. ")")
        
        -- Enhanced: Send current alarm status to newly authenticated user
        if next(active_security_alarms) then
            local notification_count = 0
            for alarm_source, alarm_data in pairs(active_security_alarms) do
                local alarm_notification = {
                    type = "security_notification", 
                    alert_type = alarm_data.type,
                    action = "start",
                    source_name = alarm_data.source_name,
                    timestamp = alarm_data.start_time,
                    server_name = config.server_name
                }
                
                local success, error_msg = pcall(function()
                    rednet.send(user_id, alarm_notification, PHONE_PROTOCOL)
                end)
                
                if success then
                    notification_count = notification_count + 1
                else
                    log("Failed to send alarm notification to user " .. user_id .. ": " .. tostring(error_msg), "WARN")
                    server_stats.network_errors = server_stats.network_errors + 1
                end
            end
            
            if notification_count > 0 then
                log("Sent " .. notification_count .. " active alarm notifications to newly authenticated user " .. user_id)
            end
        end
        
        return true
    else
        log("Authentication failed for user " .. user_id .. " - invalid password hash", "WARN")
        return false
    end
end

local function isUserAuthenticated(user_id)
    local auth = authenticated_users[user_id]
    if auth and os.time() < auth.expires then
        return true
    end
    authenticated_users[user_id] = nil  -- Clean up expired auth
    return false
end

-- FIXED: Authentication response function using broadcast
local function sendPasswordResponse(user_id, password_attempt)
    if not config.allow_password_requests then
        log("Password requests disabled, rejecting auth for user " .. user_id, "WARN")
        return
    end
    
    log("Processing password attempt for user " .. user_id, "DEBUG")
    
    local is_correct = authenticateUser(user_id, password_attempt)
    
    local response = {
        type = "security_auth_response",
        authenticated = is_correct,
        target_user_id = user_id,
        server_name = config.server_name,
        server_id = computer_id,
        timestamp = os.time()
    }
    
    if is_correct then
        response.expires = os.time() + 3600
    end
    
    log("Sending auth response: authenticated=" .. tostring(is_correct) .. " target=" .. user_id, "DEBUG")
    
    -- Send multiple times to ensure delivery
    for i = 1, 3 do
        local success, error_msg = pcall(function()
            rednet.broadcast(response, PHONE_PROTOCOL)
        end)
        
        if success then
            log("Auth response broadcast " .. i .. "/3 successful for user " .. user_id, "DEBUG")
        else
            log("Auth response broadcast " .. i .. "/3 failed for user " .. user_id .. ": " .. tostring(error_msg), "ERROR")
            server_stats.network_errors = server_stats.network_errors + 1
        end
        
        sleep(0.1)  -- Small delay between broadcasts
    end
    
    log("Password verification " .. (is_correct and "SUCCESS" or "FAILED") .. " for user " .. user_id, "INFO")
end

-- Enhanced cleanup function for performance
local function cleanupStaleData()
    local current_time = os.time()
    local cleanup_count = 0
    
    -- Clean up stale security nodes
    for node_id, node_data in pairs(security_nodes) do
        if (current_time - node_data.last_seen) > 300 then  -- 5 minutes
            security_nodes[node_id] = nil
            cleanup_count = cleanup_count + 1
        end
    end
    
    -- Clean up expired authentication
    for user_id, auth_data in pairs(authenticated_users) do
        if current_time >= auth_data.expires then
            authenticated_users[user_id] = nil
            cleanup_count = cleanup_count + 1
        end
    end
    
    if cleanup_count > 0 then
        log("Cleaned up " .. cleanup_count .. " stale data entries")
    end
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
    
    local success, error_msg = pcall(function()
        rednet.send(user_id, message, PHONE_PROTOCOL)
    end)
    
    if success then
        server_stats.config_pushes = server_stats.config_pushes + 1
        log("Config update sent to user " .. user_id)
        return true
    else
        log("Failed to send config update to " .. user_id .. ": " .. tostring(error_msg), "ERROR")
        server_stats.network_errors = server_stats.network_errors + 1
        return false
    end
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

-- FIXED: Message handling with consistent structure and proper delivery marking
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
    server_stats.messages_stored = server_stats.messages_stored + 1
    saveData()
    return message
end

-- FIXED: Only mark as delivered AFTER successful send
local function getStoredMessages(user_id)
    local user_messages = {}
    for _, msg in ipairs(stored_messages) do
        if msg.to_id == user_id and not msg.delivered then
            table.insert(user_messages, msg)
            -- DON'T mark as delivered yet - wait for successful send
        end
    end
    return user_messages
end

-- FIXED: Mark messages as delivered only after successful delivery
local function markMessagesDelivered(message_ids)
    for _, msg in ipairs(stored_messages) do
        for _, delivered_id in ipairs(message_ids) do
            if msg.id == delivered_id then
                msg.delivered = true
                server_stats.messages_delivered = server_stats.messages_delivered + 1
                break
            end
        end
    end
    saveData()
end

-- FIXED: Consistent message structure for both real-time and stored messages
local function createStandardMessage(from_id, to_id, content, message_id, timestamp)
    local from_user = connected_users[from_id]
    return {
        type = "direct_message",
        from_id = from_id,
        from_username = from_user and from_user.username or ("User-" .. from_id),
        to_id = to_id,
        content = content,
        timestamp = timestamp or os.time(),
        message_id = message_id or (from_id .. "_" .. os.time() .. "_" .. math.random(1000, 9999))
    }
end

local function relayMessage(original_sender, message)
    -- Relay direct messages to target user
    if message.type == "direct_message" and message.to_id then
        if connected_users[message.to_id] then
            -- User is online, relay immediately with consistent structure
            local relay_message = createStandardMessage(
                message.from_id, 
                message.to_id, 
                message.content, 
                message.message_id, 
                message.timestamp
            )
            
            local success, error_msg = pcall(function()
                rednet.send(message.to_id, relay_message, PHONE_PROTOCOL)
            end)
            
            if success then
                server_stats.messages_relayed = server_stats.messages_relayed + 1
                log("Relayed message from " .. (connected_users[original_sender] and connected_users[original_sender].username or original_sender) .. 
                    " to " .. (connected_users[message.to_id] and connected_users[message.to_id].username or message.to_id))
            else
                log("Failed to relay message: " .. tostring(error_msg), "ERROR")
                server_stats.network_errors = server_stats.network_errors + 1
                -- Store message for offline delivery due to network error
                storeMessage(message.from_id, message.to_id, message.content, "direct")
                log("Stored message for offline delivery due to network error")
            end
        else
            -- User is offline, store message
            storeMessage(message.from_id, message.to_id, message.content, "direct")
            log("Stored message for offline user " .. message.to_id)
        end
    end
    
    -- Broadcast user presence updates
    if message.type == "user_presence" then
        local success, error_msg = pcall(function()
            rednet.broadcast(message, PHONE_PROTOCOL)
        end)
        
        if not success then
            log("Failed to broadcast user presence: " .. tostring(error_msg), "ERROR")
            server_stats.network_errors = server_stats.network_errors + 1
        end
    end
end

-- Enhanced security monitoring and cross-protocol relay
local function handleSecurityMessage(sender_id, message)
    if not config.security_monitoring then return end
    
    -- Enhanced password verification - allow messages from authenticated phones
    local is_authenticated = false
    local auth_method = "none"
    
    if message.password_hash then
        if message.password_hash == hashPassword(config.security_password) then
            is_authenticated = true
            auth_method = "password_hash"
        end
    elseif message.authenticated_user and connected_users[sender_id] then
        -- Allow messages from authenticated phone users
        if isUserAuthenticated(sender_id) then
            is_authenticated = true
            auth_method = "phone_auth"
        end
    end
    
    if not is_authenticated then
        log("Rejected unauthorized security message from " .. sender_id .. " (method: " .. auth_method .. ")", "WARN")
        return
    end
    
    -- Enhanced: Handle security test messages
    if message.type == "security_test" then
        log("Security test received from " .. sender_id)
        local response = {
            type = "security_test_response",
            server_name = config.server_name,
            server_id = computer_id,
            timestamp = os.time()
        }
        
        local success, error_msg = pcall(function()
            rednet.send(sender_id, response, SECURITY_PROTOCOL)
        end)
        
        if not success then
            log("Failed to send security test response to " .. sender_id .. ": " .. tostring(error_msg), "ERROR")
            server_stats.network_errors = server_stats.network_errors + 1
        end
        return
    end
    
    if message.type == "security_alert" then
        server_stats.security_alerts = server_stats.security_alerts + 1
        local action_text = message.action or "unknown"
        local alarm_type = message.alarm_type or "general"
        local source_name = message.source_name or ("Node-" .. sender_id)
        
        log("SECURITY ALERT: " .. action_text .. " " .. alarm_type .. " from " .. source_name .. " (auth: " .. auth_method .. ")", "ALERT")
        
        -- Track active alarms globally with enhanced info
        if message.action == "start" then
            active_security_alarms[sender_id] = {
                type = alarm_type,
                source_name = source_name,
                start_time = message.timestamp or os.time(),
                device_type = message.device_type or "unknown",
                auth_method = auth_method
            }
            log("Active alarm added: " .. sender_id .. " (" .. alarm_type .. ")")
            
        elseif message.action == "stop" then
            log("Processing stop message from " .. sender_id .. ", global_cancel: " .. tostring(message.global_cancel))
            
            if message.global_cancel then
                -- Global cancel - clear all alarms with enhanced logging
                local cleared_count = tableCount(active_security_alarms)
                local cleared_sources = {}
                for alarm_id, alarm_data in pairs(active_security_alarms) do
                    table.insert(cleared_sources, alarm_data.source_name)
                end
                active_security_alarms = {}
                log("Global cancel: cleared " .. cleared_count .. " active alarms from: " .. table.concat(cleared_sources, ", "))
            else
                -- Specific device cancel - clear just that alarm  
                if active_security_alarms[sender_id] then
                    local alarm_data = active_security_alarms[sender_id]
                    active_security_alarms[sender_id] = nil
                    log("Cleared specific alarm from " .. alarm_data.source_name .. " (" .. alarm_data.type .. ")")
                else
                    log("No active alarm found for " .. sender_id .. " to clear")
                end
            end
        end
        
        -- Update security node info with enhanced tracking
        security_nodes[sender_id] = {
            last_seen = os.time(),
            device_name = source_name,
            device_type = message.device_type or "unknown",
            last_action = message.action,
            alarm_type = alarm_type,
            alarm_active = (message.action == "start"),
            auth_method = auth_method,
            message_count = (security_nodes[sender_id] and security_nodes[sender_id].message_count or 0) + 1
        }
        
        -- Enhanced cross-protocol relay with better error handling
        if config.auto_relay_messages then
            log("Broadcasting security alert on security protocol")
            
            -- Don't relay back to sender to prevent loops
            if not message.relayed_by_server then
                local relay_message = {}
                for key, value in pairs(message) do
                    relay_message[key] = value
                end
                relay_message.relayed_by_server = computer_id
                relay_message.original_sender = sender_id
                
                -- Ensure password hash is included for security systems
                if not relay_message.password_hash then
                    relay_message.password_hash = hashPassword(config.security_password)
                end
                
                local success, error_msg = pcall(function()
                    rednet.broadcast(relay_message, SECURITY_PROTOCOL)
                end)
                
                if success then
                    log("Security alert broadcast completed")
                else
                    log("Failed to broadcast security alert: " .. tostring(error_msg), "ERROR")
                    server_stats.network_errors = server_stats.network_errors + 1
                end
                
                -- Enhanced: Send phone notifications to authenticated users
                local notification_count = 0
                local phone_notification = {
                    type = "security_notification",
                    alert_type = alarm_type,
                    action = message.action,
                    source_name = source_name,
                    timestamp = message.timestamp or os.time(),
                    server_name = config.server_name
                }
                
                -- Optimized loop - collect authenticated users first
                local authenticated_users_list = {}
                for user_id, _ in pairs(connected_users) do
                    if user_id ~= sender_id and isUserAuthenticated(user_id) then
                        table.insert(authenticated_users_list, user_id)
                    end
                end
                
                -- Send notifications with error handling
                for _, user_id in ipairs(authenticated_users_list) do
                    local success, error_msg = pcall(function()
                        rednet.send(user_id, phone_notification, PHONE_PROTOCOL)
                    end)
                    
                    if success then
                        notification_count = notification_count + 1
                    else
                        log("Failed to send notification to user " .. user_id .. ": " .. tostring(error_msg), "WARN")
                        server_stats.network_errors = server_stats.network_errors + 1
                    end
                end
                
                if notification_count > 0 then
                    log("Phone notifications sent to " .. notification_count .. " authenticated users")
                end
            end
        end
        
    elseif message.type == "security_heartbeat" then
        -- Enhanced heartbeat processing
        security_nodes[sender_id] = {
            last_seen = os.time(),
            device_name = message.device_name or ("Node-" .. sender_id),
            device_type = message.device_type or "unknown",
            alarm_active = message.alarm_active,
            alarm_type = message.alarm_type,
            message_count = (security_nodes[sender_id] and security_nodes[sender_id].message_count or 0) + 1
        }
        
        -- Enhanced alarm sync with error handling
        if message.alarm_active == false and next(active_security_alarms) then
            local sync_count = 0
            log("Syncing " .. tableCount(active_security_alarms) .. " active alarms to " .. sender_id)
            
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
                        sync_message = true,
                        relayed_by_server = computer_id,
                        password_hash = hashPassword(config.security_password)
                    }
                    
                    local success, error_msg = pcall(function()
                        rednet.send(sender_id, sync_message, SECURITY_PROTOCOL)
                    end)
                    
                    if success then
                        sync_count = sync_count + 1
                        log("Sent alarm sync to " .. sender_id .. " for alarm from " .. alarm_source)
                    else
                        log("Failed to sync alarm to " .. sender_id .. ": " .. tostring(error_msg), "ERROR")
                        server_stats.network_errors = server_stats.network_errors + 1
                    end
                end
            end
            
            if sync_count > 0 then
                log("Successfully synced " .. sync_count .. " alarms to " .. sender_id)
            end
        end
    end
end

-- Admin request handling
local function handleAdminRequest(sender_id, message)
    local user_data = connected_users[sender_id]
    if not user_data then return end
    
    -- Check if sender is authenticated for admin access
    if not isUserAuthenticated(sender_id) then
        log("Unauthorized admin request from " .. sender_id, "WARN")
        return
    end
    
    if message.type == "admin_status_request" then
        local response = {
            type = "admin_status_response",
            server_name = config.server_name,
            server_id = computer_id,
            stats = {
                uptime = os.time() - server_stats.uptime_start,
                messages_relayed = server_stats.messages_relayed,
                messages_stored = server_stats.messages_stored,
                messages_delivered = server_stats.messages_delivered,
                security_alerts = server_stats.security_alerts,
                password_requests = server_stats.password_requests,
                network_errors = server_stats.network_errors,
                connected_users = tableCount(connected_users),
                authenticated_users = tableCount(authenticated_users),
                active_alarms = tableCount(active_security_alarms),
                security_nodes = tableCount(security_nodes),
                stored_messages = #stored_messages
            },
            capabilities = {
                message_relay = config.auto_relay_messages,
                app_repository = config.app_repository_enabled,
                security_monitoring = config.security_monitoring
            },
            timestamp = os.time()
        }
        
        local success, error_msg = pcall(function()
            rednet.send(sender_id, response, PHONE_PROTOCOL)
        end)
        
        if success then
            log("Sent admin status to " .. sender_id)
        else
            log("Failed to send admin status to " .. sender_id .. ": " .. tostring(error_msg), "ERROR")
        end
    end
end

local function handleAdminCommand(sender_id, message)
    local user_data = connected_users[sender_id]
    if not user_data then return end
    
    -- Check if sender is authenticated for admin access
    if not isUserAuthenticated(sender_id) then
        log("Unauthorized admin command from " .. sender_id .. ": " .. (message.command or "unknown"), "WARN")
        return
    end
    
    local command = message.command
    local admin_user = message.admin_user or "Unknown"
    
    log("Admin command received from " .. admin_user .. " (" .. sender_id .. "): " .. command, "INFO")
    
    if command == "status_request" then
        -- Send detailed status
        handleAdminRequest(sender_id, {type = "admin_status_request"})
        
    elseif command == "emergency_shutdown" then
        log("EMERGENCY SHUTDOWN requested by admin " .. admin_user, "ALERT")
        
        -- Send shutdown notice to all users
        local shutdown_notice = {
            type = "server_shutdown",
            reason = "Emergency shutdown by admin",
            admin_user = admin_user,
            timestamp = os.time()
        }
        
        local success, error_msg = pcall(function()
            rednet.broadcast(shutdown_notice, PHONE_PROTOCOL)
        end)
        
        -- Graceful shutdown
        saveData()
        
        -- Send confirmation to admin
        local confirm = {
            type = "admin_command_response",
            command = command,
            status = "executed",
            message = "Server shutting down..."
        }
        
        pcall(function()
            rednet.send(sender_id, confirm, PHONE_PROTOCOL)
        end)
        
        print("EMERGENCY SHUTDOWN initiated by admin: " .. admin_user)
        sleep(2)
        os.shutdown()
        
    elseif command == "clear_logs" then
        -- Clear log file
        if fs.exists(LOGS_FILE) then
            fs.delete(LOGS_FILE)
            log("Server logs cleared by admin " .. admin_user, "INFO")
        end
        
        local confirm = {
            type = "admin_command_response", 
            command = command,
            status = "executed",
            message = "Server logs cleared"
        }
        
        pcall(function()
            rednet.send(sender_id, confirm, PHONE_PROTOCOL)
        end)
        
    elseif command == "restart_services" then
        -- Restart key services
        log("Service restart requested by admin " .. admin_user, "INFO")
        
        -- Reset statistics
        server_stats.network_errors = 0
        
        -- Clean up stale data
        cleanupStaleData()
        
        local confirm = {
            type = "admin_command_response",
            command = command,
            status = "executed", 
            message = "Services restarted"
        }
        
        pcall(function()
            rednet.send(sender_id, confirm, PHONE_PROTOCOL)
        end)
        
    else
        log("Unknown admin command: " .. command .. " from " .. admin_user, "WARN")
        
        local error_response = {
            type = "admin_command_response",
            command = command,
            status = "error",
            message = "Unknown command"
        }
        
        pcall(function()
            rednet.send(sender_id, error_response, PHONE_PROTOCOL)
        end)
    end
end

local function relayAdminBroadcast(sender_id, message)
    local user_data = connected_users[sender_id]
    if not user_data then return end
    
    -- Check if sender is authenticated for admin access
    if not isUserAuthenticated(sender_id) then
        log("Unauthorized admin broadcast from " .. sender_id, "WARN")
        return
    end
    
    local admin_user = message.from_admin or "Unknown Admin"
    log("Admin broadcast from " .. admin_user .. ": " .. (message.message or ""), "INFO")
    
    -- Relay to all connected users except sender
    local broadcast_count = 0
    for user_id, _ in pairs(connected_users) do
        if user_id ~= sender_id then
            local success, error_msg = pcall(function()
                rednet.send(user_id, message, PHONE_PROTOCOL)
            end)
            
            if success then
                broadcast_count = broadcast_count + 1
            else
                server_stats.network_errors = server_stats.network_errors + 1
            end
        end
    end
    
    if broadcast_count > 0 then
        log("Admin broadcast relayed to " .. broadcast_count .. " users")
    end
end

-- Enhanced app repository with device restrictions
local function handleAppRequest(sender_id, message)
    if not config.app_repository_enabled then return end
    
    local user_data = connected_users[sender_id]
    if not user_data then
        log("App request from unknown user " .. sender_id, "WARN")
        return
    end
    
    local user_device_type = user_data.device_type
    local user_authenticated = isUserAuthenticated(sender_id)
    
    if message.type == "app_list_request" then
        local filtered_apps = {}
        
        for app_id, app_data in pairs(config.apps) do
            -- Check device compatibility
            local device_compatible = false
            for _, device in ipairs(app_data.compatible_devices) do
                if device == user_device_type then
                    device_compatible = true
                    break
                end
            end
            
            -- Check device restrictions
            local device_allowed = true
            if app_data.device_restrictions then
                device_allowed = false
                for _, device in ipairs(app_data.device_restrictions) do
                    if device == user_device_type then
                        device_allowed = true
                        break
                    end
                end
            end
            
            -- Check authentication requirements
            local auth_ok = true
            if app_data.requires_auth and not user_authenticated then
                auth_ok = false
            end
            
            -- Only include if all checks pass
            if device_compatible and device_allowed and auth_ok then
                filtered_apps[app_id] = {
                    name = app_data.name,
                    version = app_data.version,
                    description = app_data.description,
                    category = app_data.category or "general",
                    install_name = app_data.install_name or app_id
                }
            end
        end
        
        local response = {
            type = "app_list_response",
            apps = filtered_apps,
            server_name = config.server_name,
            user_device_type = user_device_type,
            user_authenticated = user_authenticated
        }
        
        local success, error_msg = pcall(function()
            rednet.send(sender_id, response, PHONE_PROTOCOL)
        end)
        
        if success then
            log("Sent filtered app list to " .. sender_id .. " (" .. tableCount(filtered_apps) .. " apps)")
        else
            log("Failed to send app list to " .. sender_id .. ": " .. tostring(error_msg), "ERROR")
            server_stats.network_errors = server_stats.network_errors + 1
        end
        
    elseif message.type == "app_download_request" then
        local app_id = message.app_id
        local app_data = config.apps[app_id]
        
        if not app_data then
            log("App download request for unknown app: " .. app_id, "WARN")
            return
        end
        
        -- Verify user can access this app (same checks as above)
        local device_compatible = false
        for _, device in ipairs(app_data.compatible_devices) do
            if device == user_device_type then
                device_compatible = true
                break
            end
        end
        
        local device_allowed = true
        if app_data.device_restrictions then
            device_allowed = false
            for _, device in ipairs(app_data.device_restrictions) do
                if device == user_device_type then
                    device_allowed = true
                    break
                end
            end
        end
        
        local auth_ok = true
        if app_data.requires_auth and not user_authenticated then
            auth_ok = false
        end
        
        if not (device_compatible and device_allowed and auth_ok) then
            log("Unauthorized app download request from " .. sender_id .. " for " .. app_id, "WARN")
            
            local error_response = {
                type = "app_download_error",
                app_id = app_id,
                error = "Access denied",
                reason = not auth_ok and "authentication_required" or "device_incompatible"
            }
            
            local success, error_msg = pcall(function()
                rednet.send(sender_id, error_response, PHONE_PROTOCOL)
            end)
            return
        end
        
        local response = {
            type = "app_download_response",
            app_id = app_id,
            download_url = app_data.url,
            name = app_data.name,
            version = app_data.version,
            install_name = app_data.install_name or app_id,
            description = app_data.description
        }
        
        local success, error_msg = pcall(function()
            rednet.send(sender_id, response, PHONE_PROTOCOL)
        end)
        
        if success then
            log("Sent download info for " .. app_id .. " to " .. sender_id)
        else
            log("Failed to send download info to " .. sender_id .. ": " .. tostring(error_msg), "ERROR")
            server_stats.network_errors = server_stats.network_errors + 1
        end
        
    elseif message.type == "app_update_check" then
        -- Handle update checking
        local installed_apps = message.installed_apps or {}
        local updates_available = {}
        
        for app_id, installed_version in pairs(installed_apps) do
            local app_data = config.apps[app_id]
            if app_data and app_data.version ~= installed_version then
                -- Check if user can still access this app
                local device_compatible = false
                for _, device in ipairs(app_data.compatible_devices) do
                    if device == user_device_type then
                        device_compatible = true
                        break
                    end
                end
                
                if device_compatible then
                    updates_available[app_id] = {
                        current_version = installed_version,
                        new_version = app_data.version,
                        name = app_data.name
                    }
                end
            end
        end
        
        local response = {
            type = "app_update_response",
            updates_available = updates_available,
            server_name = config.server_name
        }
        
        local success, error_msg = pcall(function()
            rednet.send(sender_id, response, PHONE_PROTOCOL)
        end)
        
        if success and next(updates_available) then
            log("Sent update notifications to " .. sender_id .. " (" .. tableCount(updates_available) .. " updates)")
        end
    end
end

-- Broadcast update notifications to all users
local function broadcastAppUpdates(app_id)
    if not config.app_repository_enabled then return end
    
    local app_data = config.apps[app_id]
    if not app_data then return end
    
    local notification = {
        type = "app_update_notification",
        app_id = app_id,
        app_name = app_data.name,
        new_version = app_data.version,
        description = app_data.description,
        server_name = config.server_name
    }
    
    local notified_count = 0
    for user_id, user_data in pairs(connected_users) do
        -- Check if user's device is compatible with this app
        local device_compatible = false
        for _, device in ipairs(app_data.compatible_devices) do
            if device == user_data.device_type then
                device_compatible = true
                break
            end
        end
        
        if device_compatible then
            local success, error_msg = pcall(function()
                rednet.send(user_id, notification, PHONE_PROTOCOL)
            end)
            
            if success then
                notified_count = notified_count + 1
            else
                server_stats.network_errors = server_stats.network_errors + 1
            end
        end
    end
    
    if notified_count > 0 then
        log("Broadcast update notification for " .. app_data.name .. " to " .. notified_count .. " users")
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
        connected_users = tableCount(connected_users)
    }
    
    local success, error_msg = pcall(function()
        rednet.broadcast(announcement, PHONE_PROTOCOL)
    end)
    
    if not success then
        log("Failed to broadcast server announcement: " .. tostring(error_msg), "ERROR")
        server_stats.network_errors = server_stats.network_errors + 1
    end
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
    
    local success, error_msg = pcall(function()
        rednet.send(requester_id, response, PHONE_PROTOCOL)
    end)
    
    if not success then
        log("Failed to send user list to " .. requester_id .. ": " .. tostring(error_msg), "ERROR")
        server_stats.network_errors = server_stats.network_errors + 1
    end
end

-- Enhanced message processing with comprehensive error handling
local function handleMessage(sender_id, message, protocol)
    -- Wrap entire message handling in error protection
    local success, error_msg = pcall(function()
        if protocol == PHONE_PROTOCOL then
            if message.type == "user_presence" then
                updateUserPresence(message.user_id, message.username, message.device_type)
                
                -- FIXED: Send stored messages with consistent structure and proper delivery tracking
                local stored = getStoredMessages(message.user_id)
                local delivered_ids = {}
                
                for _, stored_msg in ipairs(stored) do
                    local delivery_msg = createStandardMessage(
                        stored_msg.from_id,
                        stored_msg.to_id,
                        stored_msg.content,
                        "stored_" .. stored_msg.id,
                        stored_msg.timestamp
                    )
                    
                    local success, error_msg = pcall(function()
                        rednet.send(message.user_id, delivery_msg, PHONE_PROTOCOL)
                    end)
                    
                    if success then
                        table.insert(delivered_ids, stored_msg.id)
                    else
                        log("Failed to deliver stored message to " .. message.user_id .. ": " .. tostring(error_msg), "WARN")
                        server_stats.network_errors = server_stats.network_errors + 1
                    end
                end
                
                -- Only mark as delivered AFTER successful send
                if #delivered_ids > 0 then
                    markMessagesDelivered(delivered_ids)
                    log("Delivered " .. #delivered_ids .. "/" .. #stored .. " stored messages to " .. message.username)
                end
                
                -- Enhanced: Send security status to authenticated users
                if isUserAuthenticated(message.user_id) and next(active_security_alarms) then
                    local alarm_count = tableCount(active_security_alarms)
                    local status_msg = {
                        type = "security_status",
                        active_alarms = alarm_count,
                        server_name = config.server_name,
                        timestamp = os.time()
                    }
                    
                    local success, error_msg = pcall(function()
                        rednet.send(message.user_id, status_msg, PHONE_PROTOCOL)
                    end)
                    
                    if success then
                        log("Sent security status to " .. message.username .. " (" .. alarm_count .. " active alarms)")
                    else
                        log("Failed to send security status to " .. message.username .. ": " .. tostring(error_msg), "WARN")
                        server_stats.network_errors = server_stats.network_errors + 1
                    end
                end
                
            elseif message.type == "direct_message" then
                if config.auto_relay_messages then
                    relayMessage(sender_id, message)
                end
                
            elseif message.type == "user_list_request" then
                sendUserList(sender_id)
                
            elseif message.type == "security_auth_request" then
                log("Received auth request from sender " .. sender_id .. " for user " .. (message.user_id or "unknown"), "DEBUG")
                if message.password_hash and message.user_id then
                    log("Auth request valid - hash=" .. message.password_hash .. " user=" .. message.user_id, "DEBUG")
                    sendPasswordResponse(message.user_id, message.password_hash)
                    log("Processing auth request from sender " .. sender_id .. " for user " .. message.user_id)
                else
                    log("Auth request missing data - hash=" .. tostring(message.password_hash) .. " user=" .. tostring(message.user_id), "WARN")
                end
                
            elseif message.type == "modem_detection_request" then
                log("Received modem detection request from user " .. (message.user_id or sender_id), "DEBUG")
                local override = config.modem_detection_override[sender_id]
                local response = {
                    type = "modem_detection_response",
                    recommended_type = override or "auto",
                    force_ender = override == "ender",
                    server_recommendation = config.require_ender_modem and "ender" or "wireless"
                }
                
                local success, error_msg = pcall(function()
                    rednet.broadcast(response, PHONE_PROTOCOL)
                end)
                
                if success then
                    log("Sent modem detection response to user " .. (message.user_id or sender_id), "DEBUG")
                else
                    log("Failed to send modem detection response to " .. sender_id .. ": " .. tostring(error_msg), "ERROR")
                    server_stats.network_errors = server_stats.network_errors + 1
                end
                
            elseif message.type == "network_test" then
                -- Enhanced: Handle network test requests
                local response = {
                    type = "network_test_response",
                    server_name = config.server_name,
                    server_id = computer_id,
                    timestamp = os.time(),
                    uptime = os.time() - server_stats.uptime_start,
                    active_alarms = tableCount(active_security_alarms),
                    connected_users = tableCount(connected_users),
                    network_errors = server_stats.network_errors
                }
                
                local success, error_msg = pcall(function()
                    rednet.send(sender_id, response, PHONE_PROTOCOL)
                end)
                
                if not success then
                    log("Failed to send network test response to " .. sender_id .. ": " .. tostring(error_msg), "ERROR")
                    server_stats.network_errors = server_stats.network_errors + 1
                end
                
            elseif message.type == "app_list_request" then
                local user_data = connected_users[sender_id]
                if user_data then
                    handleAppRequest(sender_id, message)
                end
                
            elseif message.type == "app_download_request" then
                local user_data = connected_users[sender_id]
                if user_data then
                    handleAppRequest(sender_id, message)
                end
                
            elseif message.type == "app_update_check" then
                local user_data = connected_users[sender_id]
                if user_data then
                    handleAppRequest(sender_id, message)
                end
                
            elseif message.type == "admin_status_request" then
                -- Handle admin status requests
                handleAdminRequest(sender_id, message)
                
            elseif message.type == "admin_command" then
                -- Handle admin commands
                handleAdminCommand(sender_id, message)
                
            elseif message.type == "admin_broadcast" then
                -- Relay admin broadcasts to all users
                relayAdminBroadcast(sender_id, message)
                
            else
                -- Check if it's an unhandled app-related message
                if message.type and string.find(message.type, "app_") then
                    handleAppRequest(sender_id, message)
                end
            end
            
        elseif protocol == SECURITY_PROTOCOL then
            handleSecurityMessage(sender_id, message)
        end
    end)
    
    if not success then
        log("Error handling message from " .. sender_id .. " on " .. protocol .. ": " .. tostring(error_msg), "ERROR")
        server_stats.network_errors = server_stats.network_errors + 1
    end
end

-- Enhanced status display with better monitoring
local function drawServerStatus()
    term.clear()
    term.setCursorPos(1, 1)
    
    print("=== POGGISHTOWN SERVER v2.1 ===")
    print("Server: " .. string.sub(config.server_name, 1, 20))
    print("ID: " .. computer_id .. " | Up: " .. math.floor((os.time() - server_stats.uptime_start) / 60) .. "m")
    print("")
    
    -- Enhanced alarm display with more details
    local active_alarm_count = tableCount(active_security_alarms)
    if active_alarm_count > 0 then
        term.setTextColor(colors.red)
        print("! ACTIVE ALARMS: " .. active_alarm_count .. " !")
        term.setTextColor(colors.white)
        
        -- Show up to 3 most recent alarms
        local alarm_list = {}
        for source_id, alarm_data in pairs(active_security_alarms) do
            table.insert(alarm_list, {id = source_id, data = alarm_data})
        end
        table.sort(alarm_list, function(a, b) return a.data.start_time > b.data.start_time end)
        
        for i = 1, math.min(3, #alarm_list) do
            local alarm = alarm_list[i]
            local elapsed = os.time() - alarm.data.start_time
            print("  " .. alarm.data.source_name .. " (" .. alarm.data.type .. ") " .. elapsed .. "s")
        end
        
        if #alarm_list > 3 then
            print("  +" .. (#alarm_list - 3) .. " more...")
        end
        print("")
    end
    
    -- Enhanced authentication status
    local auth_count = tableCount(authenticated_users)
    if auth_count > 0 then
        term.setTextColor(colors.yellow)
        print("Authenticated users: " .. auth_count)
        term.setTextColor(colors.white)
        print("")
    end
    
    -- Network info
    print("Network: " .. (modem_side or "None") .. (hasEnderModem() and " (Ender)" or " (WiFi)"))
    if server_stats.network_errors > 0 then
        term.setTextColor(colors.red)
        print("Network errors: " .. server_stats.network_errors)
        term.setTextColor(colors.white)
    end
    print("")
    
    -- Enhanced statistics with color coding
    print("Stats:")
    term.setTextColor(colors.lightBlue)
    print("  Users: " .. tableCount(connected_users) .. " | Messages: " .. server_stats.messages_relayed)
    print("  Stored: " .. server_stats.messages_stored .. " | Delivered: " .. server_stats.messages_delivered)
    print("  Alerts: " .. server_stats.security_alerts .. " | Auth: " .. server_stats.password_requests)
    print("  Nodes: " .. tableCount(security_nodes) .. " | Pending: " .. #stored_messages)
    term.setTextColor(colors.white)
    print("")
    
    -- Services status
    print("Services:")
    term.setTextColor(config.auto_relay_messages and colors.green or colors.red)
    print("  Relay: " .. (config.auto_relay_messages and "ON" or "OFF"))
    term.setTextColor(config.app_repository_enabled and colors.green or colors.red)
    print("  Apps: " .. (config.app_repository_enabled and "ON" or "OFF"))
    term.setTextColor(config.security_monitoring and colors.green or colors.red)
    print("  Security: " .. (config.security_monitoring and "ON" or "OFF"))
    term.setTextColor(colors.white)
    print("")
    
    -- Enhanced user display with color coding
    local user_count = tableCount(connected_users)
    if user_count > 0 then
        print("Users (" .. user_count .. "):")
        local shown = 0
        for user_id, user_data in pairs(connected_users) do
            if shown < 3 then
                local name = string.sub(user_data.username, 1, 12)
                local device = string.sub(user_data.device_type, 1, 1):upper()
                local is_authenticated = isUserAuthenticated(user_id)
                local time_ago = os.time() - user_data.last_seen
                local time_str = time_ago < 60 and (time_ago .. "s") or (math.floor(time_ago/60) .. "m")
                
                -- Color code device type
                if user_data.device_type == "terminal" then
                    term.setTextColor(colors.cyan)
                else
                    term.setTextColor(colors.blue)
                end
                
                local auth_indicator = is_authenticated and " [AUTH]" or ""
                print("  [" .. device .. "] " .. name .. auth_indicator .. " (" .. time_str .. ")")
                term.setTextColor(colors.white)
                shown = shown + 1
            end
        end
        if user_count > 3 then
            term.setTextColor(colors.lightGray)
            print("  +" .. (user_count - 3) .. " more")
            term.setTextColor(colors.white)
        end
    else
        term.setTextColor(colors.gray)
        print("No users online")
        term.setTextColor(colors.white)
    end
    
    print("")
    print("Keys: S-Status L-Logs U-Users D-Debug")
    print("      A-Apps C-Config R-Repository Q-Quit")
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

-- Enhanced user details view
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

-- Enhanced: Debug information screen
local function showDebugInfo()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== DEBUG INFORMATION ===")
    print("")
    print("Server Statistics:")
    print("  Uptime: " .. math.floor((os.time() - server_stats.uptime_start) / 60) .. " minutes")
    print("  Messages relayed: " .. server_stats.messages_relayed)
    print("  Messages stored: " .. server_stats.messages_stored)
    print("  Messages delivered: " .. server_stats.messages_delivered)
    print("  Security alerts: " .. server_stats.security_alerts)
    print("  Auth requests: " .. server_stats.password_requests)
    print("  Config pushes: " .. server_stats.config_pushes)
    print("  Network errors: " .. server_stats.network_errors)
    print("")
    
    print("Memory Usage:")
    print("  Connected users: " .. tableCount(connected_users))
    print("  Security nodes: " .. tableCount(security_nodes))
    print("  Authenticated users: " .. tableCount(authenticated_users))
    print("  Active alarms: " .. tableCount(active_security_alarms))
    print("  Stored messages: " .. #stored_messages)
    print("")
    
    print("Configuration:")
    print("  Auto relay: " .. (config.auto_relay_messages and "ON" or "OFF"))
    print("  Security monitoring: " .. (config.security_monitoring and "ON" or "OFF"))
    print("  App repository: " .. (config.app_repository_enabled and "ON" or "OFF"))
    print("  User timeout: " .. config.user_timeout .. "s")
    print("  Message retention: " .. config.message_retention_days .. " days")
    print("")
    
    print("Press any key to return...")
    os.pullEvent("key")
end

local function showAppRepository()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== APP REPOSITORY ===")
    
    if not config.app_repository_enabled then
        term.setTextColor(colors.red)
        print("App repository is DISABLED")
        term.setTextColor(colors.white)
        print("")
        print("Enable in Configuration menu first")
    else
        print("Available Apps:")
        print("")
        
        local app_count = 0
        for app_id, app_data in pairs(config.apps) do
            app_count = app_count + 1
            term.setTextColor(colors.yellow)
            print("ID: " .. app_id)
            term.setTextColor(colors.white)
            print("Name: " .. app_data.name .. " v" .. app_data.version)
            print("Description: " .. app_data.description)
            print("Devices: " .. table.concat(app_data.compatible_devices, ", "))
            if app_data.device_restrictions then
                term.setTextColor(colors.red)
                print("Restricted to: " .. table.concat(app_data.device_restrictions, ", "))
                term.setTextColor(colors.white)
            end
            if app_data.requires_auth then
                term.setTextColor(colors.yellow)
                print("Requires authentication")
                term.setTextColor(colors.white)
            end
            print("Install name: " .. (app_data.install_name or app_id))
            print("URL: " .. string.sub(app_data.url, 1, 50) .. (string.len(app_data.url) > 50 and "..." or ""))
            print("")
        end
        
        if app_count == 0 then
            term.setTextColor(colors.gray)
            print("No apps configured")
            term.setTextColor(colors.white)
        end
        
        print("Management:")
        print("A - Add App | E - Edit App | D - Delete App")
        print("U - Push Update Notification | R - Reload from File")
    end
    
    print("B - Back")
    print("")
    print("Enter choice:")
    
    local input = read()
    
    if input:lower() == "b" then
        return
    elseif input:lower() == "a" and config.app_repository_enabled then
        -- Add new app
        addNewApp()
    elseif input:lower() == "e" and config.app_repository_enabled then
        -- Edit existing app
        editApp()
    elseif input:lower() == "d" and config.app_repository_enabled then
        -- Delete app
        deleteApp()
    elseif input:lower() == "u" and config.app_repository_enabled then
        -- Push update notification
        pushUpdateNotification()
    elseif input:lower() == "r" and config.app_repository_enabled then
        -- Reload apps from external config
        print("Feature not implemented yet")
        sleep(1)
    end
end

local function addNewApp()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== ADD NEW APP ===")
    
    print("Enter app ID (lowercase, no spaces):")
    local app_id = read()
    if not app_id or app_id == "" or config.apps[app_id] then
        print("Invalid or existing app ID")
        sleep(1)
        return
    end
    
    print("Enter app name:")
    local app_name = read()
    if not app_name or app_name == "" then
        print("Name required")
        sleep(1)
        return
    end
    
    print("Enter version (e.g. 1.0):")
    local version = read()
    if not version or version == "" then
        version = "1.0"
    end
    
    print("Enter description:")
    local description = read()
    if not description or description == "" then
        description = "No description"
    end
    
    print("Enter download URL:")
    local url = read()
    if not url or url == "" then
        print("URL required")
        sleep(1)
        return
    end
    
    print("Compatible devices (comma separated - computer,terminal):")
    local devices_str = read()
    local compatible_devices = {}
    if devices_str and devices_str ~= "" then
        for device in devices_str:gmatch("[^,]+") do
            table.insert(compatible_devices, device:gsub("^%s*(.-)%s*$", "%1"))
        end
    else
        compatible_devices = {"computer", "terminal"}
    end
    
    print("Device restrictions (leave empty for none, or computer,terminal):")
    local restrictions_str = read()
    local device_restrictions = nil
    if restrictions_str and restrictions_str ~= "" then
        device_restrictions = {}
        for device in restrictions_str:gmatch("[^,]+") do
            table.insert(device_restrictions, device:gsub("^%s*(.-)%s*$", "%1"))
        end
    end
    
    print("Requires authentication? (y/N):")
    local auth_input = read()
    local requires_auth = auth_input:lower() == "y"
    
    print("Install filename (leave empty for app ID):")
    local install_name = read()
    if install_name == "" then
        install_name = app_id
    end
    
    print("Category (communication/security/admin/general):")
    local category = read()
    if category == "" then
        category = "general"
    end
    
    -- Add the app
    config.apps[app_id] = {
        name = app_name,
        version = version,
        url = url,
        description = description,
        compatible_devices = compatible_devices,
        device_restrictions = device_restrictions,
        requires_auth = requires_auth,
        category = category,
        install_name = install_name
    }
    
    saveData()
    
    term.setTextColor(colors.green)
    print("\nApp added successfully!")
    term.setTextColor(colors.white)
    print("Push update notification? (y/N)")
    
    local push_update = read()
    if push_update:lower() == "y" then
        broadcastAppUpdates(app_id)
        print("Update notification sent!")
    end
    
    sleep(2)
end

local function editApp()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== EDIT APP ===")
    
    local app_list = {}
    for app_id, _ in pairs(config.apps) do
        table.insert(app_list, app_id)
    end
    
    if #app_list == 0 then
        print("No apps to edit")
        sleep(1)
        return
    end
    
    print("Available apps:")
    for i, app_id in ipairs(app_list) do
        print(i .. ". " .. app_id .. " (" .. config.apps[app_id].name .. ")")
    end
    
    print("\nEnter app number:")
    local choice = tonumber(read())
    
    if not choice or choice < 1 or choice > #app_list then
        print("Invalid choice")
        sleep(1)
        return
    end
    
    local app_id = app_list[choice]
    local app_data = config.apps[app_id]
    
    print("\nEditing: " .. app_data.name)
    print("1. Name: " .. app_data.name)
    print("2. Version: " .. app_data.version)
    print("3. Description: " .. app_data.description)
    print("4. URL: " .. string.sub(app_data.url, 1, 40) .. "...")
    print("5. Compatible devices: " .. table.concat(app_data.compatible_devices, ", "))
    print("6. Restrictions: " .. (app_data.device_restrictions and table.concat(app_data.device_restrictions, ", ") or "None"))
    print("7. Requires auth: " .. (app_data.requires_auth and "Yes" or "No"))
    print("8. Install name: " .. app_data.install_name)
    print("9. Category: " .. app_data.category)
    
    print("\nEnter field number to edit (or Enter to finish):")
    local field = read()
    
    if field == "1" then
        print("New name:")
        local new_name = read()
        if new_name ~= "" then app_data.name = new_name end
    elseif field == "2" then
        print("New version:")
        local new_version = read()
        if new_version ~= "" then app_data.version = new_version end
    elseif field == "3" then
        print("New description:")
        local new_desc = read()
        if new_desc ~= "" then app_data.description = new_desc end
    elseif field == "4" then
        print("New URL:")
        local new_url = read()
        if new_url ~= "" then app_data.url = new_url end
    elseif field == "7" then
        print("Requires authentication? (y/N):")
        local auth_input = read()
        app_data.requires_auth = auth_input:lower() == "y"
    elseif field == "8" then
        print("New install name:")
        local new_install = read()
        if new_install ~= "" then app_data.install_name = new_install end
    elseif field == "9" then
        print("New category:")
        local new_category = read()
        if new_category ~= "" then app_data.category = new_category end
    end
    
    if field ~= "" then
        saveData()
        term.setTextColor(colors.green)
        print("App updated!")
        term.setTextColor(colors.white)
        
        print("Push update notification? (y/N)")
        local push_update = read()
        if push_update:lower() == "y" then
            broadcastAppUpdates(app_id)
            print("Update notification sent!")
        end
        sleep(2)
    end
end

local function deleteApp()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== DELETE APP ===")
    
    local app_list = {}
    for app_id, _ in pairs(config.apps) do
        table.insert(app_list, app_id)
    end
    
    if #app_list == 0 then
        print("No apps to delete")
        sleep(1)
        return
    end
    
    print("Available apps:")
    for i, app_id in ipairs(app_list) do
        print(i .. ". " .. app_id .. " (" .. config.apps[app_id].name .. ")")
    end
    
    print("\nEnter app number to delete:")
    local choice = tonumber(read())
    
    if not choice or choice < 1 or choice > #app_list then
        print("Invalid choice")
        sleep(1)
        return
    end
    
    local app_id = app_list[choice]
    local app_name = config.apps[app_id].name
    
    print("\nDelete " .. app_name .. "? (y/N)")
    local confirm = read()
    
    if confirm:lower() == "y" then
        config.apps[app_id] = nil
        saveData()
        
        term.setTextColor(colors.green)
        print("App deleted!")
        term.setTextColor(colors.white)
        sleep(1)
    end
end

local function pushUpdateNotification()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== PUSH UPDATE NOTIFICATION ===")
    
    local app_list = {}
    for app_id, _ in pairs(config.apps) do
        table.insert(app_list, app_id)
    end
    
    if #app_list == 0 then
        print("No apps available")
        sleep(1)
        return
    end
    
    print("Available apps:")
    for i, app_id in ipairs(app_list) do
        print(i .. ". " .. app_id .. " (" .. config.apps[app_id].name .. " v" .. config.apps[app_id].version .. ")")
    end
    print(#app_list + 1 .. ". All apps")
    
    print("\nEnter choice:")
    local choice = tonumber(read())
    
    if not choice or choice < 1 or choice > #app_list + 1 then
        print("Invalid choice")
        sleep(1)
        return
    end
    
    if choice == #app_list + 1 then
        -- Push all apps
        local count = 0
        for app_id, _ in pairs(config.apps) do
            broadcastAppUpdates(app_id)
            count = count + 1
        end
        print("Pushed updates for " .. count .. " apps")
    else
        -- Push specific app
        local app_id = app_list[choice]
        broadcastAppUpdates(app_id)
        print("Update notification sent for " .. config.apps[app_id].name)
    end
    
    sleep(2)
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

-- Enhanced main server loop
local function main()
    print("=== PoggishTown Server v2.1 Starting ===")
    
    loadData()
    
    if not initializeModem() then
        print("ERROR: No suitable modem found!")
        if config.require_ender_modem then
            print("This server requires an ender modem.")
        end
        print("Please attach appropriate modem and restart.")
        return
    end
    
    log("PoggishTown Server v2.1 starting...")
    log("Server: " .. config.server_name .. " (ID: " .. computer_id .. ")")
    log("Modem: " .. modem_side .. (hasEnderModem() and " (Ender)" or " (Wireless)"))
    log("Services: " .. 
        (config.auto_relay_messages and "Relay " or "") ..
        (config.app_repository_enabled and "Apps " or "") ..
        (config.security_monitoring and "Security " or ""))
    
    -- Send initial server announcement
    broadcastServerAnnouncement()
    
    -- Enhanced main event loop with cleanup
    local announcement_timer = os.startTimer(60)  -- Announce every minute
    local cleanup_timer = os.startTimer(120)      -- Cleanup every 2 minutes
    local save_timer = os.startTimer(300)         -- Save every 5 minutes
    local stale_cleanup_timer = os.startTimer(600) -- Enhanced: Cleanup stale data every 10 minutes
    
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
                        elseif key == keys.d then  -- Enhanced: Debug info screen
                            showDebugInfo()
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
                        elseif key == keys.r then
                            showAppRepository()
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
                        elseif timer_id == stale_cleanup_timer then  -- Enhanced: Stale data cleanup
                            cleanupStaleData()
                            stale_cleanup_timer = os.startTimer(600)
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
    
    -- Enhanced shutdown announcement with error handling
    local shutdown_msg = {
        type = "server_shutdown",
        server_name = config.server_name,
        message = "Server shutting down for maintenance"
    }
    
    local success, error_msg = pcall(function()
        rednet.broadcast(shutdown_msg, PHONE_PROTOCOL)
    end)
    
    if not success then
        log("Failed to send shutdown announcement: " .. tostring(error_msg), "ERROR")
    end
    
    print("PoggishTown Server v2.1 shutdown complete.")
end

-- Run the server
main()
