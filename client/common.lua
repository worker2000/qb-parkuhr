-- client/common.lua
local QBCore = exports['qb-core']:GetCoreObject()

-- ===== GLOBAL STATE =====
spawnedDevices = spawnedDevices or {}   -- [string(deviceId)] = entity (Automaten)
deviceAreas    = deviceAreas    or {}   -- [deviceId] = { polygon1, polygon2, ... }

-- ===== CONFIG =====
INTERACT_KEY       = (Config and Config.InteractKey) or 38   -- E
MACHINE_USE_DIST   = (Config and Config.MachineUseDist) or 1.8
SMALL_METER_MODELS = (Config and Config.SmallMeterModels) or { `prop_parknmeter_01`, `prop_parknmeter_02` }

placing       = placing or false
ghost         = ghost   or nil
ghostHeading  = ghostHeading or 0.0
placePos      = placePos or nil

-- ===== HELPERS =====
function DrawText3D(c, text)
    local onScreen, x, y = World3dToScreen2d(c.x, c.y, c.z + 1.0)
    if not onScreen then return end
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255,255,255,215)
    SetTextEntry("STRING")
    SetTextCentre(true)
    AddTextComponentString(text)
    DrawText(x, y)
end

function Draw2D(x, y, text)
    SetTextFont(4)
    SetTextScale(0.35, 0.35)
    SetTextColour(255,255,255,220)
    SetTextCentre(false)
    SetTextEntry("STRING")
    AddTextComponentString(text)
    DrawText(x, y)
end

function GetPlate(veh)
    return QBCore.Shared.Trim(GetVehicleNumberPlateText(veh))
end

function RaycastGroundZ(x, y, zStart, zEnd)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(x, y, zStart, x, y, zEnd, 1, 0, 7)
    local _, hit, hitCoords = GetShapeTestResult(handle)
    if hit == 1 then return true, hitCoords.z end
    return false, nil
end

local function safeRemoveTargetEntity(entity)
    if exports['qb-target'] and exports['qb-target'].RemoveTargetEntity then
        exports['qb-target']:RemoveTargetEntity(entity)
    end
end

function DespawnDeviceRaw(entity)
    if entity and DoesEntityExist(entity) then
        safeRemoveTargetEntity(entity)
        SetEntityAsMissionEntity(entity, true, true)
        DeleteEntity(entity)
    end
end

-- ==== qb-target Parameter robust normalisieren ====
local function ResolveTargetEntity(param)
    if param == nil then return 0 end
    local t = type(param)
    if t == "number" then
        return param
    elseif t == "table" then
        if type(param.entity) == "number" then return param.entity end
        if type(param[1]) == "number" then return param[1] end
        if param.data and type(param.data.entity) == "number" then return param.data.entity end
    end
    return 0
end

function GetDeviceIdFromEntity(param)
    local entity = ResolveTargetEntity(param)
    if entity == 0 or not DoesEntityExist(entity) then return nil end
    for id, ent in pairs(spawnedDevices) do
        if ent == entity then return tonumber(id) end
    end
    return nil
end

-- ===== Boden-Snap (fix für „Kopfhöhe“ nach Spawn) =====
local function SnapEntityToGround(entity, x, y, zHint)
    if not (entity and DoesEntityExist(entity)) then return end

    -- Während des Snaps NICHT einfrieren
    FreezeEntityPosition(entity, false)
    SetEntityCollision(entity, true, true)

    -- Kollision laden
    RequestCollisionAtCoord(x, y, (zHint or 50.0))
    local t = GetGameTimer() + 800
    while not HasCollisionLoadedAroundEntity(entity) and GetGameTimer() < t do
        Wait(0)
    end

    -- 1) sanft setzen
    PlaceObjectOnGroundProperly(entity)
    Wait(0)

    -- 2) GroundZ hart ermitteln & setzen
    local ok, gz = GetGroundZFor_3dCoord(x, y, (zHint or 60.0), false)
    if ok then
        SetEntityCoordsNoOffset(entity, x, y, gz + 0.02, false, false, false)
        Wait(0)
    end

    -- 3) Feintuning
    PlaceObjectOnGroundProperly(entity)
    Wait(0)

    -- jetzt einfrieren
    FreezeEntityPosition(entity, true)
end

-- ===== SERVER SYNC (Automaten) =====
local function attachTargetOptions(obj, dev)
    if not (obj and DoesEntityExist(obj)) then return end
    exports['qb-target']:AddTargetEntity(obj, {
        options = {
            { type="client", event="qb_parkuhr:evtUseDevice",    icon="fas fa-ticket-alt",    label=("Parkschein kaufen (ID %d)"):format(dev.id or 0) },
            { type="client", event="qb_parkuhr:evtEmptyDevice",  icon="fas fa-box-open",      label="Automat leeren",        job="parking" },
            { type="client", event="qb_parkuhr:evtRemoveDevice", icon="fas fa-trash",         label="Automat entfernen",     job="parking" },
            { type="client", event="qb_parkuhr:evtEditArea",     icon="fas fa-vector-square", label="Parkbereich bearbeiten", job="parking" },
            { type="client", event="qb_parkuhr:evtLootMachine",  icon="fas fa-search",        label="Automat durchsuchen" },
        },
        distance = 2.0
    })
end

local function spawnDevice(dev)
    if not dev then return end
    local key = tostring(dev.id)
    if spawnedDevices[key] and DoesEntityExist(spawnedDevices[key]) then return end

    local model = joaat(dev.model or 'prop_park_ticket_01')
    RequestModel(model); while not HasModelLoaded(model) do Wait(0) end

    local px, py, pz = dev.x, dev.y, dev.z
    -- Vorab-Annäherung an Boden (optional)
    local ok, gz = RaycastGroundZ(px, py, (pz or 50.0) + 20.0, (pz or 50.0) - 20.0)
    if ok then pz = gz + 0.02 end

    -- Anti-Duplikat
    local existing = GetClosestObjectOfType(vector3(px,py,pz), 0.9, model, false, false, false)

    local obj
    if existing ~= 0 and DoesEntityExist(existing) then
        obj = existing
    else
        obj = CreateObjectNoOffset(model, px, py, pz, false, false, false)
    end

    -- NICHT einfrieren vor dem Snap!
    SetEntityHeading(obj, dev.heading or 0.0)
    SetEntityCollision(obj, true, true)
    SetEntityDynamic(obj, false)
    SetEntityInvincible(obj, true)

    -- 🌍 Zuverlässig auf Boden setzen
    SnapEntityToGround(obj, px, py, pz)

    spawnedDevices[key] = obj
    attachTargetOptions(obj, dev)
end

RegisterNetEvent("qb_parkuhr:syncDevices", function(list)
    for k, ent in pairs(spawnedDevices) do DespawnDeviceRaw(ent); spawnedDevices[k]=nil end
    for _, dev in ipairs(list or {}) do spawnDevice(dev) end
end)

RegisterNetEvent("qb_parkuhr:deviceAdded", function(dev) spawnDevice(dev) end)

RegisterNetEvent("qb_parkuhr:deviceRemoved", function(id)
    local key = tostring(id)
    if spawnedDevices[key] then DespawnDeviceRaw(spawnedDevices[key]); spawnedDevices[key]=nil end
    -- Fallback: lösche nächstes passendes Prop in der Nähe
    local p = GetEntityCoords(PlayerPedId())
    local near = GetClosestObjectOfType(p, 5.0, `prop_park_ticket_01`, false, false, false)
    if near ~= 0 and DoesEntityExist(near) then DespawnDeviceRaw(near) end
end)

-- Erstsync nach Join
CreateThread(function()
    Wait(1000)
    TriggerServerEvent("qb_parkuhr:requestDeviceList")
end)

-- kurzzeitig die ID über dem Gerät anzeigen
RegisterNetEvent("qb_parkuhr:placedMachineId", function(id, dev)
    CreateThread(function()
        local obj = spawnedDevices[tostring(id)]
        local t = GetGameTimer() + 6000
        while obj and DoesEntityExist(obj) and GetGameTimer() < t do
            local c = GetEntityCoords(obj)
            DrawText3D(c + vector3(0,0,1.2), ("ID: %d"):format(id))
            Wait(0)
        end
    end)
end)

-- ===== Areas vom Server cachen (+ kleine Preview) =====
RegisterNetEvent("qb_parkuhr:areasForDevice", function(deviceId, rows)
    deviceId = tonumber(deviceId)
    deviceAreas[deviceId] = {}
    if rows then
        for _, r in ipairs(rows) do
            if r.points_json then
                local ok, dec = pcall(json.decode, r.points_json)
                if ok and dec and type(dec)=="table" and #dec>=3 then
                    table.insert(deviceAreas[deviceId], dec)
                end
            end
        end
    end
    -- Preview der ersten Fläche (optional)
    local pts = deviceAreas[deviceId][1]
    if pts then
        CreateThread(function()
            local untilTime = GetGameTimer() + 6000
            while GetGameTimer() < untilTime do
                for i, p in ipairs(pts) do
                    DrawMarker(1, p.x, p.y, GetEntityCoords(PlayerPedId()).z-1.0, 0,0,0, 0,0,0, 0.4,0.4,0.2, 0,150,255,120, false,false,2, false,nil,nil,false)
                    if i>1 then
                        local p2 = pts[i-1]
                        DrawLine(p.x, p.y, 0.0, p2.x, p2.y, 0.0, 0,150,255,200)
                    end
                end
                if #pts>=3 then
                    DrawLine(pts[1].x, pts[1].y, 0.0, pts[#pts].x, pts[#pts].y, 0.0, 0,150,255,200)
                end
                Wait(0)
            end
        end)
    end
end)

-- ===== NUI: gemeinsame Callbacks (teilt sich Meter/Automat) =====
RegisterNUICallback("buyTicket", function(data, cb)
    local ped = PlayerPedId()
    local opt = {}
    if data and data.deviceId then opt.deviceId = tonumber(data.deviceId) end

    local meterCoords
    local veh = 0

    if not opt.deviceId then
        -- kleine Parkuhr (Automaten-Logik ist in client/automat.lua)
        local p = GetEntityCoords(ped)
        local meter = 0
        for _, model in ipairs(SMALL_METER_MODELS) do
            meter = GetClosestObjectOfType(p, 1.5, model, false, false, false)
            if meter ~= 0 and DoesEntityExist(meter) then break end
        end
        if meter == 0 then TriggerEvent("QBCore:Notify","Keine Parkuhr in der Nähe.", "error"); cb("fail"); return end
        meterCoords = GetEntityCoords(meter)
        veh = GetClosestVehicle(meterCoords, 5.0, 0, 70)
        if veh == 0 or not DoesEntityExist(veh) then TriggerEvent("QBCore:Notify","Kein Fahrzeug in der Nähe!", "error"); cb("fail"); return end
    else
        -- Kauf am Automaten – Fahrzeug muss in den Areas stehen
        local devId = opt.deviceId
        if not deviceAreas[devId] or #deviceAreas[devId]==0 then
            TriggerServerEvent("qb_parkuhr:requestAreasForDevice", devId)
            Wait(150)
        end
        meterCoords = GetEntityCoords(ped)
        veh = exports['qb-parkuhr']:PickVehicleInAreas(devId) -- Export aus client/automat.lua
        if veh == 0 or not DoesEntityExist(veh) then
            TriggerEvent("QBCore:Notify","Kein Fahrzeug im definierten Parkbereich gefunden.", "error"); cb("fail"); return
        end
    end

    local plate = GetPlate(veh)
    local vehCoords = GetEntityCoords(veh)
    TriggerServerEvent("qb_parkuhr:registerTicket", tonumber(data.minutes) or 0, plate, meterCoords, vehCoords, opt)
    cb("ok")
end)

RegisterNUICallback("close", function(_, cb)
    SetNuiFocus(false, false)
    cb("ok")
    SetTimeout(200, function() SetNuiFocus(false, false) end)
end)

RegisterNetEvent("qb_parkuhr:showTicketInfo", function(data)
    SendNUIMessage({ action = "showSideInfo", info = data })
end)

-- ===== Resync & Cleanup =====
RegisterCommand("parkuhr_resync", function()
    TriggerServerEvent("qb_parkuhr:requestDeviceList")
    TriggerEvent("QBCore:Notify", "Automaten neu synchronisiert.", "primary")
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for k, ent in pairs(spawnedDevices) do DespawnDeviceRaw(ent); spawnedDevices[k]=nil end
    if ghost and DoesEntityExist(ghost) then DeleteEntity(ghost) end
end)
