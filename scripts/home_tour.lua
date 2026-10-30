-- Walk the HOME menu tiles and come back, using OCR to confirm where we are.

-- Rules are checked in order; every word must be on screen (spaces ignored).
rule("home", "options", "ok")
rule("settings", "system settings")

tap("HOME", 0.15)
if not wait("home", 10) then
  log("HOME menu not detected - is the console on the HOME screen?")
  return
end
log("on HOME")

for i = 1, 3 do
  dpad("right", 0.1)
  sleep(0.4)
end
log("moved 3 tiles right")

for i = 1, 3 do
  dpad("left", 0.1)
  sleep(0.4)
end

log("screen is: " .. screen())
