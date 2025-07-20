-- PoggishTown Admin v2.1 - Network Administration Tool
-- For terminal devices only - monitors and manages the PoggishTown network

local PHONE_PROTOCOL = "pogphone"
local SECURITY_PROTOCOL = "pogalert"
local CONFIG_FILE = "pogadmin_config"

-- Device restriction check
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

-- Security check - only run on terminals
local is_terminal = isWirelessTerminal()
if not is_terminal then
    print("ERROR: PoggishTown Admin is restricted to terminals only")
    print("Computers should run PoggishTown Security instead")
    print("This prevents accidental admin access on security stations")
    return
end

-- Global state
local computer_id = os.getComputerID()
local modem_side = nil

-- Configuration
local config = {
    username = nil,
    auto_refresh = true,
    refresh_interval = 5,
    show_detailed_logs = false,
    monitor_threshold_users = 10,
    monitor_threshold_alarms = 3
}

-- Data
local connected_servers = {}
local network_users = {}
local security_nodes = {}
local active_alarms = {}
local network_stats = {}
local admin_log = {}

-- Authentication
local authenticated = false
local auth_expires = 0

local function addAdminLog(message, level)
    level = level or "INFO"
    local entry = {
        timestamp = os.time(),
        level = level,
        message = message
    }
    table.insert(admin_log, entry)
    
    -- Keep only last 50 entries
    if #admin_log > 50 then
        table.remove(admin_log, 1)
    end
end

-- Helper functions
local function tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

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
    return "Admin-" .. computer_id
end

local function isAuthenticated()
    return authenticated and os.time() < auth_expires
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
end

local function saveData()
    local file = fs.open(CONFIG_FILE, "w")
    if file then
        file.write(textutils.serialize(config))
        file.close()
    end
end

-- Network initialization
local function initModem()
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            addAdminLog("Modem opened on " .. side)
            return true
        end
    end
    return false
end

-- Authentication
local function authenticate(password)
    addAdminLog("Attempting authentication for admin access")
    
    local message = {
        type = "security_auth_request",
        password_hash = hashPassword(password),
        user_id = computer_id,
        username = getUsername(),
        timestamp = os.time(),
        admin_client = true
    }
    
    rednet.broadcast(message, PHONE_PROTOCOL)
    
    local start_time = os.clock()
    while (os.clock() - start_time) < 10 do
        local sender_id, response, protocol = rednet.receive(nil, 1)
        
        if sender_id and protocol == PHONE_PROTOCOL then
            if response.type == "security_auth_response" and response.target_user_id == computer_id then
                if response.authenticated then
                    authenticated = true
                    auth_expires = response.expires or (os.time() + 3600)
                    addAdminLog("Admin authentication successful", "SUCCESS")
                    return true
                else
                    addAdminLog("Admin authentication failed - invalid password", "ERROR")
                    return false
                end
            end
        end
    end
    
    addAdminLog("Admin authentication timeout", "ERROR")
    return false
end

-- Network scanning and monitoring
local function scanNetwork()
    addAdminLog("Scanning network for devices and servers")
    
    -- Request user list
    local user_request = {
        type = "user_list_request",
        from_id = computer_id,
        admin_scan = true,
        timestamp = os.time()
    }
    rednet.broadcast(user_request, PHONE_PROTOCOL)
    
    -- Request server status
    local server_request = {
        type = "admin_status_request", 
        from_id = computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(server_request, PHONE_PROTOCOL)
    
    -- Send presence to get server announcements
    local presence = {
        type = "user_presence",
        user_id = computer_id,
        username = getUsername(),
        device_type = "terminal",
        admin_client = true,
        timestamp = os.time()
    }
    rednet.broadcast(presence, PHONE_PROTOCOL)
end

-- Message handling
local function handleMessage(sender_id, message, protocol)
    if protocol == PHONE_PROTOCOL then
        if message.type == "server_announcement" then
            connected_servers[sender_id] = {
                name = message.server_name or "Server-" .. sender_id,
                last_seen = os.time(),
                capabilities = message.capabilities or {},
                uptime = message.uptime or 0,
                connected_users = message.connected_users or 0
            }
            
        elseif message.type == "user_list_response" then
            if message.users then
                network_users = {}
                for user_id, user_data in pairs(message.users) do
                    network_users[user_id] = user_data
                end
                addAdminLog("Updated user list - " .. tableCount(network_users) .. " users online")
            end
            
        elseif message.type == "admin_status_response" then
            network_stats[sender_id] = {
                server_name = message.server_name,
                stats = message.stats or {},
                last_updated = os.time()
            }
            
        elseif message.type == "security_auth_response" then
            -- Handle authentication responses (already handled in authenticate function)
            
        end
        
    elseif protocol == SECURITY_PROTOCOL then
        if message.type == "security_alert" then
            local source_id = message.source_id or message.original_sender or sender_id
            
            if message.action == "start" then
                active_alarms[source_id] = {
                    type = message.alarm_type or "general",
                    source_name = message.source_name or ("Node-" .. source_id),
                    start_time = message.timestamp or os.time(),
                    device_type = message.device_type or "unknown"
                }
                addAdminLog("SECURITY ALERT: " .. (message.alarm_type or "general") .. " from " .. (message.source_name or source_id), "ALERT")
                
            elseif message.action == "stop" then
                if message.global_cancel then
                    local cleared_count = tableCount(active_alarms)
                    active_alarms = {}
                    addAdminLog("Global alarm cancel - cleared " .. cleared_count .. " alarms", "INFO")
                else
                    if active_alarms[source_id] then
                        active_alarms[source_id] = nil
                        addAdminLog("Alarm cleared from " .. (message.source_name or source_id), "INFO")
                    end
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
        end
    end
end

-- Admin commands
local function sendAdminCommand(command, target_server, params)
    if not isAuthenticated() then
        addAdminLog("Admin command blocked - not authenticated", "ERROR")
        return false
    end
    
    local message = {
        type = "admin_command",
        command = command,
        params = params or {},
        from_id = computer_id,
        admin_user = getUsername(),
        timestamp = os.time(),
        target_server = target_server
    }
    
    if target_server then
        rednet.send(target_server, message, PHONE_PROTOCOL)
    else
        rednet.broadcast(message, PHONE_PROTOCOL)
    end
    
    addAdminLog("Sent admin command: " .. command .. " to " .. (target_server or "all servers"))
    return true
end

local function broadcastMessage(message_text, priority)
    if not isAuthenticated() then
        return false, "Not authenticated"
    end
    
    local broadcast = {
        type = "admin_broadcast",
        message = message_text,
        priority = priority or "normal",
        from_admin = getUsername(),
        timestamp = os.time()
    }
    
    rednet.broadcast(broadcast, PHONE_PROTOCOL)
    addAdminLog("Broadcast message: " .. message_text)
    return true
end

-- UI Functions
local function drawHeader()
    print("=== POGGISHTOWN ADMIN v2.1 ===")
    print("Admin: " .. getUsername() .. " | Terminal ID: " .. computer_id)
    
    if isAuthenticated() then
        term.setTextColor(colors.green)
        print("Status: AUTHENTICATED")
        local expires_in = auth_expires - os.time()
        print("Session: " .. math.floor(expires_in / 60) .. " minutes remaining")
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.red)
        print("Status: NOT AUTHENTICATED")
        term.setTextColor(colors.white)
    end
    print("")
end

local function drawNetworkOverview()
    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    
    print("=== NETWORK OVERVIEW ===")
    print("")
    
    -- Server status
    local server_count = tableCount(connected_servers)
    if server_count > 0 then
        term.setTextColor(colors.green)
        print("SERVERS ONLINE: " .. server_count)
        term.setTextColor(colors.white)
        
        for server_id, server_data in pairs(connected_servers) do
            local time_ago = os.time() - server_data.last_seen
            if time_ago < 300 then -- 5 minutes
                print("  " .. server_data.name .. " - " .. server_data.connected_users .. " users")
                if server_data.uptime then
                    print("    Uptime: " .. math.floor(server_data.uptime / 60) .. " minutes")
                end
            end
        end
    else
        term.setTextColor(colors.red)
        print("NO SERVERS DETECTED")
        term.setTextColor(colors.white)
    end
    print("")
    
    -- User count
    local user_count = tableCount(network_users)
    if user_count > 0 then
        if user_count >= config.monitor_threshold_users then
            term.setTextColor(colors.yellow)
        else
            term.setTextColor(colors.blue)
        end
        print("NETWORK USERS: " .. user_count)
        term.setTextColor(colors.white)
        
        -- Show device breakdown
        local terminals = 0
        local computers = 0
        for _, user_data in pairs(network_users) do
            if user_data.device_type == "terminal" then
                terminals = terminals + 1
            else
                computers = computers + 1
            end
        end
        print("  Terminals: " .. terminals .. " | Computers: " .. computers)
    else
        print("NETWORK USERS: 0")
    end
    print("")
    
    -- Security status
    local alarm_count = tableCount(active_alarms)
    local node_count = tableCount(security_nodes)
    
    if alarm_count > 0 then
        term.setTextColor(colors.red)
        print("ACTIVE ALARMS: " .. alarm_count)
        term.setTextColor(colors.white)
        
        for source_id, alarm_data in pairs(active_alarms) do
            local elapsed = os.time() - alarm_data.start_time
            print("  " .. alarm_data.source_name .. " (" .. alarm_data.type .. ") - " .. elapsed .. "s")
        end
    else
        term.setTextColor(colors.green)
        print("SECURITY: ALL CLEAR")
        term.setTextColor(colors.white)
    end
    
    if node_count > 0 then
        print("Security nodes active: " .. node_count)
    end
    
    print("")
    print("Actions:")
    if isAuthenticated() then
        print("1-Network Scan  2-User Management  3-Server Admin")
        print("4-Security Ops  5-Broadcast Msg   6-System Logs")
    else
        print("L-Login for admin access")
    end
    print("R-Refresh  S-Settings  Q-Quit")
    print("")
    print("Enter choice:")
end

local function networkScan()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== NETWORK SCAN ===")
    print("Scanning network...")
    
    scanNetwork()
    
    print("Waiting for responses...")
    local start_time = os.clock()
    
    while (os.clock() - start_time) < 5 do
        local sender_id, message, protocol = rednet.receive(nil, 0.5)
        if sender_id then
            handleMessage(sender_id, message, protocol)
        end
    end
    
    print("")
    print("Scan complete!")
    print("Servers found: " .. tableCount(connected_servers))
    print("Users found: " .. tableCount(network_users))
    print("Security nodes: " .. tableCount(security_nodes))
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
end

local function userManagement()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== USER MANAGEMENT ===")
    
    if not isAuthenticated() then
        term.setTextColor(colors.red)
        print("Authentication required")
        term.setTextColor(colors.white)
        print("Press any key to return...")
        os.pullEvent("key")
        return
    end
    
    if tableCount(network_users) == 0 then
        print("No users found. Run network scan first.")
        print("Press any key to return...")
        os.pullEvent("key")
        return
    end
    
    print("Connected Users:")
    print("")
    
    local user_list = {}
    for user_id, user_data in pairs(network_users) do
        table.insert(user_list, {id = user_id, data = user_data})
    end
    
    for i, user in ipairs(user_list) do
        local device_type = user.data.device_type or "unknown"
        local time_ago = user.data.last_seen and (os.time() - user.data.last_seen) or 0
        
        if device_type == "terminal" then
            term.setTextColor(colors.cyan)
        else
            term.setTextColor(colors.blue)
        end
        
        print(i .. ". " .. user.data.username .. " [" .. device_type:upper() .. "]")
        term.setTextColor(colors.white)
        print("   ID: " .. user.id .. " | Last seen: " .. time_ago .. "s ago")
    end
    
    print("")
    print("Actions:")
    print("M - Send Message to User")
    print("K - Send Admin Notice")
    print("B - Back")
    print("")
    print("Enter choice:")
    
    local input = read()
    
    if input:lower() == "m" then
        print("\nEnter user number:")
        local user_num = tonumber(read())
        if user_num and user_num >= 1 and user_num <= #user_list then
            print("Message to " .. user_list[user_num].data.username .. ":")
            local message = read()
            if message ~= "" then
                -- Send admin message
                local admin_msg = {
                    type = "admin_message",
                    from_admin = getUsername(),
                    to_user = user_list[user_num].id,
                    message = message,
                    timestamp = os.time()
                }
                rednet.send(user_list[user_num].id, admin_msg, PHONE_PROTOCOL)
                print("Message sent!")
                sleep(1)
            end
        end
    elseif input:lower() == "k" then
        print("\nAdmin notice message:")
        local notice = read()
        if notice ~= "" then
            broadcastMessage("[ADMIN NOTICE] " .. notice, "high")
            print("Notice broadcast to all users!")
            sleep(1)
        end
    end
end

local function serverAdmin()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SERVER ADMINISTRATION ===")
    
    if not isAuthenticated() then
        term.setTextColor(colors.red)
        print("Authentication required")
        term.setTextColor(colors.white)
        print("Press any key to return...")
        os.pullEvent("key")
        return
    end
    
    if tableCount(connected_servers) == 0 then
        print("No servers found. Run network scan first.")
        print("Press any key to return...")
        os.pullEvent("key")
        return
    end
    
    print("Connected Servers:")
    print("")
    
    local server_list = {}
    for server_id, server_data in pairs(connected_servers) do
        table.insert(server_list, {id = server_id, data = server_data})
    end
    
    for i, server in ipairs(server_list) do
        local time_ago = os.time() - server.data.last_seen
        if time_ago < 300 then
            term.setTextColor(colors.green)
            print(i .. ". " .. server.data.name .. " [ONLINE]")
            term.setTextColor(colors.white)
            print("   ID: " .. server.id .. " | Users: " .. server.data.connected_users)
            if server.data.uptime then
                print("   Uptime: " .. math.floor(server.data.uptime / 60) .. " minutes")
            end
        else
            term.setTextColor(colors.red)
            print(i .. ". " .. server.data.name .. " [OFFLINE]")
            term.setTextColor(colors.white)
            print("   Last seen: " .. time_ago .. "s ago")
        end
        print("")
    end
    
    print("Commands:")
    print("R - Request Status Update")
    print("S - Server Shutdown (Emergency)")
    print("C - Clear Server Logs")
    print("B - Back")
    print("")
    print("Enter choice:")
    
    local input = read()
    
    if input:lower() == "r" then
        print("\nRequesting status updates...")
        sendAdminCommand("status_request")
        sleep(2)
    elseif input:lower() == "s" then
        print("\nEmergency server shutdown!")
        print("Enter server number (or 'all'):")
        local target = read()
        print("Confirm shutdown? (yes/no)")
        local confirm = read()
        if confirm:lower() == "yes" then
            if target:lower() == "all" then
                sendAdminCommand("emergency_shutdown")
            else
                local server_num = tonumber(target)
                if server_num and server_list[server_num] then
                    sendAdminCommand("emergency_shutdown", server_list[server_num].id)
                end
            end
            print("Shutdown command sent!")
            sleep(2)
        end
    elseif input:lower() == "c" then
        print("\nClear server logs? (y/n)")
        local confirm = read()
        if confirm:lower() == "y" then
            sendAdminCommand("clear_logs")
            print("Log clear command sent!")
            sleep(1)
        end
    end
end

local function securityOperations()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SECURITY OPERATIONS ===")
    
    if not isAuthenticated() then
        term.setTextColor(colors.red)
        print("Authentication required")
        term.setTextColor(colors.white)
        print("Press any key to return...")
        os.pullEvent("key")
        return
    end
    
    local alarm_count = tableCount(active_alarms)
    local node_count = tableCount(security_nodes)
    
    print("Security Status:")
    print("")
    
    if alarm_count > 0 then
        term.setTextColor(colors.red)
        print("ACTIVE ALARMS: " .. alarm_count)
        term.setTextColor(colors.white)
        
        for source_id, alarm_data in pairs(active_alarms) do
            local elapsed = os.time() - alarm_data.start_time
            print("  " .. alarm_data.source_name .. " - " .. alarm_data.type)
            print("    Duration: " .. elapsed .. " seconds")
        end
        print("")
    else
        term.setTextColor(colors.green)
        print("ALL CLEAR - No active alarms")
        term.setTextColor(colors.white)
        print("")
    end
    
    if node_count > 0 then
        print("Security Nodes (" .. node_count .. "):")
        for node_id, node_data in pairs(security_nodes) do
            local time_ago = os.time() - node_data.last_seen
            if time_ago < 120 then -- 2 minutes
                if node_data.alarm_active then
                    term.setTextColor(colors.red)
                    print("  " .. node_data.device_name .. " [ALARM]")
                else
                    term.setTextColor(colors.green)
                    print("  " .. node_data.device_name .. " [OK]")
                end
                term.setTextColor(colors.white)
            end
        end
        print("")
    end
    
    print("Operations:")
    if alarm_count > 0 then
        print("C - Global Alarm Cancel")
    end
    print("T - System Test")
    print("S - Send Security Alert")
    print("B - Back")
    print("")
    print("Enter choice:")
    
    local input = read()
    
    if input:lower() == "c" and alarm_count > 0 then
        print("\nCancel all alarms? (yes/no)")
        local confirm = read()
        if confirm:lower() == "yes" then
            local cancel_msg = {
                type = "security_alert",
                action = "stop",
                global_cancel = true,
                source_id = computer_id,
                source_name = getUsername() .. " (Admin)",
                timestamp = os.time(),
                admin_override = true
            }
            rednet.broadcast(cancel_msg, SECURITY_PROTOCOL)
            print("Global cancel sent!")
            sleep(1)
        end
    elseif input:lower() == "t" then
        print("\nSending system test...")
        local test_msg = {
            type = "security_test",
            from_admin = getUsername(),
            test_id = computer_id .. "_" .. os.time(),
            timestamp = os.time()
        }
        rednet.broadcast(test_msg, SECURITY_PROTOCOL)
        print("Test signal sent!")
        sleep(1)
    elseif input:lower() == "s" then
        print("\nAlert type (general/evacuation/lockdown):")
        local alert_type = read()
        if alert_type ~= "" then
            local alert_msg = {
                type = "security_alert",
                action = "start",
                alarm_type = alert_type,
                source_id = computer_id,
                source_name = getUsername() .. " (Admin)",
                timestamp = os.time(),
                admin_issued = true
            }
            rednet.broadcast(alert_msg, SECURITY_PROTOCOL)
            print("Security alert sent!")
            sleep(1)
        end
    end
end

local function viewSystemLogs()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== SYSTEM LOGS ===")
    print("")
    
    if #admin_log == 0 then
        print("No log entries")
    else
        local start_idx = math.max(1, #admin_log - 15)
        for i = start_idx, #admin_log do
            local entry = admin_log[i]
            local time_str = textutils.formatTime(entry.timestamp, true)
            
            if entry.level == "ERROR" then
                term.setTextColor(colors.red)
            elseif entry.level == "ALERT" then
                term.setTextColor(colors.yellow)
            elseif entry.level == "SUCCESS" then
                term.setTextColor(colors.green)
            else
                term.setTextColor(colors.white)
            end
            
            print("[" .. time_str .. "] " .. entry.level .. ": " .. entry.message)
        end
        term.setTextColor(colors.white)
        
        if #admin_log > 15 then
            print("")
            print("(" .. (#admin_log - 15) .. " older entries not shown)")
        end
    end
    
    print("")
    print("Press any key to return...")
    os.pullEvent("key")
end

local function settings()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== ADMIN SETTINGS ===")
    print("")
    print("1. Username: " .. getUsername())
    print("2. Auto Refresh: " .. (config.auto_refresh and "ON" or "OFF"))
    print("3. Refresh Interval: " .. config.refresh_interval .. " seconds")
    print("4. Detailed Logs: " .. (config.show_detailed_logs and "ON" or "OFF"))
    print("5. User Alert Threshold: " .. config.monitor_threshold_users)
    print("6. Alarm Alert Threshold: " .. config.monitor_threshold_alarms)
    print("")
    if isAuthenticated() then
        print("7. Logout from Admin")
    else
        print("7. Login to Admin")
    end
    print("8. Clear Admin Logs")
    print("")
    print("B. Back")
    print("")
    print("Enter choice:")
    
    local input = read()
    
    if input:lower() == "b" then
        return
    elseif input == "1" then
        print("\nEnter new username:")
        local new_name = read()
        if new_name ~= "" then
            config.username = new_name
            saveData()
            print("Username updated!")
            sleep(1)
        end
    elseif input == "2" then
        config.auto_refresh = not config.auto_refresh
        saveData()
        print("\nAuto refresh " .. (config.auto_refresh and "enabled" or "disabled"))
        sleep(1)
    elseif input == "3" then
        print("\nEnter refresh interval (3-60 seconds):")
        local interval = tonumber(read())
        if interval and interval >= 3 and interval <= 60 then
            config.refresh_interval = interval
            saveData()
            print("Refresh interval updated!")
            sleep(1)
        end
    elseif input == "7" then
        if isAuthenticated() then
            authenticated = false
            auth_expires = 0
            addAdminLog("Admin session ended")
            print("\nLogged out of admin functions")
            sleep(1)
        else
            print("\nEnter admin password:")
            local password = read("*")
            if password ~= "" then
                if authenticate(password) then
                    print("Admin access granted!")
                else
                    print("Authentication failed!")
                end
                sleep(2)
            end
        end
    elseif input == "8" then
        print("\nClear all admin logs? (y/n)")
        local confirm = read()
        if confirm:lower() == "y" then
            admin_log = {}
            addAdminLog("Admin logs cleared")
            print("Logs cleared!")
            sleep(1)
        end
    end
end

-- Main application loop
local function main()
    print("PoggishTown Admin v2.1 Starting...")
    print("Device restriction: Terminals only")
    print("")
    
    if not initModem() then
        print("ERROR: No modem found!")
        return
    end
    
    loadData()
    addAdminLog("PoggishTown Admin started")
    
    -- Initial network scan
    print("Performing initial network scan...")
    scanNetwork()
    sleep(2)
    
    local last_refresh = os.clock()
    
    while true do
        -- Auto-refresh if enabled
        if config.auto_refresh and (os.clock() - last_refresh) > config.refresh_interval then
            scanNetwork()
            last_refresh = os.clock()
        end
        
        -- Process background messages
        local sender_id, message, protocol = rednet.receive(nil, 0.1)
        if sender_id then
            handleMessage(sender_id, message, protocol)
        end
        
        drawNetworkOverview()
        local choice = read()
        
        if choice:lower() == "q" then
            break
        elseif choice:lower() == "r" then
            scanNetwork()
        elseif choice:lower() == "s" then
            settings()
        elseif choice:lower() == "l" and not isAuthenticated() then
            print("\nEnter admin password:")
            local password = read("*")
            if password ~= "" then
                authenticate(password)
            end
        elseif isAuthenticated() then
            if choice == "1" then
                networkScan()
            elseif choice == "2" then
                userManagement()
            elseif choice == "3" then
                serverAdmin()
            elseif choice == "4" then
                securityOperations()
            elseif choice == "5" then
                print("\nBroadcast message:")
                local msg = read()
                if msg ~= "" then
                    broadcastMessage(msg, "normal")
                    print("Message broadcast!")
                    sleep(1)
                end
            elseif choice == "6" then
                viewSystemLogs()
            end
        end
    end
    
    addAdminLog("PoggishTown Admin shutting down")
    saveData()
    print("PoggishTown Admin shutting down...")
end

-- Run the application
main()
