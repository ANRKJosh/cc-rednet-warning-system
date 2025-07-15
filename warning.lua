--[[
================================================================================
-- Two-Way Modem Warning System for ComputerCraft --
================================================================================
-- INSTRUCTIONS:
-- 1. Save this code on two different computers in your world.
-- 2. Make sure both computers have a Wireless Modem attached to any side.
-- 3. Run the program on both computers.
--
-- HOW TO USE:
-- - Press any key on either computer to broadcast a warning.
--   This will cause both computers to play an audible alarm.
-- - To stop the alarm, press the 'c' key on either computer.
--
-- MODEM CONFIGURATION:
-- - The program uses channel 65530 for communication. You can change this
--   by modifying the 'modemChannel' variable below. Make sure the channel
--   is the same on both computers.
================================================================================
]]

-- Configuration
local modemChannel = 65530 -- The channel for modem communication.
local isWarningActive = false -- Tracks the state of the warning.

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
  print("Listening for messages...")
end

-- Function to start the audible warning
local function startWarning()
  if not isWarningActive then
    isWarningActive = true
    updateDisplay()
    -- Play a continuous alarm sound
    parallel.waitForAny(
      function()
        while isWarningActive do
          speaker.playNote("harp", 1, 1)
          sleep(0.5)
          speaker.playNote("harp", 1, 1.5)
          sleep(0.5)
        end
      end,
      function()
        -- This function will handle the cancellation event
        while isWarningActive do
            local event, key = os.pullEvent("key")
            if key == keys.c then
                rednet.broadcast("cancel_warning", "protocol_warning")
                isWarningActive = false
            end
        end
      end
    )
    updateDisplay()
  end
end

-- Function to cancel the warning
local function cancelWarning()
  if isWarningActive then
    isWarningActive = false
    updateDisplay()
    -- The parallel task in startWarning will see isWarningActive is false and stop.
  end
end

-- Open the modem on the specified channel
rednet.open("right") -- Assumes modem is on the right, change if needed.
rednet.host("protocol_warning", "warning_system")


-- Main program loop
updateDisplay()

while true do
  -- Use parallel API to listen for both keyboard presses and modem messages
  local id, message, protocol = parallel.waitForAny(
    function()
      -- Listen for keyboard input
      local event, key = os.pullEvent("key")
      return { eventType = "key_press", key = key }
    end,
    function()
      -- Listen for rednet messages
      local senderID, msg, proto = rednet.receive("protocol_warning")
      return { eventType = "rednet_message", sender = senderID, message = msg, protocol = proto }
    end
  )

  -- Handle keyboard input
  if id.eventType == "key_press" then
    if id.key == keys.c then
      -- Send a cancel message
      rednet.broadcast("cancel_warning", "protocol_warning")
      cancelWarning()
    else
      -- Send a warning message
      rednet.broadcast("start_warning", "protocol_warning")
      startWarning()
    end
  -- Handle incoming rednet messages
  elseif id.eventType == "rednet_message" then
    if id.message == "start_warning" then
      startWarning()
    elseif id.message == "cancel_warning" then
      cancelWarning()
    end
  end
end
