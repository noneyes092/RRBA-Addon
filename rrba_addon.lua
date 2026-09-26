-- RRBA - Republican Reserve Bank addon for SCP: Roleplay server addons.

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local API_URL = "https://rrba-api.noneyes092.workers.dev"
local API_KEY = "ohE3wEYpvaCpuUFbu49n" -- RRBA_GAME_KEY (or the admin key if you did not create one)
local RIG_NAME = "Winston"                 -- name of the rig loaded with :load rig
local CURRENCY = "REZ"
local ENABLE_CHAT_COMMANDS = true

-- Interaction part names (set these as the "Name" of each CustomInteractionPart2)
local BALANCE_INTERACTION = "RRBA_Balance"
local WITHDRAW_INTERACTION = "RRBA_Withdraw" -- money -> score
local DEPOSIT_INTERACTION = "RRBA_Deposit"   -- score -> money

-- Exchange rates: how much REZ and Score move per interaction (button press).
-- Change these two pairs to whatever rate you want; they don't have to match.
local WITHDRAW_REZ_AMOUNT = 50   -- REZ removed from the account per press
local WITHDRAW_SCORE_AMOUNT = 50  -- Score given to the player per press

local DEPOSIT_SCORE_AMOUNT = 50   -- Score removed from the player per press
local DEPOSIT_REZ_AMOUNT = 50    -- REZ added to the account per press

-- Minimum seconds a player must wait between exchange presses (avoids
-- double-charges from lag or button-mashing).
local EXCHANGE_COOLDOWN_SECONDS = 2

-- Guard against sandboxes where the "os" library is unavailable: if calling
-- os.time() ever errors, cooldown checks are skipped instead of silently
-- breaking the whole withdraw/deposit action.
local osTimeWorks = pcall(function() return os.time() end)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local protectedCall = pcall or function(fn, ...)
  return true, fn(...)
end

local function say(message)
  rigSay(RIG_NAME, message)
end

-- No thousands separators on purpose: Roblox's chat filter is more likely
-- to flag messages that contain comma-grouped digit sequences (they can
-- look like phone numbers), especially when a message has more than one.
local function formatNumber(value)
  return tostring(value)
end

-- The http() return type can vary, so accept a string, a table with Body, or (ok, body).
local function extractBody(first, second)
  local result = first
  if type(first) == "boolean" and second ~= nil then
    result = second
  end
  if type(result) == "table" then
    result = result.Body or result.body or result[1]
  end
  return tostring(result or "")
end

-- Splits "OK|123" into "OK", "123".
local function parseReply(body)
  body = string.gsub(body, "^%s+", "")
  body = string.gsub(body, "%s+$", "")
  local separator = string.find(body, "|", 1, true)
  if not separator then
    return "ERROR", "BAD_RESPONSE"
  end
  return string.sub(body, 1, separator - 1), string.sub(body, separator + 1)
end

local function callApi(method, path, payload)
  local headers = { ["X-RRBA-Key"] = API_KEY }
  local body = nil
  if payload then
    headers["Content-Type"] = "application/json"
    body = jsonEncode(payload)
  end

  local ok, first, second = protectedCall(function()
    return http(API_URL .. path, method, headers, body)
  end)
  if not ok then
    return "ERROR", "REQUEST_FAILED"
  end
  return parseReply(extractBody(first, second))
end

-- Simple per-player cooldown so a laggy double-click can't fire the
-- exchange twice. os.time() has second resolution, which is enough here.
local lastExchangeAt = {}

local function onCooldown(player)
  if not osTimeWorks then
    return false -- os.time unavailable in this sandbox; skip cooldown, don't break the action
  end
  local ok, now = pcall(os.time)
  if not ok then
    return false
  end
  local last = lastExchangeAt[player]
  if last and (now - last) < EXCHANGE_COOLDOWN_SECONDS then
    return true
  end
  lastExchangeAt[player] = now
  return false
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------
local function showBalance(player)
  local status, value = callApi("get", "/api/balance/" .. player)
  if status == "OK" then
    say(player .. ", your balance is " .. formatNumber(value) .. " " .. CURRENCY .. ".")
  elseif value == "ACCOUNT_NOT_FOUND" then
    say(player .. ", you do not have an RRBA account yet. Please ask a bank employee to open one.")
  else
    say("Sorry " .. player .. ", the bank system is unavailable right now. Please try again later.")
  end
end

local PAY_ERRORS = {
  SENDER_NOT_FOUND = "you do not have an RRBA account.",
  RECIPIENT_NOT_FOUND = "that recipient does not have an RRBA account.",
  INSUFFICIENT_FUNDS = "you do not have enough funds.",
  SAME_ACCOUNT = "you cannot send money to yourself.",
  INVALID_AMOUNT = "that amount is not valid.",
  INVALID_USERNAME = "that username is not valid.",
}

local function pay(player, target, amount)
  local status, value = callApi("post", "/api/pay", {
    from = player,
    to = target,
    amount = amount,
  })
  if status == "OK" then
    say(player .. ", you sent " .. formatNumber(amount) .. " " .. CURRENCY .. " to " .. target ..
      ". Your new balance is " .. formatNumber(value) .. " " .. CURRENCY .. ".")
  elseif PAY_ERRORS[value] then
    say("Sorry " .. player .. ", " .. PAY_ERRORS[value])
  else
    say("Sorry " .. player .. ", the transfer could not be completed. Please try again later.")
  end
end

local EXCHANGE_ERRORS = {
  ACCOUNT_NOT_FOUND = "you do not have an RRBA account yet. Please ask a bank employee to open one.",
  INSUFFICIENT_FUNDS = "you do not have enough funds for that.",
  INVALID_AMOUNT = "that amount is not valid.",
  INVALID_USERNAME = "that username is not valid.",
}

-- RRBA_Withdraw: pulls REZ_AMOUNT out of the account and gives SCORE_AMOUNT of score.
local function withdrawToScore(player)
  if onCooldown(player) then
    return
  end
  local status, value = callApi("post", "/api/exchange", {
    username = player,
    amount = WITHDRAW_REZ_AMOUNT,
    direction = "to_score",
  })
  if status == "OK" then
    local newScore = getPlayerScore(player) + WITHDRAW_SCORE_AMOUNT
    setPlayerScore(player, newScore)
    say(player .. ", exchange complete.")
    say("New balance: " .. formatNumber(value) .. " " .. CURRENCY)
    say("New score: " .. formatNumber(newScore))
  elseif EXCHANGE_ERRORS[value] then
    say("Sorry " .. player .. ", " .. EXCHANGE_ERRORS[value])
  else
    say("Sorry " .. player .. ", the bank system is unavailable right now. Please try again later.")
  end
end

-- RRBA_Deposit: takes SCORE_AMOUNT of score and credits REZ_AMOUNT of REZ.
-- Score only exists in-game, so it is checked and spent locally, and only
-- after the bank confirms the REZ was added.
local function depositFromScore(player)
  if onCooldown(player) then
    return
  end
  local currentScore = getPlayerScore(player)
  if currentScore < DEPOSIT_SCORE_AMOUNT then
    say(player .. ", you need at least " .. formatNumber(DEPOSIT_SCORE_AMOUNT) .. " score to do that.")
    return
  end

  local status, value = callApi("post", "/api/exchange", {
    username = player,
    amount = DEPOSIT_REZ_AMOUNT,
    direction = "to_money",
  })
  if status == "OK" then
    local newScore = currentScore - DEPOSIT_SCORE_AMOUNT
    setPlayerScore(player, newScore)
    say(player .. ", exchange complete.")
    say("New balance: " .. formatNumber(value) .. " " .. CURRENCY)
    say("New score: " .. formatNumber(newScore))
  elseif EXCHANGE_ERRORS[value] then
    say("Sorry " .. player .. ", " .. EXCHANGE_ERRORS[value])
  else
    say("Sorry " .. player .. ", the bank system is unavailable right now. Please try again later.")
  end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
event("interaction", function(Data)
  local Player = Data.Value[1]
  local Interaction = Data.Value[2]

  if Interaction == BALANCE_INTERACTION then
    showBalance(Player)
  elseif Interaction == WITHDRAW_INTERACTION then
    withdrawToScore(Player)
  elseif Interaction == DEPOSIT_INTERACTION then
    depositFromScore(Player)
  end
end)

if ENABLE_CHAT_COMMANDS then
  event("chatted", function(Data)
    local Player = Data.Value[1]
    local Message = Data.Value[2]
    if type(Message) ~= "string" then
      return
    end

    if string.lower(Message) == "!balance" then
      showBalance(Player)
      return
    end

    local target, amount = string.match(Message, "^!pay%s+(%S+)%s+(%d+)%s*$")
    if target and amount then
      pay(Player, target, tonumber(amount))
    elseif string.lower(string.sub(Message, 1, 4)) == "!pay" then
      say("Usage: !pay <username> <amount>")
    end
  end)
end
