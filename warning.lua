-- Enhanced Two-Way Warning System
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
    auto_stop_timeout = 900,    -- seconds to auto-stop alarm (15 minutes)
    volume_increment = 0.05,
    max_volume = 5.0,
    base_volume = 0.5
}

-- Network state tracking
local network_nodes = {}
local last_heartbeat = 0
local computer_id = os.getComputerID()
local alarm_triggered_by = nil

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

-- Play alarm with current pattern
local function playAlarm()
    local volume = config.base_volume
    local pattern = alarm_patterns[current_alarm_type]
    
    while warning_active do
        for _, sound in ipairs(pattern) do
            if not warning_active then break end
            if speaker then
                speaker.playNote("bass", volume, sound.note)
            end
            sleep(sound.duration)
        end
        volume = math.min(config.max_volume, volume + config.volume_increment)
        
        -- Check for auto-timeout
        if alarm_start_time and (os.time() - alarm_start_time) > config.auto_stop_timeout then
            log("Auto-stopping alarm due to timeout")
            stopAlarm()
            break
        end
    end
end

-- Format time string
local function getTimeString()
    local t = textutils.formatTime(os.time(), true)
    return "Triggered at: " .. t
end

-- Count active network nodes
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
    print("================================")
    print("=  Poggishtown Warning System  =")
    print("================================")
    
    -- Computer info
    term.setCursorPos(1, 4)
    print("Computer ID: " .. computer_id)
    print("Active Nodes: " .. getActiveNodeCount())
    
    -- Status
    term.setCursorPos(1, 7)
    if warning_active then
        term.setTextColor(colors.red)
        print("STATUS: !! WARNING ACTIVE !!")
        term.setTextColor(colors.yellow)
        print("Type: " .. string.upper(current_alarm_type))
        term.setTextColor(colors.white)
        if alarm_start_time then
            print(getTimeString())
        end
        if alarm_triggered_by then
            print("Triggered by: Computer " .. alarm_triggered_by)
        end
        
        -- Auto-stop countdown
        if alarm_start_time then
            local elapsed = os.time() - alarm_start_time
            local remaining = config.auto_stop_timeout - elapsed
            if remaining > 0 then
                print("Auto-stop in: " .. math.floor(remaining) .. "s")
            end
        end
    else
        term.setTextColor(colors.green)
        print("STATUS: System Idle")
    end
    
    term.setTextColor(colors.white)
    term.setCursorPos(1, 15)
    print("Controls:")
    print("Any key - General alarm")
    print("E - Evacuation alarm")
    print("C - Cancel alarm")
    print("S - Show status")
    print("L - View logs")
    
    term.setCursorPos(1, 22)
    print("System Ready. Listening for events...")
end

-- Broadcast over network with source ID
local function broadcast(action, alarm_type, source_id)
    local message = {
        type = "warning",
        action = action,
        alarm_type = alarm_type or current_alarm_type,
        source_id = source_id or computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(message, protocol)
    log("Broadcast: " .. action .. " (" .. (alarm_type or "general") .. ") from " .. (source_id or computer_id))
end

-- Send heartbeat
local function sendHeartbeat()
    local message = {
        type = "heartbeat",
        computer_id = computer_id,
        timestamp = os.time()
    }
    rednet.broadcast(message, protocol)
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
    print("Alarm Active: " .. tostring(warning_active))
    if warning_active then
        print("Alarm Type: " .. current_alarm_type)
        print("Triggered by: " .. (alarm_triggered_by or "Unknown"))
    end
    print("\nNetwork Nodes:")
    
    local current_time = os.time()
    for id, node in pairs(network_nodes) do
        local status = (current_time - node.last_seen) <= config.max_offline_time and "ONLINE" or "OFFLINE"
        print("  Computer " .. id .. ": " .. status .. " (last seen: " .. math.floor(current_time - node.last_seen) .. "s ago)")
    end
    
    print("\nPress any key to return...")
    os.pullEvent("key")
    drawScreen()
end

-- Show recent logs
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

-- Handle network message
local function handleMessage(msg)
    if msg.type == "warning" then
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
        network_nodes[msg.computer_id] = {
            last_seen = os.time(),
            computer_id = msg.computer_id
        }
    end
end

-- Modem check and initialization
local function init()
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            log("System started - Modem found on " .. side)
            break
        end
    end

    if not modem_side then
        error("No modem found. Please attach one on left or right.")
    end
    if not speaker then
        log("Warning: No speaker found. Audio will not play.")
    end
    
    -- Initial heartbeat
    sendHeartbeat()
end

-- Input handler function
local function handleInput()
    while true do
        local _, keyCode = os.pullEvent("key")
        if keyCode == keys.c then
            stopAlarm()
        elseif keyCode == keys.e then
            startAlarm("evacuation")
        elseif keyCode == keys.s then
            showStatus()
        elseif keyCode == keys.l then
            showLogs()
        elseif not warning_active then
            -- Any other key starts general alarm
            startAlarm("general")
        end
    end
end

-- Network handler function
local function handleNetwork()
    while true do
        local _, _, _, _, msg, proto = os.pullEvent("rednet_message")
        if proto == protocol then
            handleMessage(msg)
        end
    end
end

-- Alarm sound handler function
local function handleAlarm()
    while true do
        if warning_active then
            playAlarm()
        else
            sleep(0.1)
        end
    end
end

-- Heartbeat handler function
local function handleHeartbeat()
    while true do
        sleep(config.heartbeat_interval)
        sendHeartbeat()
    end
end

-- Main loop
local function main()
    init()
    drawScreen()

    -- Run all handlers in parallel
    parallel.waitForAll(
        handleInput,
        handleNetwork,
        handleAlarm,
        handleHeartbeat
    )
end

main()
