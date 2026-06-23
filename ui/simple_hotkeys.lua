-- Simple Hotkeys
-- A small collection of simple hotkey actions built on the Hotkey API
-- (hotkey_api/ui/hotkey_api.lua), registered via the direct-Lua path
-- (HotkeyApi.RegisterAction) rather than MD, since none of these actions
-- need MD involvement at all - everything here is pure Lua, dispatched
-- straight from onHotKey's actionLua call.

local function debugLog(fmt, ...)
  if select("#", ...) > 0 then
    DebugError("Simple Hotkeys: " .. string.format(fmt, ...))
  else
    DebugError("Simple Hotkeys: " .. fmt)
  end
end

-- Renames an object by reusing vanilla's own rename popup (menu_map.lua's
-- "renamecontext" mode - the same flow the right-click interact menu's
-- "Rename" entry drives), rather than building a custom dialog from
-- scratch. Works from any game mode:
--  - If MapMenu is already open, pop the rename box on top of it directly
--    (mirrors menu_map.lua's own menu.onInteractMenuCallback dispatch).
--  - Otherwise open MapMenu fresh with mode="renamecontext", landing
--    straight in the rename popup instead of the full map view (mirrors
--    menu_interactmenu.lua's menu.buttonRename, minus the "close current
--    menu" part - there's nothing of ours to close here).
local function OpenRenamePopup(object)
  local mapMenu = Helper.getMenu("MapMenu")
  if not mapMenu then
    debugLog("OpenRenamePopup: MapMenu not found")
    return
  end

  if mapMenu.shown then
    mapMenu.onInteractMenuCallback("renamecontext", { object, false })
  else
    OpenMenu("MapMenu", Helper.convertComponentIDs({ 0, 0, true, nil, nil, "renamecontext", { ConvertStringTo64Bit(tostring(object)), false } }), nil)
  end
end

local function OnRenameAction(params)
  local object = params and params.object
  if not object then
    return
  end

  if not GetComponentData(object, "isplayerowned") then
    debugLog("OnRenameAction: object %s is not player-owned - ignoring", tostring(object))
    return
  end

  debugLog("OnRenameAction: opening rename popup for object %s", tostring(object))
  OpenRenamePopup(object)
end

local function RegisterActions()
  if not (HotkeyApi and HotkeyApi.RegisterAction) then
    DebugError("Simple Hotkeys: HotkeyApi.RegisterAction not available - is hotkey_api loaded?")
    return
  end

  debugLog("Register_Request event received, registering actions.")

  HotkeyApi.RegisterAction({
    id = "simple_hotkeys_rename",
    area = "any",
    isObjectRequired = true,
    name = "Rename Selected/Targeted Object",
    version = 1,
    actionLua = OnRenameAction,
  })
end

RegisterEvent("HotkeyApi.Register_Request", RegisterActions)
