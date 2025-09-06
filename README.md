Hi everyone 👋,
I’m from Germany 🇩🇪 and this is my **first script for QBCore**. It is still under development and can (and should) evolve further, but I wanted to share it with the community.

---

## 📋 Features

* Place **parking machines** (`prop_park_ticket_01`) with the Parking Enforcement job
* Vehicles can buy **tickets** with durations (10 min, 30 min, 1 day, 7 days, …)
* Tickets are stored in DB with **expiry times**
* **Police** can check tickets with `/check` and see expiry/owner
* **Parking Enforcement** can:

  * Define areas around machines
  * Empty machines (cash, minimum float stays inside)
  * Remove machines
* Citizens can **loot** small amounts from meters with chance
* **Central Web Panel** (`Parkraum Zentrale`):

  * Device overview (machines & meters, revenues)
  * Last sales (summarized & expandable list)
  * Future: Change tariffs/prices per device

---

## 📦 Installation

1. Copy folder `qb-parkuhr` into your `resources/[qb]` directory.
2. Add to your `server.cfg`:

   ```cfg
   ensure qb-parkuhr
   ```
3. Import the following SQL schema (see below).
4. Give yourself or others the **job `parking`** (Parkraumüberwachung).

---

## 🗄️ SQL Schema

```sql
CREATE TABLE `parking_devices` (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT,
  `type` enum('machine','meter_small','meter_large') NOT NULL,
  `model` varchar(64) NOT NULL,
  `x` double NOT NULL,
  `y` double NOT NULL,
  `z` double NOT NULL,
  `heading` double NOT NULL DEFAULT 0,
  `cash_cents` int(11) NOT NULL DEFAULT 0,
  `placed_by` varchar(64) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE `parking_areas` (
  `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT,
  `device_id` int(10) UNSIGNED NOT NULL,
  `points_json` longtext NOT NULL CHECK (json_valid(`points_json`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE `parking_cash_log` (
  `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT,
  `device_id` int(10) UNSIGNED NOT NULL,
  `change_cents` int(11) NOT NULL,
  `reason` varchar(64) NOT NULL,
  `actor` varchar(64) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE `parking_loot_log` (
  `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT,
  `device_type` enum('meter_small','machine') NOT NULL,
  `device_key` varchar(128) NOT NULL,
  `identifier` varchar(64) NOT NULL,
  `ts` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE `parking_tariffs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `device_id` int(11) DEFAULT NULL,
  `type` varchar(32) DEFAULT NULL,
  `duration_min` int(11) NOT NULL,
  `price_cents` int(11) NOT NULL,
  `updated_by` varchar(50) DEFAULT NULL,
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `parking_warnings` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `plate` varchar(10) DEFAULT NULL,
  `officer` varchar(50) DEFAULT NULL,
  `reason` text DEFAULT NULL,
  `timestamp` datetime DEFAULT NULL,
  `meter_x` double DEFAULT NULL,
  `meter_y` double DEFAULT NULL,
  `meter_z` double DEFAULT NULL,
  `vehicle_x` double DEFAULT NULL,
  `vehicle_y` double DEFAULT NULL,
  `vehicle_z` double DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `park_tickets` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `plate` varchar(10) DEFAULT NULL,
  `parked_at` datetime DEFAULT NULL,
  `duration_minutes` int(11) DEFAULT NULL,
  `expires_at` datetime DEFAULT NULL,
  `meter_x` double DEFAULT NULL,
  `meter_y` double DEFAULT NULL,
  `meter_z` double DEFAULT NULL,
  `vehicle_x` double DEFAULT NULL,
  `vehicle_y` double DEFAULT NULL,
  `vehicle_z` double DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
```

---

## 🔧 Notes

* This is my **first release** – expect bugs and missing features.
* I am German 🇩🇪, so some translations are still rough.
* Feel free to improve, optimize, and expand – it should become a community project.

---

👉 Would you like me to **bundle this into a ready-to-upload ZIP** (with `__resource.lua/fxmanifest.lua`, client, server, html, SQL) so you can post it directly?
