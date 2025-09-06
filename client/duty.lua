local QBCore = exports['qb-core']:GetCoreObject()

CreateThread(function()
    while true do
        local sleep = 1000
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)

        for _, loc in ipairs(Config.DutyPoints) do
            if #(pos - loc) < (Config.DutyDistance or 2.0) then
                sleep = 0
                -- Text anzeigen
                SetTextComponentFormat('STRING')
                AddTextComponentString('~INPUT_CONTEXT~ Dienst an/aus melden')
                DisplayHelpTextFromStringLabel(0, false, true, -1)

                if IsControlJustReleased(0, 38) then -- Taste E
                    TriggerServerEvent('qb-parkuhr:toggleDuty')
                end
            end
        end

        Wait(sleep)
    end
end)
