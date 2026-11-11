--[[--
Calendar events from a CalDAV server, shown in To Do's calendar. Read only:
what the server has is fetched and kept on the Kindle, nothing is sent back.

A GET of the calendar's address serves most servers their events whole; when
the answer isn't a calendar, a REPORT calendar-query asks the collection for
the events in a window. Plain Lua (no KOReader modules) for the tests; the
network and the settings are passed in, as todoapi does. A time with a Z is
UTC; one without (or with a TZID) is taken as this Kindle's time.
]]

local Dates = require("tododates")

local Caldav = {}
Caldav.__index = Caldav

-- Events kept from so many days before and after today (the REPORT window;
-- a GET keeps what it gets, the calendar shows the month it is on).
Caldav.BEFORE = 60
Caldav.AFTER = 200

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- An event's own text: the backslashes iCal puts in front of , ; \ and newlines come off.
local function unescape(text)
    text = text:gsub("\\\\", "\1")
    text = text:gsub("\\n", "\n"):gsub("\\N", "\n"):gsub("\\,", ","):gsub("\\;", ";")
    return (text:gsub("\1", "\\"))
end

function Caldav.base64(data)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
            .. chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
            .. (b and chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
            .. (c and chars:sub(n % 64 + 1, n % 64 + 1) or "=")
    end
    return table.concat(out)
end

--- options: settings (get(key), set(key, value), save()), request(method, url,
-- headers, body) returning (status number or error string, body string).
function Caldav.new(options)
    local self = setmetatable({}, Caldav)
    self.settings = options.settings
    self.request = options.request
    return self
end

function Caldav:get(key) return self.settings and self.settings.get(key) or nil end

--- The calendar's address: an absolute one as given, or the calendar's path on
-- the server's address. Nil when neither is set.
function Caldav:calendarUrl()
    local calendar = trim(self:get("caldav_calendar"))
    if calendar == "" then return nil end
    if calendar:find("^https?://") then return calendar end
    local base = trim(self:get("caldav_url"))
    if base == "" then return nil end
    if not base:find("^https?://") then base = "http://" .. base end
    return base:gsub("/+$", "") .. "/" .. calendar:gsub("^/+", ""):gsub("/+$", "")
end

function Caldav:configured() return self:calendarUrl() ~= nil end

-- The Basic sign-in header (none when no username is set).
function Caldav:authHeader()
    local user = trim(self:get("caldav_user"))
    if user == "" then return nil end
    return "Basic " .. Caldav.base64(user .. ":" .. (self:get("caldav_pass") or ""))
end

-- ------------------------------------------------------------------ iCal parsing

-- A date or date-time as iCal writes it ("20261020", "20261020T093000", with a
-- Z for UTC, separators allowed): { day, second, utc, timed } or nil.
local function parseStamp(value)
    value = tostring(value or "")
    local y, m, d, rest = value:match("^(%d%d%d%d)-?(%d%d)-?(%d%d)T?(.*)$")
    if not y then return nil end
    local h, mi, s = 0, 0, 0
    if rest and #rest > 0 then
        h, mi, s = rest:match("^(%d%d?):?(%d%d?):?(%d%d?)")
        if not h then return nil end
        h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
    end
    return { day = Dates.fromCivil(tonumber(y), tonumber(m), tonumber(d)),
        second = h * 3600 + mi * 60 + s, utc = value:find("Z%s*$") ~= nil, timed = rest and #rest > 0 or false }
end

-- A stamp as Unix seconds: UTC ones as they are, the rest as the Kindle's time.
local function stampSeconds(stamp, offset)
    if stamp.utc then return stamp.day * 86400 + stamp.second end
    return stamp.day * 86400 + stamp.second - offset
end

--- "PT2H30M", "P1D", "P2W" as seconds (nil when it is not one).
function Caldav.parseDuration(text)
    text = tostring(text or "")
    local sign = text:find("^%-") and -1 or 1
    local weeks = text:match("^[%+%-]?P(%d+)W$")
    if weeks then return sign * tonumber(weeks) * 7 * 86400 end
    local days = tonumber(text:match("^[%+%-]?P(%d+)D") or 0) or 0
    local time = text:match("^[%+%-]?P%d*D(.*)$") or text:match("^[%+%-]?P(.*)$") or ""
    local h = tonumber(time:match("T(%d+)H") or 0) or 0
    local m = tonumber(time:match("(%d+)M") or 0) or 0
    local s = tonumber(time:match("(%d+)S") or 0) or 0
    if days == 0 and h == 0 and m == 0 and s == 0 then return nil end
    return sign * (days * 86400 + h * 3600 + m * 60 + s)
end

-- An RRULE the calendar follows: DAILY, WEEKLY, MONTHLY or YEARLY with INTERVAL,
-- COUNT, UNTIL and (weekly) BYDAY. Anything else is no repeat.
local BYDAY = { MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6, SU = 0 }

function Caldav.parseRrule(text)
    local rule = { interval = 1 }
    for key, value in tostring(text or ""):upper():gmatch("([%w%-]+)=([^;]+)") do
        if key == "FREQ" then rule.freq = value
        elseif key == "INTERVAL" then rule.interval = tonumber(value) or 1
        elseif key == "COUNT" then rule.count = tonumber(value)
        elseif key == "UNTIL" then rule.untilStamp = parseStamp(value)
        elseif key == "BYDAY" then
            rule.byday = {}
            for token in value:gmatch("[^,]+") do
                local wd = token:match("([A-Z][A-Z])$")
                if BYDAY[wd] then table.insert(rule.byday, wd) end
            end
            if #rule.byday == 0 then rule.byday = nil end
        end
    end
    if not rule.freq or not ({ DAILY = true, WEEKLY = true, MONTHLY = true, YEARLY = true })[rule.freq] then return nil end
    return rule
end

-- A property line "NAME;PARAMS:VALUE" (the value may hold colons): name, params, value.
local function splitProp(line)
    local quotes = false
    for i = 1, #line do
        local c = line:sub(i, i)
        if c == '"' then quotes = not quotes
        elseif c == ":" and not quotes then
            local name, params = line:sub(1, i - 1):match("^([^;]+);?(.*)$")
            return name:upper(), params, line:sub(i + 1)
        end
    end
end

-- Folded lines back into one (RFC 5545: a line break and a space are none).
function Caldav.unfold(text)
    return (tostring(text or ""):gsub("\r?\n[ \t]", ""))
end

--- The VEVENTs of an .ics, as the calendar keeps them:
-- { uid, title, location, notes, allDay, day, days, starts, ends, rrule }.
-- All-day events have `day` and `days`; timed ones have `starts` (and `ends`,
-- when the event says so), in Unix seconds (UTC). A UID twice over counts once
-- (the first wins), cancelled events are left out. `offset`: the Kindle's
-- seconds from UTC, for times the server wrote without a zone.
function Caldav.parseIcs(text, offset)
    local events, seen = {}, {}
    local props, cancelled, depth
    local function keep()
        if cancelled or not (props and props.DTSTART) then return end
        local start = parseStamp(props.DTSTART.value)
        if not start then return end
        local event = {
            uid = props.UID and props.UID.value or nil,
            title = unescape((props.SUMMARY or props.LOCATION or { value = "" }).value),
            location = props.LOCATION and unescape(props.LOCATION.value) or nil,
            notes = props.DESCRIPTION and unescape(props.DESCRIPTION.value) or nil,
        }
        if event.title == "" then event.title = "(no title)" end
        if start.timed then
            event.starts = stampSeconds(start, offset)
            local endStamp = props.DTEND and parseStamp(props.DTEND.value) or nil
            if endStamp then event.ends = stampSeconds(endStamp, offset)
            elseif props.DURATION then event.ends = event.starts + (Caldav.parseDuration(props.DURATION.value) or 0) end
        else
            event.allDay = true
            event.day = start.day
            local endStamp = props.DTEND and parseStamp(props.DTEND.value) or nil
            event.days = endStamp and math.max(1, endStamp.day - start.day) or 1
        end
        if props.RRULE then event.rrule = Caldav.parseRrule(props.RRULE.value) end
        if event.uid and seen[event.uid] then return end
        if event.uid then seen[event.uid] = true end
        table.insert(events, event)
    end
    for line in Caldav.unfold(text):gmatch("[^\r\n]+") do
        local name, params, value = splitProp(line)
        if name == "BEGIN" then
            if value == "VEVENT" then props, cancelled, depth = {}, false, 0
            elseif props then depth = depth + 1 end
        elseif name == "END" then
            if value == "VEVENT" then keep() props = nil
            elseif props and depth > 0 then depth = depth - 1 end
        elseif props and depth == 0 and name then
            if name == "STATUS" and value:upper():find("CANCELLED", 1, true) then cancelled = true end
            props[name] = { params = params, value = value }
        end
    end
    return events
end

-- ------------------------------------------------------------------ repeats

local function localDayOf(seconds, offset) return math.floor((seconds + offset) / 86400) end
local function localMinuteOf(seconds, offset) return math.floor((seconds + offset) % 86400 / 60) end

-- The Monday of a day's week (iCal's weeks start on Monday unless said otherwise).
local function weekBase(day) return day - (Dates.weekdayIndex(day) + 6) % 7 end

--- The occurrences of an event in the days [first..last]:
-- { { day, minute, ["repeat"] } } in day order (all-day ones have no minute).
-- Repeats follow a basic RRULE (DAILY, WEEKLY, MONTHLY, YEARLY with INTERVAL,
-- COUNT, UNTIL and a weekly BYDAY); a monthly one falls on the same day of the
-- month, shortened where the month is shorter.
function Caldav.occurrences(event, first, last, offset)
    local out = {}
    local function add(day, minute, isRepeat)
        if day >= first and day <= last then
            table.insert(out, { day = day, minute = minute, ["repeat"] = isRepeat or nil })
        end
    end
    local rule = event.rrule
    if not rule then
        if event.allDay then
            for i = 0, (event.days or 1) - 1 do add(event.day + i, nil) end
        elseif event.starts then
            add(localDayOf(event.starts, offset), localMinuteOf(event.starts, offset))
        end
        return out
    end
    local startDay = event.allDay and event.day or (event.starts and localDayOf(event.starts, offset))
    if not startDay then return out end
    local startMinute
    if not event.allDay and event.starts then startMinute = localMinuteOf(event.starts, offset) end
    local untilDay
    if rule.untilStamp then
        untilDay = rule.untilStamp.timed and localDayOf(stampSeconds(rule.untilStamp, offset), offset) or rule.untilStamp.day
    end
    local count = 0
    local function visit(day)
        count = count + 1
        if day >= startDay and (not untilDay or day <= untilDay) then
            if event.allDay then
                for i = 0, (event.days or 1) - 1 do add(day + i, nil, day ~= startDay) end
            else
                add(day, startMinute, day ~= startDay)
            end
        end
        if rule.count and count >= rule.count then return true end
        if untilDay and day > untilDay then return true end
        return false
    end
    local interval = math.max(1, rule.interval or 1)
    if rule.freq == "DAILY" then
        local day = startDay
        while day <= last do
            if visit(day) then break end
            day = day + interval
        end
    elseif rule.freq == "WEEKLY" then
        local set = {}
        if rule.byday then
            for __, k in ipairs(rule.byday) do set[BYDAY[k]] = true end
        else
            set[Dates.weekdayIndex(startDay)] = true
        end
        local week, stop = weekBase(startDay), false
        while week <= last and not stop do
            for wd = 0, 6 do
                local day = week + wd
                if day >= startDay and set[Dates.weekdayIndex(day)] then
                    if visit(day) then stop = true break end
                end
            end
            week = week + 7 * interval
        end
    else
        local y, m, d = Dates.toCivil(startDay)
        local step = rule.freq == "YEARLY" and 12 * interval or interval
        for k = 0, 1200 do
            local yy, mm = Dates.addMonths(y, m, k * step)
            local day = Dates.fromCivil(yy, mm, math.min(d, Dates.daysInMonth(yy, mm)))
            if day > last then break end
            if visit(day) then break end
        end
    end
    return out
end

-- ------------------------------------------------------------------ fetching

-- A moment as iCal writes it (UTC).
local function queryStamp(seconds) return os.date("!%Y%m%dT%H%M%SZ", math.floor(seconds)) end

--- The REPORT calendar-query for the events between two moments (nil window:
-- every event, whatever its day).
function Caldav.queryBody(from, until_)
    local filter
    if from and until_ then
        filter = "<C:comp-filter name=\"VEVENT\"><C:time-range start=\"" .. queryStamp(from)
            .. "\" end=\"" .. queryStamp(until_) .. "\"/></C:comp-filter>"
    else
        filter = "<C:comp-filter name=\"VEVENT\"/>"
    end
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        .. "<C:calendar-query xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
        .. "<D:prop><D:getetag/><C:calendar-data/></D:prop>"
        .. "<C:filter><C:comp-filter name=\"VCALENDAR\">" .. filter .. "</C:comp-filter></C:filter>"
        .. "</C:calendar-query>"
end

-- The iCal bodies inside a REPORT's answer (<…:calendar-data>…</…:calendar-data>).
local ENTITIES = { ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = "\"", ["&apos;"] = "'", ["&amp;"] = "&" }

function Caldav.extractCalendarData(xml)
    local out = {}
    if type(xml) ~= "string" then return out end
    for chunk in xml:gmatch("<[%w%-]*:?[cC]alendar%-data[^>]*>(.-)</[%w%-]*:?[cC]alendar%-data%s*>") do
        chunk = chunk:match("<!%[CDATA%[(.-)%]%]>") or chunk
        chunk = chunk:gsub("&[%w]+;", ENTITIES)
        table.insert(out, chunk)
    end
    return out
end

--- The events between `from` and `until_` (Unix seconds; nil: the server's
-- whole calendar). A GET of the calendar's address first; when the answer
-- isn't a calendar, a REPORT calendar-query asks the collection. Returns the
-- events, or nil and why.
function Caldav:fetch(from, until_, offset)
    local url = self:calendarUrl()
    if not url then return nil, "No calendar address is set" end
    local headers = { Depth = "1" }
    local auth = self:authHeader()
    if auth then headers.Authorization = auth end
    offset = offset or Dates.utcOffset()
    local status, body = self.request("GET", url, headers)
    if type(status) == "number" and status == 200 and type(body) == "string" and body:find("BEGIN:VCALENDAR", 1, true) then
        return Caldav.parseIcs(body, offset)
    end
    status, body = self.request("REPORT", url, headers, Caldav.queryBody(from, until_))
    if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
    if status == 207 and type(body) == "string" then
        local events = {}
        for __, ics in ipairs(Caldav.extractCalendarData(body)) do
            for __, event in ipairs(Caldav.parseIcs(ics, offset)) do table.insert(events, event) end
        end
        return events
    end
    return nil, "HTTP " .. tostring(status)
end

--- One row for the connection test (appstest.lua): the calendar asked for its
-- events. clock() gives seconds.
function Caldav:testConnection(clock, from, until_)
    local started = clock()
    local events, why = self:fetch(from, until_)
    local url = self:calendarUrl()
    local row = { name = "caldav", detail = url and tostring(url):match("^https?://([^/]+)") or tostring(url),
        ms = math.floor((clock() - started) * 1000) }
    if events then
        row.ok, row.kind = true, "ok"
    elseif tostring(why):find("^No connection") then
        row.ok, row.kind, row.err = false, "unreachable", tostring(why):gsub("^No connection: ", "")
    else
        row.ok, row.kind, row.err = false, "failed", why
    end
    return { row }
end

return Caldav
