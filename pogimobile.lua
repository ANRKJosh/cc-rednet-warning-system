-- Minimal PogiMobile v1.0 - Authentication Test
-- Focus: Get authentication working with minimal complexity

local PHONE_PROTOCOL = "pogphone"
local computer_id = os.getComputerID()

-- Simple state
local authenticated = false
local auth_expires = 0

-- Simple password hash function (same as server)
local function hashPassword(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 1000000
    end
    return tostring(hash)
end

-- Initialize modem
local function initModem()
    for _, side in pairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            print("Modem opened on " .. side)
            return true
        end
    end
    print("ERROR: No modem found!")
    return false
end

-- Check if authenticated
local function isAuthenticated()
    return authenticated and os.time() < auth_expires
end

-- Send authentication request
local function authenticate(password)
    print("Sending auth request...")
    
    local message = {
        type = "security_auth_request",
        password_hash = hashPassword(password),
        user_id = computer_id,
        username = "TestUser-" .. computer_id,
        timestamp = os.time()
    }
    
    print("Password hash: " .. message.password_hash)
    print("User ID: " .. message.user_id)
    
    rednet.broadcast(message, PHONE_PROTOCOL)
    print("Auth request broadcasted")
end

-- Wait for authentication response
local function waitForAuthResponse()
    print("Waiting for auth response...")
    local start_time = os.clock()
    local timeout = 15  -- 15 seconds
    
    while (os.clock() - start_time) < timeout do
        local sender_id, message, protocol = rednet.receive(nil, 1) -- 1 second timeout per check
        
        if sender_id then
            print("Received: " .. protocol .. "/" .. (message.type or "unknown") .. " from " .. sender_id)
            
            if protocol == PHONE_PROTOCOL then
                if message.type == "security_auth_response" and message.target_user_id == computer_id then
                    print("*** AUTH RESPONSE RECEIVED! ***")
                    print("Authenticated: " .. tostring(message.authenticated))
                    
                    if message.authenticated then
                        authenticated = true
                        auth_expires = message.expires or (os.time() + 3600)
                        print("SUCCESS: Authentication successful!")
                        print("Expires at: " .. auth_expires)
                        return true
                    else
                        print("FAILED: Authentication failed!")
                        return false
                    end
                    
                elseif message.type == "server_announcement" and message.auth_result_for_user == computer_id then
                    print("*** DISGUISED AUTH RESPONSE RECEIVED! ***")
                    print("Auth success: " .. tostring(message.auth_success))
                    
                    if message.auth_success then
                        authenticated = true
                        auth_expires = message.auth_expires or (os.time() + 3600)
                        print("SUCCESS: Authentication successful (disguised)!")
                        return true
                    else
                        print("FAILED: Authentication failed (disguised)!")
                        return false
                    end
                    
                else
                    print("Other message: " .. (message.type or "unknown"))
                end
            else
                print("Other protocol: " .. protocol)
            end
        else
            -- No message received in 1 second, show progress
            local elapsed = os.clock() - start_time
            print("Waiting... " .. math.floor(elapsed) .. "s")
        end
    end
    
    print("TIMEOUT: No auth response received")
    return false
end

-- Test network connectivity
local function testNetwork()
    print("=== Network Test ===")
    
    local test_message = {
        type = "network_test",
        from_user = computer_id,
        test_data = "Hello from minimal client",
        timestamp = os.time()
    }
    
    rednet.broadcast(test_message, PHONE_PROTOCOL)
    print("Network test message sent")
    
    print("Listening for responses...")
    local start_time = os.clock()
    
    while (os.clock() - start_time) < 5 do
        local sender_id, message, protocol = rednet.receive(nil, 1)
        if sender_id then
            print("Response: " .. protocol .. "/" .. (message.type or "unknown") .. " from " .. sender_id)
        end
    end
    
    print("Network test complete")
end

-- Main menu
local function showMenu()
    print("\n=== MINIMAL POGIMOBILE ===")
    print("Computer ID: " .. computer_id)
    print("Auth Status: " .. (isAuthenticated() and "AUTHENTICATED" or "NOT AUTHENTICATED"))
    if isAuthenticated() then
        local remaining = auth_expires - os.time()
        print("Expires in: " .. math.floor(remaining / 60) .. " minutes")
    end
    print("\nOptions:")
    print("1. Test Network")
    print("2. Authenticate")
    print("3. Check Auth Status") 
    print("4. Exit")
    print("\nEnter choice:")
end

-- Main program
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("Minimal PogiMobile Starting...")
    
    if not initModem() then
        return
    end
    
    while true do
        showMenu()
        local choice = read()
        
        if choice == "1" then
            testNetwork()
            
        elseif choice == "2" then
            print("\nEnter password:")
            local password = read("*")
            if password and password ~= "" then
                authenticate(password)
                waitForAuthResponse()
            else
                print("No password entered")
            end
            
        elseif choice == "3" then
            print("\nAuth Status: " .. (isAuthenticated() and "AUTHENTICATED" or "NOT AUTHENTICATED"))
            if isAuthenticated() then
                local remaining = auth_expires - os.time()
                print("Time remaining: " .. math.floor(remaining / 60) .. " minutes")
            end
            print("Press any key to continue...")
            os.pullEvent("key")
            
        elseif choice == "4" then
            print("Goodbye!")
            break
            
        else
            print("Invalid choice")
        end
        
        print("\nPress any key to continue...")
        os.pullEvent("key")
        term.clear()
        term.setCursorPos(1, 1)
    end
end

-- Run the program
main()
