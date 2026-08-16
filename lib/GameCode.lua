-- Normalize mGBA's game identifier across frontend versions.
-- Stable 0.10 builds may return "AGB-BPEE" while newer builds return "BPEE".

local M={}

function M.normalize(value)
    local reported=tostring(value or ""):upper()
    return reported:match("([A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])$") or reported
end

function M.current(core)
    return M.normalize(core:getGameCode())
end

return M
