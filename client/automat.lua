-- client/automat.lua

-- ======================================================
-- Flächen-Logik (Polygon) & Vehicle-Pick
-- ======================================================

local function pointInPolygon(x, y, poly)
    if not poly or #poly < 3 then return false end
    local inside, j = false, #poly
    for i = 1, #poly do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        if ((yi > y) ~= (yj > y)) then
            local denom = (yj - yi)
            if denom == 0 then denom = 1e-9 end
            local xint = (xj - xi) * (y - yi) / denom + xi
            if x < xint then inside = not inside end
        end
        j = i
    end
    return inside
end

local function isInsideAnyArea(deviceId, x, y)
    local areas = deviceAreas[deviceId]
    if not areas or #areas == 0 then return false end
    for _, poly in ipairs(areas) do
        if pointInPolygon(x, y, poly) then return true end
    end
    return false
end

local function pickVehicleInAreas(deviceId)
    local areas = deviceAreas[deviceId]
    if not areas or #areas == 0 then return 0 end

    local devEnt = spawnedDevices[tostring(deviceId)]
    local anchor = devEnt and GetEntityCoords(devEnt) or GetEntityCoords(PlayerPedId())

    local bestVeh, bestDist = 0, 1e9
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if veh ~= 0 and DoesEntityExist(veh) then
            local pos = GetEntityCoords(veh)
            if #(pos - anchor) <= 80.0 then -- Performance-Limit
                if isInsideAnyArea(deviceId, pos.x, pos.y) then
                    local d = #(pos - anchor)
                    if d < bestDist then bestVeh, bestDist = veh, d end
                end
            end
        end
    end
    return bestVeh
end

-- Export für NUI-Buy in common.lua
exports('PickVehicleInAreas', function(deviceId)
    return pickVehicleInAreas(tonumber(deviceId))
end)

-- ======================================================
-- E-Prompt am Automaten
-- ======================================================

local function getNearestMachine(maxDist)
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local bestId, bestEnt, bestPos, bestD = nil, nil, nil, maxDist or MACHINE_USE_DIST
    for id, ent in pairs(spawnedDevices) do
        if ent and DoesEntityExist(ent) then
            local c = GetEntityCoords(ent)
            local d = #(p - c)
            if d <= bestD then
                bestD, bestId, bestEnt, bestPos = d, tonumber(id), ent, c
            end
        end
    end
    return bestId, bestEnt, bestPos, bestD
end

CreateThread(function()
    while true do
        local wait = 500
        if not placing and not IsPedInAnyVehicle(PlayerPedId(), false) then
            local devId, ent, pos = getNearestMachine(MACHINE_USE_DIST)
            if devId and ent then
                wait = 0
                DrawText3D(pos + vector3(0,0,1.0), "[E] Parkschein (Parkbereich)")
                if IsControlJustReleased(0, INTERACT_KEY) then
                    -- Flächen anfordern (Cache füllen)
                    TriggerServerEvent("qb_parkuhr:requestAreasForDevice", devId)
                    Wait(150)
                    SetNuiFocus(true, true)
                    SendNUIMessage({ action = "open", deviceId = devId })
                    Wait(200)
                end
            end
        end
        Wait(wait)
    end
end)

-- ======================================================
-- qb-target Events (Param via GetDeviceIdFromEntity aus common.lua)
-- ======================================================

RegisterNetEvent("qb_parkuhr:evtUseDevice", function(param)
    local id = GetDeviceIdFromEntity(param)
    if not id then TriggerEvent("QBCore:Notify", "Gerät unbekannt.", "error"); return end
    TriggerServerEvent("qb_parkuhr:requestAreasForDevice", id)
    Wait(150)
    SetNuiFocus(true, true)
    SendNUIMessage({ action = "open", deviceId = id })
end)

RegisterNetEvent("qb_parkuhr:evtEmptyDevice", function(param)
    local id = GetDeviceIdFromEntity(param)
    if not id then TriggerEvent("QBCore:Notify", "Gerät unbekannt.", "error"); return end
    TriggerServerEvent("qb_parkuhr:emptyDevice", id)
end)

RegisterNetEvent("qb_parkuhr:evtRemoveDevice", function(param)
    local id = GetDeviceIdFromEntity(param)
    if not id then TriggerEvent("QBCore:Notify", "Gerät unbekannt.", "error"); return end
    TriggerServerEvent("qb_parkuhr:removeMachine", id)
end)

RegisterNetEvent("qb_parkuhr:evtEditArea", function(param)
    local id = GetDeviceIdFromEntity(param)
    if not id then TriggerEvent("QBCore:Notify", "Gerät unbekannt.", "error"); return end
    TriggerEvent("QBCore:Notify", ("Editor: /place_parkinglot %d 1..4 für Ecken"):format(id), "primary")
    TriggerServerEvent("qb_parkuhr:requestAreasForDevice", id)
end)

RegisterNetEvent("qb_parkuhr:evtLootMachine", function(param)
    local id = GetDeviceIdFromEntity(param)
    if not id then TriggerEvent("QBCore:Notify", "Gerät unbekannt.", "error"); return end
    TriggerServerEvent("qb_parkuhr:tryLoot", { dtype = 'machine', dkey = tostring(id) })
end)

-- ======================================================
-- Placement (mit Spieler-Lock) & Deep Ground Snap
-- ======================================================

local placeStep   = 0.10
local rotateStep  = 2.0
local raiseStep   = 0.05

local playerLocked = false
local function lockPlayer()
    if playerLocked then return end
    playerLocked = true
    local ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, true)
end
local function unlockPlayer()
    if not playerLocked then return end
    playerLocked = false
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
end

-- Heading-basierte Bewegungsvektoren (build-unabhängig)
local function ForwardVector(entity)
    local h = math.rad(GetEntityHeading(entity) or 0.0)
    return vector3(-math.sin(h), math.cos(h), 0.0)
end
local function RightVector(entity)
    local h = math.rad(GetEntityHeading(entity) or 0.0)
    return vector3(math.cos(h), math.sin(h), 0.0)
end

-- Boden robust finden
local function DeepGroundZAt(x, y, zHint)
    local z = zHint or 50.0
    -- 1) Sweep
    for dz = 60, -60, -5 do
        local ok, gz = GetGroundZFor_3dCoord(x, y, (z + dz), false)
        if ok then return gz end
    end
    -- 2) Ray
    local handle = StartExpensiveSynchronousShapeTestLosProbe(x, y, z + 50.0, x, y, z - 50.0, 1, 0, 7)
    local _, hit, hitCoords = GetShapeTestResult(handle)
    if hit == 1 then return hitCoords.z end
    -- 3) Fallback
    return (zHint or z) - 1.0
end

local function spawnGhostAt(pos, heading)
    if ghost and DoesEntityExist(ghost) then DeleteEntity(ghost) end
    local model = `prop_park_ticket_01`
    RequestModel(model); while not HasModelLoaded(model) do Wait(0) end
    ghost = CreateObjectNoOffset(model, pos.x, pos.y, pos.z, false, false, false)
    SetEntityAlpha(ghost, 160, false)
    SetEntityCollision(ghost, false, false)
    SetEntityInvincible(ghost, true)
    SetEntityHeading(ghost, heading or 0.0)
    FreezeEntityPosition(ghost, true)
end

local function endPlacement()
    placing = false
    if ghost and DoesEntityExist(ghost) then DeleteEntity(ghost) end
    ghost = nil
    unlockPlayer()
end

RegisterCommand("place_automat", function()
    local ped = PlayerPedId()
    local fwd = GetOffsetFromEntityInWorldCoords(ped, 0.0, 1.5, 0.0)
    local px, py, pz = fwd.x, fwd.y, fwd.z
    local found, gz = GetGroundZFor_3dCoord(px, py, pz + 10.0, false)
    placePos = vector3(px, py, (found and gz or pz) + 0.02)
    ghostHeading = GetEntityHeading(ped)
    spawnGhostAt(placePos, ghostHeading)
    placing = true
    lockPlayer()
    TriggerEvent("QBCore:Notify", "Placement: [W/A/S/D] bewegen, [Q/E] drehen, [PgUp/PgDn] Höhe, [Enter] speichern, [Backspace] abbrechen. (Shift = schneller)", "primary")
end, false)

CreateThread(function()
    while true do
        if placing and ghost and DoesEntityExist(ghost) then
            -- Eingaben blocken
            DisableControlAction(0, 30,  true)  -- Move LR
            DisableControlAction(0, 31,  true)  -- Move UD
            DisableControlAction(0, 21,  true)  -- Sprint
            DisableControlAction(0, 22,  true)  -- Jump
            DisableControlAction(0, 23,  true)  -- Enter vehicle
            DisableControlAction(0, 24,  true)  -- Attack
            DisableControlAction(0, 25,  true)  -- Aim
            DisableControlAction(0, 44,  true)  -- Cover
            DisableControlAction(0, 75,  true)  -- Exit vehicle
            DisableControlAction(0, 37,  true)  -- Weapon wheel
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 257, true)
            DisableControlAction(0, 263, true)
            DisableControlAction(0, 264, true)
            DisablePlayerFiring(PlayerId(), true)

            local moved = false
            local stepMul = IsControlPressed(0, 21) and 5.0 or 1.0 -- Shift = schneller

            -- Vor/Zurück
            if IsControlPressed(0, 32) then
                placePos = placePos + (ForwardVector(ghost) * (placeStep * stepMul)); moved = true
            end
            if IsControlPressed(0, 33) then
                placePos = placePos - (ForwardVector(ghost) * (placeStep * stepMul)); moved = true
            end
            -- Seitlich
            if IsControlPressed(0, 34) then
                placePos = placePos - (RightVector(ghost) * (placeStep * stepMul)); moved = true
            end
            if IsControlPressed(0, 35) then
                placePos = placePos + (RightVector(ghost) * (placeStep * stepMul)); moved = true
            end
            -- Höhe
            if IsControlPressed(0, 10) then placePos = placePos + vector3(0,0, raiseStep*stepMul); moved = true end
            if IsControlPressed(0, 11) then placePos = placePos - vector3(0,0, raiseStep*stepMul); moved = true end
            -- Drehen
            if IsControlPressed(0, 44) then ghostHeading = (ghostHeading - rotateStep*stepMul) % 360; moved = true end
            if IsControlPressed(0, 46) then ghostHeading = (ghostHeading + rotateStep*stepMul) % 360; moved = true end

            -- Bestätigen / Abbrechen
            if IsControlJustPressed(0, 191) then -- Enter
                local gz = DeepGroundZAt(placePos.x, placePos.y, placePos.z)
                placePos = vector3(placePos.x, placePos.y, (gz or placePos.z) + 0.02)
                TriggerServerEvent("qb_parkuhr:placeMachine", { x = placePos.x, y = placePos.y, z = placePos.z, h = ghostHeading })
                endPlacement()
            elseif IsControlJustPressed(0, 177) then -- Backspace
                endPlacement()
                TriggerEvent("QBCore:Notify", "Placement abgebrochen.", "error")
            end

            if moved then
                SetEntityCoordsNoOffset(ghost, placePos.x, placePos.y, placePos.z, false,false,false)
                SetEntityHeading(ghost, ghostHeading)
            end

            Draw2D(0.66, 0.90, "W/A/S/D bewegen | Q/E drehen | PgUp/PgDn Höhe | Enter speichern | Backspace abbrechen | Shift = schneller")
        end
        Wait(0)
    end
end)

-- ======================================================
-- Zonen markieren (4 Ecken)
-- ======================================================
RegisterCommand("place_parkinglot", function(_, args)
    local devId  = tonumber(args[1] or "")
    local corner = tonumber(args[2] or "")
    if not devId or not corner or corner < 1 or corner > 4 then
        TriggerEvent("QBCore:Notify","Nutzung: /place_parkinglot <AutomatID> <1|2|3|4>", "error"); return
    end
    local p = GetEntityCoords(PlayerPedId())
    TriggerServerEvent("qb_parkuhr:saveAreaCorner", devId, corner, { x = p.x, y = p.y })
end, false)
