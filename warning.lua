-- Enhanced PoggishTown Warning System - now we can auto start
-- Speaker + Modem required (expected on left/right)
-- Redstone output on BACK when alarm is active

local protocol = "poggishtown_warning"
local warning_active = false
local modem_side = nil
local speaker = peripheral.find("speaker")
local alarm_start_time = nil
local redstone_output_side = "back"

-- Configuration
local config = {
    heartbeat_interval = 30,    -- seconds between heartbeats
    max_offline_time = 90,      -- seconds before marking node as offline
    auto_stop_timeout = 300,    -- seconds to auto-stop alarm (5 minutes)
    volume_increment = 0.05,
    max_volume = 2.0,
    base_volume = 0.5,
    enable_relay = true,        -- enable message relaying
    max_hops = 5,              -- maximum number of hops for a message
    relay_delay = 0.1          -- small delay before relaying to prevent spam
}

-- Network state tracking
local network_nodes = {}
local last_heartbeat = 0
local computer_id = os.getComputerID()
local alarm_triggered_by = nil
local message_history = {}  -- Track recent messages to prevent loops

-- Alarm patterns (different sounds for different alert types)
local alarm_patterns = {
    general = {
        {note = 3, duration = 0.2},
        {note = 6, duration = 0.2},
        {note = 9, duration = 0.4}
    },
    evacuation = {
        {note = 12, duration = 0.15},
        {note = 15, duration = 0.15},
        {note = 18, duration = 0.15},
        {note = 15, duration = 0.15}
    }
}

local current_alarm_type = "general"

-- Logging system
local log_file = "warning_system.log"
local function log(message)
    local timestamp = textutils.formatTime(os.time(), true)
    local entry = "[" .. timestamp .. "] " .. message .. "\n"
    
    local file = fs.open(log_file, "a")
    if file then
        file.write(entry)
        file.close()
    end
end

-- Play alarm with current pattern (non-blocking version)
local function playAlarmStep()
    if not warning_active then return end
    
    local pattern = alarm_patterns[current_alarm_type]
    local volume = config.base_volume + (config.volume_increment * math.min(50, (os.time() - (alarm_start_time or 0))))
    volume = math.min(config.max_volume, volume)
    
    for _, sound in ipairs(pattern) do
        if not warning_active then break end
        if speaker then
            speaker.playNote("bass", volume, sound.note)
        end
        sleep(sound.duration)
    end
    
    -- Check for auto-timeout
    if alarm_start_time and (os.time() - alarm_start_time) > config.auto_stop_timeout then
        log("Auto-stopping alarm due to timeout")
        stopAlarm()
    end
end

-- Generate unique message ID
local function generateMessageId()
    return computer_id .. "_" .. os.time() .. "_" .. math.random(1000, 9999)
end

-- Check if we've seen this message before
local function isMessageSeen(msg_id)
    return message_history[msg_id] ~= nil
end

-- Mark message as seen
local function markMessageSeen(msg_id)
    message_history[msg_id] = os.time()
    -- Clean up old messages (older than 5 minutes)
    for id, timestamp in pairs(message_history) do
        if (os.time() - timestamp) > 300 then
            message_history[id] = nil
        end
    end
end

-- Relay message to other nodes
local function relayMessage(msg)
    if not config.enable_relay then return end
    if not msg.hops then msg.hops = 0 end
    if msg.hops >= config.max_hops then return end
    
    -- Don't relay our own messages
    if msg.origin_id == computer_id then return end
    
    -- Don't relay if we've already seen this message
    if msg.message_id and isMessageSeen(msg.message_id) then return end
    
    -- Add small delay to prevent network spam
    sleep(config.relay_delay)
    
    -- Increment hop count and relay
    msg.hops = msg.hops + 1
    msg.relayed_by = computer_id
    
    rednet.broadcast(msg, protocol)
    
    if msg.message_id then
        markMessageSeen(msg.message_id)
    end
end

-- Format time string
local function getTimeString()
    local t = textutils.formatTime(os.time(), true)
    return "Triggered at: " .. t
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

-- Draw enhanced status UI
local function drawScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("===============================")
    print("= PoggishTown Warning System  =")
    print("===============================")
    
    -- Computer info
    term.setCursorPos(1, 4)
    print("ID: " .. computer_id .. " | Nodes: " .. getActiveNodeCount())
    
    -- Status
    term.setCursorPos(1, 6)
    if warning_active then
        term.setTextColor(colors.red)
        print("STATUS: !! WARNING ACTIVE !!")
        term.setTextColor(colors.yellow)
        print("Type: " .. string.upper(current_alarm_type))
        term.setTextColor(colors.white)
        if alarm_start_time then
            local t = textutils.formatTime(alarm_start_time, true)
            print("Started: " .. t)
        end
        if alarm_triggered_by then
            print("By: Computer " .. alarm_triggered_by)
        end
        
        -- Auto-stop countdown
        if alarm_start_time then
            local elapsed = os.time() - alarm_start_time
            local remaining = config.auto_stop_timeout - elapsed
            if remaining > 0 then
                print("Auto-stop: " .. math.floor(remaining) .. "s")
            end
        end
    else
        term.setTextColor(colors.green)
        print("STATUS: System Ready")
    end
    
    term.setTextColor(colors.white)
    term.setCursorPos(1, 14)
    print("Controls:")
    print("Any key - General alarm")
    print("E - Evacuation alarm")
    print("C - Cancel alarm")
    print("S - Status | L - Logs | T - Test")
end

-- Broadcast over network with source ID and relay support
local function broadcast(action, alarm_type, source_id)
    local message = {
        type = "warning",
        action = action,
        alarm_type = alarm_type or current_alarm_type,
        source_id = source_id or computer_id,
        origin_id = computer_id,  -- Original sender
        timestamp = os.time(),
        message_id = generateMessageId(),
        hops = 0
    }
    rednet.broadcast(message, protocol)
    markMessageSeen(message.message_id)
    log("Broadcast: " .. action .. " (" .. (alarm_type or "general") .. ") from " .. (source_id or computer_id))
end

-- Send heartbeat with relay support
local function sendHeartbeat()
    local message = {
        type = "heartbeat",
        computer_id = computer_id,
        origin_id = computer_id,
        timestamp = os.time(),
        message_id = generateMessageId(),
        hops = 0
    }
    rednet.broadcast(message, protocol)
    markMessageSeen(message.message_id)
end

-- Start the alarm with type
local function startAlarm(alarm_type)
    alarm_type = alarm_type or "general"
    if not warning_active then
        warning_active = true
        current_alarm_type = alarm_type
        alarm_start_time = os.time()
        alarm_triggered_by = computer_id
        redstone.setOutput(redstone_output_side, true)
        drawScreen()
        broadcast("start", alarm_type, computer_id)
        log("Alarm started: " .. alarm_type .. " by computer " .. computer_id)
    end
end

-- Stop the alarm
local function stopAlarm()
    if warning_active then
        warning_active = false
        redstone.setOutput(redstone_output_side, false)
        drawScreen()
        broadcast("stop", current_alarm_type, computer_id)
        log("Alarm stopped by computer " .. computer_id)
        alarm_triggered_by = nil
    end
end

-- Show system status
local function showStatus()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== System Status ===")
    print("Computer ID: " .. computer_id)
    print("Relay Mode: " .. (config.enable_relay and "ENABLED" or "DISABLED"))
    print("Max Hops: " .. config.max_hops)
    print("Alarm Active: " .. tostring(warning_active))
    if warning_active then
        print("Alarm Type: " .. current_alarm_type)
        print("Triggered by: " .. (alarm_triggered_by or "Unknown"))
    end
    print("\nNetwork Nodes:")
    
    local current_time = os.time()
    for id, node in pairs(network_nodes) do
        local status = (current_time - node.last_seen) <= config.max_offline_time and "ONLINE" or "OFFLINE"
        local hop_info = node.hops and (" (via " .. node.hops .. " hops)") or ""
        print("  Computer " .. id .. ": " .. status .. hop_info .. " (last seen: " .. math.floor(current_time - node.last_seen) .. "s ago)")
    end
    
    print("\nMessage History: " .. #message_history .. " recent messages")
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

-- Test network connectivity
local function testNetwork()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Network Test ===")
    print("Computer ID: " .. computer_id)
    print("Protocol: " .. protocol)
    print("Modem side: " .. modem_side)
    
    -- Check modem type
    local modem = peripheral.wrap(modem_side)
    if modem.isWireless then
        print("Modem type: Wireless")
    else
        print("Modem type: Wired (THIS WON'T WORK!)")
    end
    
    print("\nSending test broadcast...")
    local test_msg = {
        type = "test",
        from = computer_id,
        message = "Hello from " .. computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(test_msg, protocol)
    
    print("Listening for responses (5 seconds)...")
    local responses = 0
    local start_time = os.clock()
    
    while (os.clock() - start_time) < 5 do
        local sender_id, message, proto = rednet.receive(protocol, 1)
        if sender_id and message and message.type == "test" and message.from ~= computer_id then
            print("Response from Computer " .. message.from)
            responses = responses + 1
        end
    end
    
    print("\nTest complete. Received " .. responses .. " responses.")
    if responses == 0 then
        print("No responses - check:")
        print("1. Other computers running?")
        print("2. Using wireless modems?")
        print("3. Same protocol name?")
        print("4. Within 64 block range?")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

local function showLogs()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Recent Logs ===")
    
    if fs.exists(log_file) then
        local file = fs.open(log_file, "r")
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
                print(lines[i])
            end
        end
    else
        print("No log file found.")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

-- Handle network message with relay support
local function handleMessage(msg)
    -- Debug: Log what we're processing
    log("Processing message type: " .. (msg.type or "unknown") .. " from: " .. (msg.from or msg.computer_id or msg.origin_id or "unknown"))
    
    -- Handle test messages first - always respond
    if msg.type == "test" and msg.from ~= computer_id then
        log("Responding to test message from " .. msg.from)
        local response = {
            type = "test",
            from = computer_id,
            message = "Response from " .. computer_id,
            timestamp = os.time()
        }
        rednet.broadcast(response, protocol)
        return
    end
    
    -- For relay messages, skip our own messages
    if msg.origin_id and msg.origin_id == computer_id then 
        log("Skipping own message")
        return 
    end
    
    -- Skip duplicate messages (only for messages that have message_id)
    if msg.message_id and isMessageSeen(msg.message_id) then 
        log("Skipping duplicate message")
        return 
    end
    
    -- Mark as seen and relay if appropriate (only for relay-enabled messages)
    if msg.message_id then
        markMessageSeen(msg.message_id)
        relayMessage(msg)
    end
    
    if msg.type == "warning" then
        log("Processing warning message: " .. msg.action)
        if msg.action == "start" and not warning_active then
            warning_active = true
            current_alarm_type = msg.alarm_type or "general"
            alarm_start_time = os.time()
            alarm_triggered_by = msg.source_id
            redstone.setOutput(redstone_output_side, true)
            drawScreen()
            log("Alarm started remotely: " .. current_alarm_type .. " by computer " .. msg.source_id)
        elseif msg.action == "stop" and warning_active then
            warning_active = false
            redstone.setOutput(redstone_output_side, false)
            drawScreen()
            log("Alarm stopped remotely by computer " .. msg.source_id)
            alarm_triggered_by = nil
        end
    elseif msg.type == "heartbeat" then
        log("Processing heartbeat from " .. msg.computer_id)
        network_nodes[msg.computer_id] = {
            last_seen = os.time(),
            computer_id = msg.computer_id,
            hops = msg.hops or 0
        }
        -- Only update screen if we're on the main screen
        if term.getCursorPos() == 1 then
            drawScreen()
        end
    end
end

-- Modem check and initialization
local function init()
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            print("Modem found on " .. side)
            log("System started - Modem found on " .. side)
            break
        end
    end

    if not modem_side then
        error("No modem found. Please attach one on left or right.")
    end
    if not speaker then
        print("Warning: No speaker found. Audio will not play.")
        log("Warning: No speaker found. Audio will not play.")
    end
    
    -- Debug: Check if rednet is actually open
    print("Rednet open on side: " .. modem_side)
    print("Computer ID: " .. computer_id)
    print("Protocol: " .. protocol)
    
    -- Check what type of modem we have
    local modem = peripheral.wrap(modem_side)
    if modem.isWireless then
        print("Wireless modem detected")
        if modem.isWireless() then
            print("Wireless functionality confirmed")
        else
            print("ERROR: Modem not in wireless mode!")
        end
    else
        print("WARNING: This appears to be a wired modem!")
        print("You need a WIRELESS modem for this to work!")
    end
    
    -- Wait a moment then send initial heartbeat
    sleep(1)
    print("Sending initial heartbeat...")
    sendHeartbeat()
    
    -- Wait a moment for any responses
    sleep(2)
    print("Starting system...")
end

-- Main loop
local function main()
    init()
    drawScreen()
    
    log("Starting unified event handler...")
    
    -- Start heartbeat timer
    local heartbeat_timer = os.startTimer(config.heartbeat_interval)
    
    -- Unified event loop instead of parallel processing
    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        
        if event == "key" then
            local keyCode = param1
            if keyCode == keys.c then
                stopAlarm()
            elseif keyCode == keys.e then
                startAlarm("evacuation")
            elseif keyCode == keys.s then
                showStatus()
            elseif keyCode == keys.l then
                showLogs()
            elseif keyCode == keys.t then
                testNetwork()
            elseif not warning_active then
                -- Any other key starts general alarm
                startAlarm("general")
            end
            
        elseif event == "rednet_message" then
            local sender_id, message, proto = param1, param2, param3
            if proto == protocol then
                log("Raw message received: " .. textutils.serialize(message))
                handleMessage(message)
            end
            
        elseif event == "timer" then
            local timer_id = param1
            if timer_id == heartbeat_timer then
                sendHeartbeat()
                heartbeat_timer = os.startTimer(config.heartbeat_interval)
            end
        end
        
        -- Handle alarm sound in the background
        if warning_active then
            -- Start alarm sound in parallel without blocking main event loop
            parallel.waitForAny(
                function()
                    playAlarmStep()
                end,
                function()
                    os.pullEvent() -- Wait for any event to interrupt alarm
                end
            )
        end
    end
end

main()
