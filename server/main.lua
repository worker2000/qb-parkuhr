local QBCore = exports['qb-core']:GetCoreObject()

-- =========================
-- CONFIG
-- =========================
local PRICE_PER_MIN    = 1          -- $ pro Minute
local VALID_RADIUS     = 6.0        -- für polizeiliche Standortprüfung
local REBUY_DISTANCE   = 10.0       -- kein Direkt-Nachkauf am selben Spot
local PLACEABLE_MODEL  = 'prop_park_ticket_01'

-- === Overrides aus config.lua (wenn vorhanden) ===
if type(Config) == 'table' then
    PRICE_PER_MIN    = Config.PricePerMin      or PRICE_PER_MIN
    VALID_RADIUS     = Config.ValidRadius      or VALID_RADIUS
    REBUY_DISTANCE   = Config.RebuyDistance    or REBUY_DISTANCE
    PLACEABLE_MODEL  = Config.PlaceableModel   or PLACEABLE_MODEL

    FLOAT_MIN_CENTS          = Config.FloatMinCents          or FLOAT_MIN_CENTS
    LOOT_COOLDOWN_MIN_SMALL  = Config.LootCooldownMinSmall   or LOOT_COOLDOWN_MIN_SMALL
    LOOT_COOLDOWN_MIN_MACHINE= Config.LootCooldownMinMachine or LOOT_COOLDOWN_MIN_MACHINE
    LOOT_CHANCE_SMALL        = Config.LootChanceSmall        or LOOT_CHANCE_SMALL
    LOOT_CHANCE_MACHINE      = Config.LootChanceMachine      or LOOT_CHANCE_MACHINE
    LOOT_MIN_SMALL           = Config.LootMinSmall           or LOOT_MIN_SMALL
    LOOT_MAX_SMALL           = Config.LootMaxSmall           or LOOT_MAX_SMALL
    LOOT_MIN_MACHINE         = Config.LootMinMachine         or LOOT_MIN_MACHINE
    LOOT_MAX_MACHINE         = Config.LootMaxMachine         or LOOT_MAX_MACHINE
end

-- vordefinierte erlaubte Dauern
local DURATIONS = {
    meter_small = {10, 30, 60},         -- kleine Parkuhr
    machine     = {60, 1440, 10080},    -- Automat
    meter_big   = {10, 30, 60},
}
-- Cash-Logik
local FLOAT_MIN_CENTS        = 6000   -- Mindestbestand, bleibt beim Leeren im Gerät
local LOOT_COOLDOWN_MIN_SMALL   = 15
local LOOT_COOLDOWN_MIN_MACHINE = 30
local LOOT_CHANCE_SMALL         = 0.25
local LOOT_CHANCE_MACHINE       = 0.15
local LOOT_MIN_SMALL,   LOOT_MAX_SMALL   = 2, 5
local LOOT_MIN_MACHINE, LOOT_MAX_MACHINE = 10, 50

-- =========================
-- HELPERS
-- =========================
local function distance2D(ax, ay, bx, by)
    local dx = (ax or 0.0) - (bx or 0.0)
    local dy = (ay or 0.0) - (by or 0.0)
    return math.sqrt(dx*dx + dy*dy)
end
local function cents(n) return math.floor((n or 0) * 100) end
local function isParkingJob(player)
    return player and player.PlayerData and player.PlayerData.job and player.PlayerData.job.name == (Config and Config.JobName or 'parking')
end

-- point-in-polygon (2D)
local function pointInPolygon(x, y, poly)
    if not poly or #poly < 3 then return false end
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        local intersect = ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / ((yj - yi) ~= 0 and (yj - yi) or 1e-9) + xi)
        if intersect then inside = not inside end
        j = i
    end
    return inside
end

-- =========================
-- SYNC: Geräte & Zonen
-- =========================
RegisterNetEvent("qb_parkuhr:requestDeviceList", function()
    local src = source
    local list = MySQL.query.await("SELECT id, type, model, x, y, z, heading, cash_cents FROM parking_devices")
    TriggerClientEvent("qb_parkuhr:syncDevices", src, list or {})
end)

RegisterNetEvent("qb_parkuhr:requestAreasForDevice", function(deviceId)
    local src = source
    local areas = MySQL.query.await("SELECT id, device_id, points_json FROM parking_areas WHERE device_id = ?", { tonumber(deviceId) })
    TriggerClientEvent("qb_parkuhr:areasForDevice", src, deviceId, areas or {})
end)

local function broadcastDeviceAdded(dev)  TriggerClientEvent("qb_parkuhr:deviceAdded", -1, dev) end
local function broadcastDeviceRemoved(id) TriggerClientEvent("qb_parkuhr:deviceRemoved", -1, id) end

-- Kompakte Helfer zum Pushen der Geräte
local function fetchAllDevices()
    return MySQL.query.await([[
        SELECT id, type, model, x, y, z, heading, cash_cents
        FROM parking_devices
        ORDER BY id ASC
    ]], {}) or {}
end

local function pushDevices(target)
    local list = fetchAllDevices()
    if target == -1 then
        TriggerClientEvent("qb_parkuhr:syncDevices", -1, list)
    else
        TriggerClientEvent("qb_parkuhr:syncDevices", target, list)
    end
end

-- Beim Start der Resource: allen aktuellen Spielern die Geräte schicken
AddEventHandler("onResourceStart", function(res)
    if res ~= GetCurrentResourceName() then return end
    -- kleinen Delay, damit MySQL & Playerlist ready sind
    CreateThread(function()
        Wait(500)
        pushDevices(-1)
    end)
end)

-- Wenn ein Spieler vollständig geladen ist: nur ihm die Geräte schicken
AddEventHandler('QBCore:Server:OnPlayerLoaded', function(src)
    if not src then return end
    pushDevices(src)
end)

-- Client kann aktiv FullSync anfordern (z. B. beim Client-Start)
RegisterNetEvent("qb_parkuhr:requestFullSync", function()
    local src = source
    pushDevices(src)
end)


-- =========================
-- JOB: Platzieren / Entfernen / Leeren
-- =========================
RegisterNetEvent("qb_parkuhr:placeMachine", function(pos)
    local src = source
    local p = QBCore.Functions.GetPlayer(src)
    if not isParkingJob(p) then TriggerClientEvent("QBCore:Notify", src, "Nicht erlaubt.", "error"); return end
    if not pos or not pos.x then TriggerClientEvent("QBCore:Notify", src, "Position fehlt.", "error"); return end

    local id = MySQL.insert.await([[
        INSERT INTO parking_devices (type, model, x, y, z, heading, cash_cents, placed_by)
        VALUES ('machine', ?, ?, ?, ?, ?, ?, ?)
    ]], { PLACEABLE_MODEL, pos.x, pos.y, pos.z, pos.h or 0.0, FLOAT_MIN_CENTS, p.PlayerData.citizenid })

    if not id then TriggerClientEvent("QBCore:Notify", src, "Fehler beim Platzieren.", "error"); return end

    local dev = MySQL.single.await("SELECT id, type, model, x,y,z,heading, cash_cents FROM parking_devices WHERE id = ?", { id })
    broadcastDeviceAdded(dev)
    TriggerClientEvent("qb_parkuhr:placedMachineId", src, id, dev)
end)

RegisterNetEvent("qb_parkuhr:removeMachine", function(deviceId)
    local src = source
    local p = QBCore.Functions.GetPlayer(src)
    if not isParkingJob(p) then TriggerClientEvent("QBCore:Notify", src, "Nicht erlaubt.", "error"); return end
    deviceId = tonumber(deviceId)
    if not deviceId then TriggerClientEvent("QBCore:Notify", src, "Geräte-ID fehlt.", "error"); return end

    local del = MySQL.update.await("DELETE FROM parking_devices WHERE id = ? AND type='machine'", { deviceId })
    if del and del > 0 then
        broadcastDeviceRemoved(deviceId)
        TriggerClientEvent("QBCore:Notify", src, "Automat entfernt.", "success")
    else
        TriggerClientEvent("QBCore:Notify", src, "Automat nicht gefunden.", "error")
    end
end)

RegisterNetEvent("qb_parkuhr:emptyDevice", function(deviceId)
    local src = source
    local p = QBCore.Functions.GetPlayer(src)
    if not isParkingJob(p) then TriggerClientEvent("QBCore:Notify", src, "Nicht erlaubt.", "error"); return end
    deviceId = tonumber(deviceId)
    if not deviceId then TriggerClientEvent("QBCore:Notify", src, "Geräte-ID fehlt.", "error"); return end

    local dev = MySQL.single.await("SELECT id, cash_cents FROM parking_devices WHERE id = ?", { deviceId })
    if not dev then TriggerClientEvent("QBCore:Notify", src, "Gerät nicht gefunden.", "error"); return end

    local current = dev.cash_cents or 0
    local removable = math.max(current - FLOAT_MIN_CENTS, 0)        -- immer 6000¢ drin lassen
    if removable <= 0 then
        TriggerClientEvent("QBCore:Notify", src, "Kein entnehmbarer Betrag (Mindestbestand bleibt im Gerät).", "error")
        return
    end

    MySQL.transaction.await({
        { query = "UPDATE parking_devices SET cash_cents = cash_cents - ? WHERE id = ?", values = { removable, deviceId } },
        { query = "INSERT INTO parking_cash_log (device_id, change_cents, reason, actor) VALUES (?,?, 'empty', ?)", values = { deviceId, -removable, p.PlayerData.citizenid } }
    })
    local dollars = math.floor(removable / 100)
    if dollars > 0 then p.Functions.AddMoney("cash", dollars, "parking-empty") end
    TriggerClientEvent("QBCore:Notify", src, ("Entnommen: $%d (Mindestbestand verbleibt)"):format(dollars), "success")
end)

-- =========================
-- PARKZONEN (4 Ecken)
-- =========================
RegisterNetEvent("qb_parkuhr:saveAreaCorner", function(deviceId, cornerIndex, pos)
    local src = source
    local p = QBCore.Functions.GetPlayer(src)
    if not isParkingJob(p) then TriggerClientEvent("QBCore:Notify", src, "Nicht erlaubt.", "error"); return end
    deviceId = tonumber(deviceId)
    if not deviceId or not cornerIndex or not pos then
        TriggerClientEvent("QBCore:Notify", src, "Ungültige Parameter.", "error"); return
    end

    local row = MySQL.single.await("SELECT id, points_json FROM parking_areas WHERE device_id = ? ORDER BY id DESC LIMIT 1", { deviceId })
    local points = { }
    if row and row.points_json then
        local ok, dec = pcall(json.decode, row.points_json)
        if ok and dec then points = dec end
    end

    points[cornerIndex] = { x = pos.x, y = pos.y }
    local jsonStr = json.encode(points)

    if row then
        MySQL.update.await("UPDATE parking_areas SET points_json = ? WHERE id = ?", { jsonStr, row.id })
    else
        MySQL.insert.await("INSERT INTO parking_areas (device_id, points_json) VALUES (?,?)", { deviceId, jsonStr })
    end
    TriggerClientEvent("QBCore:Notify", src, ("Ecke %d gespeichert."):format(cornerIndex), "success")
    TriggerClientEvent("qb_parkuhr:areasForDevice", src, deviceId, { { id = row and row.id or 0, device_id = deviceId, points_json = jsonStr } })
end)

-- =========================
-- KASSE (Zuschreibungen)
-- =========================
local function addCashToDevice(deviceId, amountDollars, actor)
    local add = cents(amountDollars); if add <= 0 then return end
    MySQL.transaction.await({
        { query = "UPDATE parking_devices SET cash_cents = cash_cents + ? WHERE id = ?", values = { add, deviceId } },
        { query = "INSERT INTO parking_cash_log (device_id, change_cents, reason, actor) VALUES (?,?, 'ticket', ?)", values = { deviceId, add, actor } }
    })
end

local function ensureMeterDevice(typeStr, model, pos)
    local near = MySQL.single.await([[
        SELECT id FROM parking_devices
        WHERE type = ? AND model = ? AND ABS(x - ?) < 2.0 AND ABS(y - ?) < 2.0
        ORDER BY ABS(x-?)+ABS(y-?) ASC LIMIT 1
    ]], { typeStr, model, pos.x, pos.y, pos.x, pos.y })
    if near and near.id then return near.id end
    local ins = MySQL.insert.await([[
        INSERT INTO parking_devices (type, model, x,y,z,heading,cash_cents, placed_by)
        VALUES (?,?,?,?,?,?,?,NULL)
    ]], { typeStr, model, pos.x, pos.y, pos.z, 0.0, FLOAT_MIN_CENTS })
    return ins
end

-- =========================
-- Ticket kaufen
-- =========================
RegisterNetEvent("qb_parkuhr:registerTicket", function(duration, plate, meterCoords, vehCoords, opt)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    duration = tonumber(duration) or 0
    if duration <= 0 then TriggerClientEvent("QBCore:Notify", src, "Ungültige Dauer.", "error"); return end
    if not (meterCoords and vehCoords) then TriggerClientEvent("QBCore:Notify", src, "Koordinaten fehlen.", "error"); return end

    -- (Optional) Wenn Kauf am Automaten: Fläche wird client- & serverseitig geprüft
    if opt and opt.deviceId then
        local areas = MySQL.query.await("SELECT points_json FROM parking_areas WHERE device_id = ?", { tonumber(opt.deviceId) })
        if areas and #areas > 0 then
            local allowed = false
            for _, a in ipairs(areas) do
                local ok, poly = pcall(json.decode, a.points_json or "[]")
                if ok and poly and #poly >= 3 then
                    if pointInPolygon(vehCoords.x, vehCoords.y, poly) then allowed = true; break end
                end
            end
            if not allowed then
                TriggerClientEvent("QBCore:Notify", src, "Dieses Fahrzeug steht nicht im zugehörigen Parkbereich.", "error")
                return
            end
        end
    end

-- Preis aus Tarifen (pro Gerät oder Standard) ermitteln
local function lookupPriceCents(durationMin, typeStr, deviceId)
    durationMin = tonumber(durationMin) or 0
    -- 1) Gerätespezifisch?
    if deviceId then
        local row = MySQL.single.await(
            "SELECT price_cents FROM parking_tariffs WHERE device_id = ? AND duration_min = ? LIMIT 1",
            { tonumber(deviceId), durationMin }
        )
        if row and row.price_cents then return row.price_cents end
    end
    -- 2) Standard für Typ?
    if typeStr then
        local row = MySQL.single.await(
            "SELECT price_cents FROM parking_tariffs WHERE device_id IS NULL AND `type` = ? AND duration_min = ? LIMIT 1",
            { tostring(typeStr), durationMin }
        )
        if row and row.price_cents then return row.price_cents end
    end
    -- 3) Fallback: Minutenpreis * Dauer
    return cents((PRICE_PER_MIN or 1) * durationMin)
end
    if price > 0 then
        if not player.Functions.RemoveMoney("cash", price, "parking-ticket") then
            TriggerClientEvent("QBCore:Notify", src, "Nicht genug Bargeld.", "error"); return
        end
    end

    -- Existierendes Ticket am gleichen Standort verhindern / beenden
    local old = MySQL.single.await([[
        SELECT id, meter_x, meter_y, expires_at
        FROM park_tickets
        WHERE plate = ? AND NOW() < COALESCE(expires_at, expires_at)
        ORDER BY COALESCE(expires_at, expires_at) DESC
        LIMIT 1
    ]], { plate })

    if old then
        local dist = distance2D(vehCoords.x, vehCoords.y, old.meter_x, old.meter_y)
        if dist <= REBUY_DISTANCE then
            TriggerClientEvent("QBCore:Notify", src, "Es besteht bereits ein gültiger Parkschein an diesem Standort.", "error")
            return
        else
            -- altes Ticket sofort beenden
            MySQL.update.await("UPDATE park_tickets SET expires_at = NOW() WHERE id = ?", { old.id })
        end
    end

    -- Neues Ticket (Minuten → korrekt als INTERVAL MINUTE)
    local ok = MySQL.insert.await([[
        INSERT INTO park_tickets
            (plate, parked_at, duration_minutes, expires_at, meter_x, meter_y, meter_z, vehicle_x, vehicle_y, vehicle_z)
        VALUES
            (?, NOW(), ?, DATE_ADD(NOW(), INTERVAL ? MINUTE), ?, ?, ?, ?, ?, ?)
    ]], {
        plate, duration, duration,
        meterCoords.x, meterCoords.y, meterCoords.z,
        vehCoords.x, vehCoords.y, vehCoords.z
    })
    if not ok then TriggerClientEvent("QBCore:Notify", src, "Fehler beim Speichern des Parkscheins.", "error"); return end

    -- Kasse befüllen
    if opt and opt.deviceId then
        addCashToDevice(opt.deviceId, price, player.PlayerData.citizenid)
    else
        local deviceId = ensureMeterDevice('meter_small', 'prop_parknmeter_auto', { x = meterCoords.x, y = meterCoords.y, z = meterCoords.z })
        if deviceId then addCashToDevice(deviceId, price, player.PlayerData.citizenid) end
    end

    TriggerClientEvent("QBCore:Notify", src, ("Parkschein gekauft: %d Min. ($%d)"):format(duration, price), "success")
end)

-- =========================
-- Polizei: Ticket prüfen
-- =========================
RegisterNetEvent("qb_parkuhr:requestTicketCheck", function(plate, currentPos)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player or (player.PlayerData.job and player.PlayerData.job.name ~= "police") then
        TriggerClientEvent("QBCore:Notify", src, "Nicht erlaubt.", "error"); return
    end
    if not (currentPos and currentPos.x and currentPos.y) then
        TriggerClientEvent("QBCore:Notify", src, "Position fehlt (Client).", "error"); return
    end

    local ticket = MySQL.single.await([[
        SELECT
            pt.id                         AS ticket_id,
            pt.plate                      AS plate,
            COALESCE(pt.expires_at, pt.expires_at) AS expires_at,
            pt.meter_x                    AS meter_x,
            pt.meter_y                    AS meter_y,
            pt.meter_z                    AS meter_z,
            UNIX_TIMESTAMP(COALESCE(pt.expires_at, pt.expires_at)) AS exp_epoch,
            TIMESTAMPDIFF(SECOND, NOW(), COALESCE(pt.expires_at, pt.expires_at)) AS remaining_sec,
            pv.citizenid                  AS owner_citizenid
        FROM park_tickets AS pt
        LEFT JOIN player_vehicles AS pv ON pv.plate = pt.plate
        WHERE pt.plate = ?
        ORDER BY COALESCE(pt.expires_at, pt.expires_at) DESC
        LIMIT 1
    ]], { plate })

    if not ticket then
        TriggerClientEvent("QBCore:Notify", src, "Kein Parkschein gefunden.", "error"); return
    end
    if not ticket.remaining_sec or ticket.remaining_sec <= 0 then
        TriggerClientEvent("QBCore:Notify", src, "Parkschein ist abgelaufen!", "error"); return
    end

    local dist = distance2D(currentPos.x, currentPos.y, ticket.meter_x, ticket.meter_y)
    if dist > VALID_RADIUS then
        TriggerClientEvent("QBCore:Notify", src, ("Kein gültiger Parkschein an diesem Standort (%.0fm entfernt)."):format(dist), "error")
        return
    end

    local owner = "Unbekannt"
    if ticket.owner_citizenid then
        local info = MySQL.single.await("SELECT charinfo FROM players WHERE citizenid = ? LIMIT 1", { ticket.owner_citizenid })
        if info and info.charinfo then
            local okDec, data = pcall(json.decode, info.charinfo)
            if okDec and data then
                owner = (data.firstname or "") .. " " .. (data.lastname or "")
                owner = owner:gsub("^%s*(.-)%s*$", "%1")
                if owner == "" then owner = "Unbekannt" end
            end
        end
    end

    TriggerClientEvent("qb_parkuhr:showTicketInfo", src, {
        plate        = plate,
        owner        = owner,
        expires      = ticket.expires_at,
        expiresEpoch = ticket.exp_epoch
    })
end)

-- =========================
-- Loot & Verwarnungen
-- =========================
RegisterNetEvent("qb_parkuhr:tryLoot", function(payload)
    local src = source
    local p = QBCore.Functions.GetPlayer(src); if not p then return end
    local dtype = payload and payload.dtype
    local dkey  = payload and payload.dkey
    if not dtype or not dkey then TriggerClientEvent("QBCore:Notify", src, "Fehlerhafte Aktion.", "error"); return end

    local minutes = (dtype == 'machine') and LOOT_COOLDOWN_MIN_MACHINE or LOOT_COOLDOWN_MIN_SMALL
    local recent = MySQL.single.await([[
        SELECT id FROM parking_loot_log
        WHERE device_type = ? AND device_key = ? AND identifier = ? AND ts > (NOW() - INTERVAL ? MINUTE)
        ORDER BY id DESC LIMIT 1
    ]], { dtype, dkey, p.PlayerData.citizenid, minutes })
    if recent then TriggerClientEvent("QBCore:Notify", src, "Hier findest du gerade nichts.", "error"); return end

    local chance = (dtype == 'machine') and LOOT_CHANCE_MACHINE or LOOT_CHANCE_SMALL
    if math.random() > chance then
        MySQL.insert.await("INSERT INTO parking_loot_log (device_type, device_key, identifier) VALUES (?,?,?)",
            { dtype, dkey, p.PlayerData.citizenid })
        TriggerClientEvent("QBCore:Notify", src, "Leer…", "primary"); return
    end

    if dtype == 'machine' then
        local dev = MySQL.single.await("SELECT cash_cents FROM parking_devices WHERE id = ? AND type='machine' LIMIT 1", { tonumber(dkey) })
        if not dev or not dev.cash_cents then
            TriggerClientEvent("QBCore:Notify", src, "Leer…", "primary")
            return
        end
        local amount = math.random(LOOT_MIN_MACHINE, LOOT_MAX_MACHINE)
        local need   = cents(amount)
        local freeCents = math.max((dev.cash_cents or 0) - FLOAT_MIN_CENTS, 0)  -- nur Überschuss
        if freeCents < need then
            -- evtl. kleineren Betrag geben, wenn noch etwas Überschuss vorhanden ist
            if freeCents >= 100 then
                local give = math.floor(freeCents / 100)
                MySQL.transaction.await({
                    { query = "UPDATE parking_devices SET cash_cents = cash_cents - ? WHERE id = ?", values = { give*100, tonumber(dkey) } },
                    { query = "INSERT INTO parking_cash_log (device_id, change_cents, reason, actor) VALUES (?,?, 'loot', ?)", values = { tonumber(dkey), -(give*100), p.PlayerData.citizenid } },
                    { query = "INSERT INTO parking_loot_log (device_type, device_key, identifier) VALUES (?,?,?)", values = { 'machine', tostring(dkey), p.PlayerData.citizenid } }
                })
                p.Functions.AddMoney("cash", give, "parking-loot")
                TriggerClientEvent("QBCore:Notify", src, ("Du findest $%d im Automat!"):format(give), "success")
            else
                MySQL.insert.await("INSERT INTO parking_loot_log (device_type, device_key, identifier) VALUES (?,?,?)",
                    { 'machine', tostring(dkey), p.PlayerData.citizenid })
                TriggerClientEvent("QBCore:Notify", src, "Leer…", "primary")
            end
            return
        end
        -- genug Überschuss: normaler Loot
        MySQL.transaction.await({
            { query = "UPDATE parking_devices SET cash_cents = cash_cents - ? WHERE id = ?", values = { need, tonumber(dkey) } },
            { query = "INSERT INTO parking_cash_log (device_id, change_cents, reason, actor) VALUES (?,?, 'loot', ?)", values = { tonumber(dkey), -need, p.PlayerData.citizenid } },
            { query = "INSERT INTO parking_loot_log (device_type, device_key, identifier) VALUES (?,?,?)", values = { 'machine', tostring(dkey), p.PlayerData.citizenid } }
        })
        p.Functions.AddMoney("cash", amount, "parking-loot")
        TriggerClientEvent("QBCore:Notify", src, ("Du findest $%d im Automat!"):format(amount), "success")
        return
    end

    -- kleine Parkuhr: rein fiktiv, keine Kasse
    local amount = math.random(LOOT_MIN_SMALL, LOOT_MAX_SMALL)
    MySQL.insert.await("INSERT INTO parking_loot_log (device_type, device_key, identifier) VALUES (?,?,?)",
        { 'meter_small', dkey, p.PlayerData.citizenid })
    p.Functions.AddMoney("cash", amount, "parking-loot")
    TriggerClientEvent("QBCore:Notify", src, ("Du findest $%d in der Parkuhr!"):format(amount), "success")
end)

RegisterNetEvent("qb_parkuhr:issueWarning", function(plate, reason)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player or (player.PlayerData.job and player.PlayerData.job.name ~= "police") then
        TriggerClientEvent("QBCore:Notify", src, "Nicht erlaubt.", "error"); return
    end
    if not plate or plate == "" then
        TriggerClientEvent("QBCore:Notify", src, "Kein Nummernschild.", "error"); return
    end

    local ci = player.PlayerData.charinfo or {}
    local officerName = ((ci.firstname or "") .. " " .. (ci.lastname or "")):gsub("^%s*(.-)%s*$", "%1")
    if officerName == "" then officerName = "Unbekannt" end

    local warned_at = os.date("%Y-%m-%d %H:%M:%S")
    TriggerClientEvent("qb_parkuhr:getVehicleCoords", src, plate, reason or "Kein Grund angegeben", officerName, warned_at)
end)

RegisterNetEvent("qb_parkuhr:storeWarningWithCoords", function(plate, reason, officerName, warned_at, vehCoords)
    local src = source
    local ok = MySQL.insert.await([[
        INSERT INTO parking_warnings (plate, officer, reason, timestamp, vehicle_x, vehicle_y, vehicle_z)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], {
        plate, (officerName or "Unbekannt"), (reason or "Kein Grund angegeben"), warned_at,
        vehCoords.x, vehCoords.y, vehCoords.z
    })
    if ok then TriggerClientEvent("QBCore:Notify", src, "Verwarnung gespeichert.", "primary")
    else TriggerClientEvent("QBCore:Notify", src, "Fehler beim Speichern der Verwarnung!", "error") end
end)
RegisterNetEvent('qb-parkuhr:toggleDuty', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Player.PlayerData.job.name ~= (Config.JobName or 'parking') then
        TriggerClientEvent('QBCore:Notify', src, 'Kein Zugriff.', 'error')
        return
    end

    local onDuty = Player.PlayerData.job.onduty
    Player.Functions.SetJobDuty(not onDuty)
    TriggerClientEvent('QBCore:Notify', src,
        onDuty and 'Du bist nun im Feierabend.' or 'Du hast den Dienst angetreten.',
        'success')
end)
-- Hilfen fürs Panel
local function minutesToLabel(mins)
    if not mins then return "Ticket" end
    mins = tonumber(mins) or 0
    if mins == 10 or mins == 30 or mins == 60 then return (mins .. " Minuten") end
    if mins == 1440 then return "1 Tag" end
    if mins == 10080 then return "7 Tage" end
    if mins % 1440 == 0 then
        local d = math.floor(mins / 1440)
        return (d .. " Tage")
    end
    return (mins .. " Min")
end

QBCore.Functions.CreateCallback('qb-parkuhr:getPanelData', function(src, cb)
    -- 1) Geräte aus parking_devices (deine echten Spalten)
    local devices = MySQL.query.await([[
        SELECT
            id, `type`, model, x, y, z, heading,
            cash_cents, placed_by, created_at
        FROM parking_devices
        ORDER BY id ASC
    ]], {}) or {}

    -- 2) Letzte Verkäufe pro Standort (ohne Kennzeichen)
    --   Wir nutzen duration_minutes & expires_at aus park_tickets.
    local sales = MySQL.query.await([[
        SELECT
            id,
            meter_x, meter_y, meter_z,
            expires_at,
            parked_at,
            duration_minutes
        FROM park_tickets
        WHERE expires_at IS NOT NULL
        ORDER BY expires_at DESC
        LIMIT 500
    ]], {}) or {}

    -- 3) Gruppieren nach Meter-Koordinate (2 Nachkommastellen reichen)
    local function key(x,y,z) return string.format("%.2f:%.2f:%.2f", x or 0, y or 0, z or 0) end
    local grouped = {}
    for _, s in ipairs(sales) do
        local k = key(s.meter_x, s.meter_y, s.meter_z)
        local bucket = grouped[k] or { rows = {}, total = 0.0 }
        table.insert(bucket.rows, {
            ts    = s.expires_at,                       -- NUI formatiert Datum
            label = minutesToLabel(s.duration_minutes), -- „Ticket für X“
            price = nil                                  -- Preis summieren wir hier nicht; Einnahmen kommen aus cash_cents
        })
        grouped[k] = bucket
    end

    -- 4) Payload bauen; Einnahmen = cash_cents (Kassenbestand) in $
    local payload = {}
    for _, d in ipairs(devices) do
        local k = key(d.x, d.y, d.z)
        local g = grouped[k] or { rows = {}, total = 0.0 }
        local cash = tonumber(d.cash_cents or 0) / 100.0

        table.insert(payload, {
            id       = d.id,
            type     = d.type or 'device',
            model    = d.model,
            pos      = { x = d.x, y = d.y, z = d.z },
            since    = d.created_at,
            placed_by= d.placed_by,
            sales    = g.rows,            -- [{ts, label}]
            revenue  = cash,              -- €/$ aus cash_cents
        })
    end

    cb({
        devices  = payload,
        currency = Config.CurrencySymbol or "€"
    })
end)
-- === Re-Sync Helfer ===
local function fetchAllDevices()
    return MySQL.query.await([[
        SELECT id, type, model, x, y, z, heading, cash_cents
        FROM parking_devices
        ORDER BY id ASC
    ]], {}) or {}
end

local function pushDevices(target)
    local list = fetchAllDevices()
    if target == -1 then
        TriggerClientEvent("qb_parkuhr:syncDevices", -1, list)
    else
        TriggerClientEvent("qb_parkuhr:syncDevices", target, list)
    end
end

AddEventHandler("onResourceStart", function(res)
    if res ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(500)
        pushDevices(-1)
    end)
end)

AddEventHandler('QBCore:Server:OnPlayerLoaded', function(src)
    if not src then return end
    pushDevices(src)
end)

RegisterNetEvent("qb_parkuhr:requestFullSync", function()
    pushDevices(source)
end)

-- === Anzeigeformat für Ticketdauer ===
local function minutesToLabel(mins)
    if not mins then return "Ticket" end
    mins = tonumber(mins) or 0
    if mins == 10 or mins == 30 or mins == 60 then return (mins .. " Minuten") end
    if mins == 1440 then return "1 Tag" end
    if mins == 10080 then return "7 Tage" end
    if mins % 1440 == 0 then
        local d = math.floor(mins / 1440)
        return (d .. " Tage")
    end
    return (mins .. " Min")
end

QBCore.Functions.CreateCallback('qb-parkuhr:getPanelData', function(src, cb)
    -- 1) Geräte
    local devices = MySQL.query.await([[
        SELECT
            id, `type`, model, x, y, z, heading,
            cash_cents, placed_by, created_at
        FROM parking_devices
        ORDER BY id ASC
    ]], {}) or {}

    -- 2) Verkäufe aus parking_cash_log (reason='ticket')
    local logs = MySQL.query.await([[
        SELECT device_id, change_cents, reason, actor, created_at
        FROM parking_cash_log
        WHERE reason = 'ticket'
        ORDER BY created_at DESC
        LIMIT 1000
    ]], {}) or {}

    -- gruppiere pro Gerät
    local groupedByDevice = {} -- device_id -> { rows = {} }
    for _, row in ipairs(logs) do
        local did   = tonumber(row.device_id)
        local cents = tonumber(row.change_cents or 0)
        if did and cents and cents > 0 then
            local bucket = groupedByDevice[did]
            if not bucket then
                bucket = { rows = {} }
                groupedByDevice[did] = bucket
            end
            local dollars = cents / 100.0
            local minutes = 0
            if PRICE_PER_MIN and PRICE_PER_MIN > 0 then
                minutes = math.floor(dollars / PRICE_PER_MIN + 0.5)
            end
            table.insert(bucket.rows, {
                ts    = row.created_at,           -- Zeitpunkt
                label = minutesToLabel(minutes),  -- Ticketlabel
                price = dollars                   -- (optional)
            })
            if #bucket.rows > 10 then table.remove(bucket.rows) end
        end
    end

    -- 3) Payload
    local payload = {}
    for _, d in ipairs(devices) do
        local g = groupedByDevice[tonumber(d.id)] or { rows = {} }
        local cash = tonumber(d.cash_cents or 0) / 100.0
        table.insert(payload, {
            id        = d.id,
            type      = d.type or 'device',
            model     = d.model,
            pos       = { x = d.x, y = d.y, z = d.z },
            since     = d.created_at,
            placed_by = d.placed_by,
            sales     = g.rows,      -- [{ts, label, price}]
            revenue   = cash,        -- Kassenbestand in $
        })
    end

    cb({
        devices  = payload,
        currency = Config.CurrencySymbol or "€"
    })
end)
