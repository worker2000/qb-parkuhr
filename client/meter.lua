-- E-Prompt + NUI an kleinen Parkuhren
CreateThread(function()
    while true do
        local wait = 500
        local ped = PlayerPedId()
        if not IsPedInAnyVehicle(ped, false) then
            local p = GetEntityCoords(ped)
            local meter = 0
            for _, model in ipairs(SMALL_METER_MODELS) do
                meter = GetClosestObjectOfType(p, 1.5, model, false, false, false)
                if meter ~= 0 and DoesEntityExist(meter) then break end
            end
            if meter ~= 0 and DoesEntityExist(meter) then
                wait = 0
                local pos = GetEntityCoords(meter)
                DrawText3D(pos + vector3(0,0,1.0), "[E] Parkschein lösen")
                if IsControlJustReleased(0, INTERACT_KEY) then
                    SetNuiFocus(true, true)
                    SendNUIMessage({ action = "open" })
                    Wait(200)
                end
            end
        end
        Wait(wait)
    end
end)

-- Loot (ohne AddTargetModel – per Entity)
CreateThread(function()
    while true do
        local wait = 1500
        local ped = PlayerPedId()
        local p   = GetEntityCoords(ped)
        for _, model in ipairs(SMALL_METER_MODELS) do
            local obj = GetClosestObjectOfType(p, 1.5, model, false, false, false)
            if obj ~= 0 and DoesEntityExist(obj) then
                wait = 0
                exports['qb-target']:AddTargetEntity(obj, {
                    options = {
                        { type="client", event="qb_parkuhr:evtLootSmallMeter", icon="fas fa-search", label="Parkuhr durchsuchen" }
                    },
                    distance = 1.5
                })
            end
        end
        Wait(wait)
    end
end)

RegisterNetEvent("qb_parkuhr:evtLootSmallMeter", function(param)
    local ent = param
    if type(param) == "table" then
        ent = param.entity or param[1] or (param.data and param.data.entity) or 0
    end
    if not ent or ent == 0 or not DoesEntityExist(ent) then return end
    local c = GetEntityCoords(ent)
    local key = string.format("%.1f:%.1f", c.x, c.y)
    TriggerServerEvent("qb_parkuhr:tryLoot", { dtype = 'meter_small', dkey = key })
end)

-- Polizei-Targets (global vehicle) + Check/Verwarnung
CreateThread(function()
    if exports['qb-target'] and exports['qb-target'].AddGlobalVehicle then
        exports['qb-target']:AddGlobalVehicle({
            options = {
                { type="client", event="qb_parkuhr:checkNearestVehicle", icon="fas fa-ticket-alt", label="Parkschein prüfen" },
                { type="client", event="qb_parkuhr:warnVehicle",        icon="fas fa-exclamation-triangle", label="Verwarnung ausstellen" }
            },
            distance = 2.0
        })
    end
end)

RegisterNetEvent("qb_parkuhr:checkNearestVehicle", function()
    local ped = PlayerPedId()
    local veh = GetClosestVehicle(GetEntityCoords(ped), 5.0, 0, 70)
    if veh ~= 0 and DoesEntityExist(veh) then
        local plate = GetPlate(veh)
        local vpos  = GetEntityCoords(veh)
        TriggerEvent("QBCore:Notify", "Prüfe Parkschein…", "primary")
        TriggerServerEvent("qb_parkuhr:requestTicketCheck", plate, { x=vpos.x, y=vpos.y, z=vpos.z })
    else
        TriggerEvent("QBCore:Notify", "Kein Fahrzeug in der Nähe.", "error")
    end
end)

RegisterNetEvent("qb_parkuhr:warnVehicle", function()
    local ped = PlayerPedId()
    local veh = GetClosestVehicle(GetEntityCoords(ped), 5.0, 0, 70)
    if veh ~= 0 and DoesEntityExist(veh) then
        local plate = GetPlate(veh)
        SetNuiFocus(true, true)
        SendNUIMessage({ action = "openWarn", plate = plate })
    else
        TriggerEvent("QBCore:Notify", "Kein Fahrzeug in der Nähe.", "error")
    end
end)

RegisterNetEvent("qb_parkuhr:getVehicleCoords", function(plate, reason, officerName, warned_at)
    local ped = PlayerPedId()
    local veh = GetClosestVehicle(GetEntityCoords(ped), 5.0, 0, 70)
    if veh ~= 0 and DoesEntityExist(veh) then
        local coords = GetEntityCoords(veh)
        TriggerServerEvent("qb_parkuhr:storeWarningWithCoords", plate, reason, officerName, warned_at, coords)
    else
        TriggerEvent("QBCore:Notify", "Fahrzeugposition konnte nicht ermittelt werden!", "error")
    end
end)
