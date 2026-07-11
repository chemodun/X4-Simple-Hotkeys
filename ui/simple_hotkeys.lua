-- Simple Hotkeys
-- A small collection of simple hotkey actions built on the Native Hotkey API
-- (hotkey_api/ui/hotkey_api.lua), registered via the direct-Lua path
-- (HotkeyApi.RegisterAction) rather than MD, since none of these actions
-- need MD involvement at all - everything here is pure Lua, dispatched
-- straight from onHotKey's actionLua call.

local PAGE_ID = 1972092432

local ffi = require("ffi")
local C = ffi.C
ffi.cdef [[
  typedef uint64_t UniverseID;
  UniverseID GetPlayerID(void);
  UniverseID GetPlayerOccupiedShipID(void);
  UniverseID GetPlayerControlledShipID(void);
	bool IsGamePaused(void);
  UniverseID GetContextByClass(UniverseID componentid, const char* classname, bool includeself);
  typedef struct {
    uint32_t id;
    const char* text;
    const char* type;
    bool ispossible;
    bool istobedisplayed;
  } UIAction;
  typedef struct {
    UniverseID component;
    const char* connection;
  } UIComponentSlot;
  uint32_t GetNumCompSlotPlayerActions(UIComponentSlot compslot);
  uint32_t GetCompSlotPlayerActions(UIAction* result, uint32_t resultlen, UIComponentSlot compslot);
  bool PerformCompSlotPlayerAction(UIComponentSlot compslot, uint32_t actionid);
  typedef struct {
    uint64_t softtargetID;
    const char* softtargetConnectionName;
    uint32_t messageID;
  } SofttargetDetails2;
  SofttargetDetails2 GetSofttarget2(void);
]]

local function debugLog(fmt, ...)
  if select("#", ...) > 0 then
    DebugError("Simple Hotkeys: " .. string.format(fmt, ...))
  else
    DebugError("Simple Hotkeys: " .. fmt)
  end
end

-- Shared mod-config state. Authoritative storage is __SIMPLE_HOTKEYS_DATA, a
-- <savedvariable storage="userdata"/> (ui.xml) - same pattern hotkey_api uses
-- for its own debugEnabled/usedSlots/blockedIds. Declared as a genuine global
-- (not local) since the engine's userdata persistence looks it up by name; no
-- migration from the old blackboard-cache needed (this mod isn't published
-- yet). Mutating it in place *is* the persistence - no explicit "commit" call
-- exists (mirrors hotkey_api's own SaveDebugEnabled, which only pushes to the
-- blackboard, never touches its userdata table beyond the direct assignment).
--
-- MD's own DefaultConfig library (md/simple_hotkeys.xml) still creates/reads
-- player.entity.$SimpleHotkeysConfig for Register_On_Reloaded's hotkey-gating
-- logic, but Lua now owns the source of truth - every load and every change
-- pushes the current values to that blackboard var via SetNPCBlackboard so MD
-- keeps seeing current state.
__SIMPLE_HOTKEYS_DATA = __SIMPLE_HOTKEYS_DATA or {}

local playerId = nil
local optionsConfig = nil

local function GetPlayerId()
  if not playerId then
    playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  end
  return playerId
end

-- Pushes the current config to player.entity.$SimpleHotkeysConfig so MD can
-- read it. Called after every load (in case defaults were just filled in)
-- and after every change (toggle/dropdown callback).
local function SyncConfigToBlackboard()
  SetNPCBlackboard(GetPlayerId(), "$SimpleHotkeysConfig", optionsConfig)
end

local function LoadOptionsConfig()
  if optionsConfig then
    return optionsConfig
  end
  optionsConfig = __SIMPLE_HOTKEYS_DATA
  if optionsConfig.launchHotkeysPilotEnabled == nil then
    optionsConfig.launchHotkeysPilotEnabled = true
  end
  if optionsConfig.launchHotkeysMapEnabled == nil then
    optionsConfig.launchHotkeysMapEnabled = true
  end
  optionsConfig.objectListHotkeysMode = optionsConfig.objectListHotkeysMode or "disabled"
  optionsConfig.propertyOwnedHotkeysMode = optionsConfig.propertyOwnedHotkeysMode or "disabled"
  SyncConfigToBlackboard()
  return optionsConfig
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

local function OnRenameAction(data)
  local object = data and data.object
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

-- Toggles the map's right-side info panel for whatever is currently
-- selected/second-selected, mirroring the sidebar icon's own onClick logic
-- exactly (menu_map.lua: menu.panelMode and menu.buttonToggleRightPanel() or
-- menu.buttonToggleRightBar("info")) - "info" is config.rightBar's own mode
-- string for that icon. No native hotkey exists for this at all (only the
-- mouse-click sidebar icon) - the left-side equivalent is likewise mouse-only.
local function OnOpenRightInfoAction()
  local mapMenu = Helper.getMenu("MapMenu")
  if not mapMenu or not mapMenu.shown then
    debugLog("OnOpenRightInfoAction: MapMenu not open")
    return
  end

  if mapMenu.panelMode then
    mapMenu.buttonToggleRightPanel()
  else
    mapMenu.buttonToggleRightBar("info")
  end
end

-- Attempts to find a player action on the given compslot that matches the
-- desired text, returning the first match (if any) along with its ID and
-- ispossible flag. Logs all actions found for debugging purposes.
local function TryCompSlotAction(compSlot, label, desiredText)
  local n = C.GetNumCompSlotPlayerActions(compSlot)
  debugLog("TryCompSlotAction: [%s] compslot component=%s connection=%s -> %d action(s)", label, tostring(compSlot.component), ffi.string(compSlot.connection), tonumber(n))
  if n == 0 then
    return nil
  end

  local buf = ffi.new("UIAction[?]", n)
  n = C.GetCompSlotPlayerActions(buf, n, compSlot)

  local matched = nil
  for i = 0, n - 1 do
    local text = ffi.string(buf[i].text)
    debugLog(
      "TryCompSlotAction: [%s] action %d/%d - id=%s text='%s' type=%s ispossible=%s istobedisplayed=%s",
      label, i + 1, n, tostring(buf[i].id), text, ffi.string(buf[i].type), tostring(buf[i].ispossible), tostring(buf[i].istobedisplayed)
    )
    if (not matched) and (text == desiredText) then
      matched = { id = buf[i].id, text = text, ispossible = buf[i].ispossible }
    end
  end
  return matched
end

-- Performs the "Take Command of Ship" action on the given compSlot, then
-- checks whether the player now controls the ship. If not, it will try again
-- after a short delay, up to maxIterations times. This mirrors the behavior of
-- the right-click interact menu's "Take Command" entry, which also does a
-- second click if the first fails.
local function PerformTakePilotSeatAction(compSlot, action, iteration, maxIterations)
  if iteration > maxIterations then
    debugLog("PerformTakePilotSeatAction: exceeded max iterations (%d) - aborting", maxIterations)
    return
  end

  local controlled = C.GetPlayerControlledShipID()
  debugLog(
    "PerformTakePilotSeatAction: before call %d/%d - controlled=%s firstPerson=%s",
    iteration, maxIterations, tostring(controlled), tostring(IsFirstPerson())
  )
  C.PerformCompSlotPlayerAction(compSlot, action.id)
  controlled = C.GetPlayerControlledShipID()
  debugLog(
    "PerformTakePilotSeatAction: after call %d/%d - controlled=%s firstPerson=%s",
    iteration, maxIterations, tostring(controlled), tostring(IsFirstPerson())
  )

  if controlled ~= compSlot.component then
    debugLog("PerformTakePilotSeatAction: control not taken yet - firing '%s' again (iteration %d/%d) with delay", action.text, iteration + 1, maxIterations)
    Helper.addDelayedOneTimeCallbackOnUpdate(
      function()
        PerformTakePilotSeatAction(compSlot, action, iteration + 1, maxIterations)
      end, false, getElapsedTime() + 0.3)
  end
end

-- Attempts to take control of the player's currently occupied ship (if any)
-- by performing the "Take Command of Ship" action on the ship's softtarget
-- compslot. If the player is not currently walking a ship, or the ship is not
-- player-owned, or the softtarget compslot does not have a matching action,
-- this function does nothing. If the action is found but fails to take control
-- on the first attempt, it will try a second time (mirroring the behavior of
-- the right-click interact menu's "Take Command" entry, which also does a
-- second click if the first fails).
local function OnTakePilotSeatAction(data)
  if C.IsGamePaused() then
    debugLog("OnTakePilotSeatAction: game is paused - ignoring")
    return
  end

  local ship = C.GetContextByClass(C.GetPlayerID(), "ship", false)
  local shipId64 = ConvertStringTo64Bit(tostring(ship))
  if shipId64 == 0 then
    debugLog("OnTakePilotSeatAction: player is not walking a ship - ignoring")
    return
  end
  local isPlayerOwned, name, idcode = GetComponentData(shipId64, "isplayerowned", "name", "idcode")
  if not isPlayerOwned then
    debugLog("OnTakePilotSeatAction: ship %s (%s) is not player-owned - ignoring", tostring(name), tostring(idcode))
    return
  end

  if data == nil or data.softTarget == nil then
    debugLog("OnTakePilotSeatAction: no softTarget provided - ignoring")
    return
  end

  local controlled = C.GetPlayerControlledShipID()

  if controlled == shipId64 then
    debugLog("OnTakePilotSeatAction: player already controls ship %s (%s) - ignoring", tostring(name), tostring(idcode))
    return
  end

  local takeCommandText = ReadText(1010, 58)   -- "Take Command of Ship"

  -- Attempt 1: the crosshair's actual current softtarget + connection.
  local softTargetId = tonumber(data.softTarget.softtargetID) or 0
  local softTargetConnection = ffi.string(data.softTarget.softtargetConnectionName)
  debugLog("OnTakePilotSeatAction: softTarget id=%s connection='%s' messageID=%s", tostring(softTargetId), softTargetConnection, tostring(data.softTarget.messageID))

  if (softTargetId == data.object) and IsValidComponent(softTargetId) then
    local softTargetCompSlot = ffi.new("UIComponentSlot")
    softTargetCompSlot.component = softTargetId
    local softTargetConnectionString = Helper.ffiNewString(softTargetConnection)
    softTargetCompSlot.connection = softTargetConnectionString
    local matched = TryCompSlotAction(softTargetCompSlot, "softtarget", takeCommandText)
    if matched then
      debugLog("OnTakePilotSeatAction: performing native action '%s' (id %s) on ship %s (%s)", matched.text, tostring(matched.id), tostring(name), tostring(idcode))
      PerformTakePilotSeatAction(softTargetCompSlot, matched, 1, 4)
    end
  else
    debugLog("OnTakePilotSeatAction: no valid softTarget - skipping softTarget-based attempt")
  end
end

-- Opens the given left-panel group (menu_map.lua's "objectlist"/
-- "propertyowned" infoTableMode) straight to the given category tab.
--  - If MapMenu is already open, switches live: forces the panel onto the
--    right group first (only if it isn't already showing it, to avoid an
--    unnecessary reset) via buttonToggleObjectList, then picks the tab via
--    buttonObjectSubMode/buttonPropertySubMode directly - same calls the
--    real tab-strip buttons make.
--  - Otherwise opens MapMenu fresh landing straight on that tab via mode
--    "infomode"/{groupMode, category} (mirrors OpenRenamePopup's own
--    dual-path pattern, using "infomode" instead of "renamecontext").
local function SwitchOrOpenMapTab(groupMode, subModeButtonName, category, col)
  local mapMenu = Helper.getMenu("MapMenu")
  if mapMenu and mapMenu.shown then
    if mapMenu.infoTableMode ~= groupMode then
      mapMenu.buttonToggleObjectList(groupMode, true, true)
    end
    mapMenu[subModeButtonName](category, col)
  else
    OpenMenu("MapMenu", Helper.convertComponentIDs({ 0, 0, true, nil, nil, "infomode", { groupMode, category } }), nil)
  end
end

-- Object List / Property Owned tab groups, driven by the Options menu's
-- $objectListHotkeysMode/$propertyOwnedHotkeysMode dropdowns. Category keys
-- and their vanilla text refs (page 1001) come straight from menu_map.lua's
-- config.objectCategories/config.propertyCategories, in the same order, so
-- action names always match the actual in-game tab label/translation and
-- "col" lines up reasonably with the real tab-strip column.
local TAB_GROUPS = {
  {
    idPrefix      = "simple_hotkeys_objectlist_",
    configKey     = "objectListHotkeysMode",
    groupMode     = "objectlist",
    subModeButton = "buttonObjectSubMode",
    groupNamePage = 1001,
    groupNameId   = 3224, -- "Object List"
    categories = {
      { key = "objectall",   namePage = 1001, nameId = 8380 }, -- "All"
      { key = "stations",    namePage = 1001, nameId = 8379 }, -- "Stations"
      { key = "ships",       namePage = 1001, nameId = 6 },    -- "Ships"
      { key = "deployables", namePage = 1001, nameId = 1332 }, -- "Deployables"
    },
  },
  {
    idPrefix      = "simple_hotkeys_propertyowned_",
    configKey     = "propertyOwnedHotkeysMode",
    groupMode     = "propertyowned",
    subModeButton = "buttonPropertySubMode",
    groupNamePage = 1001,
    groupNameId   = 1000, -- "Property Owned"
    categories = {
      { key = "propertyall",     namePage = 1001, nameId = 8380 }, -- "All"
      { key = "stations",        namePage = 1001, nameId = 8379 }, -- "Stations"
      { key = "fleets",          namePage = 1001, nameId = 8326 }, -- "Fleets"
      { key = "unassignedships", namePage = 1001, nameId = 8327 }, -- "Unassigned Ships"
      { key = "inventoryships",  namePage = 1001, nameId = 8381 }, -- "Inventory Ships"
      { key = "deployables",     namePage = 1001, nameId = 1332 }, -- "Deployables"
    },
  },
}

-- Registers 0/1/2 hotkey ids per category depending on its group's config
-- mode: none (disabled), "_pilot" (pilotOnly/pilotAndMapSeparated), "_map"
-- (mapOnly/pilotAndMapSeparated), or "_unified" (pilotAndMapUnified) - three
-- fully independent ids/slots per tab, never reused across modes. Display
-- names are entirely vanilla-ref-composed (group + category) with one of
-- our own three prefixes (ids 30000/10000/40000).
local function RegisterTabHotkeys()
  local cfg = LoadOptionsConfig()

  for _, group in ipairs(TAB_GROUPS) do
    local mode = cfg[group.configKey] or "disabled"
    if mode ~= "disabled" then
      local groupName = ReadText(group.groupNamePage, group.groupNameId)
      for col, cat in ipairs(group.categories) do
        local catName = ReadText(cat.namePage, cat.nameId)
        local baseName = string.format("%s: %s", groupName, catName)
        local action = function()
          SwitchOrOpenMapTab(group.groupMode, group.subModeButton, cat.key, col)
        end

        if mode == "pilotOnly" or mode == "pilotAndMapSeparated" then
          HotkeyApi.RegisterAction({
            id = group.idPrefix .. cat.key .. "_pilot",
            area = "pilot",
            isObjectRequired = false,
            name = string.format("%s %s", ReadText(PAGE_ID, 30000), baseName),
            version = 1,
            actionLua = action,
          })
        end
        if mode == "mapOnly" or mode == "pilotAndMapSeparated" then
          HotkeyApi.RegisterAction({
            id = group.idPrefix .. cat.key .. "_map",
            area = "map",
            isObjectRequired = false,
            name = string.format("%s %s", ReadText(PAGE_ID, 10000), baseName),
            version = 1,
            actionLua = action,
          })
        end
        if mode == "pilotAndMapUnified" then
          HotkeyApi.RegisterAction({
            id = group.idPrefix .. cat.key .. "_unified",
            area = "pilot;map",
            isObjectRequired = false,
            name = string.format("%s %s", ReadText(PAGE_ID, 40000), baseName),
            version = 1,
            actionLua = action,
          })
        end
      end
    end
  end
end

-- *** Extension Options: nested inside hotkey_api's own Management page ***
--
-- Instead of a separate SirNukes Simple_Menu_API/options_helper-based menu,
-- this mod's settings are appended directly into hotkey_api's native
-- "Hotkey Management" Options page (config.optionDefinitions[HotkeyApi.
-- managementPageId]), via the same displayOptions_modifyOptions UIX hook
-- hotkey_api itself uses (gameoptions.xpl). This drops the
-- sn_mod_support_apis/options_helper dependencies entirely.
--
-- Row-append ordering: gameoptions.xpl dispatches every registered
-- "displayOptions_modifyOptions" callback via pairs() over a hash-keyed
-- table, not insertion order - which mod's callback fires first on a given
-- render is not reliably tied to load/dependency order. To guarantee
-- hotkey_api's own page/rows exist before this mod appends to them, this
-- mod calls HotkeyApi.OnDisplayOptions(options, config) itself first - it's
-- idempotent (guarded by "only create if the page doesn't already exist"),
-- so calling it here is safe even if the shared callback list also invokes
-- it again later in the same render.

local HOTKEY_MODE_OPTIONS = {
  { id = "disabled",             textId = 100011 },
  { id = "pilotOnly",            textId = 100012 },
  { id = "mapOnly",              textId = 100013 },
  { id = "pilotAndMapSeparated", textId = 100014 },
  { id = "pilotAndMapUnified",   textId = 100015 },
}

-- Shared by both dropdown rows below - all four fields (id/icon/text/
-- displayremoveoption) are required by createDropDown, omitting any of them
-- throws "Invalid dropdown descriptor" at runtime.
local function BuildHotkeyModeOptions()
  local options = {}
  for _, entry in ipairs(HOTKEY_MODE_OPTIONS) do
    table.insert(options, { id = entry.id, icon = "", text = ReadText(PAGE_ID, entry.textId), displayremoveoption = false })
  end
  return options
end

local function ToggleConfigFlag(configKey)
  return function()
    local cfg = LoadOptionsConfig()
    cfg[configKey] = not cfg[configKey]
    SyncConfigToBlackboard()
    HotkeyApi.BroadcastReloaded()
  end
end

local function OnHotkeyModeChanged(configKey)
  return function(_, selectedId)
    local cfg = LoadOptionsConfig()
    cfg[configKey] = selectedId
    SyncConfigToBlackboard()
    HotkeyApi.BroadcastReloaded()
  end
end

-- valuetype="button": generic vanilla renderer has no real checkbox widget
-- outside a fully custom-rendered page (see hotkey_api's own debug toggle,
-- which uses the same button/text-flip approach for the same reason).
-- "Enabled"/"Disabled" reuse vanilla's own text refs (page 1001) - no new
-- translation needed.
local function BuildToggleRow(id, nameTextId, configKey)
  return {
    id = id,
    name = function() return ReadText(PAGE_ID, nameTextId) end,
    value = function() return LoadOptionsConfig()[configKey] and ReadText(1001, 4825) or ReadText(1001, 8942) end,
    valuetype = "button",
    callback = ToggleConfigFlag(configKey),
  }
end

-- valuetype="dropdown": a real dropdown widget, natively supported by the
-- generic renderer (confirmed via vanilla's own "online" page definitions).
local function BuildDropdownRow(id, nameTextId, configKey)
  return {
    id = id,
    name = function() return ReadText(PAGE_ID, nameTextId) end,
    value = function() return BuildHotkeyModeOptions(), LoadOptionsConfig()[configKey] end,
    valuetype = "dropdown",
    callback = OnHotkeyModeChanged(configKey),
  }
end

local function OnDisplayOptions(options, config)
  if not (HotkeyApi and HotkeyApi.OnDisplayOptions and HotkeyApi.managementPageId) then
    return options
  end

  options = HotkeyApi.OnDisplayOptions(options, config)

  local page = config and config.optionDefinitions and config.optionDefinitions[HotkeyApi.managementPageId]
  if not page then
    -- hotkey_api hasn't created its page this render (e.g. config not ready
    -- yet) - nothing safe to append to.
    return options
  end

  for _, row in ipairs(page) do
    if type(row) == "table" and row.id == "simple_hotkeys_launch_pilot_toggle" then
      return options -- already appended on a previous render
    end
  end

  table.insert(page, { id = "header", name = function() return ReadText(PAGE_ID, 100100) end })
  table.insert(page, BuildToggleRow("simple_hotkeys_launch_pilot_toggle", 100101, "launchHotkeysPilotEnabled"))
  table.insert(page, BuildToggleRow("simple_hotkeys_launch_map_toggle", 100102, "launchHotkeysMapEnabled"))
  table.insert(page, { id = "header", name = function() return ReadText(PAGE_ID, 100200) end })
  table.insert(page, BuildDropdownRow("simple_hotkeys_objectlist_mode", 100201, "objectListHotkeysMode"))
  table.insert(page, { id = "header", name = function() return ReadText(PAGE_ID, 100300) end })
  table.insert(page, BuildDropdownRow("simple_hotkeys_propertyowned_mode", 100301, "propertyOwnedHotkeysMode"))

  debugLog("OnDisplayOptions: appended Simple Hotkeys rows to hotkey_api's management page")
  return options
end

local optionsMenu = nil
local optionsMenuHooked = false

local function EnsureOptionsMenuHooked()
  if optionsMenuHooked then
    return
  end
  optionsMenu = Helper.getMenu("OptionsMenu")
  if not (optionsMenu and type(optionsMenu.registerCallback) == "function") then
    debugLog("EnsureOptionsMenuHooked: OptionsMenu not available yet")
    return
  end
  optionsMenu.registerCallback("displayOptions_modifyOptions", OnDisplayOptions)
  optionsMenuHooked = true
  debugLog("EnsureOptionsMenuHooked: registered displayOptions_modifyOptions callback")
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
    name = ReadText(PAGE_ID, 40001),
    version = 1,
    actionLua = OnRenameAction,
  })

  HotkeyApi.RegisterAction({
    id = "simple_hotkeys_zoom_in",
    area = "pilot",
    isObjectRequired = false,
    name = ReadText(PAGE_ID, 31031),
    version = 1,
    actionLua = OnZoomInAction,
  })

  HotkeyApi.RegisterAction({
    id = "simple_hotkeys_take_pilot_seat",
    area = "fps",
    isObjectRequired = true,
    name = ReadText(PAGE_ID, 20001),
    version = 1,
    actionLua = OnTakePilotSeatAction,
  })

  HotkeyApi.RegisterAction({
    id = "simple_hotkeys_open_right_info",
    area = "map",
    isObjectRequired = false,
    name = ReadText(PAGE_ID, 10011),
    version = 1,
    actionLua = OnOpenRightInfoAction,
  })

  RegisterTabHotkeys()
  EnsureOptionsMenuHooked()
end

RegisterEvent("HotkeyApi.Register_Request", RegisterActions)
