Config = {}

-- Allgemein / Rechte
Config.JobName = 'parking'               -- Jobname für Berechtigungen (z.B. Parkraumüberwachung)

-- Server: Tarife & Verhalten
Config.PricePerMin      = 1.0            -- $ pro Minute
Config.ValidRadius      = 6.0            -- Radius für polizeiliche Standortprüfung
Config.RebuyDistance    = 10.0           -- kein Direkt-Nachkauf am selben Spot (Min-Distanz)
Config.PlaceableModel   = 'prop_park_ticket_01'  -- Modellname des platzierbaren Automaten

-- Kassen- / Loot-Logik
Config.FloatMinCents           = 6000    -- Mindestbestand, bleibt beim Leeren im Gerät (in Cents)
Config.LootCooldownMinSmall    = 15      -- Minuten Cooldown beim kleinen Meter
Config.LootCooldownMinMachine  = 30      -- Minuten Cooldown beim Automaten
Config.LootChanceSmall         = 0.25    -- Chance [0..1]
Config.LootChanceMachine       = 0.15    -- Chance [0..1]
Config.LootMinSmall            = 2       -- $-Minimum beim kleinen Meter
Config.LootMaxSmall            = 5       -- $-Maximum beim kleinen Meter
Config.LootMinMachine          = 10      -- $-Minimum beim Automaten
Config.LootMaxMachine          = 50      -- $-Maximum beim Automaten

-- Client: Interaktion / Modelle
Config.InteractKey       = 38            -- E
Config.MachineUseDist    = 1.8
Config.SmallMeterModels  = { `prop_parknmeter_01`, `prop_parknmeter_02` }  -- Modelle der Map-Parkuhren

Config.DutyPoints = {
    vector3(-1092.11, -1267.59, 5.76),
}
Config.DutyDistance = 2.5
-- Optional: InteractKey global/aus common.lua, sonst:
Config.InteractKey = 38
Config.PanelPoint    = vector3(-1085.77, -1267.52, 5.77)
Config.PanelDistance = 2.5