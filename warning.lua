-- Enhanced Two-Way Warning System
-- Speaker + Modem required (expected on left/right)
-- Redstone output on BACK when alarm is active

local protocol = "poggimart_warning"
local warning_active = false
local modem_side = nil
local speaker = peripheral.find("speaker")
local alarm_start_time = nil
local redstone_output_side = "back"

-- Gradually louder air raid sound
local function playAlarm()
    local volume = 0.5
    while warning_active do
        if speaker then
            speaker.playNote("bass", volume, 3)
            sleep(0.2)
            speaker.playNote("bass", volume, 6)
            sleep(0.2)
            speaker.playNote("bass", volume, 9)
            sleep(0.4)
            volume = math.min(2.0, volume + 0.05) -- Increase volume gradually
        else
            sleep(0.8) -- Still need to sleep even without speaker
        end
    end
end

-- Format time string
local function getTimeString()
    local t = textutils.formatTime(os.time(), true)
    return "Triggered at: " .. t
end

-- Draw status UI
local function drawScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("===============================")
    print("= Two-Way Warning System      =")
    print("===============================")
    term.setCursorPos(1, 5)
    if warning_active then
        term.setTextColor(colors.red)
        print("STATUS: !! WARNING ACTIVE !!")
        term.setTextColor(colors.white)
        if alarm_start_time then
            print(getTimeString())
        end
    else
        term.setTextColor(colors.green)
        print("STATUS: System Idle")
    end
    term.setTextColor(colors.white)
    term.setCursorPos(1, 8)
    print("Press any key to send a warning.")
    print("Press 'C' to cancel the warning.")
    term.setCursorPos(1, 11)
    print("System Ready. Listening for events...")
end

-- Broadcast over network
local function broadcast(action)
    rednet.broadcast({ type = "warning", action = action }, protocol)
end

-- Start the alarm (local and broadcast)
local function startAlarm()
    if not warning_active then
        warning_active = true
        alarm_start_time = os.time()
        redstone.setOutput(redstone_output_side, true)
        drawScreen()
        broadcast("start")
    end
end

-- Stop the alarm (local and broadcast)
local function stopAlarm()
    if warning_active then
        warning_active = false
        redstone.setOutput(redstone_output_side, false)
        drawScreen()
        broadcast("stop")
    end
end

-- Handle network message
local function handleMessage(msg)
    if msg.type == "warning" then
        if msg.action == "start" and not warning_active then
            warning_active = true
            alarm_start_time = os.time()
            redstone.setOutput(redstone_output_side, true)
            drawScreen()
        elseif msg.action == "stop" and warning_active then
            warning_active = false
            redstone.setOutput(redstone_output_side, false)
            drawScreen()
        end
    end
end

-- Modem check
local function init()
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modem_side = side
            rednet.open(side)
            print("Modem found on " .. side)
            break
        end
    end

    if not modem_side then
        error("No modem found. Please attach one on left or right.")
    end
    if not speaker then
        print("Warning: No speaker found. Audio will not play.")
    end
end

-- Input handler function
local function handleInput()
    while true do
        local _, keyCode = os.pullEvent("key")
        if keyCode == keys.c then
            stopAlarm()
        elseif not warning_active then
            -- Any other key starts the alarm (but only if not already active)
            startAlarm()
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
            sleep(0.1) -- Small sleep when not active
        end
    end
end

-- Main loop
local function main()
    init()
    drawScreen()

    -- Run all three handlers in parallel
    parallel.waitForAll(
        handleInput,
        handleNetwork,
        handleAlarm
    )
end

main()
