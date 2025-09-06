local QBCore = exports['qb-core']:GetCoreObject()
local INTERACT = (INTERACT_KEY or (Config and Config.InteractKey) or 38) -- E

-- Minimaler 3D-Text (unabhängig von Common)
local function draw3d(pos, text)
    local onScreen,_x,_y = World3dToScreen2d(pos.x, pos.y, pos.z)
    local cx,cy,cz = table.unpack(GetGameplayCamCoords())
    local dist = #(pos - vector3(cx,cy,cz))
    local scale = (1.0 / math.max(dist, 0.01)) * 2.0
    if onScreen then
        SetTextScale(0.35*scale, 0.35*scale)
        SetTextFont(4)
        SetTextProportional(1)
        SetTextColour(255,255,255,215)
        SetTextDropshadow(0,0,0,0,255)
        SetTextOutline()
        SetTextCentre(1)
        BeginTextCommandDisplayText("STRING")
        AddTextComponentSubstringPlayerName(text)
        EndTextCommandDisplayText(_x, _y)
    end
end

local function drawMarker(at)
    DrawMarker(1, at.x, at.y, at.z - 1.0, 0.0,0.0,0.0, 0.0,0.0,0.0,
        0.6,0.6,0.6, 0,150,255,120, false,false,2,false,nil,nil,false)
end

local function openPanel()
    SetNuiFocus(true, true)
    SendNUIMessage({ action = "openPanel" })   -- NUI zieht die Daten selbst (panelRequest)
end

-- Loop für Interaktion an der Zentrale
CreateThread(function()
    while true do
        local sleep = 1000
        local pt = Config and Config.PanelPoint
        if pt then
            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)
            local dist = #(pos - pt)

            if dist <= math.max(2.5, (Config.PanelDistance or 2.5)) then
                sleep = 0
                drawMarker(pt)
                draw3d(pt + vector3(0,0,1.0), "[E] Zentrale öffnen")
                if IsControlJustReleased(0, INTERACT) then
                    openPanel()
                end
            elseif dist <= 25.0 then
                sleep = 0
                drawMarker(pt)
            end
        end
        Wait(sleep)
    end
end)

-- NUI fordert Daten an → vom Server laden & zurückschicken
RegisterNUICallback('panelRequest', function(_, cb)
    QBCore.Functions.TriggerCallback('qb-parkuhr:getPanelData', function(payload)
        SendNUIMessage({ action = "panelData", data = payload })
        if cb then cb(1) end
    end)
end)

-- NUI schließt Panel
RegisterNUICallback('panelClose', function(_, cb)
    SetNuiFocus(false, false)
    if cb then cb(true) end
end)

-- Nach Resource-(Re)Start komplette Geräteliste anfordern (damit Reloads sichtbar sind)
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerServerEvent('qb_parkuhr:requestFullSync')
end)
