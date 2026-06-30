local ADDON, ns = ...

--========================================================================
-- Guild tags: show "<Guild>" beside a player's name everywhere they appear.
--
-- A remote player's guild can't be looked up locally (Classic Era has no
-- GetGuildInfo(name)), so each client appends its own guild to the replies whose
-- sender we display (search R, category QR, the seller/buyer summaries C/WC, the
-- buyer-find WR). The receiver caches it by name. The field rides last on each of
-- those messages, so older clients ignore it (append-only, like the version field).
--
-- The cache is session-only: a wrong guild can't linger across a /reload, and any new
-- message from that player refreshes it. The guild is shown only on the hover tooltip of
-- a player's name (its title line), so it never costs list space and needs no setting.
--========================================================================

ns.guilds = ns.guilds or {}   -- [shortName] = guildName  (learned from the wire this session)

-- Our own guild, read live (cheap; the roster fills in shortly after login).
function ns.MyGuild()
    local g = GetGuildInfo and GetGuildInfo("player")
    return g   -- nil when not in a guild / roster not loaded yet
end

-- Remember a player's guild from a message they sent. Empty/nil is ignored so a
-- guildless sender (or an older client that sent no field) never clears a known one.
function ns.NoteGuild(sender, guild)
    if not guild or guild == "" then return end
    local s = sender and Ambiguate(sender, "short")
    if s then ns.guilds[s] = guild end
end

-- The guild we know for a name (our own resolved live, so it shows before any wire traffic).
function ns.GuildOf(name)
    if not name then return nil end
    if name == ns.playerName then return ns.MyGuild() end
    return ns.guilds[name]
end

-- A player's name for a tooltip title: "Name" or, when the guild is known, "Name <Guild>"
-- with the guild in a quiet blue so it reads apart from the name.
function ns.PlayerTitle(name)
    if not name then return "" end
    local g = ns.GuildOf(name)
    if g and g ~= "" then return ("%s |cff8a9bd1<%s>|r"):format(name, g) end
    return name
end
