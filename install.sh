apt update && apt upgrade -y
apt install docker.io curl nano sqlite3 -y
systemctl enable --now docker
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs
docker pull ubuntu:22.04

npm init -y
npm install discord.js dotenv dockerode sqlite3 node-cron
apt install -y ttyd

cat << 'EOF' > index.js
require('dotenv').config();
const { Client, GatewayIntentBits, Partials, EmbedBuilder, ActionRowBuilder, StringSelectMenuBuilder, ButtonBuilder, ButtonStyle } = require('discord.js');
const sqlite3 = require('sqlite3').verbose();
const Docker = require('dockerode');
const crypto = require('crypto');
const { exec } = require('child_process');
const fs = require('fs');
const os = require('os');

const client = new Client({
    intents: [
        GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent, GatewayIntentBits.DirectMessages
    ],
    partials: [Partials.Channel, Partials.Message] 
});

const docker = new Docker({ socketPath: '/var/run/docker.sock' });
const defaultPrefix = 'Fx?';

const db = new sqlite3.Database('./vps_data.sqlite');

db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS bot_admins (user_id TEXT UNIQUE, type TEXT DEFAULT 'admin')`);
    db.run(`CREATE TABLE IF NOT EXISTS vps_list (container_id TEXT, user_id TEXT, vps_number INTEGER, cpu INTEGER, ram INTEGER, disk INTEGER, expire_at INTEGER, is_suspended INTEGER DEFAULT 0, purge_protection INTEGER DEFAULT 0)`);
    db.run(`CREATE TABLE IF NOT EXISTS shared_vps (container_id TEXT, shared_user_id TEXT)`);
    db.run(`CREATE TABLE IF NOT EXISTS bot_settings (key TEXT UNIQUE, value TEXT)`);
    db.run(`CREATE TABLE IF NOT EXISTS user_prefixes (user_id TEXT UNIQUE, prefix TEXT)`);

    db.all("PRAGMA table_info(bot_admins)", (err, columns) => {
        if (columns && !columns.some(col => col.name === 'type')) {
            db.run("ALTER TABLE bot_admins ADD COLUMN type TEXT DEFAULT 'admin'");
        }
    });

    db.all("PRAGMA table_info(vps_list)", (err, columns) => {
        if (columns && !columns.some(col => col.name === 'purge_protection')) {
            db.run("ALTER TABLE vps_list ADD COLUMN purge_protection INTEGER DEFAULT 0");
        }
    });
});

function getUserPrefix(userId) {
    return new Promise((resolve) => {
        db.get(`SELECT prefix FROM user_prefixes WHERE user_id = ?`, [userId], (err, row) => {
            resolve(row ? row.prefix : defaultPrefix);
        });
    });
}

function parseTime(timeStr) {
    const regex = /(\d+)([dhms])/g;
    let match, ms = 0;
    while ((match = regex.exec(timeStr)) !== null) {
        if (match[2] === 'd') ms += parseInt(match[1]) * 86400000;
        if (match[2] === 'h') ms += parseInt(match[1]) * 3600000;
        if (match[2] === 'm') ms += parseInt(match[1]) * 60000;
    }
    return ms;
}

function isMainAdmin(userId) {
    return new Promise((resolve) => {
        if (process.env.MAIN_ADMINS && process.env.MAIN_ADMINS.includes(userId)) return resolve(true);
        db.get(`SELECT user_id FROM bot_admins WHERE user_id = ? AND type = 'main'`, [userId], (err, row) => resolve(!!row));
    });
}

function isAdmin(userId) {
    return new Promise(async (resolve) => {
        if (await isMainAdmin(userId)) return resolve(true);
        db.get(`SELECT user_id FROM bot_admins WHERE user_id = ?`, [userId], (err, row) => resolve(!!row));
    });
}

function getMaintenanceMode() {
    return new Promise((resolve) => {
        db.get(`SELECT value FROM bot_settings WHERE key = 'maintenance'`, (err, row) => {
            resolve(row ? row.value === 'on' : false);
        });
    });
}

function setMaintenanceMode(status) {
    return new Promise((resolve) => {
        db.run(`INSERT OR REPLACE INTO bot_settings (key, value) VALUES ('maintenance', ?)`, [status], () => resolve());
    });
}

function createProgressBar(used, total, size = 10) {
    const percentage = Math.min(Math.max(used / total, 0), 1);
    const filledCount = Math.round(percentage * size);
    const emptyCount = size - filledCount;
    return `[${'█'.repeat(filledCount)}${'░'.repeat(emptyCount)}] ${(percentage * 100).toFixed(1)}%`;
}

function createCpuVisual(cpuUsageNum) {
    const boxSize = 10;
    const filled = Math.min(Math.round((cpuUsageNum / 100) * boxSize), boxSize);
    let bar = '▪️'.repeat(filled) + '▫️'.repeat(boxSize - filled);
    if (cpuUsageNum > 80) {
        return `🔴 High Load [${bar}] ${cpuUsageNum.toFixed(2)}%`;
    } else {
        return `⬛ Normal [${bar}] ${cpuUsageNum.toFixed(2)}%`;
    }
}

async function getSystemStatusData() {
    return new Promise((resolve) => {
        const botUptime = process.uptime();
        const days = Math.floor(botUptime / 86400);
        const hours = Math.floor((botUptime % 86400) / 3600);
        const minutes = Math.floor((botUptime % 3600) / 60);
        const seconds = Math.floor(botUptime % 60);
        const botUptimeStr = `${days}d ${hours}h ${minutes}m ${seconds}s`;

        const hostUptime = os.uptime();
        const hDays = Math.floor(hostUptime / 86400);
        const hHours = Math.floor((hostUptime % 86400) / 3600);
        const hMinutes = Math.floor((hostUptime % 3600) / 60);
        const hostUptimeStr = `${hDays}d ${hHours}h ${hMinutes}m`;

        const totalMem = os.totalmem() / (1024 * 1024 * 1024);
        const freeMem = os.freemem() / (1024 * 1024 * 1024);
        const usedMem = totalMem - freeMem;
        const memoryUsage = process.memoryUsage().rss / (1024 * 1024);

        const ramBar = createProgressBar(usedMem, totalMem);

        docker.listContainers({ all: true }, async (err, containers) => {
            const totalContainers = containers ? containers.length : 0;
            const runningContainers = containers ? containers.filter(c => c.State === 'running').length : 0;

            const embed = new EmbedBuilder()
                .setTitle('<:settings:1565422148607279145> FLOATIX System Status & Uptime')
                .setDescription(
                    `🤖 **Bot Uptime:** \`${botUptimeStr}\`\n` +
                    `🖥️ **Host Uptime:** \`${hostUptimeStr}\`\n\n` +
                    `<:ram:1565421341966860419> **Bot Memory Usage:** \`${memoryUsage.toFixed(2)} MB\`\n` +
                    `<:ram:1565421341966860419> **Host RAM:** \`${usedMem.toFixed(2)} GB / ${totalMem.toFixed(2)} GB\`\n${ramBar}\n\n` +
                    `<:Desktop:1565422603642863816> **Total Machines:** \`${totalContainers}\`\n` +
                    `<a:Fh_Online:1565400190335324271> **Running Machines:** \`${runningContainers}\``
                )
                .setColor('#00FF00')
                .setFooter({ text: 'Powered by FLOATIX (Auto-refreshes every 5m)' });

            resolve(embed);
        });
    });
}

async function getVpsStatusEmbed(containerId, ownerId, viewerId = null, customStatusText = null) {
    return new Promise((resolve) => {
        db.get(`SELECT expire_at, is_suspended, cpu, ram, disk, vps_number, user_id, purge_protection FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            let statusText = customStatusText || "<a:offline:1565400363207757914> Stopped";
            let isRunning = false;
            let color = '#FF0000';
            let uptimeStr = "Offline";
            let statsStr = "Loading...";
            
            let expireStr = row ? `<t:${Math.floor(row.expire_at/1000)}:R>` : "Unknown";
            let vpsNo = row ? row.vps_number : "1";
            let purgeProtStatus = row && row.purge_protection === 1 ? "<a:Lock:1565421690798866472> Enabled" : "<:unlock_:1565421832344174643> Disabled";

            if (row && row.is_suspended === 1) {
                statusText = "<:Suspended:1565400840942915685> SUSPENDED (Expired or Overloaded)";
                color = '#808080';
            }

            let cpuUsageNum = 0.00;
            let ramUsageMB = 0;
            let ramLimitMB = row ? row.ram * 1024 : 4096;

            try {
                const container = docker.getContainer(containerId);
                const data = await container.inspect();
                isRunning = data.State.Running;
                
                if (!customStatusText) {
                    if (isRunning && row && row.is_suspended === 0) {
                        statusText = "<a:Fh_Online:1565400190335324271> Running";
                        color = '#00FF00';
                        const startedAt = new Date(data.State.StartedAt).getTime();
                        uptimeStr = `<t:${Math.floor(startedAt/1000)}:R>`;
                    } else if (row && row.is_suspended === 0) {
                        statusText = "<a:offline:1565400363207757914> Stopped";
                        color = '#FF0000';
                    }
                }

                if (isRunning && row && row.is_suspended === 0) {
                    try {
                        const stats = await container.stats({ stream: false });
                        ramUsageMB = (stats.memory_stats.usage / (1024 * 1024)).toFixed(2);
                        
                        if (stats.cpu_stats && stats.precpu_stats) {
                            const cpuDelta = stats.cpu_stats.cpu_usage.total_usage - stats.precpu_stats.cpu_usage.total_usage;
                            const sysDelta = stats.cpu_stats.system_cpu_usage - stats.precpu_stats.system_cpu_usage;
                            if (sysDelta > 0 && cpuDelta > 0) cpuUsageNum = parseFloat(((cpuDelta / sysDelta) * 100).toFixed(2));
                        }
                    } catch(e) {}
                }
            } catch (e) {
                statusText = "<a:warning2:1565401070618943539> Error / Not Found";
                color = '#FFA500';
            }

            const ramBar = createProgressBar(parseFloat(ramUsageMB), ramLimitMB);
            const diskBar = createProgressBar(2.0, row ? row.disk : 10);
            const cpuVisualBox = createCpuVisual(cpuUsageNum);

            statsStr = `<a:BarChart:1565401245584195694> **Live Stats:**\n` +
                       `<:CPU:1565421194570891387> **CPU:** ${cpuVisualBox}\n` +
                       `<:ram:1565421341966860419> **RAM:** ${ramUsageMB} MB / ${ramLimitMB} MB\n${ramBar}\n` +
                       `<a:disk:1565421542144479252> **Disk:** 2.0 GB / ${row ? row.disk : 10} GB\n${diskBar}\n` +
                       `<a:Lock:1565421690798866472> **Purge Protection:** ${purgeProtStatus}`;

            const embed = new EmbedBuilder()
                .setTitle('<:settings:1565422148607279145> FLOATIX VPS Panel (Secure)')
                .setDescription(`**VPS No:** \`${vpsNo}\` | **ID:** \`${containerId.substring(0,8)}\`\n\n**Status:** ${statusText}\n**Uptime:** ${uptimeStr}\n**Expires:** ${expireStr}\n\n${statsStr}`)
                .setColor(color)
                .setFooter({ text: 'Powered by FLOATIX' });

            if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
            if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

            const isDisabled = row && row.is_suspended === 1;
            let isSharedUser = viewerId && row && row.user_id !== viewerId;

            const row1 = new ActionRowBuilder().addComponents(
                new ButtonBuilder().setCustomId(`start_${ownerId}_${containerId}`).setLabel('Start').setEmoji('<:Start:1565401546475307129>').setStyle(ButtonStyle.Success).setDisabled(isDisabled),
                new ButtonBuilder().setCustomId(`stop_${ownerId}_${containerId}`).setLabel('Stop').setEmoji('<a:off:1565401886041968720>').setStyle(ButtonStyle.Danger).setDisabled(isDisabled),
                new ButtonBuilder().setCustomId(`restart_${ownerId}_${containerId}`).setLabel('Restart').setEmoji('<:Restart:1565408841338855545>').setStyle(ButtonStyle.Primary).setDisabled(isDisabled),
                new ButtonBuilder().setCustomId(`sshx_${ownerId}_${containerId}`).setLabel('SSHX').setEmoji('<:sshx:1565410480854667307>').setStyle(ButtonStyle.Secondary).setDisabled(!isRunning || isDisabled)
            );

            let actionRowComponents = [
                new ButtonBuilder().setCustomId(`status_${ownerId}_${containerId}`).setLabel('Refresh').setEmoji('<a:refresh:1565402498636972163>').setStyle(ButtonStyle.Secondary),
                new ButtonBuilder().setCustomId(`ssh_${ownerId}_${containerId}`).setLabel('Web SSH').setEmoji('<:web:1565402847473049610>').setStyle(ButtonStyle.Primary).setDisabled(!isRunning || isDisabled)
            ];

            if (!isSharedUser) {
                actionRowComponents.unshift(
                    new ButtonBuilder().setCustomId(`reinstall_${ownerId}_${containerId}`).setLabel('Reinstall').setEmoji('<:return:1565402283661983744>').setStyle(ButtonStyle.Secondary).setDisabled(isDisabled)
                );
            }

            const row2 = new ActionRowBuilder().addComponents(actionRowComponents);
            
            resolve({ embed, buttons: [row1, row2] });
        });
    });
}

client.on('messageCreate', async (message) => {
    if (message.author.bot) return;

    const userPrefix = await getUserPrefix(message.author.id);
    const globalPrefix = defaultPrefix;

    let activePrefix = message.content.startsWith(userPrefix) ? userPrefix : (message.content.startsWith(globalPrefix) ? globalPrefix : null);
    if (!activePrefix) return;

    const args = message.content.slice(activePrefix.length).trim().split(/ +/);
    const command = args.shift().toLowerCase();

    const isMain = await isMainAdmin(message.author.id);
    const checkAdmin = await isAdmin(message.author.id);
    const maintenance = await getMaintenanceMode();

    if (maintenance && !checkAdmin && command !== 'help' && command !== 'manage') {
        return message.reply("🛠️ **Maintenance Mode is ON!** Bot is currently under maintenance. Only Admins can execute commands.");
    }

    if (command === 'setprefix') {
        const newPrefix = args[0];
        if (!newPrefix) return message.reply(`Usage: \`${userPrefix}setprefix <new_prefix>\``);
        db.run(`INSERT OR REPLACE INTO user_prefixes (user_id, prefix) VALUES (?, ?)`, [message.author.id, newPrefix], () => {
            message.reply(`✅ **Prefix updated successfully!** Your new prefix is now \`${newPrefix}\`.`);
        });
        return;
    }

    if (command === 'resetprefix') {
        db.run(`DELETE FROM user_prefixes WHERE user_id = ?`, [message.author.id], () => {
            message.reply(`✅ **Prefix reset successfully!** Your prefix is now back to default: \`${defaultPrefix}\`.`);
        });
        return;
    }

    if (command === 'help') {
        message.delete().catch(()=>{});
        const currentPrefix = await getUserPrefix(message.author.id);
        const row = new ActionRowBuilder().addComponents(
            new ButtonBuilder().setCustomId(`openhelp_${message.author.id}_${currentPrefix}`).setLabel('View Commands').setEmoji('<:helper:1565422421841019021>').setStyle(ButtonStyle.Success)
        );
        
        const isDM = !message.guild;
        if (isDM) {
            message.channel.send({ content: `Click below to view commands:`, components: [row] });
        } else {
            message.channel.send({ content: `<@${message.author.id}>, click below to view commands securely.`, components: [row] }).then(msg => setTimeout(() => msg.delete().catch(()=>{}), 15000));
        }
        return;
    }

    if (command === 'manage') {
        message.delete().catch(()=>{});
        const row = new ActionRowBuilder().addComponents(
            new ButtonBuilder().setCustomId(`openmanage_${message.author.id}`).setLabel('Open Private Panel').setEmoji('<:Desktop:1565422603642863816>').setStyle(ButtonStyle.Primary)
        );
        
        const isDM = !message.guild;
        if (isDM) {
            message.channel.send({ content: `Click below to open your panel:`, components: [row] });
        } else {
            message.channel.send({ content: `<@${message.author.id}>, click below to open your panel privately.`, components: [row] }).then(msg => setTimeout(() => msg.delete().catch(()=>{}), 15000));
        }
        return;
    }

    if (command === 'maintenance') {
        if (!isMain) return message.reply("❌ **ACCESS DENIED!** Only Main Admins can toggle maintenance mode.");
        const status = args[0] ? args[0].toLowerCase() : '';
        if (status !== 'on' && status !== 'off') return message.reply(`Usage: \`${userPrefix}maintenance on\` or \`${userPrefix}maintenance off\``);
        
        await setMaintenanceMode(status);
        return message.reply(`✅ **Maintenance Mode is now ${status.toUpperCase()}!**`);
    }

    if (command === 'addmain') {
        if (!isMain) return message.reply("❌ **ACCESS DENIED!** Only Main Admins can add another Main Admin.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        if (!target) return message.reply(`Usage: \`${userPrefix}addmain @user\` or user ID`);
        
        db.run(`INSERT OR REPLACE INTO bot_admins (user_id, type) VALUES (?, 'main')`, [target.id], (err) => {
            if (err) return message.reply("❌ Error adding Main Admin: " + err.message);
            message.reply(`✅ <@${target.id}> is now a **Main Admin** <a:crown_crown1:1565406300765167686>!`);
        });
        return;
    }

    if (command === 'addadmin') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can add admins.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        if (!target) return message.reply(`Usage: \`${userPrefix}addadmin @user\` or user ID`);
        
        db.run(`INSERT OR REPLACE INTO bot_admins (user_id, type) VALUES (?, 'admin')`, [target.id], (err) => {
            if (err) return message.reply("❌ Error adding Admin: " + err.message);
            message.reply(`✅ <@${target.id}> is now a Bot Admin <:Admin:1565406497372897390>!`);
        });
        return;
    }

    if (command === 'removeadmin') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can remove admins.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        if (!target) return message.reply(`Usage: \`${userPrefix}removeadmin @user\``);
        
        db.run(`DELETE FROM bot_admins WHERE user_id = ?`, [target.id], () => {
            message.reply(`✅ <@${target.id}> removed from Bot Admins.`);
        });
        return;
    }

    if (command === 'protect') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can set purge protection.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}protect @user <vps_number>\``);
        
        db.run(`UPDATE vps_list SET purge_protection = 1 WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], function(err) {
            if (this.changes === 0) return message.reply("❌ VPS not found for this user.");
            message.reply(`🛡️ Purge Protection **Enabled** for VPS No: **${vpsNo}** (<@${target.id}>).`);
        });
        return;
    }

    if (command === 'unprotect') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can remove purge protection.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}unprotect @user <vps_number>\``);
        
        db.run(`UPDATE vps_list SET purge_protection = 0 WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], function(err) {
            if (this.changes === 0) return message.reply("❌ VPS not found for this user.");
            message.reply(`⚠️ Purge Protection **Disabled** for VPS No: **${vpsNo}** (<@${target.id}>).`);
        });
        return;
    }

    if (command === 'uptime') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can check system uptime.");

        const initialEmbed = await getSystemStatusData();
        const sentMsg = await message.reply({ embeds: [initialEmbed] });

        const intervalId = setInterval(async () => {
            try {
                const fetchedMsg = await sentMsg.channel.messages.fetch(sentMsg.id).catch(() => null);
                if (!fetchedMsg) {
                    clearInterval(intervalId);
                    return;
                }
                const updatedEmbed = await getSystemStatusData();
                await sentMsg.edit({ embeds: [updatedEmbed] }).catch(() => {
                    clearInterval(intervalId);
                });
            } catch (e) {
                clearInterval(intervalId);
            }
        }, 300000);

        return;
    }

    if (command === 'vps' && args[0] === 'list') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can view all VPS list.");
        
        db.all(`SELECT DISTINCT user_id FROM vps_list`, async (err, rows) => {
            if (!rows || rows.length === 0) return message.reply("❌ No VPS found in database.");
            
            const options = rows.map(r => ({
                label: `User ID: ${r.user_id}`,
                description: `Click to view this user's VPS list`,
                value: `vpsuser_${r.user_id}`
            }));

            const row = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`adminvpsuser_${message.author.id}`).setPlaceholder('Select User to view VPS...').addOptions(options)
            );
            const embed = new EmbedBuilder().setTitle('📋 Admin VPS Manager - Select User').setDescription('Choose a user from the dropdown below to check their VPS.').setColor('#0099ff');
            
            const isDM = !message.guild;
            message.reply({ embeds: [embed], components: [row], ephemeral: !isDM });
        });
        return;
    }

    if (command === 'admin' && args[0] === 'list') {
        if (!isMain) return message.reply("❌ **ACCESS DENIED!** Only Main Admins can view admin list.");

        db.all(`SELECT user_id, type FROM bot_admins`, async (err, adminRows) => {
            let admins = adminRows ? adminRows : [];

            if (admins.length === 0) return message.reply("❌ No Admin users found.");

            const options = admins.map(a => ({
                label: `Admin ID: ${a.user_id} [${a.type.toUpperCase()}]`,
                description: `Manage this admin's VPS and Access`,
                value: `manageadmin_${a.user_id}`
            }));

            const row = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`adminlistmenu_${message.author.id}`).setPlaceholder('Select Admin User...').addOptions(options)
            );
            const embed = new EmbedBuilder().setTitle('🛡️ Main Admin Panel - Admin List').setDescription('Select an admin from the menu to manage their permissions and VPS.').setColor('#FF0000');
            
            const isDM = !message.guild;
            message.reply({ embeds: [embed], components: [row], ephemeral: !isDM });
        });
        return;
    }

    if (command === 'create') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can create VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const ram = parseInt(args[1]); const cpu = parseInt(args[2]); const disk = parseInt(args[3]); const timeStr = args[4]; 
        if (!target || !ram || !cpu || !disk || !timeStr) return message.reply(`Usage: \`${userPrefix}create @user <ram(GB)> <cpu(Cores)> <disk(GB)> <time(30m/2h/1d)>\``);
        
        db.get(`SELECT MAX(vps_number) as max_no FROM vps_list WHERE user_id = ?`, [target.id], async (err, row) => {
            const vpsNo = (row && row.max_no) ? row.max_no + 1 : 1;
            const expireDate = Date.now() + parseTime(timeStr);
            
            const msg = await message.reply(`⏳ Creating Docker VPS (No: ${vpsNo}) for <@${target.id}>...`);
            try {
                const container = await docker.createContainer({
                    Image: 'ubuntu:22.04', Tty: true, OpenStdin: true, Cmd: ['/bin/bash'], 
                    HostConfig: {
                        NanoCpus: cpu * 1000000000, Memory: ram * 1024 * 1024 * 1024, DiskQuota: disk * 1024 * 1024 * 1024,
                        Privileged: true, CapAdd: ['NET_ADMIN', 'SYS_ADMIN', 'SYS_PTRACE'], SecurityOpt: ['seccomp=unconfined', 'apparmor=unconfined'],
                        Binds: ['/sys/fs/cgroup:/sys/fs/cgroup:rw']
                    }
                });
                await container.start();
                db.run(`INSERT INTO vps_list (container_id, user_id, vps_number, cpu, ram, disk, expire_at, is_suspended, purge_protection) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)`,
                    [container.id, target.id, vpsNo, cpu, ram, disk, expireDate]);
                
                const embed = new EmbedBuilder()
                    .setTitle('<a:Success:1565403959823442041> VPS Created Successfully!')
                    .setDescription(`**User:** <@${target.id}>\n**VPS No:** \`${vpsNo}\`\n**RAM:** ${ram}GB | **CPU:** ${cpu} Core | **Disk:** ${disk}GB\n**Expire:** <t:${Math.floor(expireDate/1000)}:R>`)
                    .setColor('#00FF00')
                    .setFooter({ text: 'Powered by FLOATIX' });
                
                msg.edit({ content: '', embeds: [embed] });

                const rawToken = crypto.randomBytes(3).toString('hex').toUpperCase(); 
                const pass = `token_${rawToken}`;
                const port = 7681;
                exec(`pkill ttyd`, () => {
                    setTimeout(() => {
                        const scriptContent = `#!/bin/bash\nnohup ttyd -p ${port} -c root:${pass} -W -t rendererType=canvas -t disableLeaveAlert=true -t theme='{"background":"#000000","foreground":"#00FF00","cursor":"#00FF00"}' docker exec -it ${container.id} bash > /dev/null 2>&1 &\n`;
                        fs.writeFileSync('/tmp/start_ttyd.sh', scriptContent, { mode: 0755 });
                        exec(`bash /tmp/start_ttyd.sh`);
                        
                        client.users.fetch(target.id).then(u => {
                            const link = process.env.WEB_URL;
                            const dmEmbed = new EmbedBuilder()
                                .setTitle('🎉 Your New Docker VPS is Ready!')
                                .setDescription(`**VPS No:** \`${vpsNo}\`\n<:linkk:1565412446422835231> **Web Terminal Link:** \`${link}\`\n👤 **Username:** \`root\`\n<a:key:1565412483810730056> **Password:** \`${pass}\`\n\nType \`${userPrefix}manage\` in the server to control your VPS!`)
                                .setColor('#00FF00')
                                .setFooter({ text: 'Powered by FLOATIX' });
                            if (process.env.LOGO_URL) dmEmbed.setThumbnail(process.env.LOGO_URL);
                            if (process.env.BANNER_URL) dmEmbed.setImage(process.env.BANNER_URL);

                            const copyRow = new ActionRowBuilder().addComponents(
                                new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(link).setLabel('🔗 Open Terminal'),
                                new ButtonBuilder().setCustomId(`copypass_${pass}`).setLabel('📋 Copy Password').setStyle(ButtonStyle.Secondary)
                            );

                            u.send({ embeds: [dmEmbed], components: [copyRow] }).catch(()=>{});
                        });
                    }, 1000);
                });

            } catch (e) { msg.edit("❌ Error: " + e.message); }
        });
    }

    if (command === 'delete') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can delete VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}delete @user <vps_number>\``);
        db.get(`SELECT container_id, purge_protection FROM vps_list WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], async (err, row) => {
            if (!row) return message.reply("❌ VPS not found.");
            if (row.purge_protection === 1 && !isMain) return message.reply("❌ **Purge Protection is Enabled!** Only Main Admins can delete this VPS.");
            try {
                const container = docker.getContainer(row.container_id);
                await container.stop().catch(()=>{}); await container.remove({ force: true }).catch(()=>{});
                db.run(`DELETE FROM vps_list WHERE container_id = ?`, [row.container_id]); db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [row.container_id]);
                message.reply(`✅ VPS No: **${vpsNo}** deleted successfully.`);
                client.users.fetch(target.id).then(u => { 
                    u.send(`⚠️ **Alert!** Your VPS (No: \`${vpsNo}\`) has been deleted by Admin <@${message.author.id}>.`); 
                }).catch(()=>{});
            } catch(e) { message.reply(`❌ Error deleting VPS.`); }
        });
    }

    if (command === 'purge') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can purge VPS.");
        
        let query = `SELECT * FROM vps_list WHERE purge_protection = 0 ORDER BY RANDOM()`;
        db.all(query, async (err, rows) => {
            if (!rows || rows.length === 0) return message.reply("❌ No unprotected VPS found to purge.");
            const msg = await message.reply(`<a:alert:1565404039770800159> **PURGE INITIATED!** Deleting ${rows.length} unprotected VPS...`);
            let purgedList = [];
            for (const row of rows) {
                try {
                    const container = docker.getContainer(row.container_id);
                    await container.stop().catch(()=>{});
                    await container.remove({ force: true }).catch(()=>{});
                    db.run(`DELETE FROM vps_list WHERE container_id = ?`, [row.container_id]);
                    db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [row.container_id]);
                    purgedList.push(`- <@${row.user_id}> (VPS No: **${row.vps_number}**)`);
                    client.users.fetch(row.user_id).then(u => {
                        u.send(`<a:alert:1565404039770800159> **System Purge Alert!** Your VPS (No: \`${row.vps_number}\`) has been permanently deleted during a server purge by Admin <@${message.author.id}>.`);
                    }).catch(()=>{});
                } catch (e) {}
            }
            const embed = new EmbedBuilder().setTitle('<a:Success:1565403959823442041> Purge Complete!').setDescription(`**${rows.length} VPS Destroyed!**\n\n**Purged List:**\n${purgedList.join('\n')}`).setColor('#FF0000');
            msg.edit({ content: '', embeds: [embed] });
        });
    }

    if (command === 'suspend') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can suspend VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}suspend @user <vps_number>\``);
        db.get(`SELECT container_id FROM vps_list WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], async (err, row) => {
            if (!row) return message.reply("❌ VPS not found.");
            db.run(`UPDATE vps_list SET is_suspended = 1 WHERE container_id = ?`, [row.container_id]);
            try { await docker.getContainer(row.container_id).stop().catch(()=>{}); } catch(e) {}
            message.reply(`✅ VPS No: **${vpsNo}** has been **SUSPENDED**.`);
            client.users.fetch(target.id).then(u => { u.send(`<a:alert:1565404039770800159> **Alert!** Your VPS (No: \`${vpsNo}\`) has been Suspended by Admin <@${message.author.id}>.`); }).catch(()=>{});
        });
    }

    if (command === 'unsuspend') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can unsuspend VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}unsuspend @user <vps_number>\``);
        db.get(`SELECT container_id FROM vps_list WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], (err, row) => {
            if (!row) return message.reply("❌ VPS not found.");
            db.run(`UPDATE vps_list SET is_suspended = 0 WHERE container_id = ?`, [row.container_id]);
            message.reply(`✅ VPS No: **${vpsNo}** is now **UNSUSPENDED**.`);
            client.users.fetch(target.id).then(u => { u.send(`<a:Success:1565403959823442041> **Good News!** Your VPS (No: \`${vpsNo}\`) has been Unsuspended by Admin <@${message.author.id}>.`); }).catch(()=>{});
        });
    }

    if (command === 'renew') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can renew VPS.");
        const vpsNo = parseInt(args[0]); 
        const timeStr = args[1]; 
        let targetId = message.author.id;
        
        if (message.mentions.users.first()) { 
            targetId = message.mentions.users.first().id; 
            if (!args[2] && !timeStr) return message.reply(`Usage: \`${userPrefix}renew <vps_number> <time> [@user]\``); 
        }

        db.get(`SELECT container_id, expire_at FROM vps_list WHERE user_id = ? AND vps_number = ?`, [targetId, vpsNo], (err, row) => {
            if (!row) return message.reply("❌ VPS not found for this user.");
            
            const baseTime = Math.max(row.expire_at, Date.now());
            const newTime = baseTime + parseTime(timeStr);
            
            db.run(`UPDATE vps_list SET expire_at = ?, is_suspended = 0 WHERE container_id = ?`, [newTime, row.container_id]);
            message.reply(`✅ VPS No: **${vpsNo}** renewed successfully! New Expiry: <t:${Math.floor(newTime/1000)}:R>`);
            
            client.users.fetch(targetId).then(u => { 
                u.send(`<a:Success:1565403959823442041> Your VPS (No: \`${vpsNo}\`) has been renewed by Admin <@${message.author.id}>! New Expiry: <t:${Math.floor(newTime/1000)}:R>`); 
            }).catch(()=>{});
        });
    }

    if (command === 'share') {
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}share @user <vps_number>\``);
        db.get(`SELECT container_id FROM vps_list WHERE user_id = ? AND vps_number = ?`, [message.author.id, vpsNo], (err, row) => {
            if (!row) return message.reply("❌ VPS not found or you don't own it.");
            db.run(`INSERT INTO shared_vps (container_id, shared_user_id) VALUES (?, ?)`, [row.container_id, target.id]);
            message.reply(`<:share:1565403805187702804> VPS No: **${vpsNo}** is now shared with <@${target.id}>! They can manage it using \`${userPrefix}manage\`.`);
            client.users.fetch(target.id).then(u => { u.send(`🎁 **Gift!** <@${message.author.id}> has shared their **VPS No: ${vpsNo}** with you. Type \`${userPrefix}manage\` to access it!`); }).catch(()=>{});
        });
    }
});

client.on('interactionCreate', async (interaction) => {
    if (!interaction.isStringSelectMenu() && !interaction.isButton()) return;
    const parts = interaction.customId.split('_');
    const action = parts[0];
    const ownerId = parts[1];

    const isDM = !interaction.guild;

    if (action === 'copypass') {
        const tokenVal = parts.slice(1).join('_');
        return interaction.reply({ content: `📋 **Password / Link:** \`${tokenVal}\``, ephemeral: true });
    }

    if (action === 'openhelp') {
        await interaction.deferReply({ ephemeral: !isDM });
        const userPrefix = parts[2] || defaultPrefix;
        const row = new ActionRowBuilder().addComponents(
            new StringSelectMenuBuilder().setCustomId(`helpmenu_${ownerId}_${userPrefix}`)
            .setPlaceholder('Select Help Category...')
            .addOptions([
                { label: 'Admin Commands', description: 'View admin commands', value: 'admin' },
                { label: 'User Commands', description: 'View user commands', value: 'user' }
            ])
        );
        const embed = new EmbedBuilder().setTitle('<:helper:1565422421841019021> VPS Manager - Help').setDescription('Select a category from the dropdown below.').setColor('#0099ff').setFooter({ text: 'Powered by FLOATIX' });
        if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
        if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);
        await interaction.editReply({ embeds: [embed], components: [row] });
        return;
    }

    if (action === 'helpmenu') {
        await interaction.deferUpdate();
        const val = interaction.values[0];
        const userPrefix = parts[2] || defaultPrefix;
        let replyEmbed;
        if (val === 'admin') {
            replyEmbed = new EmbedBuilder()
                .setTitle('<:helper:1565422421841019021> Admin Commands')
                .setDescription(`\`${userPrefix}create @user <ram> <cpu> <disk> <time>\`\n\`${userPrefix}renew <vps_no> <time> [@user]\`\n\`${userPrefix}suspend @user <vps_no>\`\n\`${userPrefix}unsuspend @user <vps_no>\`\n\`${userPrefix}delete @user <vps_no>\`\n\`${userPrefix}purge all / <no>\`\n\`${userPrefix}protect @user <vps_no>\`\n\`${userPrefix}unprotect @user <vps_no>\`\n\`${userPrefix}addadmin @user\`\n\`${userPrefix}removeadmin @user\`\n\`${userPrefix}addmain @user\`\n\`${userPrefix}maintenance on/off\`\n\`${userPrefix}vps list\`\n\`${userPrefix}admin list\`\n\`${userPrefix}uptime\``)
                .setColor('#FF0000')
                .setFooter({ text: 'Powered by FLOATIX' });
        } else {
            replyEmbed = new EmbedBuilder()
                .setTitle('<:helper:1565422421841019021> User Commands')
                .setDescription(`\`${userPrefix}manage\` - Open Private Panel\n\`${userPrefix}share @user <vps_no>\` - Share your VPS\n\`${userPrefix}setprefix <prefix>\` - Set Custom Prefix\n\`${userPrefix}resetprefix\` - Reset Prefix`)
                .setColor('#00FF00')
                .setFooter({ text: 'Powered by FLOATIX' });
        }
        if (process.env.LOGO_URL) replyEmbed.setThumbnail(process.env.LOGO_URL);
        if (process.env.BANNER_URL) replyEmbed.setImage(process.env.BANNER_URL);
        await interaction.editReply({ embeds: [replyEmbed] });
        return;
    }

    if (ownerId && interaction.user.id !== ownerId && !['adminvpsuser', 'adminlistmenu', 'vpsuserselect', 'manageadminuser', 'adminvpsaction'].includes(action)) {
        return interaction.reply({ content: '❌ **ACCESS DENIED!** This is locked to another user.', ephemeral: true });
    }

    if (action === 'adminvpsuser') {
        await interaction.deferUpdate();
        const targetUserId = interaction.values[0].replace('vpsuser_', '');
        db.all(`SELECT container_id, vps_number FROM vps_list WHERE user_id = ?`, [targetUserId], async (err, rows) => {
            if (!rows || rows.length === 0) return interaction.editReply({ content: "❌ This user has no VPS.", components: [] });
            
            const options = rows.map(r => ({
                label: `VPS No: ${r.vps_number} (ID: ${r.container_id.substring(0,8)})`,
                description: `Manage or Delete this VPS`,
                value: `vpsmanage_${r.container_id}`
            }));

            const row = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`vpsuserselect_${interaction.user.id}`).setPlaceholder('Select VPS to Manage/Delete...').addOptions(options)
            );
            const embed = new EmbedBuilder().setTitle(`<:k9user:1565422798065901742> VPS List for User <@${targetUserId}>`).setDescription('Select a VPS below to view panel or delete it.').setColor('#0099ff');
            await interaction.editReply({ embeds: [embed], components: [row] });
        });
        return;
    }

    if (action === 'vpsuserselect') {
        const containerId = interaction.values[0].replace('vpsmanage_', '');
        db.get(`SELECT user_id FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            if (!row) return interaction.reply({ content: "❌ VPS not found.", ephemeral: true });
            const { embed, buttons } = await getVpsStatusEmbed(containerId, row.user_id, interaction.user.id);
            const deleteBtn = new ActionRowBuilder().addComponents(
                new ButtonBuilder().setCustomId(`admindeletevps_${row.user_id}_${containerId}`).setLabel('Delete This VPS').setStyle(ButtonStyle.Danger)
            );
            await interaction.reply({ embeds: [embed], components: [...buttons, deleteBtn], ephemeral: !isDM });
        });
        return;
    }

    if (action === 'admindeletevps') {
        await interaction.deferUpdate();
        const containerId = parts[2];
        db.get(`SELECT user_id, vps_number FROM vps_list WHERE container_id = ?`, [containerId], async (err, vpsRow) => {
            try {
                const container = docker.getContainer(containerId);
                await container.stop().catch(()=>{});
                await container.remove({ force: true }).catch(()=>{});
                db.run(`DELETE FROM vps_list WHERE container_id = ?`, [containerId]);
                db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [containerId]);
                
                if (vpsRow) {
                    client.users.fetch(vpsRow.user_id).then(u => {
                        u.send(`⚠️ **Alert!** Your VPS (No: \`${vpsRow.vps_number}\`) has been deleted by Admin <@${interaction.user.id}> via Admin Panel.`);
                    }).catch(()=>{});
                }

                await interaction.editReply({ content: '✅ **VPS successfully deleted by Admin!**', embeds: [], components: [] });
            } catch (e) {
                await interaction.editReply({ content: `❌ Error deleting VPS: ${e.message}`, embeds: [], components: [] });
            }
        });
        return;
    }

    if (action === 'adminlistmenu') {
        await interaction.deferUpdate();
        const selectedAdminId = interaction.values[0].replace('manageadmin_', '');

        db.all(`SELECT container_id, vps_number FROM vps_list WHERE user_id = ?`, [selectedAdminId], async (err, rows) => {
            const vpsCount = rows ? rows.length : 0;
            const embed = new EmbedBuilder()
                .setTitle(`🛡️ Managing Admin: <@${selectedAdminId}>`)
                .setDescription(`**Total VPS Owned:** \`${vpsCount}\`\n\nChoose an action below for this admin:`)
                .setColor('#FF0000');

            const options = rows && rows.length > 0 ? rows.map(r => ({
                label: `VPS No: ${r.vps_number}`,
                value: `adminvps_${r.container_id}`
            })) : [{ label: 'No VPS Found', value: 'none' }];

            const row1 = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`adminvpsaction_${selectedAdminId}`).setPlaceholder('View Specific VPS...').addOptions(options)
            );

            const row2 = new ActionRowBuilder().addComponents(
                new ButtonBuilder().setCustomId(`removerole_${selectedAdminId}`).setLabel('Remove Admin Access').setStyle(ButtonStyle.Danger),
                new ButtonBuilder().setCustomId(`deleteAllVps_${selectedAdminId}`).setLabel('Delete All VPS of Admin').setStyle(ButtonStyle.Danger)
            );

            await interaction.editReply({ embeds: [embed], components: [row1, row2] });
        });
        return;
    }

    if (action === 'adminvpsaction') {
        const containerId = interaction.values[0];
        if (containerId === 'none') return interaction.reply({ content: '❌ This admin has no VPS.', ephemeral: !isDM });
        db.get(`SELECT user_id FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            if (!row) return interaction.reply({ content: '❌ VPS not found.', ephemeral: !isDM });
            const { embed, buttons } = await getVpsStatusEmbed(containerId, row.user_id, interaction.user.id);
            await interaction.reply({ embeds: [embed], components: buttons, ephemeral: !isDM });
        });
        return;
    }

    if (action === 'removerole') {
        await interaction.deferUpdate();
        const targetAdminId = parts[2];
        db.run(`DELETE FROM bot_admins WHERE user_id = ?`, [targetAdminId]);
        await interaction.editReply({ content: `✅ **Admin access removed successfully for <@${targetAdminId}>!**`, embeds: [], components: [] });
        return;
    }

    if (action === 'deleteAllVps') {
        await interaction.deferUpdate();
        const targetAdminId = parts[2];
        db.all(`SELECT container_id, vps_number FROM vps_list WHERE user_id = ?`, [targetAdminId], async (err, rows) => {
            if (!rows || rows.length === 0) return interaction.followUp({ content: '❌ This admin has no VPS to delete.', ephemeral: !isDM });
            for (const r of rows) {
                try {
                    const c = docker.getContainer(r.container_id);
                    await c.stop().catch(()=>{});
                    await c.remove({ force: true }).catch(()=>{});
                    client.users.fetch(targetAdminId).then(u => {
                        u.send(`⚠️ **Alert!** Your VPS (No: \`${r.vps_number}\`) has been deleted along with all admin VPS by Admin <@${interaction.user.id}>.`);
                    }).catch(()=>{});
                } catch(e){}
                db.run(`DELETE FROM vps_list WHERE container_id = ?`, [r.container_id]);
                db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [r.container_id]);
            }
            await interaction.editReply({ content: `✅ **All VPS of Admin <@${targetAdminId}> have been permanently deleted!**`, embeds: [], components: [] });
        });
        return;
    }

    if (action === 'openmanage') {
        await interaction.deferReply({ ephemeral: !isDM });
        db.all(`SELECT DISTINCT v.container_id, v.vps_number, v.user_id, CASE WHEN v.user_id = ? THEN 'Owned' ELSE 'Shared' END as status FROM vps_list v LEFT JOIN shared_vps s ON v.container_id = s.container_id WHERE v.user_id = ? OR s.shared_user_id = ?`, [ownerId, ownerId, ownerId], (err, rows) => {
            if (!rows || rows.length === 0) return interaction.editReply({ content: "❌ You don't have any VPS!" });
            const options = rows.map(row => ({ label: row.status === 'Owned' ? `👑 VPS No: ${row.vps_number}` : `🤝 Shared VPS No: ${row.vps_number}`, description: `ID: ${row.container_id.substring(0,8)}...`, value: row.container_id }));
            const rowUI = new ActionRowBuilder().addComponents(new StringSelectMenuBuilder().setCustomId(`selectvps_${ownerId}`).setPlaceholder('Select your VPS...').addOptions(options));
            const embed = new EmbedBuilder().setTitle('<:Desktop:1565422603642863816> VPS Manager').setDescription('Select your VPS.').setColor('#2F3136').setFooter({ text: 'Powered by FLOATIX' });
            if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
            if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);
            interaction.editReply({ embeds: [embed], components: [rowUI] });
        });
        return;
    }

    if (action === 'selectvps') {
        await interaction.deferUpdate();
        const containerId = interaction.values[0];
        const { embed, buttons } = await getVpsStatusEmbed(containerId, ownerId, ownerId);
        await interaction.editReply({ embeds: [embed], components: buttons });
        return;
    }

    if (['start', 'stop', 'restart', 'sshx', 'status', 'ssh', 'reinstall'].includes(action)) {
        const containerId = parts[2]; 
        db.get(`SELECT is_suspended, cpu, ram, disk, vps_number, user_id FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            if (!row) return interaction.reply({ content: '❌ **ERROR!** VPS record not found.', ephemeral: !isDM });
            
            if (action === 'reinstall' && row.user_id !== ownerId) {
                return interaction.reply({ content: '❌ **ACCESS DENIED!** Shared users cannot reinstall VPS.', ephemeral: !isDM });
            }

            if (row.is_suspended === 1 && action !== 'status') return interaction.reply({ content: '❌ **ERROR!** VPS is Suspended.', ephemeral: !isDM });

            if (action === 'start') {
                const container = docker.getContainer(containerId);
                const data = await container.inspect();
                if (data.State.Running) {
                    return interaction.reply({ content: '⚠️ **VPS is already running!**', ephemeral: !isDM });
                }

                await interaction.deferUpdate();
                const startingEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId, "🟡 **VPS is starting...**");
                await interaction.message.edit({ embeds: [startingEmbed.embed], components: startingEmbed.buttons });

                await container.start().catch(()=>{});

                const startedEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [startedEmbed.embed], components: startedEmbed.buttons });
            } else if (action === 'stop') {
                const container = docker.getContainer(containerId);
                const data = await container.inspect();
                if (!data.State.Running) {
                    return interaction.reply({ content: '⚠️ **VPS is already stopped!**', ephemeral: !isDM });
                }

                await interaction.deferUpdate();
                const stoppingEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId, "🟡 **VPS is stopping...**");
                await interaction.message.edit({ embeds: [stoppingEmbed.embed], components: stoppingEmbed.buttons });

                await container.stop().catch(()=>{});

                const stoppedEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [stoppedEmbed.embed], components: stoppedEmbed.buttons });
            } else if (action === 'restart') {
                await interaction.deferUpdate();
                const restartingEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId, "🟡 **VPS is restarting...**");
                await interaction.message.edit({ embeds: [restartingEmbed.embed], components: restartingEmbed.buttons });

                const container = docker.getContainer(containerId);
                await container.restart().catch(()=>{});

                const restartedEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [restartedEmbed.embed], components: restartedEmbed.buttons });
            } else if (action === 'status') {
                await interaction.deferUpdate();
                const { embed, buttons } = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [embed], components: buttons });
            } else if (action === 'ssh') {
                await interaction.deferReply({ ephemeral: !isDM });
                const rawToken = crypto.randomBytes(3).toString('hex').toUpperCase();
                const pass = `token_${rawToken}`;
                const port = 7681; 
                exec(`pkill ttyd`, () => {
                    setTimeout(() => {
                        const scriptContent = `#!/bin/bash\nnohup ttyd -p ${port} -c root:${pass} -W -t rendererType=canvas -t disableLeaveAlert=true -t ctrlKey=true -t enableControlKeys=true -t titleFixed="FLOATIX Terminal" -t theme='{"background":"#000000","foreground":"#00FF00","cursor":"#00FF00"}' docker exec -it ${containerId} bash > /dev/null 2>&1 &\n`;
                        fs.writeFileSync('/tmp/start_ttyd.sh', scriptContent, { mode: 0755 });
                        exec(`bash /tmp/start_ttyd.sh`);
                        const link = process.env.WEB_URL;
                        const embed = new EmbedBuilder()
                            .setTitle('🖥️ Web Terminal Ready!')
                            .setDescription(`<:linkk:1565412446422835231> **Link:** \`${link}\`\n👤 **Username:** \`root\`\n<a:key:1565412483810730056> **Password:** \`${pass}\``)
                            .setColor('#00FF00')
                            .setFooter({ text: 'Powered by FLOATIX' });
                        if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
                        if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

                        const copyRow = new ActionRowBuilder().addComponents(
                            new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(link).setLabel('🔗 Open Terminal'),
                            new ButtonBuilder().setCustomId(`copypass_${pass}`).setLabel('📋 Copy Password').setStyle(ButtonStyle.Secondary)
                        );

                        interaction.editReply({ embeds: [embed], components: [copyRow] });
                    }, 1500);
                });
            } else if (action === 'sshx') {
                await interaction.deferReply({ ephemeral: !isDM });
                const initialEmbed = new EmbedBuilder()
                    .setTitle('<a:rocket:1565421978997887158> SSHX Session Initializing...')
                    .setDescription('```ansi\n\u001b[33m[INFO] Initializing SSHX session...\u001b[0m\n```')
                    .setColor('#FFA500')
                    .setFooter({ text: 'Powered by FLOATIX' });
                if (process.env.LOGO_URL) initialEmbed.setThumbnail(process.env.LOGO_URL);
                if (process.env.BANNER_URL) initialEmbed.setImage(process.env.BANNER_URL);
                
                await interaction.editReply({ embeds: [initialEmbed] });

                const container = docker.getContainer(containerId);
                const sshxCommand = `if ! command -v sshx &> /dev/null; then apt update && apt install sudo -y && apt install curl -y && curl -sSf https://sshx.io/get | sh; else printf '\\x03'; fi; sshx`;

                const execInstance = await container.exec({
                    Cmd: ['bash', '-c', sshxCommand],
                    AttachStdout: true,
                    AttachStderr: true
                });

                execInstance.start((err, stream) => {
                    let output = '';
                    stream.on('data', async (chunk) => {
                        output += chunk.toString();
                        let cleanOutput = output.replace(/\u001b\[[0-9;]*m/g, '');
                        let match = cleanOutput.match(/https:\/\/sshx\.io\/s\/[a-zA-Z0-9#\-_]+/);
                        let sshxLink = match ? match[0] : "Initializing live logs...";
                        
                        const liveEmbed = new EmbedBuilder()
                            .setTitle('<a:rocket:1565421978997887158> Live SSHX Session Logs')
                            .setDescription(`<:linkk:1565412446422835231> **Current SSHX Link:** \`${sshxLink}\`\n\`\`\`ansi\n${output.slice(-1500)}\n\`\`\``)
                            .setColor('#00FF00')
                            .setFooter({ text: 'Powered by FLOATIX' });
                        if (process.env.LOGO_URL) liveEmbed.setThumbnail(process.env.LOGO_URL);
                        if (process.env.BANNER_URL) liveEmbed.setImage(process.env.BANNER_URL);

                        const liveRow = new ActionRowBuilder().addComponents(
                            new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(sshxLink !== "Initializing live logs..." ? sshxLink : "https://sshx.io").setLabel('🚀 Open SSHX Session').setDisabled(sshxLink === "Initializing live logs..."),
                            new ButtonBuilder().setCustomId(`copypass_${sshxLink}`).setLabel('📋 Copy SSHX Link').setStyle(ButtonStyle.Secondary).setDisabled(sshxLink === "Initializing live logs...")
                        );
                        
                        try {
                            await interaction.editReply({ embeds: [liveEmbed], components: [liveRow] });
                        } catch(e) {}
                    });

                    stream.on('end', async () => {
                        let cleanOutput = output.replace(/\u001b\[[0-9;]*m/g, '');
                        let match = cleanOutput.match(/https:\/\/sshx\.io\/s\/[a-zA-Z0-9#\-_]+/);
                        let sshxLink = match ? match[0] : "Check logs inside terminal";
                        
                        const finalEmbed = new EmbedBuilder()
                            .setTitle('<a:rocket:1565421978997887158> SSHX Session Ready!')
                            .setDescription(`<:linkk:1565412446422835231> **Final SSHX Link:** \`${sshxLink}\`\n\`\`\`ansi\n${output.slice(-1500)}\n\`\`\``)
                            .setColor('#00FF00')
                            .setFooter({ text: 'Powered by FLOATIX' });
                        if (process.env.LOGO_URL) finalEmbed.setThumbnail(process.env.LOGO_URL);
                        if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

                        const sshxRow = new ActionRowBuilder().addComponents(
                            new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(sshxLink !== "Check logs inside terminal" ? sshxLink : "https://sshx.io").setLabel('🚀 Open SSHX Session'),
                            new ButtonBuilder().setCustomId(`copypass_${sshxLink}`).setLabel('📋 Copy SSHX Link').setStyle(ButtonStyle.Secondary)
                        );
                        
                        await interaction.editReply({ embeds: [finalEmbed], components: [sshxRow] });
                        client.users.fetch(ownerId).then(u => {
                            u.send(`🚀 **Your SSHX Link for VPS No: ${row.vps_number}**\n<:linkk:1565412446422835231> Link: \`${sshxLink}\``);
                        }).catch(()=>{});
                    });
                });
            } else if (action === 'reinstall') {
                await interaction.deferReply({ ephemeral: !isDM });
                try {
                    const oldContainer = docker.getContainer(containerId);
                    await oldContainer.stop().catch(()=>{});
                    await oldContainer.remove({ force: true }).catch(()=>{});

                    const newContainer = await docker.createContainer({
                        Image: 'ubuntu:22.04', Tty: true, OpenStdin: true, Cmd: ['/bin/bash'], 
                        HostConfig: {
                            NanoCpus: row.cpu * 1000000000, Memory: row.ram * 1024 * 1024 * 1024, DiskQuota: row.disk * 1024 * 1024 * 1024,
                            Privileged: true, CapAdd: ['NET_ADMIN', 'SYS_ADMIN', 'SYS_PTRACE'], SecurityOpt: ['seccomp=unconfined', 'apparmor=unconfined'],
                            Binds: ['/sys/fs/cgroup:/sys/fs/cgroup:rw']
                        }
                    });
                    await newContainer.start();

                    db.run(`UPDATE vps_list SET container_id = ? WHERE container_id = ?`, [newContainer.id, containerId]);
                    db.run(`UPDATE shared_vps SET container_id = ? WHERE container_id = ?`, [newContainer.id, containerId]);

                    const rawToken = crypto.randomBytes(3).toString('hex').toUpperCase(); 
                    const pass = `token_${rawToken}`;
                    const port = 7681;
                    exec(`pkill ttyd`, () => {
                        setTimeout(() => {
                            const scriptContent = `#!/bin/bash\nnohup ttyd -p ${port} -c root:${pass} -W -t rendererType=canvas -t disableLeaveAlert=true -t ctrlKey=true -t enableControlKeys=true -t titleFixed="FLOATIX Terminal" -t theme='{"background":"#000000","foreground":"#00FF00","cursor":"#00FF00"}' docker exec -it ${newContainer.id} bash > /dev/null 2>&1 &\n`;
                            fs.writeFileSync('/tmp/start_ttyd.sh', scriptContent, { mode: 0755 });
                            exec(`bash /tmp/start_ttyd.sh`);

                            client.users.fetch(ownerId).then(u => {
                                const link = process.env.WEB_URL;
                                const dmEmbed = new EmbedBuilder()
                                    .setTitle('🔄 VPS Reinstalled Successfully!')
                                    .setDescription(`**VPS No:** \`${row.vps_number}\`\n<:linkk:1565412446422835231> **New Web Link:** \`${link}\`\n👤 **Username:** \`root\`\n<a:key:1565412483810730056> **New Password:** \`${pass}\``)
                                    .setColor('#00FF00')
                                    .setFooter({ text: 'Powered by FLOATIX' });
                                if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
                                if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

                                const copyRow = new ActionRowBuilder().addComponents(
                                    new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(link).setLabel('🔗 Open Terminal'),
                                    new ButtonBuilder().setCustomId(`copypass_${pass}`).setLabel('📋 Copy Password').setStyle(ButtonStyle.Secondary)
                                );

                                u.send({ embeds: [dmEmbed], components: [copyRow] });
                            }).catch(()=>{});
                        }, 1000);
                    });

                    const { embed, buttons } = await getVpsStatusEmbed(newContainer.id, ownerId, ownerId);
                    await interaction.message.edit({ embeds: [embed], components: buttons }).catch(()=>{});
                    await interaction.editReply({ content: '✅ **VPS Reinstalled Successfully! New Token sent to your DM.**' });
                } catch (e) {
                    await interaction.editReply({ content: `❌ Reinstall Error: ${e.message}` });
                }
            }
        });
    }
});

client.once('ready', () => {
    console.log(`✅ ULTIMATE FLOATIX BOT IS ONLINE AND SECURE! Logged in as ${client.user.tag}`);
    
    setInterval(() => {
        const now = Date.now();
        db.all(`SELECT container_id, user_id, vps_number FROM vps_list WHERE expire_at <= ? AND is_suspended = 0`, [now], async (err, rows) => {
            if (!rows) return;
            for (const row of rows) {
                db.run(`UPDATE vps_list SET is_suspended = 1 WHERE container_id = ?`, [row.container_id]);
                try {
                    const container = docker.getContainer(row.container_id);
                    await container.stop().catch(()=>{});
                    client.users.fetch(row.user_id).then(u => {
                        u.send(`<a:alert:1565404039770800159> **Alert!** Your VPS (No: \`${row.vps_number}\`) has **Expired** and is **Suspended**.`);
                    }).catch(()=>{});
                } catch(e) {}
            }
        });
    }, 15000); 
});

client.login(process.env.BOT_TOKEN);
EOF

systemctl restart skabot
echo "✅ FLOATIX bot fully updated with fixed help menu dropdown selection!"
cat << 'EOF' > index.js
require('dotenv').config();
const { Client, GatewayIntentBits, Partials, EmbedBuilder, ActionRowBuilder, StringSelectMenuBuilder, ButtonBuilder, ButtonStyle } = require('discord.js');
const sqlite3 = require('sqlite3').verbose();
const Docker = require('dockerode');
const crypto = require('crypto');
const { exec } = require('child_process');
const fs = require('fs');
const os = require('os');

const client = new Client({
    intents: [
        GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent, GatewayIntentBits.DirectMessages
    ],
    partials: [Partials.Channel, Partials.Message] 
});

const docker = new Docker({ socketPath: '/var/run/docker.sock' });
const defaultPrefix = 'Fx?';

const db = new sqlite3.Database('./vps_data.sqlite');

db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS bot_admins (user_id TEXT UNIQUE, type TEXT DEFAULT 'admin')`);
    db.run(`CREATE TABLE IF NOT EXISTS vps_list (container_id TEXT, user_id TEXT, vps_number INTEGER, cpu INTEGER, ram INTEGER, disk INTEGER, expire_at INTEGER, is_suspended INTEGER DEFAULT 0, purge_protection INTEGER DEFAULT 0)`);
    db.run(`CREATE TABLE IF NOT EXISTS shared_vps (container_id TEXT, shared_user_id TEXT)`);
    db.run(`CREATE TABLE IF NOT EXISTS bot_settings (key TEXT UNIQUE, value TEXT)`);
    db.run(`CREATE TABLE IF NOT EXISTS user_prefixes (user_id TEXT UNIQUE, prefix TEXT)`);

    db.all("PRAGMA table_info(bot_admins)", (err, columns) => {
        if (columns && !columns.some(col => col.name === 'type')) {
            db.run("ALTER TABLE bot_admins ADD COLUMN type TEXT DEFAULT 'admin'");
        }
    });

    db.all("PRAGMA table_info(vps_list)", (err, columns) => {
        if (columns && !columns.some(col => col.name === 'purge_protection')) {
            db.run("ALTER TABLE vps_list ADD COLUMN purge_protection INTEGER DEFAULT 0");
        }
    });
});

function getUserPrefix(userId) {
    return new Promise((resolve) => {
        db.get(`SELECT prefix FROM user_prefixes WHERE user_id = ?`, [userId], (err, row) => {
            resolve(row ? row.prefix : defaultPrefix);
        });
    });
}

function parseTime(timeStr) {
    const regex = /(\d+)([dhms])/g;
    let match, ms = 0;
    while ((match = regex.exec(timeStr)) !== null) {
        if (match[2] === 'd') ms += parseInt(match[1]) * 86400000;
        if (match[2] === 'h') ms += parseInt(match[1]) * 3600000;
        if (match[2] === 'm') ms += parseInt(match[1]) * 60000;
    }
    return ms;
}

function isMainAdmin(userId) {
    return new Promise((resolve) => {
        if (process.env.MAIN_ADMINS && process.env.MAIN_ADMINS.includes(userId)) return resolve(true);
        db.get(`SELECT user_id FROM bot_admins WHERE user_id = ? AND type = 'main'`, [userId], (err, row) => resolve(!!row));
    });
}

function isAdmin(userId) {
    return new Promise(async (resolve) => {
        if (await isMainAdmin(userId)) return resolve(true);
        db.get(`SELECT user_id FROM bot_admins WHERE user_id = ?`, [userId], (err, row) => resolve(!!row));
    });
}

function getMaintenanceMode() {
    return new Promise((resolve) => {
        db.get(`SELECT value FROM bot_settings WHERE key = 'maintenance'`, (err, row) => {
            resolve(row ? row.value === 'on' : false);
        });
    });
}

function setMaintenanceMode(status) {
    return new Promise((resolve) => {
        db.run(`INSERT OR REPLACE INTO bot_settings (key, value) VALUES ('maintenance', ?)`, [status], () => resolve());
    });
}

function createProgressBar(used, total, size = 10) {
    const percentage = Math.min(Math.max(used / total, 0), 1);
    const filledCount = Math.round(percentage * size);
    const emptyCount = size - filledCount;
    return `[${'█'.repeat(filledCount)}${'░'.repeat(emptyCount)}] ${(percentage * 100).toFixed(1)}%`;
}

function createCpuVisual(cpuUsageNum) {
    const boxSize = 10;
    const filled = Math.min(Math.round((cpuUsageNum / 100) * boxSize), boxSize);
    let bar = '▪️'.repeat(filled) + '▫️'.repeat(boxSize - filled);
    if (cpuUsageNum > 80) {
        return `🔴 High Load [${bar}] ${cpuUsageNum.toFixed(2)}%`;
    } else {
        return `⬛ Normal [${bar}] ${cpuUsageNum.toFixed(2)}%`;
    }
}

async function getSystemStatusData() {
    return new Promise((resolve) => {
        const botUptime = process.uptime();
        const days = Math.floor(botUptime / 86400);
        const hours = Math.floor((botUptime % 86400) / 3600);
        const minutes = Math.floor((botUptime % 3600) / 60);
        const seconds = Math.floor(botUptime % 60);
        const botUptimeStr = `${days}d ${hours}h ${minutes}m ${seconds}s`;

        const hostUptime = os.uptime();
        const hDays = Math.floor(hostUptime / 86400);
        const hHours = Math.floor((hostUptime % 86400) / 3600);
        const hMinutes = Math.floor((hostUptime % 3600) / 60);
        const hostUptimeStr = `${hDays}d ${hHours}h ${hMinutes}m`;

        const totalMem = os.totalmem() / (1024 * 1024 * 1024);
        const freeMem = os.freemem() / (1024 * 1024 * 1024);
        const usedMem = totalMem - freeMem;
        const memoryUsage = process.memoryUsage().rss / (1024 * 1024);

        const ramBar = createProgressBar(usedMem, totalMem);

        docker.listContainers({ all: true }, async (err, containers) => {
            const totalContainers = containers ? containers.length : 0;
            const runningContainers = containers ? containers.filter(c => c.State === 'running').length : 0;

            const embed = new EmbedBuilder()
                .setTitle('<:settings:1565422148607279145> FLOATIX System Status & Uptime')
                .setDescription(
                    `🤖 **Bot Uptime:** \`${botUptimeStr}\`\n` +
                    `🖥️ **Host Uptime:** \`${hostUptimeStr}\`\n\n` +
                    `<:ram:1565421341966860419> **Bot Memory Usage:** \`${memoryUsage.toFixed(2)} MB\`\n` +
                    `<:ram:1565421341966860419> **Host RAM:** \`${usedMem.toFixed(2)} GB / ${totalMem.toFixed(2)} GB\`\n${ramBar}\n\n` +
                    `<:Desktop:1565422603642863816> **Total Machines:** \`${totalContainers}\`\n` +
                    `<a:Fh_Online:1565400190335324271> **Running Machines:** \`${runningContainers}\``
                )
                .setColor('#00FF00')
                .setFooter({ text: 'Powered by FLOATIX (Auto-refreshes every 5m)' });

            resolve(embed);
        });
    });
}

async function getVpsStatusEmbed(containerId, ownerId, viewerId = null, customStatusText = null) {
    return new Promise((resolve) => {
        db.get(`SELECT expire_at, is_suspended, cpu, ram, disk, vps_number, user_id, purge_protection FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            let statusText = customStatusText || "<a:offline:1565400363207757914> Stopped";
            let isRunning = false;
            let color = '#FF0000';
            let uptimeStr = "Offline";
            let statsStr = "Loading...";
            
            let expireStr = row ? `<t:${Math.floor(row.expire_at/1000)}:R>` : "Unknown";
            let vpsNo = row ? row.vps_number : "1";
            let purgeProtStatus = row && row.purge_protection === 1 ? "<a:Lock:1565421690798866472> Enabled" : "<:unlock_:1565421832344174643> Disabled";

            if (row && row.is_suspended === 1) {
                statusText = "<:Suspended:1565400840942915685> SUSPENDED (Expired or Overloaded)";
                color = '#808080';
            }

            let cpuUsageNum = 0.00;
            let ramUsageMB = 0;
            let ramLimitMB = row ? row.ram * 1024 : 4096;

            try {
                const container = docker.getContainer(containerId);
                const data = await container.inspect();
                isRunning = data.State.Running;
                
                if (!customStatusText) {
                    if (isRunning && row && row.is_suspended === 0) {
                        statusText = "<a:Fh_Online:1565400190335324271> Running";
                        color = '#00FF00';
                        const startedAt = new Date(data.State.StartedAt).getTime();
                        uptimeStr = `<t:${Math.floor(startedAt/1000)}:R>`;
                    } else if (row && row.is_suspended === 0) {
                        statusText = "<a:offline:1565400363207757914> Stopped";
                        color = '#FF0000';
                    }
                }

                if (isRunning && row && row.is_suspended === 0) {
                    try {
                        const stats = await container.stats({ stream: false });
                        ramUsageMB = (stats.memory_stats.usage / (1024 * 1024)).toFixed(2);
                        
                        if (stats.cpu_stats && stats.precpu_stats) {
                            const cpuDelta = stats.cpu_stats.cpu_usage.total_usage - stats.precpu_stats.cpu_usage.total_usage;
                            const sysDelta = stats.cpu_stats.system_cpu_usage - stats.precpu_stats.system_cpu_usage;
                            if (sysDelta > 0 && cpuDelta > 0) cpuUsageNum = parseFloat(((cpuDelta / sysDelta) * 100).toFixed(2));
                        }
                    } catch(e) {}
                }
            } catch (e) {
                statusText = "<a:warning2:1565401070618943539> Error / Not Found";
                color = '#FFA500';
            }

            const ramBar = createProgressBar(parseFloat(ramUsageMB), ramLimitMB);
            const diskBar = createProgressBar(2.0, row ? row.disk : 10);
            const cpuVisualBox = createCpuVisual(cpuUsageNum);

            statsStr = `<a:BarChart:1565401245584195694> **Live Stats:**\n` +
                       `<:CPU:1565421194570891387> **CPU:** ${cpuVisualBox}\n` +
                       `<:ram:1565421341966860419> **RAM:** ${ramUsageMB} MB / ${ramLimitMB} MB\n${ramBar}\n` +
                       `<a:disk:1565421542144479252> **Disk:** 2.0 GB / ${row ? row.disk : 10} GB\n${diskBar}\n` +
                       `<a:Lock:1565421690798866472> **Purge Protection:** ${purgeProtStatus}`;

            const embed = new EmbedBuilder()
                .setTitle('<:settings:1565422148607279145> FLOATIX VPS Panel (Secure)')
                .setDescription(`**VPS No:** \`${vpsNo}\` | **ID:** \`${containerId.substring(0,8)}\`\n\n**Status:** ${statusText}\n**Uptime:** ${uptimeStr}\n**Expires:** ${expireStr}\n\n${statsStr}`)
                .setColor(color)
                .setFooter({ text: 'Powered by FLOATIX' });

            if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
            if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

            const isDisabled = row && row.is_suspended === 1;
            let isSharedUser = viewerId && row && row.user_id !== viewerId;

            const row1 = new ActionRowBuilder().addComponents(
                new ButtonBuilder().setCustomId(`start_${ownerId}_${containerId}`).setLabel('Start').setEmoji('<:Start:1565401546475307129>').setStyle(ButtonStyle.Success).setDisabled(isDisabled),
                new ButtonBuilder().setCustomId(`stop_${ownerId}_${containerId}`).setLabel('Stop').setEmoji('<a:off:1565401886041968720>').setStyle(ButtonStyle.Danger).setDisabled(isDisabled),
                new ButtonBuilder().setCustomId(`restart_${ownerId}_${containerId}`).setLabel('Restart').setEmoji('<:Restart:1565408841338855545>').setStyle(ButtonStyle.Primary).setDisabled(isDisabled),
                new ButtonBuilder().setCustomId(`sshx_${ownerId}_${containerId}`).setLabel('SSHX').setEmoji('<:sshx:1565410480854667307>').setStyle(ButtonStyle.Secondary).setDisabled(!isRunning || isDisabled)
            );

            let actionRowComponents = [
                new ButtonBuilder().setCustomId(`status_${ownerId}_${containerId}`).setLabel('Refresh').setEmoji('<a:refresh:1565402498636972163>').setStyle(ButtonStyle.Secondary),
                new ButtonBuilder().setCustomId(`ssh_${ownerId}_${containerId}`).setLabel('Web SSH').setEmoji('<:web:1565402847473049610>').setStyle(ButtonStyle.Primary).setDisabled(!isRunning || isDisabled)
            ];

            if (!isSharedUser) {
                actionRowComponents.unshift(
                    new ButtonBuilder().setCustomId(`reinstall_${ownerId}_${containerId}`).setLabel('Reinstall').setEmoji('<:return:1565402283661983744>').setStyle(ButtonStyle.Secondary).setDisabled(isDisabled)
                );
            }

            const row2 = new ActionRowBuilder().addComponents(actionRowComponents);
            
            resolve({ embed, buttons: [row1, row2] });
        });
    });
}

client.on('messageCreate', async (message) => {
    if (message.author.bot) return;

    const userPrefix = await getUserPrefix(message.author.id);
    const globalPrefix = defaultPrefix;

    let activePrefix = message.content.startsWith(userPrefix) ? userPrefix : (message.content.startsWith(globalPrefix) ? globalPrefix : null);
    if (!activePrefix) return;

    const args = message.content.slice(activePrefix.length).trim().split(/ +/);
    const command = args.shift().toLowerCase();

    const isMain = await isMainAdmin(message.author.id);
    const checkAdmin = await isAdmin(message.author.id);
    const maintenance = await getMaintenanceMode();

    if (maintenance && !checkAdmin && command !== 'help' && command !== 'manage') {
        return message.reply("🛠️ **Maintenance Mode is ON!** Bot is currently under maintenance. Only Admins can execute commands.");
    }

    if (command === 'setprefix') {
        const newPrefix = args[0];
        if (!newPrefix) return message.reply(`Usage: \`${userPrefix}setprefix <new_prefix>\``);
        db.run(`INSERT OR REPLACE INTO user_prefixes (user_id, prefix) VALUES (?, ?)`, [message.author.id, newPrefix], () => {
            message.reply(`✅ **Prefix updated successfully!** Your new prefix is now \`${newPrefix}\`.`);
        });
        return;
    }

    if (command === 'resetprefix') {
        db.run(`DELETE FROM user_prefixes WHERE user_id = ?`, [message.author.id], () => {
            message.reply(`✅ **Prefix reset successfully!** Your prefix is now back to default: \`${defaultPrefix}\`.`);
        });
        return;
    }

    if (command === 'help') {
        message.delete().catch(()=>{});
        const currentPrefix = await getUserPrefix(message.author.id);
        const row = new ActionRowBuilder().addComponents(
            new ButtonBuilder().setCustomId(`openhelp_${message.author.id}_${currentPrefix}`).setLabel('View Commands').setEmoji('<:helper:1565422421841019021>').setStyle(ButtonStyle.Success)
        );
        
        const isDM = !message.guild;
        if (isDM) {
            message.channel.send({ content: `Click below to view commands:`, components: [row] });
        } else {
            message.channel.send({ content: `<@${message.author.id}>, click below to view commands securely.`, components: [row] }).then(msg => setTimeout(() => msg.delete().catch(()=>{}), 15000));
        }
        return;
    }

    if (command === 'manage') {
        message.delete().catch(()=>{});
        const row = new ActionRowBuilder().addComponents(
            new ButtonBuilder().setCustomId(`openmanage_${message.author.id}`).setLabel('Open Private Panel').setEmoji('<:Desktop:1565422603642863816>').setStyle(ButtonStyle.Primary)
        );
        
        const isDM = !message.guild;
        if (isDM) {
            message.channel.send({ content: `Click below to open your panel:`, components: [row] });
        } else {
            message.channel.send({ content: `<@${message.author.id}>, click below to open your panel privately.`, components: [row] }).then(msg => setTimeout(() => msg.delete().catch(()=>{}), 15000));
        }
        return;
    }

    if (command === 'maintenance') {
        if (!isMain) return message.reply("❌ **ACCESS DENIED!** Only Main Admins can toggle maintenance mode.");
        const status = args[0] ? args[0].toLowerCase() : '';
        if (status !== 'on' && status !== 'off') return message.reply(`Usage: \`${userPrefix}maintenance on\` or \`${userPrefix}maintenance off\``);
        
        await setMaintenanceMode(status);
        return message.reply(`✅ **Maintenance Mode is now ${status.toUpperCase()}!**`);
    }

    if (command === 'addmain') {
        if (!isMain) return message.reply("❌ **ACCESS DENIED!** Only Main Admins can add another Main Admin.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        if (!target) return message.reply(`Usage: \`${userPrefix}addmain @user\` or user ID`);
        
        db.run(`INSERT OR REPLACE INTO bot_admins (user_id, type) VALUES (?, 'main')`, [target.id], (err) => {
            if (err) return message.reply("❌ Error adding Main Admin: " + err.message);
            message.reply(`✅ <@${target.id}> is now a **Main Admin** <a:crown_crown1:1565406300765167686>!`);
        });
        return;
    }

    if (command === 'addadmin') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can add admins.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        if (!target) return message.reply(`Usage: \`${userPrefix}addadmin @user\` or user ID`);
        
        db.run(`INSERT OR REPLACE INTO bot_admins (user_id, type) VALUES (?, 'admin')`, [target.id], (err) => {
            if (err) return message.reply("❌ Error adding Admin: " + err.message);
            message.reply(`✅ <@${target.id}> is now a Bot Admin <:Admin:1565406497372897390>!`);
        });
        return;
    }

    if (command === 'removeadmin') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can remove admins.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        if (!target) return message.reply(`Usage: \`${userPrefix}removeadmin @user\``);
        
        db.run(`DELETE FROM bot_admins WHERE user_id = ?`, [target.id], () => {
            message.reply(`✅ <@${target.id}> removed from Bot Admins.`);
        });
        return;
    }

    if (command === 'protect') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can set purge protection.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}protect @user <vps_number>\``);
        
        db.run(`UPDATE vps_list SET purge_protection = 1 WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], function(err) {
            if (this.changes === 0) return message.reply("❌ VPS not found for this user.");
            message.reply(`🛡️ Purge Protection **Enabled** for VPS No: **${vpsNo}** (<@${target.id}>).`);
        });
        return;
    }

    if (command === 'unprotect') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can remove purge protection.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}unprotect @user <vps_number>\``);
        
        db.run(`UPDATE vps_list SET purge_protection = 0 WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], function(err) {
            if (this.changes === 0) return message.reply("❌ VPS not found for this user.");
            message.reply(`⚠️ Purge Protection **Disabled** for VPS No: **${vpsNo}** (<@${target.id}>).`);
        });
        return;
    }

    if (command === 'uptime') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can check system uptime.");

        const initialEmbed = await getSystemStatusData();
        const sentMsg = await message.reply({ embeds: [initialEmbed] });

        const intervalId = setInterval(async () => {
            try {
                const fetchedMsg = await sentMsg.channel.messages.fetch(sentMsg.id).catch(() => null);
                if (!fetchedMsg) {
                    clearInterval(intervalId);
                    return;
                }
                const updatedEmbed = await getSystemStatusData();
                await sentMsg.edit({ embeds: [updatedEmbed] }).catch(() => {
                    clearInterval(intervalId);
                });
            } catch (e) {
                clearInterval(intervalId);
            }
        }, 300000);

        return;
    }

    if (command === 'vps' && args[0] === 'list') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can view all VPS list.");
        
        db.all(`SELECT DISTINCT user_id FROM vps_list`, async (err, rows) => {
            if (!rows || rows.length === 0) return message.reply("❌ No VPS found in database.");
            
            const options = rows.map(r => ({
                label: `User ID: ${r.user_id}`,
                description: `Click to view this user's VPS list`,
                value: `vpsuser_${r.user_id}`
            }));

            const row = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`adminvpsuser_${message.author.id}`).setPlaceholder('Select User to view VPS...').addOptions(options)
            );
            const embed = new EmbedBuilder().setTitle('📋 Admin VPS Manager - Select User').setDescription('Choose a user from the dropdown below to check their VPS.').setColor('#0099ff');
            
            const isDM = !message.guild;
            message.reply({ embeds: [embed], components: [row], ephemeral: !isDM });
        });
        return;
    }

    if (command === 'admin' && args[0] === 'list') {
        if (!isMain) return message.reply("❌ **ACCESS DENIED!** Only Main Admins can view admin list.");

        db.all(`SELECT user_id, type FROM bot_admins`, async (err, adminRows) => {
            let admins = adminRows ? adminRows : [];

            if (admins.length === 0) return message.reply("❌ No Admin users found.");

            const options = admins.map(a => ({
                label: `Admin ID: ${a.user_id} [${a.type.toUpperCase()}]`,
                description: `Manage this admin's VPS and Access`,
                value: `manageadmin_${a.user_id}`
            }));

            const row = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`adminlistmenu_${message.author.id}`).setPlaceholder('Select Admin User...').addOptions(options)
            );
            const embed = new EmbedBuilder().setTitle('🛡️ Main Admin Panel - Admin List').setDescription('Select an admin from the menu to manage their permissions and VPS.').setColor('#FF0000');
            
            const isDM = !message.guild;
            message.reply({ embeds: [embed], components: [row], ephemeral: !isDM });
        });
        return;
    }

    if (command === 'create') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can create VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const ram = parseInt(args[1]); const cpu = parseInt(args[2]); const disk = parseInt(args[3]); const timeStr = args[4]; 
        if (!target || !ram || !cpu || !disk || !timeStr) return message.reply(`Usage: \`${userPrefix}create @user <ram(GB)> <cpu(Cores)> <disk(GB)> <time(30m/2h/1d)>\``);
        
        db.get(`SELECT MAX(vps_number) as max_no FROM vps_list WHERE user_id = ?`, [target.id], async (err, row) => {
            const vpsNo = (row && row.max_no) ? row.max_no + 1 : 1;
            const expireDate = Date.now() + parseTime(timeStr);
            
            const msg = await message.reply(`⏳ Creating Docker VPS (No: ${vpsNo}) for <@${target.id}>...`);
            try {
                const container = await docker.createContainer({
                    Image: 'ubuntu:22.04', Tty: true, OpenStdin: true, Cmd: ['/bin/bash'], 
                    HostConfig: {
                        NanoCpus: cpu * 1000000000, Memory: ram * 1024 * 1024 * 1024, DiskQuota: disk * 1024 * 1024 * 1024,
                        Privileged: true, CapAdd: ['NET_ADMIN', 'SYS_ADMIN', 'SYS_PTRACE'], SecurityOpt: ['seccomp=unconfined', 'apparmor=unconfined'],
                        Binds: ['/sys/fs/cgroup:/sys/fs/cgroup:rw']
                    }
                });
                await container.start();
                db.run(`INSERT INTO vps_list (container_id, user_id, vps_number, cpu, ram, disk, expire_at, is_suspended, purge_protection) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)`,
                    [container.id, target.id, vpsNo, cpu, ram, disk, expireDate]);
                
                const embed = new EmbedBuilder()
                    .setTitle('<a:Success:1565403959823442041> VPS Created Successfully!')
                    .setDescription(`**User:** <@${target.id}>\n**VPS No:** \`${vpsNo}\`\n**RAM:** ${ram}GB | **CPU:** ${cpu} Core | **Disk:** ${disk}GB\n**Expire:** <t:${Math.floor(expireDate/1000)}:R>`)
                    .setColor('#00FF00')
                    .setFooter({ text: 'Powered by FLOATIX' });
                
                msg.edit({ content: '', embeds: [embed] });

                const rawToken = crypto.randomBytes(3).toString('hex').toUpperCase(); 
                const pass = `token_${rawToken}`;
                const port = 7681;
                exec(`pkill ttyd`, () => {
                    setTimeout(() => {
                        const scriptContent = `#!/bin/bash\nnohup ttyd -p ${port} -c root:${pass} -W -t rendererType=canvas -t disableLeaveAlert=true -t theme='{"background":"#000000","foreground":"#00FF00","cursor":"#00FF00"}' docker exec -it ${container.id} bash > /dev/null 2>&1 &\n`;
                        fs.writeFileSync('/tmp/start_ttyd.sh', scriptContent, { mode: 0755 });
                        exec(`bash /tmp/start_ttyd.sh`);
                        
                        client.users.fetch(target.id).then(u => {
                            const link = process.env.WEB_URL;
                            const dmEmbed = new EmbedBuilder()
                                .setTitle('🎉 Your New Docker VPS is Ready!')
                                .setDescription(`**VPS No:** \`${vpsNo}\`\n<:linkk:1565412446422835231> **Web Terminal Link:** \`${link}\`\n👤 **Username:** \`root\`\n<a:key:1565412483810730056> **Password:** \`${pass}\`\n\nType \`${userPrefix}manage\` in the server to control your VPS!`)
                                .setColor('#00FF00')
                                .setFooter({ text: 'Powered by FLOATIX' });
                            if (process.env.LOGO_URL) dmEmbed.setThumbnail(process.env.LOGO_URL);
                            if (process.env.BANNER_URL) dmEmbed.setImage(process.env.BANNER_URL);

                            const copyRow = new ActionRowBuilder().addComponents(
                                new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(link).setLabel('🔗 Open Terminal'),
                                new ButtonBuilder().setCustomId(`copypass_${pass}`).setLabel('📋 Copy Password').setStyle(ButtonStyle.Secondary)
                            );

                            u.send({ embeds: [dmEmbed], components: [copyRow] }).catch(()=>{});
                        });
                    }, 1000);
                });

            } catch (e) { msg.edit("❌ Error: " + e.message); }
        });
    }

    if (command === 'delete') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can delete VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}delete @user <vps_number>\``);
        db.get(`SELECT container_id, purge_protection FROM vps_list WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], async (err, row) => {
            if (!row) return message.reply("❌ VPS not found.");
            if (row.purge_protection === 1 && !isMain) return message.reply("❌ **Purge Protection is Enabled!** Only Main Admins can delete this VPS.");
            try {
                const container = docker.getContainer(row.container_id);
                await container.stop().catch(()=>{}); await container.remove({ force: true }).catch(()=>{});
                db.run(`DELETE FROM vps_list WHERE container_id = ?`, [row.container_id]); db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [row.container_id]);
                message.reply(`✅ VPS No: **${vpsNo}** deleted successfully.`);
                client.users.fetch(target.id).then(u => { 
                    u.send(`⚠️ **Alert!** Your VPS (No: \`${vpsNo}\`) has been deleted by Admin <@${message.author.id}>.`); 
                }).catch(()=>{});
            } catch(e) { message.reply(`❌ Error deleting VPS.`); }
        });
    }

    if (command === 'purge') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can purge VPS.");
        
        let query = `SELECT * FROM vps_list WHERE purge_protection = 0 ORDER BY RANDOM()`;
        db.all(query, async (err, rows) => {
            if (!rows || rows.length === 0) return message.reply("❌ No unprotected VPS found to purge.");
            const msg = await message.reply(`<a:alert:1565404039770800159> **PURGE INITIATED!** Deleting ${rows.length} unprotected VPS...`);
            let purgedList = [];
            for (const row of rows) {
                try {
                    const container = docker.getContainer(row.container_id);
                    await container.stop().catch(()=>{});
                    await container.remove({ force: true }).catch(()=>{});
                    db.run(`DELETE FROM vps_list WHERE container_id = ?`, [row.container_id]);
                    db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [row.container_id]);
                    purgedList.push(`- <@${row.user_id}> (VPS No: **${row.vps_number}**)`);
                    client.users.fetch(row.user_id).then(u => {
                        u.send(`<a:alert:1565404039770800159> **System Purge Alert!** Your VPS (No: \`${row.vps_number}\`) has been permanently deleted during a server purge by Admin <@${message.author.id}>.`);
                    }).catch(()=>{});
                } catch (e) {}
            }
            const embed = new EmbedBuilder().setTitle('<a:Success:1565403959823442041> Purge Complete!').setDescription(`**${rows.length} VPS Destroyed!**\n\n**Purged List:**\n${purgedList.join('\n')}`).setColor('#FF0000');
            msg.edit({ content: '', embeds: [embed] });
        });
    }

    if (command === 'suspend') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can suspend VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}suspend @user <vps_number>\``);
        db.get(`SELECT container_id FROM vps_list WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], async (err, row) => {
            if (!row) return message.reply("❌ VPS not found.");
            db.run(`UPDATE vps_list SET is_suspended = 1 WHERE container_id = ?`, [row.container_id]);
            try { await docker.getContainer(row.container_id).stop().catch(()=>{}); } catch(e) {}
            message.reply(`✅ VPS No: **${vpsNo}** has been **SUSPENDED**.`);
            client.users.fetch(target.id).then(u => { u.send(`<a:alert:1565404039770800159> **Alert!** Your VPS (No: \`${vpsNo}\`) has been Suspended by Admin <@${message.author.id}>.`); }).catch(()=>{});
        });
    }

    if (command === 'unsuspend') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can unsuspend VPS.");
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}unsuspend @user <vps_number>\``);
        db.get(`SELECT container_id FROM vps_list WHERE user_id = ? AND vps_number = ?`, [target.id, vpsNo], (err, row) => {
            if (!row) return message.reply("❌ VPS not found.");
            db.run(`UPDATE vps_list SET is_suspended = 0 WHERE container_id = ?`, [row.container_id]);
            message.reply(`✅ VPS No: **${vpsNo}** is now **UNSUSPENDED**.`);
            client.users.fetch(target.id).then(u => { u.send(`<a:Success:1565403959823442041> **Good News!** Your VPS (No: \`${vpsNo}\`) has been Unsuspended by Admin <@${message.author.id}>.`); }).catch(()=>{});
        });
    }

    if (command === 'renew') {
        if (!checkAdmin) return message.reply("❌ **ACCESS DENIED!** Only Admins can renew VPS.");
        const vpsNo = parseInt(args[0]); 
        const timeStr = args[1]; 
        let targetId = message.author.id;
        
        if (message.mentions.users.first()) { 
            targetId = message.mentions.users.first().id; 
            if (!args[2] && !timeStr) return message.reply(`Usage: \`${userPrefix}renew <vps_number> <time> [@user]\``); 
        }

        db.get(`SELECT container_id, expire_at FROM vps_list WHERE user_id = ? AND vps_number = ?`, [targetId, vpsNo], (err, row) => {
            if (!row) return message.reply("❌ VPS not found for this user.");
            
            const baseTime = Math.max(row.expire_at, Date.now());
            const newTime = baseTime + parseTime(timeStr);
            
            db.run(`UPDATE vps_list SET expire_at = ?, is_suspended = 0 WHERE container_id = ?`, [newTime, row.container_id]);
            message.reply(`✅ VPS No: **${vpsNo}** renewed successfully! New Expiry: <t:${Math.floor(newTime/1000)}:R>`);
            
            client.users.fetch(targetId).then(u => { 
                u.send(`<a:Success:1565403959823442041> Your VPS (No: \`${vpsNo}\`) has been renewed by Admin <@${message.author.id}>! New Expiry: <t:${Math.floor(newTime/1000)}:R>`); 
            }).catch(()=>{});
        });
    }

    if (command === 'share') {
        const target = message.mentions.users.first() || (args[0] ? client.users.cache.get(args[0].replace(/[<@!>]/g, '')) : null);
        const vpsNo = parseInt(args[1]);
        if (!target || !vpsNo) return message.reply(`Usage: \`${userPrefix}share @user <vps_number>\``);
        db.get(`SELECT container_id FROM vps_list WHERE user_id = ? AND vps_number = ?`, [message.author.id, vpsNo], (err, row) => {
            if (!row) return message.reply("❌ VPS not found or you don't own it.");
            db.run(`INSERT INTO shared_vps (container_id, shared_user_id) VALUES (?, ?)`, [row.container_id, target.id]);
            message.reply(`<:share:1565403805187702804> VPS No: **${vpsNo}** is now shared with <@${target.id}>! They can manage it using \`${userPrefix}manage\`.`);
            client.users.fetch(target.id).then(u => { u.send(`🎁 **Gift!** <@${message.author.id}> has shared their **VPS No: ${vpsNo}** with you. Type \`${userPrefix}manage\` to access it!`); }).catch(()=>{});
        });
    }
});

client.on('interactionCreate', async (interaction) => {
    if (!interaction.isStringSelectMenu() && !interaction.isButton()) return;
    const parts = interaction.customId.split('_');
    const action = parts[0];
    const ownerId = parts[1];

    const isDM = !interaction.guild;

    if (action === 'copypass') {
        const tokenVal = parts.slice(1).join('_');
        return interaction.reply({ content: `📋 **Password / Link:** \`${tokenVal}\``, ephemeral: true });
    }

    if (action === 'openhelp') {
        await interaction.deferReply({ ephemeral: !isDM });
        const userPrefix = parts[2] || defaultPrefix;
        const row = new ActionRowBuilder().addComponents(
            new StringSelectMenuBuilder().setCustomId(`helpmenu_${ownerId}_${userPrefix}`)
            .setPlaceholder('Select Help Category...')
            .addOptions([
                { label: 'Admin Commands', description: 'View admin commands', value: 'admin' },
                { label: 'User Commands', description: 'View user commands', value: 'user' }
            ])
        );
        const embed = new EmbedBuilder().setTitle('<:helper:1565422421841019021> VPS Manager - Help').setDescription('Select a category from the dropdown below.').setColor('#0099ff').setFooter({ text: 'Powered by FLOATIX' });
        if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
        if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);
        await interaction.editReply({ embeds: [embed], components: [row] });
        return;
    }

    if (action === 'helpmenu') {
        await interaction.deferUpdate();
        const val = interaction.values[0];
        const userPrefix = parts[2] || defaultPrefix;
        let replyEmbed;
        if (val === 'admin') {
            replyEmbed = new EmbedBuilder()
                .setTitle('<:helper:1565422421841019021> Admin Commands')
                .setDescription(`\`${userPrefix}create @user <ram> <cpu> <disk> <time>\`\n\`${userPrefix}renew <vps_no> <time> [@user]\`\n\`${userPrefix}suspend @user <vps_no>\`\n\`${userPrefix}unsuspend @user <vps_no>\`\n\`${userPrefix}delete @user <vps_no>\`\n\`${userPrefix}purge all / <no>\`\n\`${userPrefix}protect @user <vps_no>\`\n\`${userPrefix}unprotect @user <vps_no>\`\n\`${userPrefix}addadmin @user\`\n\`${userPrefix}removeadmin @user\`\n\`${userPrefix}addmain @user\`\n\`${userPrefix}maintenance on/off\`\n\`${userPrefix}vps list\`\n\`${userPrefix}admin list\`\n\`${userPrefix}uptime\``)
                .setColor('#FF0000')
                .setFooter({ text: 'Powered by FLOATIX' });
        } else {
            replyEmbed = new EmbedBuilder()
                .setTitle('<:helper:1565422421841019021> User Commands')
                .setDescription(`\`${userPrefix}manage\` - Open Private Panel\n\`${userPrefix}share @user <vps_no>\` - Share your VPS\n\`${userPrefix}setprefix <prefix>\` - Set Custom Prefix\n\`${userPrefix}resetprefix\` - Reset Prefix`)
                .setColor('#00FF00')
                .setFooter({ text: 'Powered by FLOATIX' });
        }
        if (process.env.LOGO_URL) replyEmbed.setThumbnail(process.env.LOGO_URL);
        if (process.env.BANNER_URL) replyEmbed.setImage(process.env.BANNER_URL);
        await interaction.editReply({ embeds: [replyEmbed] });
        return;
    }

    if (ownerId && interaction.user.id !== ownerId && !['adminvpsuser', 'adminlistmenu', 'vpsuserselect', 'manageadminuser', 'adminvpsaction'].includes(action)) {
        return interaction.reply({ content: '❌ **ACCESS DENIED!** This is locked to another user.', ephemeral: true });
    }

    if (action === 'adminvpsuser') {
        await interaction.deferUpdate();
        const targetUserId = interaction.values[0].replace('vpsuser_', '');
        db.all(`SELECT container_id, vps_number FROM vps_list WHERE user_id = ?`, [targetUserId], async (err, rows) => {
            if (!rows || rows.length === 0) return interaction.editReply({ content: "❌ This user has no VPS.", components: [] });
            
            const options = rows.map(r => ({
                label: `VPS No: ${r.vps_number} (ID: ${r.container_id.substring(0,8)})`,
                description: `Manage or Delete this VPS`,
                value: `vpsmanage_${r.container_id}`
            }));

            const row = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`vpsuserselect_${interaction.user.id}`).setPlaceholder('Select VPS to Manage/Delete...').addOptions(options)
            );
            const embed = new EmbedBuilder().setTitle(`<:k9user:1565422798065901742> VPS List for User <@${targetUserId}>`).setDescription('Select a VPS below to view panel or delete it.').setColor('#0099ff');
            await interaction.editReply({ embeds: [embed], components: [row] });
        });
        return;
    }

    if (action === 'vpsuserselect') {
        const containerId = interaction.values[0].replace('vpsmanage_', '');
        db.get(`SELECT user_id FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            if (!row) return interaction.reply({ content: "❌ VPS not found.", ephemeral: true });
            const { embed, buttons } = await getVpsStatusEmbed(containerId, row.user_id, interaction.user.id);
            const deleteBtn = new ActionRowBuilder().addComponents(
                new ButtonBuilder().setCustomId(`admindeletevps_${row.user_id}_${containerId}`).setLabel('Delete This VPS').setStyle(ButtonStyle.Danger)
            );
            await interaction.reply({ embeds: [embed], components: [...buttons, deleteBtn], ephemeral: !isDM });
        });
        return;
    }

    if (action === 'admindeletevps') {
        await interaction.deferUpdate();
        const containerId = parts[2];
        db.get(`SELECT user_id, vps_number FROM vps_list WHERE container_id = ?`, [containerId], async (err, vpsRow) => {
            try {
                const container = docker.getContainer(containerId);
                await container.stop().catch(()=>{});
                await container.remove({ force: true }).catch(()=>{});
                db.run(`DELETE FROM vps_list WHERE container_id = ?`, [containerId]);
                db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [containerId]);
                
                if (vpsRow) {
                    client.users.fetch(vpsRow.user_id).then(u => {
                        u.send(`⚠️ **Alert!** Your VPS (No: \`${vpsRow.vps_number}\`) has been deleted by Admin <@${interaction.user.id}> via Admin Panel.`);
                    }).catch(()=>{});
                }

                await interaction.editReply({ content: '✅ **VPS successfully deleted by Admin!**', embeds: [], components: [] });
            } catch (e) {
                await interaction.editReply({ content: `❌ Error deleting VPS: ${e.message}`, embeds: [], components: [] });
            }
        });
        return;
    }

    if (action === 'adminlistmenu') {
        await interaction.deferUpdate();
        const selectedAdminId = interaction.values[0].replace('manageadmin_', '');

        db.all(`SELECT container_id, vps_number FROM vps_list WHERE user_id = ?`, [selectedAdminId], async (err, rows) => {
            const vpsCount = rows ? rows.length : 0;
            const embed = new EmbedBuilder()
                .setTitle(`🛡️ Managing Admin: <@${selectedAdminId}>`)
                .setDescription(`**Total VPS Owned:** \`${vpsCount}\`\n\nChoose an action below for this admin:`)
                .setColor('#FF0000');

            const options = rows && rows.length > 0 ? rows.map(r => ({
                label: `VPS No: ${r.vps_number}`,
                value: `adminvps_${r.container_id}`
            })) : [{ label: 'No VPS Found', value: 'none' }];

            const row1 = new ActionRowBuilder().addComponents(
                new StringSelectMenuBuilder().setCustomId(`adminvpsaction_${selectedAdminId}`).setPlaceholder('View Specific VPS...').addOptions(options)
            );

            const row2 = new ActionRowBuilder().addComponents(
                new ButtonBuilder().setCustomId(`removerole_${selectedAdminId}`).setLabel('Remove Admin Access').setStyle(ButtonStyle.Danger),
                new ButtonBuilder().setCustomId(`deleteAllVps_${selectedAdminId}`).setLabel('Delete All VPS of Admin').setStyle(ButtonStyle.Danger)
            );

            await interaction.editReply({ embeds: [embed], components: [row1, row2] });
        });
        return;
    }

    if (action === 'adminvpsaction') {
        const containerId = interaction.values[0];
        if (containerId === 'none') return interaction.reply({ content: '❌ This admin has no VPS.', ephemeral: !isDM });
        db.get(`SELECT user_id FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            if (!row) return interaction.reply({ content: '❌ VPS not found.', ephemeral: !isDM });
            const { embed, buttons } = await getVpsStatusEmbed(containerId, row.user_id, interaction.user.id);
            await interaction.reply({ embeds: [embed], components: buttons, ephemeral: !isDM });
        });
        return;
    }

    if (action === 'removerole') {
        await interaction.deferUpdate();
        const targetAdminId = parts[2];
        db.run(`DELETE FROM bot_admins WHERE user_id = ?`, [targetAdminId]);
        await interaction.editReply({ content: `✅ **Admin access removed successfully for <@${targetAdminId}>!**`, embeds: [], components: [] });
        return;
    }

    if (action === 'deleteAllVps') {
        await interaction.deferUpdate();
        const targetAdminId = parts[2];
        db.all(`SELECT container_id, vps_number FROM vps_list WHERE user_id = ?`, [targetAdminId], async (err, rows) => {
            if (!rows || rows.length === 0) return interaction.followUp({ content: '❌ This admin has no VPS to delete.', ephemeral: !isDM });
            for (const r of rows) {
                try {
                    const c = docker.getContainer(r.container_id);
                    await c.stop().catch(()=>{});
                    await c.remove({ force: true }).catch(()=>{});
                    client.users.fetch(targetAdminId).then(u => {
                        u.send(`⚠️ **Alert!** Your VPS (No: \`${r.vps_number}\`) has been deleted along with all admin VPS by Admin <@${interaction.user.id}>.`);
                    }).catch(()=>{});
                } catch(e){}
                db.run(`DELETE FROM vps_list WHERE container_id = ?`, [r.container_id]);
                db.run(`DELETE FROM shared_vps WHERE container_id = ?`, [r.container_id]);
            }
            await interaction.editReply({ content: `✅ **All VPS of Admin <@${targetAdminId}> have been permanently deleted!**`, embeds: [], components: [] });
        });
        return;
    }

    if (action === 'openmanage') {
        await interaction.deferReply({ ephemeral: !isDM });
        db.all(`SELECT DISTINCT v.container_id, v.vps_number, v.user_id, CASE WHEN v.user_id = ? THEN 'Owned' ELSE 'Shared' END as status FROM vps_list v LEFT JOIN shared_vps s ON v.container_id = s.container_id WHERE v.user_id = ? OR s.shared_user_id = ?`, [ownerId, ownerId, ownerId], (err, rows) => {
            if (!rows || rows.length === 0) return interaction.editReply({ content: "❌ You don't have any VPS!" });
            const options = rows.map(row => ({ label: row.status === 'Owned' ? `👑 VPS No: ${row.vps_number}` : `🤝 Shared VPS No: ${row.vps_number}`, description: `ID: ${row.container_id.substring(0,8)}...`, value: row.container_id }));
            const rowUI = new ActionRowBuilder().addComponents(new StringSelectMenuBuilder().setCustomId(`selectvps_${ownerId}`).setPlaceholder('Select your VPS...').addOptions(options));
            const embed = new EmbedBuilder().setTitle('<:Desktop:1565422603642863816> VPS Manager').setDescription('Select your VPS.').setColor('#2F3136').setFooter({ text: 'Powered by FLOATIX' });
            if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
            if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);
            interaction.editReply({ embeds: [embed], components: [rowUI] });
        });
        return;
    }

    if (action === 'selectvps') {
        await interaction.deferUpdate();
        const containerId = interaction.values[0];
        const { embed, buttons } = await getVpsStatusEmbed(containerId, ownerId, ownerId);
        await interaction.editReply({ embeds: [embed], components: buttons });
        return;
    }

    if (['start', 'stop', 'restart', 'sshx', 'status', 'ssh', 'reinstall'].includes(action)) {
        const containerId = parts[2]; 
        db.get(`SELECT is_suspended, cpu, ram, disk, vps_number, user_id FROM vps_list WHERE container_id = ?`, [containerId], async (err, row) => {
            if (!row) return interaction.reply({ content: '❌ **ERROR!** VPS record not found.', ephemeral: !isDM });
            
            if (action === 'reinstall' && row.user_id !== ownerId) {
                return interaction.reply({ content: '❌ **ACCESS DENIED!** Shared users cannot reinstall VPS.', ephemeral: !isDM });
            }

            if (row.is_suspended === 1 && action !== 'status') return interaction.reply({ content: '❌ **ERROR!** VPS is Suspended.', ephemeral: !isDM });

            if (action === 'start') {
                const container = docker.getContainer(containerId);
                const data = await container.inspect();
                if (data.State.Running) {
                    return interaction.reply({ content: '⚠️ **VPS is already running!**', ephemeral: !isDM });
                }

                await interaction.deferUpdate();
                const startingEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId, "🟡 **VPS is starting...**");
                await interaction.message.edit({ embeds: [startingEmbed.embed], components: startingEmbed.buttons });

                await container.start().catch(()=>{});

                const startedEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [startedEmbed.embed], components: startedEmbed.buttons });
            } else if (action === 'stop') {
                const container = docker.getContainer(containerId);
                const data = await container.inspect();
                if (!data.State.Running) {
                    return interaction.reply({ content: '⚠️ **VPS is already stopped!**', ephemeral: !isDM });
                }

                await interaction.deferUpdate();
                const stoppingEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId, "🟡 **VPS is stopping...**");
                await interaction.message.edit({ embeds: [stoppingEmbed.embed], components: stoppingEmbed.buttons });

                await container.stop().catch(()=>{});

                const stoppedEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [stoppedEmbed.embed], components: stoppedEmbed.buttons });
            } else if (action === 'restart') {
                await interaction.deferUpdate();
                const restartingEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId, "🟡 **VPS is restarting...**");
                await interaction.message.edit({ embeds: [restartingEmbed.embed], components: restartingEmbed.buttons });

                const container = docker.getContainer(containerId);
                await container.restart().catch(()=>{});

                const restartedEmbed = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [restartedEmbed.embed], components: restartedEmbed.buttons });
            } else if (action === 'status') {
                await interaction.deferUpdate();
                const { embed, buttons } = await getVpsStatusEmbed(containerId, ownerId, ownerId);
                await interaction.message.edit({ embeds: [embed], components: buttons });
            } else if (action === 'ssh') {
                await interaction.deferReply({ ephemeral: !isDM });
                const rawToken = crypto.randomBytes(3).toString('hex').toUpperCase();
                const pass = `token_${rawToken}`;
                const port = 7681; 
                exec(`pkill ttyd`, () => {
                    setTimeout(() => {
                        const scriptContent = `#!/bin/bash\nnohup ttyd -p ${port} -c root:${pass} -W -t rendererType=canvas -t disableLeaveAlert=true -t ctrlKey=true -t enableControlKeys=true -t titleFixed="FLOATIX Terminal" -t theme='{"background":"#000000","foreground":"#00FF00","cursor":"#00FF00"}' docker exec -it ${containerId} bash > /dev/null 2>&1 &\n`;
                        fs.writeFileSync('/tmp/start_ttyd.sh', scriptContent, { mode: 0755 });
                        exec(`bash /tmp/start_ttyd.sh`);
                        const link = process.env.WEB_URL;
                        const embed = new EmbedBuilder()
                            .setTitle('🖥️ Web Terminal Ready!')
                            .setDescription(`<:linkk:1565412446422835231> **Link:** \`${link}\`\n👤 **Username:** \`root\`\n<a:key:1565412483810730056> **Password:** \`${pass}\``)
                            .setColor('#00FF00')
                            .setFooter({ text: 'Powered by FLOATIX' });
                        if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
                        if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

                        const copyRow = new ActionRowBuilder().addComponents(
                            new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(link).setLabel('🔗 Open Terminal'),
                            new ButtonBuilder().setCustomId(`copypass_${pass}`).setLabel('📋 Copy Password').setStyle(ButtonStyle.Secondary)
                        );

                        interaction.editReply({ embeds: [embed], components: [copyRow] });
                    }, 1500);
                });
            } else if (action === 'sshx') {
                await interaction.deferReply({ ephemeral: !isDM });
                const initialEmbed = new EmbedBuilder()
                    .setTitle('<a:rocket:1565421978997887158> SSHX Session Initializing...')
                    .setDescription('```ansi\n\u001b[33m[INFO] Initializing SSHX session...\u001b[0m\n```')
                    .setColor('#FFA500')
                    .setFooter({ text: 'Powered by FLOATIX' });
                if (process.env.LOGO_URL) initialEmbed.setThumbnail(process.env.LOGO_URL);
                if (process.env.BANNER_URL) initialEmbed.setImage(process.env.BANNER_URL);
                
                await interaction.editReply({ embeds: [initialEmbed] });

                const container = docker.getContainer(containerId);
                const sshxCommand = `if ! command -v sshx &> /dev/null; then apt update && apt install sudo -y && apt install curl -y && curl -sSf https://sshx.io/get | sh; else printf '\\x03'; fi; sshx`;

                const execInstance = await container.exec({
                    Cmd: ['bash', '-c', sshxCommand],
                    AttachStdout: true,
                    AttachStderr: true
                });

                execInstance.start((err, stream) => {
                    let output = '';
                    stream.on('data', async (chunk) => {
                        output += chunk.toString();
                        let cleanOutput = output.replace(/\u001b\[[0-9;]*m/g, '');
                        let match = cleanOutput.match(/https:\/\/sshx\.io\/s\/[a-zA-Z0-9#\-_]+/);
                        let sshxLink = match ? match[0] : "Initializing live logs...";
                        
                        const liveEmbed = new EmbedBuilder()
                            .setTitle('<a:rocket:1565421978997887158> Live SSHX Session Logs')
                            .setDescription(`<:linkk:1565412446422835231> **Current SSHX Link:** \`${sshxLink}\`\n\`\`\`ansi\n${output.slice(-1500)}\n\`\`\``)
                            .setColor('#00FF00')
                            .setFooter({ text: 'Powered by FLOATIX' });
                        if (process.env.LOGO_URL) liveEmbed.setThumbnail(process.env.LOGO_URL);
                        if (process.env.BANNER_URL) liveEmbed.setImage(process.env.BANNER_URL);

                        const liveRow = new ActionRowBuilder().addComponents(
                            new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(sshxLink !== "Initializing live logs..." ? sshxLink : "https://sshx.io").setLabel('🚀 Open SSHX Session').setDisabled(sshxLink === "Initializing live logs..."),
                            new ButtonBuilder().setCustomId(`copypass_${sshxLink}`).setLabel('📋 Copy SSHX Link').setStyle(ButtonStyle.Secondary).setDisabled(sshxLink === "Initializing live logs...")
                        );
                        
                        try {
                            await interaction.editReply({ embeds: [liveEmbed], components: [liveRow] });
                        } catch(e) {}
                    });

                    stream.on('end', async () => {
                        let cleanOutput = output.replace(/\u001b\[[0-9;]*m/g, '');
                        let match = cleanOutput.match(/https:\/\/sshx\.io\/s\/[a-zA-Z0-9#\-_]+/);
                        let sshxLink = match ? match[0] : "Check logs inside terminal";
                        
                        const finalEmbed = new EmbedBuilder()
                            .setTitle('<a:rocket:1565421978997887158> SSHX Session Ready!')
                            .setDescription(`<:linkk:1565412446422835231> **Final SSHX Link:** \`${sshxLink}\`\n\`\`\`ansi\n${output.slice(-1500)}\n\`\`\``)
                            .setColor('#00FF00')
                            .setFooter({ text: 'Powered by FLOATIX' });
                        if (process.env.LOGO_URL) finalEmbed.setThumbnail(process.env.LOGO_URL);
                        if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

                        const sshxRow = new ActionRowBuilder().addComponents(
                            new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(sshxLink !== "Check logs inside terminal" ? sshxLink : "https://sshx.io").setLabel('🚀 Open SSHX Session'),
                            new ButtonBuilder().setCustomId(`copypass_${sshxLink}`).setLabel('📋 Copy SSHX Link').setStyle(ButtonStyle.Secondary)
                        );
                        
                        await interaction.editReply({ embeds: [finalEmbed], components: [sshxRow] });
                        client.users.fetch(ownerId).then(u => {
                            u.send(`🚀 **Your SSHX Link for VPS No: ${row.vps_number}**\n<:linkk:1565412446422835231> Link: \`${sshxLink}\``);
                        }).catch(()=>{});
                    });
                });
            } else if (action === 'reinstall') {
                await interaction.deferReply({ ephemeral: !isDM });
                try {
                    const oldContainer = docker.getContainer(containerId);
                    await oldContainer.stop().catch(()=>{});
                    await oldContainer.remove({ force: true }).catch(()=>{});

                    const newContainer = await docker.createContainer({
                        Image: 'ubuntu:22.04', Tty: true, OpenStdin: true, Cmd: ['/bin/bash'], 
                        HostConfig: {
                            NanoCpus: row.cpu * 1000000000, Memory: row.ram * 1024 * 1024 * 1024, DiskQuota: row.disk * 1024 * 1024 * 1024,
                            Privileged: true, CapAdd: ['NET_ADMIN', 'SYS_ADMIN', 'SYS_PTRACE'], SecurityOpt: ['seccomp=unconfined', 'apparmor=unconfined'],
                            Binds: ['/sys/fs/cgroup:/sys/fs/cgroup:rw']
                        }
                    });
                    await newContainer.start();

                    db.run(`UPDATE vps_list SET container_id = ? WHERE container_id = ?`, [newContainer.id, containerId]);
                    db.run(`UPDATE shared_vps SET container_id = ? WHERE container_id = ?`, [newContainer.id, containerId]);

                    const rawToken = crypto.randomBytes(3).toString('hex').toUpperCase(); 
                    const pass = `token_${rawToken}`;
                    const port = 7681;
                    exec(`pkill ttyd`, () => {
                        setTimeout(() => {
                            const scriptContent = `#!/bin/bash\nnohup ttyd -p ${port} -c root:${pass} -W -t rendererType=canvas -t disableLeaveAlert=true -t ctrlKey=true -t enableControlKeys=true -t titleFixed="FLOATIX Terminal" -t theme='{"background":"#000000","foreground":"#00FF00","cursor":"#00FF00"}' docker exec -it ${newContainer.id} bash > /dev/null 2>&1 &\n`;
                            fs.writeFileSync('/tmp/start_ttyd.sh', scriptContent, { mode: 0755 });
                            exec(`bash /tmp/start_ttyd.sh`);

                            client.users.fetch(ownerId).then(u => {
                                const link = process.env.WEB_URL;
                                const dmEmbed = new EmbedBuilder()
                                    .setTitle('🔄 VPS Reinstalled Successfully!')
                                    .setDescription(`**VPS No:** \`${row.vps_number}\`\n<:linkk:1565412446422835231> **New Web Link:** \`${link}\`\n👤 **Username:** \`root\`\n<a:key:1565412483810730056> **New Password:** \`${pass}\``)
                                    .setColor('#00FF00')
                                    .setFooter({ text: 'Powered by FLOATIX' });
                                if (process.env.LOGO_URL) embed.setThumbnail(process.env.LOGO_URL);
                                if (process.env.BANNER_URL) embed.setImage(process.env.BANNER_URL);

                                const copyRow = new ActionRowBuilder().addComponents(
                                    new ButtonBuilder().setStyle(ButtonStyle.Link).setURL(link).setLabel('🔗 Open Terminal'),
                                    new ButtonBuilder().setCustomId(`copypass_${pass}`).setLabel('📋 Copy Password').setStyle(ButtonStyle.Secondary)
                                );

                                u.send({ embeds: [dmEmbed], components: [copyRow] });
                            }).catch(()=>{});
                        }, 1000);
                    });

                    const { embed, buttons } = await getVpsStatusEmbed(newContainer.id, ownerId, ownerId);
                    await interaction.message.edit({ embeds: [embed], components: buttons }).catch(()=>{});
                    await interaction.editReply({ content: '✅ **VPS Reinstalled Successfully! New Token sent to your DM.**' });
                } catch (e) {
                    await interaction.editReply({ content: `❌ Reinstall Error: ${e.message}` });
                }
            }
        });
    }
});

client.once('ready', () => {
    console.log(`✅ ULTIMATE FLOATIX BOT IS ONLINE AND SECURE! Logged in as ${client.user.tag}`);
    
    setInterval(() => {
        const now = Date.now();
        db.all(`SELECT container_id, user_id, vps_number FROM vps_list WHERE expire_at <= ? AND is_suspended = 0`, [now], async (err, rows) => {
            if (!rows) return;
            for (const row of rows) {
                db.run(`UPDATE vps_list SET is_suspended = 1 WHERE container_id = ?`, [row.container_id]);
                try {
                    const container = docker.getContainer(row.container_id);
                    await container.stop().catch(()=>{});
                    client.users.fetch(row.user_id).then(u => {
                        u.send(`<a:alert:1565404039770800159> **Alert!** Your VPS (No: \`${row.vps_number}\`) has **Expired** and is **Suspended**.`);
                    }).catch(()=>{});
                } catch(e) {}
            }
        });
    }, 15000); 
});

client.login(process.env.BOT_TOKEN);
EOF
cat << 'EOF' > /etc/systemd/system/skabot.service
[Unit]
Description=SKA VPS Manager Bot
After=network.service docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/node /root/index.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable skabot
systemctl restart skabot

systemctl restart skabot
echo "✅ FLOATIX bot fully updated with fixed help menu dropdown selection!"
