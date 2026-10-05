-- drovr status for WezTerm: counts workers by reading drovr's state directory, so a
-- status bar polling every few hundred ms never spawns a process.
--
--   local drovr = dofile(os.getenv("HOME") .. "/.local/share/drovr/wezterm.lua")
--   wezterm.on("update-status", function(window)
--     window:set_right_status(drovr.status())  -- e.g. "drovr 2▶ 1✓"
--   end)
--
-- Call it from update-status: wezterm.read_dir is async and fails elsewhere.
local wezterm = require("wezterm")

local M = {}

local root = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/drovr"

local function read_line(path)
  local f = io.open(path)
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

-- counts() -> running, done, failed
function M.counts()
  local ok, entries = pcall(wezterm.read_dir, root)
  if not ok or not entries then return 0, 0, 0 end
  local run, done, failed = 0, 0, 0
  for _, dir in ipairs(entries) do
    if read_line(dir .. "/cwd") then -- a worker, not a stray file
      local exit = read_line(dir .. "/exit")
      if exit == nil then
        run = run + 1
      elseif exit == "0" then
        done = done + 1
      else
        failed = failed + 1
      end
    end
  end
  return run, done, failed
end

-- status([prefix]) -> "drovr 2▶ 1✓ 1✗", or "" when there are no workers.
function M.status(prefix)
  local run, done, failed = M.counts()
  local parts = {}
  if run > 0 then table.insert(parts, run .. "▶") end
  if done > 0 then table.insert(parts, done .. "✓") end
  if failed > 0 then table.insert(parts, failed .. "✗") end
  if #parts == 0 then return "" end
  return (prefix or "drovr ") .. table.concat(parts, " ")
end

return M
