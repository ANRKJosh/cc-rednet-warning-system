-- PoggishTown Server v2.0 - Enhanced Security Message Relay
-- These are the enhancements needed for better cross-protocol communication

-- Enhanced security message handling with better relay logic
local function handleSecurityMessage(sender_id, message)
    if not config.security_monitoring then return end
    
    -- Enhanced password verification - allow messages from authenticated phones
    local is_authenticated = false
    if message.password_hash then
        if message.password_hash == hashPassword(config.security_password) then
            is_authenticated = true
        end
    elseif message.authenticated_user and connected_users[sender_id] then
        -- Allow messages from authenticated phone users
        is_authenticated = isUserAuthenticated(sender_id)
    end
    
    if not is_authenticated then
        log("Rejected unauthorized security message from " .. sender_id, "WARN")
        return
    end
    
    if message.type == "security_alert" then
        server_stats.security_alerts = server_stats.security_alerts + 1
        local action_text = message.action or "unknown"
        local alarm_type = message.alarm_type or "general"
        local source_name = message.source_name or ("Node-" .. sender_id)
        
        log("SECURITY ALERT: " .. action_text .. " " .. alarm_type .. " from " .. source_name, "ALERT")
        
        -- Track active alarms globally with enhanced info
        if message.action == "start" then
            active_security_alarms[sender_id] = {
                type = alarm_type,
                source_name = source_name,
                start_time = message.timestamp or os.time(),
                device_type = message.device_type or "unknown",
                origin_id = message.origin_id or sender_id
            }
            log("Active alarm added: " .. sender_id .. " (" .. alarm_type .. ")")
            
        elseif message.action == "stop" then
            log("Processing stop message from " .. sender_id .. ", global_cancel: " .. tostring(message.global_cancel))
            
            if message.global_cancel then
                -- Global cancel - clear all alarms
                local cleared_count = 0
                for alarm_id, _ in pairs(active_security_alarms) do
                    cleared_count = cleared_count + 1
                end
                active_security_alarms = {}
                log("Global cancel: cleared " .. cleared_count .. " active alarms")
            else
                -- Specific device cancel - clear just that alarm  
                if active_security_alarms[sender_id] then
                    active_security_alarms[sender_id] = nil
                    log("Cleared specific alarm from " .. sender_id)
                else
                    log("No active alarm found for " .. sender_id .. " to clear")
                end
            end
        end
        
        -- Update security node info
        security_nodes[sender_id] = {
            last_seen = os.time(),
            device_name = source_name,
            device_type = message.device_type or "unknown",
            last_action = message.action,
            alarm_type = alarm_type,
            alarm_active = (message.action == "start")
        }
        
        -- ENHANCED CROSS-PROTOCOL RELAY
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
                
                rednet.broadcast(relay_message, SECURITY_PROTOCOL)
                log("Security alert broadcast completed")
                
                -- Also send as phone notification to authenticated users
                local phone_notification = {
                    type = "security_notification",
                    alert_type = alarm_type,
                    action = message.action,
                    source_name = source_name,
                    timestamp = message.timestamp or os.time(),
                    server_name = config.server_name
                }
                
                -- Send to all authenticated phone users
                for user_id, _ in pairs(connected_users) do
                    if user_id ~= sender_id and isUserAuthenticated(user_id) then
                        rednet.send(user_id, phone_notification, PHONE_PROTOCOL)
                    end
                end
                log("Phone notifications sent to authenticated users")
            end
        end
        
    elseif message.type == "security_heartbeat" then
        security_nodes[sender_id] = {
            last_seen = os.time(),
            device_name = message.device_name or ("Node-" .. sender_id),
            device_type = message.device_type or "unknown",
            alarm_active = message.alarm_active,
            alarm_type = message.alarm_type
        }
        
        -- Enhanced alarm sync - send active alarms to newly connected devices
        if message.alarm_active == false and next(active_security_alarms) then
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
                    rednet.send(sender_id, sync_message, SECURITY_PROTOCOL)
                    log("Sent alarm sync to " .. sender_id .. " for alarm from " .. alarm_source)
                end
            end
        end
    end
end

-- Enhanced user authentication with security features
local function authenticateUser(user_id, password_hash)
    if hashPassword(config.security_password) == password_hash then
        authenticated_users[user_id] = {
            authenticated_time = os.time(),
            expires = os.time() + 3600  -- 1 hour authentication
        }
        server_stats.password_requests = server_stats.password_requests + 1
        log("User " .. user_id .. " authenticated for security features")
        
        -- Send current alarm status to newly authenticated user
        if next(active_security_alarms) then
            for alarm_source, alarm_data in pairs(active_security_alarms) do
                local alarm_notification = {
                    type = "security_notification", 
                    alert_type = alarm_data.type,
                    action = "start",
                    source_name = alarm_data.source_name,
                    timestamp = alarm_data.start_time,
                    server_name = config.server_name
                }
                rednet.send(user_id, alarm_notification, PHONE_PROTOCOL)
            end
            log("Sent active alarm status to newly authenticated user " .. user_id)
        end
        
        return true
    end
    return false
end

-- Enhanced phone message handling to include security notifications
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
            
            -- Send current security status to authenticated users
            if isUserAuthenticated(message.user_id) and next(active_security_alarms) then
                local alarm_count = tableCount(active_security_alarms)
                local status_msg = {
                    type = "security_status",
                    active_alarms = alarm_count,
                    server_name = config.server_name,
                    timestamp = os.time()
                }
                rednet.send(message.user_id, status_msg, PHONE_PROTOCOL)
                log("Sent security status to " .. message.username .. " (" .. alarm_count .. " active alarms)")
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
            
        elseif message.type == "network_test" then
            -- Handle network test requests
            local response = {
                type = "network_test_response",
                server_name = config.server_name,
                server_id = computer_id,
                timestamp = os.time(),
                uptime = os.time() - server_stats.uptime_start
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

-- Enhanced server status display with security info
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
            local elapsed = os.time() - alarm_data.start_time
            print("  " .. alarm_data.source_name .. " (" .. alarm_data.type .. ") " .. elapsed .. "s")
        end
        print("")
    end
    
    -- Authentication status
    local auth_count = tableCount(authenticated_users)
    if auth_count > 0 then
        term.setTextColor(colors.yellow)
        print("Authenticated users: " .. auth_count)
        term.setTextColor(colors.white)
        print("")
    end
    
    -- Network info (compact)
    print("Network: " .. (modem_side or "None") .. (hasEnderModem() and " (Ender)" or " (WiFi)"))
    print("")
    
    -- Statistics (compact)
    print("Stats:")
    print("  Users: " .. tableCount(connected_users) .. " | Messages: " .. server_stats.messages_relayed)
    print("  Alerts: " .. server_stats.security_alerts .. " | Auth: " .. server_stats.password_requests)
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
                local auth_status = isUserAuthenticated(user_id) and "*" or ""
                print("  [" .. device .. "] " .. name .. auth_status)
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
