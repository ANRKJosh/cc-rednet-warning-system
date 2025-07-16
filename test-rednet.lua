-- Simple network test to debug the issue
local protocol = "poggishtown_warning"
local computer_id = os.getComputerID()

-- Find and open modem
local modem_side = nil
for _, side in pairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        modem_side = side
        rednet.open(side)
        print("Modem opened on: " .. side)
        break
    end
end

if not modem_side then
    error("No modem found")
end

print("Computer ID: " .. computer_id)
print("Protocol: " .. protocol)
print("Listening for messages...")
print("Press 'T' to send test message")
print("Press 'Q' to quit")

-- Simple event loop
while true do
    local event, param1, param2, param3, param4, param5 = os.pullEvent()
    
    if event == "key" then
        local key = param1
        if key == keys.t then
            local msg = {
                type = "test",
                from = computer_id,
                message = "Hello from " .. computer_id,
                timestamp = os.time()
            }
            print("Sending test message...")
            rednet.broadcast(msg, protocol)
        elseif key == keys.q then
            break
        end
    elseif event == "rednet_message" then
        local sender_id, message, proto = param1, param2, param3
        print("Received rednet_message event:")
        print("  Sender: " .. sender_id)
        print("  Protocol: " .. proto)
        print("  Message: " .. textutils.serialize(message))
        
        if proto == protocol and message.type == "test" and message.from ~= computer_id then
            print("Responding to test...")
            local response = {
                type = "test",
                from = computer_id,
                message = "Response from " .. computer_id,
                timestamp = os.time()
            }
            rednet.broadcast(response, protocol)
        end
    end
end

print("Shutting down...")
rednet.close(modem_side)
