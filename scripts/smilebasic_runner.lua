-- Drive SmileBASIC 4 through the NS2 demo's startup commands.
--
-- The script only presses buttons and types: it walks the console to Direct
-- mode, then enters LOAD "TXT:NS2", RUN and the REMOVE line, checking each
-- screen with OCR before moving on.  Nothing is typed if a step's screen does
-- not match, so a stray dialog cannot make it fire the next command.
--
-- NS2 must already be saved in slot 0, and something must be listening on
-- TCP 39380 before the last step.  Set HOST below to this PC's address on the
-- link the console can reach (NS2_HOST / NS2_START override it).

local PORT = 39380             -- port the demo connects back to

rule("error-code", "error code")
rule("loaded", "dist boot ready")
rule("direct", "bytes free")
rule("topmenu", "make a program")
rule("home", "smilebasic")
rule("load-confirm", "load the file")
rule("tag-dialog", "tag information")

local function enter(line)
  -- The console applies Caps Lock to USB keyboard letters: sending shifted
  -- (upper-case) text with Caps on lands as lower-case.  So send unshifted
  -- text and let Caps produce the upper-case on screen.  When the console
  -- reports Caps off, literal text is already correct.
  if capslock() ~= false then line = line:lower() end
  type(line .. "\n")
  sleep(0.4)
end

-- Type this PC's address on the link the console can reach.  NetworkManager's
-- shared-Ethernet default is 10.42.0.1; NS2_HOST overrides it.
local HOST = os.getenv("NS2_HOST") or "10.42.0.1"

-- The console can pop an Error Code dialog (e.g. 2155-8007) at any point.
-- "Close" is the focused button, so A dismisses it.
local function dismiss_error()
  if find("error code") then
    tap("A"); sleep(2)
    return true
  end
  return false
end

-- Wait for `word`, dismissing error dialogs that appear meanwhile.
local function expect(word, timeout)
  local deadline = os.time() + timeout
  while os.time() < deadline do
    dismiss_error()
    if find(word) then return true end
    sleep(0.5)
  end
  return false
end

-- Wait for whichever of two words appears first.
local function expect_any(a, b, timeout)
  local deadline = os.time() + timeout
  while os.time() < deadline do
    dismiss_error()
    if find(a) then return a end
    if find(b) then return b end
    sleep(0.5)
  end
  return nil
end

-- HOME menu, "Make a Program", or Direct mode -> Direct mode.  Dialogs are
-- re-checked in the loop because "Tag Information" can follow the launch.
local function to_direct()
  local deadline = os.time() + 30
  local launched = false
  while os.time() < deadline do
    if dismiss_error() then launched = false end
    if find("dist boot ready") then return "loaded" end
    if find("bytes free") then return "direct" end
    if find("tag information") or find("make a program") then
      tap("A"); sleep(1.5)
    elseif find("smilebasic") and not launched then
      tap("A"); sleep(6)                                 -- launch from HOME
      launched = true
    else
      sleep(0.5)
    end
  end
  return nil
end

-- SmileBASIC defaults to Caps Lock on; make sure it is if the console
-- reports it off.  nil means the state has not been reported yet.
local function ensure_caps()
  local deadline = os.time() + 5
  while os.time() < deadline do
    local caps = capslock()
    if caps == true then return true end
    if caps == false then key("capslock"); sleep(0.6) else sleep(0.2) end
  end
  return capslock()
end

-- Build the line now so it is logged before the console starts moving.
local start = os.getenv("NS2_START")
if not start or start == "" then
  start = "V=START(" .. PORT .. "," .. (HOST:gsub("%.", ",")) .. ")"
end
log("START line: " .. start)

local state = to_direct()
if not state then
  log("could not reach SmileBASIC Direct mode - open Make a Program and retry")
  return
end
if state == "loaded" then
  log("bootstrap already ran in this app session; restart SmileBASIC to start over")
  return
end

local caps = ensure_caps()
if caps == true then
  log("Caps Lock on")
elseif caps == false then
  log("Caps Lock is off and did not turn on - typed text will stay lower-case")
else
  log("Caps Lock state not reported; assuming SmileBASIC's default (on)")
end

enter('LOAD "TXT:NS2"')
if expect("load the file", 8) then
  tap("A")
  sleep(1.5)
else
  log("no load confirmation appeared")
end
if not expect("bytes free", 20) then
  log("LOAD did not return to Direct mode")
  return
end
log('loaded NS2')

enter("RUN")
if not expect("dist boot ready", 25) then
  log("bootstrap did not print DIST BOOT READY - is NS2 the current program?")
  return
end
log("bootstrap ran")

-- Expected "Out of memory"; the demo's REMOVE is deliberately oversized.
enter("REMOVE NSR,&H60000000,&H3FFFFFFF")
sleep(2)
log("REMOVE issued")

-- "DIST BOOT READY" stays on screen, so the screen is still labelled
-- "loaded"; the status line is what proves we are back at the prompt.
if not expect("bytes free", 10) then
  log("not back in Direct mode after REMOVE")
  return
end

enter(start)

-- The bootstrap prints HOST CONNECTED once the socket is up, or BOOT FAILED
-- if the address/port did not answer.  Watch for whichever comes first.
local outcome = expect_any("host connected", "boot failed", 20)
if outcome == "host connected" then
  log("console connected - run is under way")
elseif outcome == "boot failed" then
  log("console reported BOOT FAILED - check HOST, then restart SmileBASIC")
else
  log("no HOST CONNECTED yet; check that the listener is running on " .. HOST)
end
