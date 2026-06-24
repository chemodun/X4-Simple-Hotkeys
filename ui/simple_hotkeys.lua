-- Simple Hotkeys
-- A small collection of simple hotkey actions built on the Native Hotkey API
-- (hotkey_api/ui/hotkey_api.lua), registered via the direct-Lua path
-- (HotkeyApi.RegisterAction) rather than MD, since none of these actions
-- need MD involvement at all - everything here is pure Lua, dispatched
-- straight from onHotKey's actionLua call.

local PAGE_ID = 1972092432

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

-- A single self-resetting action (no MD equivalent exists - camera FOV is
-- Lua/FFI-only): each press steps to the next zoom factor; pressing again
-- once at the highest factor resets straight back to the fov that was
-- active before zooming started. actionLua only ever fires once per press
-- (no onRepeat/onRelease), so this cycle is the natural fit, rather than
-- needing a second "reset" hotkey or trying to hold-to-zoom.
local zoom = {
  baseline = nil,
  factors = { 1, 2, 4, 8 },
  index = 1,
}

local function OnZoomInAction()
  if zoom.index >= #zoom.factors then
    if zoom.baseline then
      SetFOVOption(zoom.baseline)
    end
    debugLog("OnZoomInAction: at max zoom - reset to baseline fov %s", tostring(zoom.baseline))
    zoom.index = 1
    return
  end

  if zoom.index == 1 then
    zoom.baseline = GetFOVOption()
  end
  zoom.index = zoom.index + 1
  SetFOVOption(zoom.baseline / zoom.factors[zoom.index])
  debugLog("OnZoomInAction: stepped to factor %dx (baseline fov %s)", zoom.factors[zoom.index], tostring(zoom.baseline))
end

local function RegisterActions()
  if not (HotkeyApi and HotkeyApi.RegisterAction) then
    DebugError("Simple Hotkeys: HotkeyApi.RegisterAction not available - is hotkey_api loaded?")
    return
  end

  debugLog("Register_Request event received, registering actions.")

  HotkeyApi.RegisterAction({
    id = "simple_hotkeys_rename",
    area = "map;pilot",
    isObjectRequired = true,
    name = ReadText(PAGE_ID, 10001),
    version = 1,
    actionLua = OnRenameAction,
  })

  HotkeyApi.RegisterAction({
    id = "simple_hotkeys_zoom_in",
    area = "pilot",
    isObjectRequired = false,
    name = ReadText(PAGE_ID, 10201),
    version = 1,
    actionLua = OnZoomInAction,
  })
end

RegisterEvent("HotkeyApi.Register_Request", RegisterActions)
