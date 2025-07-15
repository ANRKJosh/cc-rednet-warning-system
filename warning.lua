-- Enhanced Two-Way Warning System
-- Speaker + Modem required (expected on left/right)
-- Redstone output on BACK when alarm is active

local protocol = "poggishtown_warning"
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
    print("================================")
    print("=  PoggishTown Warning System  =")
    print("================================")
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

-- Handle network message
local function handleMessage(msg)
    if msg.type == "warning" then
        if msg.action == "start" and not warning_active then
            warning_active = true
            alarm_start_time = os.time()
            redstone.setOutput(redstone_output_side, true)
            drawScreen()
            parallel.waitForAny(playAlarm)
        elseif msg.action == "cancel" and warning_active then
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
        error("No speaker found. Please attach one on left or right.")
    end
end

-- Main loop
local function main()
    init()
    drawScreen()

    while true do
        parallel.waitForAny(
            -- Input handler
            function()
                local _, keyCode = os.pullEvent("key")
                if warning_active then
                    if keyCode == keys.c then
                        warning_active = false
                        redstone.setOutput(redstone_output_side, false)
                        drawScreen()
                        broadcast("cancel")
                    end
                else
                    warning_active = true
                    alarm_start_time = os.time()
                    redstone.setOutput(redstone_output_side, true)
                    drawScreen()
                    broadcast("start")
                    playAlarm()
                end
