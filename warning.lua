--[[
================================================================================
-- Two-Way Modem Warning System for ComputerCraft --
-- CORRECTED AND IMPROVED VERSION
================================================================================
-- INSTRUCTIONS:
-- 1. Save this code on two different computers in your world.
-- 2. Make sure both computers have a Wireless Modem attached.
-- 3. Run the program on both computers.
--
-- HOW TO USE:
-- - Press any key on either computer to broadcast a warning.
--   This will cause both computers to play an audible alarm.
-- - To stop the alarm, press the 'c' key on either computer.
================================================================================
]]

-- Configuration
local modemChannel = 65530 -- The channel for modem communication.
local isWarningActive = false -- Tracks the state of the warning.

-- Open the modem on the specified channel.
-- IMPORTANT: Change "right" to the side your modem is on!
rednet.open("right") 
rednet.host("protocol_warning", "warning_system")

-- Function to print the status to the screen
local function updateDisplay()
  term.clear()
  term.setCursorPos(1, 1)
  print("===============================")
  print("= Two-Way Warning System      =")
  print("===============================")
  term.setCursorPos(1, 5)
  if isWarningActive then
    term.setTextColor(colors.red)
    print("STATUS: !! WARNING ACTIVE !!")
  else
    term.setTextColor(colors.green)
    print("STATUS: System Idle")
  end
  term.setTextColor(colors.white)
  term.setCursorPos(1, 7)
  print("Press any key to send a warning.")
  print("Press 'c' to cancel the warning.")
  term.setCursorPos(1, 10)
  print("System Ready. Listening for events...")
end

-- Actions are now simpler: they just change the state.
local function startWarning()
  if not isWarningActive then
    isWarningActive = true
    updateDisplay()
  end
end

local function cancelWarning()
  if isWarningActive then
    isWarningActive = false
    updateDisplay()
  end
end

-- This function will run in the background to handle sound.
local function soundController()
  while true do
    if isWarningActive then
      -- Play a two-tone alarm sound
      speaker.playNote("harp", 1, 1)
      sleep(0.5)
      speaker.playNote("harp", 1, 1.5)
      sleep(0.5)
    else
      -- If the alarm is off, sleep briefly to prevent high CPU usage.
      sleep(0.1)
    end
  end
end

-- This function will run in the background to handle events.
local function eventHandler()
  updateDisplay()
  while true do
    -- We'll capture all return values into a table for safety.
    local returns = { parallel.waitForAny(
      function()
        local _, key = os.pullEvent("key")
        return { eventType = "key_press", key = key }
      end,
      function()
        local _, msg = rednet.receive("protocol_warning")
        return { eventType = "rednet_message", message = msg }
      end
    ) }
    
    -- The event data table is the second value returned.
    local eventData = returns[2]

    -- Add a "guard" to ensure eventData is not nil before we use it.
    -- This handles the rare edge case that was causing the crash.
    if eventData then
      -- Handle keyboard input
      if eventData.eventType == "key_press" then
        if eventData.key == keys.c then
          rednet.broadcast("cancel_warning", "protocol_warning")
          cancelWarning()
        else
          rednet.broadcast("start_warning", "protocol_warning")
          startWarning()
        end
      -- Handle incoming rednet messages
      elseif eventData.eventType == "rednet_message" then
        if eventData.message == "start_warning" then
          startWarning()
        elseif eventData.message == "cancel_warning" then
          cancelWarning()
        end
      end
    end
    -- If eventData was nil, the loop simply continues and waits for the next event.
  end
end
-- Run the sound controller and event handler in parallel.
-- The program will now run correctly until you terminate it (Ctrl+T).
parallel.waitForAll(soundController, eventHandler)
