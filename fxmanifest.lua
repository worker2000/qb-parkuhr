fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qb-parkuhr'
description 'QBCore Parkuhr & Ticketautomaten'
author 'Antony.R+ChatGPT'
version '1.7.0'

shared_script '@qb-core/shared/locale.lua'
shared_script 'config.lua'

client_scripts {
    'client/common.lua',   -- MUSS vor duty.lua
    'client/meter.lua',
    'client/automat.lua',
    'client/main.lua',
    'client/duty.lua',
    'client/panel.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}
