--!nonstrict
--[[

	MacLib  ~  a clean, sleek macOS-flavoured UI library for Roblox
	------------------------------------------------------------------
	Version : 1.0.0
	Source  : https://github.com/JSWorth/Maclib
	Usage   : local MacLib = loadstring(game:HttpGet(
	              "https://raw.githubusercontent.com/JSWorth/Maclib/main/main.lua"))()

	Icons    : Solar Icon Set  (https://solar-icons.vercel.app)
	           Fetched at runtime through the executor `request({})` function,
	           parsed from SVG and rasterised into an EditableImage.
	           If `identifyexecutor` is missing (LocalScript / Studio VM) the
	           library silently falls back to an embedded offline vector set.

	Everything is a single file. No dependencies. No assets to upload.

]]

local MacLib = {
	Version      = "1.0.0",
	Windows      = {},
	Flags        = {},   -- flag -> element object
	Values       = {},   -- flag -> current value
	Unloaded     = false,
	_Connections = {},
}
MacLib.__index = MacLib

--=================================================================================================
--  SERVICES
--=================================================================================================

local TweenService     = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")
local AssetService      = game:GetService("AssetService")
local CoreGui           = game:GetService("CoreGui")
local Lighting          = game:GetService("Lighting")
local TextService       = game:GetService("TextService")

local LocalPlayer = Players.LocalPlayer

--=================================================================================================
--  ENVIRONMENT DETECTION
--=================================================================================================

local Env = {}
do
	local function grab(name)
		local ok, v = pcall(function()
			return (getgenv and getgenv()[name]) or rawget(_G, name) or (getfenv and getfenv(0)[name])
		end)
		if ok then return v end
		return nil
	end

	Env.grab = grab

	-- identifyexecutor is the canonical "am I inside an executor" probe
	local idf = grab("identifyexecutor") or grab("getexecutorname")
	Env.Identify = (type(idf) == "function") and idf or nil

	if Env.Identify then
		local ok, name, ver = pcall(Env.Identify)
		Env.IsExecutor = ok
		Env.Executor   = ok and tostring(name) or "Unknown"
		Env.Version    = ok and ver and tostring(ver) or ""
	else
		Env.IsExecutor = false
		Env.Executor   = "LocalScript VM"
		Env.Version    = ""
	end

	Env.IsStudio = RunService:IsStudio()
	Env.IsClient = RunService:IsClient()

	-- filesystem
	Env.writefile = grab("writefile")
	Env.readfile  = grab("readfile")
	Env.isfile    = grab("isfile")
	Env.isfolder  = grab("isfolder")
	Env.makefolder= grab("makefolder")
	Env.listfiles = grab("listfiles")
	Env.delfile   = grab("delfile")
	Env.HasFS     = type(Env.writefile) == "function" and type(Env.readfile) == "function"

	-- gui protection
	Env.gethui       = grab("gethui")
	Env.protectgui   = grab("protect_gui") or grab("protectgui")
	Env.setclipboard = grab("setclipboard") or grab("toclipboard")
end

--=================================================================================================
--  HTTP LAYER
--   Priority:  executor request({})  ->  game:HttpGet  ->  HttpService  ->  nil
--=================================================================================================

local Http = {}
do
	local function resolveRequest()
		if not Env.IsExecutor then return nil end
		local syn    = Env.grab("syn")
		local http   = Env.grab("http")
		local fluxus = Env.grab("fluxus")
		local candidates = {
			Env.grab("request"),
			Env.grab("http_request"),
			(type(http) == "table") and http.request or nil,
			(type(syn) == "table") and syn.request or nil,
			(type(fluxus) == "table") and fluxus.request or nil,
		}
		for _, fn in ipairs(candidates) do
			if type(fn) == "function" then return fn end
		end
		return nil
	end

	Http.Request = resolveRequest()
	Http.Available = false

	--- Performs a blocking GET. Returns the response body string, or nil + reason.
	function Http.Get(url)
		-- 1. executor request({ }) -- exactly as requested
		if Http.Request then
			local ok, res = pcall(Http.Request, {
				Url     = url,
				Method  = "GET",
				Headers = {
					["User-Agent"]   = "MacLib/" .. MacLib.Version,
					["Content-Type"] = "application/json",
				},
			})
			if ok and type(res) == "table" then
				local body   = res.Body or res.body
				local status = res.StatusCode or res.status_code or res.Status or 200
				if body and tonumber(status) and tonumber(status) < 400 then
					return body
				end
			end
		end

		-- 2. legacy HttpGet (still present on nearly every executor)
		local hg = Env.grab("httpget")
		if Env.IsExecutor then
			local ok, body = pcall(function()
				return game:HttpGet(url, true)
			end)
			if ok and type(body) == "string" and #body > 0 then return body end
			if type(hg) == "function" then
				local ok2, body2 = pcall(hg, url)
				if ok2 and type(body2) == "string" and #body2 > 0 then return body2 end
			end
		end

		-- 3. HttpService -- only ever succeeds from a plugin / command bar / server VM,
		--    but it costs nothing to try and it makes the library usable in Studio.
		local ok3, body3 = pcall(function()
			return HttpService:GetAsync(url, true)
		end)
		if ok3 and type(body3) == "string" and #body3 > 0 then return body3 end

		return nil, "no http transport available"
	end

	-- Executors are known-good synchronously. Everything else gets one cheap async probe
	-- so the icon engine never blocks the UI while it waits to find out.
	Http.Available = (Http.Request ~= nil) or Env.IsExecutor
	Http.Probed    = Http.Available
	if not Http.Probed then
		task.spawn(function()
			local ok = pcall(function()
				return HttpService:GetAsync("https://api.iconify.design/solar/home-2-outline.svg", true)
			end)
			Http.Available = ok
			Http.Probed = true
		end)
	end
end

--=================================================================================================
--  SVG  ->  VECTOR  ->  EditableImage
--  A tiny but honest SVG rasteriser. Supports <path> (M L H V C S Q T A Z), <circle>,
--  <ellipse>, <rect>, <line>, <polyline>, <polygon>, <g> inheritance and transforms.
--  Fills use a scanline with 4x vertical supersampling + analytic horizontal coverage.
--  Strokes use per-pixel distance-to-segment (round caps/joins, free anti-aliasing).
--=================================================================================================

local SVG = {}
do
	local floor, ceil, abs, sqrt = math.floor, math.ceil, math.abs, math.sqrt
	local min, max = math.min, math.max

	local function clamp01(v)
		if v < 0 then return 0 end
		if v > 1 then return 1 end
		return v
	end

	local function newArray(n, v)
		if table.create then return table.create(n, v) end
		local t = {}
		for i = 1, n do t[i] = v end
		return t
	end

	----------------------------------------------------------------------------------------------
	-- scanner
	----------------------------------------------------------------------------------------------
	local Scanner = {}
	Scanner.__index = Scanner

	local function newScanner(s)
		return setmetatable({ s = s, i = 1, n = #s }, Scanner)
	end

	function Scanner:skip()
		while self.i <= self.n do
			local c = self.s:sub(self.i, self.i)
			if c == " " or c == "," or c == "\n" or c == "\t" or c == "\r" then
				self.i = self.i + 1
			else
				break
			end
		end
	end

	function Scanner:num()
		self:skip()
		local st = self.i
		local c = self.s:sub(self.i, self.i)
		if c == "+" or c == "-" then self.i = self.i + 1 end
		local digits = false
		while self.i <= self.n and self.s:sub(self.i, self.i):match("%d") do
			self.i = self.i + 1; digits = true
		end
		if self.s:sub(self.i, self.i) == "." then
			self.i = self.i + 1
			while self.i <= self.n and self.s:sub(self.i, self.i):match("%d") do
				self.i = self.i + 1; digits = true
			end
		end
		if not digits then self.i = st return nil end
		local e = self.s:sub(self.i, self.i)
		if e == "e" or e == "E" then
			local save = self.i
			self.i = self.i + 1
			local sg = self.s:sub(self.i, self.i)
			if sg == "+" or sg == "-" then self.i = self.i + 1 end
			local d2 = false
			while self.i <= self.n and self.s:sub(self.i, self.i):match("%d") do
				self.i = self.i + 1; d2 = true
			end
			if not d2 then self.i = save end
		end
		return tonumber(self.s:sub(st, self.i - 1))
	end

	-- arc flags are single characters and may be glued to the next number ("0014.2")
	function Scanner:flag()
		self:skip()
		local c = self.s:sub(self.i, self.i)
		if c == "0" or c == "1" then
			self.i = self.i + 1
			return tonumber(c)
		end
		return self:num()
	end

	function Scanner:letter()
		self:skip()
		local c = self.s:sub(self.i, self.i)
		if c ~= "" and c:match("%a") then
			self.i = self.i + 1
			return c
		end
		return nil
	end

	function Scanner:eof()
		self:skip()
		return self.i > self.n
	end

	local function numberList(s)
		local out, sc = {}, newScanner(s)
		while not sc:eof() do
			local v = sc:num()
			if not v then break end
			out[#out + 1] = v
		end
		return out
	end
	SVG.numberList = numberList

	----------------------------------------------------------------------------------------------
	-- 2x3 matrices  { a, b, c, d, e, f }   ->   x' = a*x + c*y + e ,  y' = b*x + d*y + f
	----------------------------------------------------------------------------------------------
	local IDENTITY = { 1, 0, 0, 1, 0, 0 }

	local function matMul(m, n)
		return {
			m[1] * n[1] + m[3] * n[2],
			m[2] * n[1] + m[4] * n[2],
			m[1] * n[3] + m[3] * n[4],
			m[2] * n[3] + m[4] * n[4],
			m[1] * n[5] + m[3] * n[6] + m[5],
			m[2] * n[5] + m[4] * n[6] + m[6],
		}
	end

	local function parseTransform(str)
		local m = IDENTITY
		if not str or str == "" then return m end
		for name, argstr in str:gmatch("(%a[%w]*)%s*%(([^%)]*)%)") do
			local a = numberList(argstr)
			local t = nil
			if name == "translate" then
				t = { 1, 0, 0, 1, a[1] or 0, a[2] or 0 }
			elseif name == "scale" then
				t = { a[1] or 1, 0, 0, a[2] or a[1] or 1, 0, 0 }
			elseif name == "rotate" then
				local ang = math.rad(a[1] or 0)
				local cs, sn = math.cos(ang), math.sin(ang)
				t = { cs, sn, -sn, cs, 0, 0 }
				if a[2] then
					t = matMul({ 1, 0, 0, 1, a[2], a[3] or 0 }, matMul(t, { 1, 0, 0, 1, -a[2], -(a[3] or 0) }))
				end
			elseif name == "matrix" then
				t = { a[1] or 1, a[2] or 0, a[3] or 0, a[4] or 1, a[5] or 0, a[6] or 0 }
			elseif name == "skewX" then
				t = { 1, 0, math.tan(math.rad(a[1] or 0)), 1, 0, 0 }
			elseif name == "skewY" then
				t = { 1, math.tan(math.rad(a[1] or 0)), 0, 1, 0, 0 }
			end
			if t then m = matMul(m, t) end
		end
		return m
	end

	----------------------------------------------------------------------------------------------
	-- path flattening
	----------------------------------------------------------------------------------------------
	local function flattenPath(d, quality)
		local polys, closed = {}, {}
		local cur = nil
		local cx, cy, sx, sy = 0, 0, 0, 0
		local lastC1x, lastC1y = nil, nil
		local lastQx, lastQy = nil, nil
		local sc = newScanner(d)

		local function open(x, y)
			cur = { x, y }
			polys[#polys + 1] = cur
			closed[#polys] = false
		end
		local function push(x, y)
			if not cur then open(cx, cy) end
			cur[#cur + 1] = x
			cur[#cur + 1] = y
		end

		local function cubic(x1, y1, x2, y2, x3, y3)
			local x0, y0 = cx, cy
			local len = abs(x1 - x0) + abs(y1 - y0) + abs(x2 - x1) + abs(y2 - y1) + abs(x3 - x2) + abs(y3 - y2)
			local n = floor(len * quality / 2.5)
			if n < 4 then n = 4 end
			if n > 40 then n = 40 end
			for i = 1, n do
				local t = i / n
				local mt = 1 - t
				local a = mt * mt * mt
				local b = 3 * mt * mt * t
				local c = 3 * mt * t * t
				local e = t * t * t
				push(a * x0 + b * x1 + c * x2 + e * x3, a * y0 + b * y1 + c * y2 + e * y3)
			end
			cx, cy = x3, y3
		end

		local function quad(x1, y1, x2, y2)
			local x0, y0 = cx, cy
			cubic(x0 + 2 / 3 * (x1 - x0), y0 + 2 / 3 * (y1 - y0),
				x2 + 2 / 3 * (x1 - x2), y2 + 2 / 3 * (y1 - y2), x2, y2)
		end

		local function arc(rx, ry, rot, laf, sf, x2, y2)
			local x1, y1 = cx, cy
			if rx == 0 or ry == 0 then push(x2, y2) cx, cy = x2, y2 return end
			rx, ry = abs(rx), abs(ry)
			local phi = math.rad(rot)
			local cosp, sinp = math.cos(phi), math.sin(phi)
			local dx2, dy2 = (x1 - x2) / 2, (y1 - y2) / 2
			local x1p = cosp * dx2 + sinp * dy2
			local y1p = -sinp * dx2 + cosp * dy2
			local lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
			if lam > 1 then
				local s = sqrt(lam)
				rx, ry = rx * s, ry * s
			end
			local num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
			local den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
			if den == 0 then den = 1e-9 end
			local co = sqrt(max(0, num / den))
			if laf == sf then co = -co end
			local cxp = co * rx * y1p / ry
			local cyp = -co * ry * x1p / rx
			local ccx = cosp * cxp - sinp * cyp + (x1 + x2) / 2
			local ccy = sinp * cxp + cosp * cyp + (y1 + y2) / 2

			local function angle(ux, uy, vx, vy)
				local dot = ux * vx + uy * vy
				local len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
				if len == 0 then return 0 end
				local a = math.acos(max(-1, min(1, dot / len)))
				if ux * vy - uy * vx < 0 then a = -a end
				return a
			end

			local t1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
			local dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
			if sf == 0 and dt > 0 then dt = dt - 2 * math.pi end
			if sf == 1 and dt < 0 then dt = dt + 2 * math.pi end

			local n = floor(abs(dt) * max(rx, ry) * quality / 2.5)
			if n < 4 then n = 4 end
			if n > 48 then n = 48 end
			for i = 1, n do
				local th = t1 + dt * (i / n)
				local ex = rx * math.cos(th)
				local ey = ry * math.sin(th)
				push(ccx + cosp * ex - sinp * ey, ccy + sinp * ex + cosp * ey)
			end
			cx, cy = x2, y2
		end

		local cmd = nil
		while not sc:eof() do
			local c = sc:letter()
			if c then
				cmd = c
			elseif not cmd then
				break
			elseif cmd == "M" then
				cmd = "L"
			elseif cmd == "m" then
				cmd = "l"
			end

			local lower = cmd:lower()
			local rel = (cmd ~= cmd:upper())
			local ox = rel and cx or 0
			local oy = rel and cy or 0

			if lower == "m" then
				local x, y = sc:num(), sc:num()
				if not x or not y then break end
				cx, cy = x + ox, y + oy
				sx, sy = cx, cy
				open(cx, cy)
				lastC1x, lastQx = nil, nil
			elseif lower == "l" then
				local x, y = sc:num(), sc:num()
				if not x or not y then break end
				cx, cy = x + ox, y + oy
				push(cx, cy)
				lastC1x, lastQx = nil, nil
			elseif lower == "h" then
				local x = sc:num()
				if not x then break end
				cx = x + ox
				push(cx, cy)
				lastC1x, lastQx = nil, nil
			elseif lower == "v" then
				local y = sc:num()
				if not y then break end
				cy = y + oy
				push(cx, cy)
				lastC1x, lastQx = nil, nil
			elseif lower == "c" then
				local x1, y1, x2, y2, x3, y3 = sc:num(), sc:num(), sc:num(), sc:num(), sc:num(), sc:num()
				if not y3 then break end
				x1, y1, x2, y2, x3, y3 = x1 + ox, y1 + oy, x2 + ox, y2 + oy, x3 + ox, y3 + oy
				cubic(x1, y1, x2, y2, x3, y3)
				lastC1x, lastC1y = x2, y2
				lastQx = nil
			elseif lower == "s" then
				local x2, y2, x3, y3 = sc:num(), sc:num(), sc:num(), sc:num()
				if not y3 then break end
				x2, y2, x3, y3 = x2 + ox, y2 + oy, x3 + ox, y3 + oy
				local x1 = lastC1x and (2 * cx - lastC1x) or cx
				local y1 = lastC1y and (2 * cy - lastC1y) or cy
				cubic(x1, y1, x2, y2, x3, y3)
				lastC1x, lastC1y = x2, y2
				lastQx = nil
			elseif lower == "q" then
				local x1, y1, x2, y2 = sc:num(), sc:num(), sc:num(), sc:num()
				if not y2 then break end
				x1, y1, x2, y2 = x1 + ox, y1 + oy, x2 + ox, y2 + oy
				quad(x1, y1, x2, y2)
				lastQx, lastQy = x1, y1
				lastC1x = nil
			elseif lower == "t" then
				local x2, y2 = sc:num(), sc:num()
				if not y2 then break end
				x2, y2 = x2 + ox, y2 + oy
				local x1 = lastQx and (2 * cx - lastQx) or cx
				local y1 = lastQy and (2 * cy - lastQy) or cy
				quad(x1, y1, x2, y2)
				lastQx, lastQy = x1, y1
				lastC1x = nil
			elseif lower == "a" then
				local rx, ry, rot = sc:num(), sc:num(), sc:num()
				local laf, sf = sc:flag(), sc:flag()
				local x2, y2 = sc:num(), sc:num()
				if not y2 then break end
				arc(rx, ry, rot, laf, sf, x2 + ox, y2 + oy)
				lastC1x, lastQx = nil, nil
			elseif lower == "z" then
				if cur then closed[#polys] = true end
				cx, cy = sx, sy
				cur = nil
				lastC1x, lastQx = nil, nil
			else
				break
			end
		end

		return polys, closed
	end
	SVG.flattenPath = flattenPath

	----------------------------------------------------------------------------------------------
	-- primitive shapes -> polylines
	----------------------------------------------------------------------------------------------
	local function circlePoly(cx, cy, rx, ry, quality)
		local n = floor(math.max(rx, ry) * quality)
		if n < 12 then n = 12 end
		if n > 64 then n = 64 end
		local pts = {}
		for i = 0, n - 1 do
			local a = (i / n) * math.pi * 2
			pts[#pts + 1] = cx + math.cos(a) * rx
			pts[#pts + 1] = cy + math.sin(a) * ry
		end
		return pts
	end

	local function rectPoly(x, y, w, h, rx, ry, quality)
		if rx <= 0 and ry <= 0 then
			return { x, y, x + w, y, x + w, y + h, x, y + h }
		end
		if rx <= 0 then rx = ry end
		if ry <= 0 then ry = rx end
		rx = math.min(rx, w / 2)
		ry = math.min(ry, h / 2)
		local seg = floor(math.max(rx, ry) * quality / 2)
		if seg < 4 then seg = 4 end
		if seg > 16 then seg = 16 end
		local pts = {}
		local corners = {
			{ x + w - rx, y + ry, -math.pi / 2, 0 },
			{ x + w - rx, y + h - ry, 0, math.pi / 2 },
			{ x + rx, y + h - ry, math.pi / 2, math.pi },
			{ x + rx, y + ry, math.pi, math.pi * 1.5 },
		}
		for _, c in ipairs(corners) do
			for i = 0, seg do
				local a = c[3] + (c[4] - c[3]) * (i / seg)
				pts[#pts + 1] = c[1] + math.cos(a) * rx
				pts[#pts + 1] = c[2] + math.sin(a) * ry
			end
		end
		return pts
	end

	----------------------------------------------------------------------------------------------
	-- document parsing
	----------------------------------------------------------------------------------------------
	local function parseAttrs(str)
		local t = {}
		for k, v in str:gmatch('([%w%-:]+)%s*=%s*"([^"]*)"') do t[k:lower()] = v end
		for k, v in str:gmatch("([%w%-:]+)%s*=%s*'([^']*)'") do
			if t[k:lower()] == nil then t[k:lower()] = v end
		end
		return t
	end

	local function inherit(parent, attrs)
		local s = {
			fill        = parent.fill,
			stroke      = parent.stroke,
			strokeWidth = parent.strokeWidth,
			fillRule    = parent.fillRule,
			opacity     = parent.opacity,
			fillOpacity = parent.fillOpacity,
			strokeOpacity = parent.strokeOpacity,
			matrix      = parent.matrix,
		}
		if attrs.fill then s.fill = attrs.fill:lower() end
		if attrs.stroke then s.stroke = attrs.stroke:lower() end
		if attrs["stroke-width"] then s.strokeWidth = tonumber(attrs["stroke-width"]) or s.strokeWidth end
		if attrs["fill-rule"] then s.fillRule = attrs["fill-rule"]:lower() end
		if attrs["clip-rule"] then s.fillRule = attrs["clip-rule"]:lower() end
		if attrs.opacity then s.opacity = (tonumber(attrs.opacity) or 1) * s.opacity end
		if attrs["fill-opacity"] then s.fillOpacity = tonumber(attrs["fill-opacity"]) or 1 end
		if attrs["stroke-opacity"] then s.strokeOpacity = tonumber(attrs["stroke-opacity"]) or 1 end
		if attrs.transform then s.matrix = matMul(s.matrix, parseTransform(attrs.transform)) end
		if attrs.style then
			for k, v in attrs.style:gmatch("([%w%-]+)%s*:%s*([^;]+)") do
				k = k:lower()
				v = v:gsub("^%s+", ""):gsub("%s+$", ""):lower()
				if k == "fill" then s.fill = v
				elseif k == "stroke" then s.stroke = v
				elseif k == "stroke-width" then s.strokeWidth = tonumber(v) or s.strokeWidth
				elseif k == "fill-rule" then s.fillRule = v
				elseif k == "opacity" then s.opacity = (tonumber(v) or 1) * s.opacity end
			end
		end
		return s
	end

	--- Parses an SVG source string into a device-independent shape list.
	function SVG.Parse(src)
		if type(src) ~= "string" then return nil end
		src = src:gsub("<!%-%-.-%-%->", "")

		local doc = { minX = 0, minY = 0, width = 24, height = 24, shapes = {} }
		local vb = src:match('viewBox%s*=%s*"([^"]*)"') or src:match("viewBox%s*=%s*'([^']*)'")
		if vb then
			local v = numberList(vb)
			if #v >= 4 then
				doc.minX, doc.minY, doc.width, doc.height = v[1], v[2], v[3], v[4]
			end
		else
			local w = tonumber((src:match('width%s*=%s*"([%d%.]+)') or ""))
			local h = tonumber((src:match('height%s*=%s*"([%d%.]+)') or ""))
			doc.width  = w or 24
			doc.height = h or 24
		end
		if doc.width <= 0 then doc.width = 24 end
		if doc.height <= 0 then doc.height = 24 end

		-- quality = flattening samples per user unit, tuned for a 24-unit icon grid
		local quality = 96 / math.max(doc.width, doc.height)

		local stack = { {
			fill = nil, stroke = nil, strokeWidth = 1, fillRule = "nonzero",
			opacity = 1, fillOpacity = 1, strokeOpacity = 1, matrix = IDENTITY,
		} }

		local function emit(state, polys, closed, forceClosed)
			local fillPaint   = state.fill
			local strokePaint = state.stroke
			local doFill   = (fillPaint == nil) or (fillPaint ~= "none" and fillPaint ~= "transparent")
			local doStroke = strokePaint ~= nil and strokePaint ~= "none" and strokePaint ~= "transparent"
			if not doFill and not doStroke then return end

			local m = state.matrix
			local out = {}
			for i = 1, #polys do
				local p = polys[i]
				local q = {}
				for j = 1, #p, 2 do
					local x, y = p[j], p[j + 1]
					q[#q + 1] = m[1] * x + m[3] * y + m[5]
					q[#q + 1] = m[2] * x + m[4] * y + m[6]
				end
				out[#out + 1] = q
				if forceClosed then closed[i] = true end
			end

			-- average scale so stroke width survives transforms
			local sxx = sqrt(m[1] * m[1] + m[2] * m[2])
			local syy = sqrt(m[3] * m[3] + m[4] * m[4])
			local avg = (sxx + syy) / 2
			if avg <= 0 then avg = 1 end

			doc.shapes[#doc.shapes + 1] = {
				polys       = out,
				closed      = closed,
				fill        = doFill,
				evenodd     = state.fillRule == "evenodd",
				fillAlpha   = state.opacity * (state.fillOpacity or 1),
				stroke      = doStroke,
				strokeWidth = (state.strokeWidth or 1) * avg,
				strokeAlpha = state.opacity * (state.strokeOpacity or 1),
			}
		end

		for closing, name, rest in src:gmatch("<(/?)([%w:%-]+)([^>]*)>") do
			name = name:lower():gsub("^%a+:", "")
			local selfClose = rest:sub(-1) == "/"
			local attrs = parseAttrs(rest)
			local top = stack[#stack]

			if closing == "/" then
				if #stack > 1 then table.remove(stack) end
			elseif name == "svg" or name == "g" or name == "symbol" then
				local s = inherit(top, attrs)
				if not selfClose then stack[#stack + 1] = s end
			elseif name == "path" then
				if attrs.d then
					local s = inherit(top, attrs)
					local polys, closed = flattenPath(attrs.d, quality)
					emit(s, polys, closed, false)
				end
			elseif name == "circle" then
				local s = inherit(top, attrs)
				local r = tonumber(attrs.r) or 0
				if r > 0 then
					emit(s, { circlePoly(tonumber(attrs.cx) or 0, tonumber(attrs.cy) or 0, r, r, quality) }, {}, true)
				end
			elseif name == "ellipse" then
				local s = inherit(top, attrs)
				local rx = tonumber(attrs.rx) or 0
				local ry = tonumber(attrs.ry) or 0
				if rx > 0 and ry > 0 then
					emit(s, { circlePoly(tonumber(attrs.cx) or 0, tonumber(attrs.cy) or 0, rx, ry, quality) }, {}, true)
				end
			elseif name == "rect" then
				local s = inherit(top, attrs)
				local w = tonumber(attrs.width) or 0
				local h = tonumber(attrs.height) or 0
				if w > 0 and h > 0 then
					emit(s, { rectPoly(tonumber(attrs.x) or 0, tonumber(attrs.y) or 0, w, h,
						tonumber(attrs.rx) or 0, tonumber(attrs.ry) or 0, quality) }, {}, true)
				end
			elseif name == "line" then
				local s = inherit(top, attrs)
				s.fill = "none"
				emit(s, { { tonumber(attrs.x1) or 0, tonumber(attrs.y1) or 0,
					tonumber(attrs.x2) or 0, tonumber(attrs.y2) or 0 } }, { false }, false)
			elseif name == "polyline" or name == "polygon" then
				local s = inherit(top, attrs)
				local pts = numberList(attrs.points or "")
				if #pts >= 4 then
					emit(s, { pts }, { name == "polygon" }, name == "polygon")
				end
			end
		end

		return doc
	end

	----------------------------------------------------------------------------------------------
	-- rasteriser
	----------------------------------------------------------------------------------------------
	local function addSpan(row, w, x0, x1, amt)
		if x1 <= x0 then return end
		if x0 < 0 then x0 = 0 end
		if x1 > w then x1 = w end
		if x1 <= x0 then return end
		local i0 = floor(x0)
		local i1 = ceil(x1) - 1
		if i1 < i0 then i1 = i0 end
		if i0 == i1 then
			row[i0] = (row[i0] or 0) + (x1 - x0) * amt
		else
			row[i0] = (row[i0] or 0) + ((i0 + 1) - x0) * amt
			for x = i0 + 1, i1 - 1 do row[x] = (row[x] or 0) + amt end
			row[i1] = (row[i1] or 0) + (x1 - i1) * amt
		end
	end

	local function fillPolys(cov, size, polys, evenodd, alpha)
		local edges, ecount = {}, 0
		local minY, maxY = math.huge, -math.huge
		for _, p in ipairs(polys) do
			local n = #p
			if n >= 6 then
				local lx, ly = p[n - 1], p[n]
				for i = 1, n, 2 do
					local x, y = p[i], p[i + 1]
					if ly ~= y then
						ecount = ecount + 1
						edges[ecount] = { lx, ly, x, y }
						if y < minY then minY = y end
						if y > maxY then maxY = y end
						if ly < minY then minY = ly end
						if ly > maxY then maxY = ly end
					end
					lx, ly = x, y
				end
			end
		end
		if ecount == 0 then return end

		local y0 = max(0, floor(minY))
		local y1 = min(size - 1, ceil(maxY))
		local SS = 4
		local inv = 1 / SS
		local xs, dirs = {}, {}

		for py = y0, y1 do
			local row = nil
			for s = 0, SS - 1 do
				local sy = py + (s + 0.5) * inv
				local cnt = 0
				for i = 1, ecount do
					local e = edges[i]
					local ay, by = e[2], e[4]
					if (ay <= sy and by > sy) or (by <= sy and ay > sy) then
						cnt = cnt + 1
						xs[cnt] = e[1] + (sy - ay) / (by - ay) * (e[3] - e[1])
						dirs[cnt] = (by > ay) and 1 or -1
					end
				end
				if cnt > 1 then
					for i = 2, cnt do
						local kx, kd = xs[i], dirs[i]
						local j = i - 1
						while j >= 1 and xs[j] > kx do
							xs[j + 1] = xs[j]; dirs[j + 1] = dirs[j]; j = j - 1
						end
						xs[j + 1] = kx; dirs[j + 1] = kd
					end
					local wind = 0
					for i = 1, cnt - 1 do
						wind = wind + (evenodd and 1 or dirs[i])
						local inside
						if evenodd then inside = (wind % 2) == 1 else inside = wind ~= 0 end
						if inside then
							if not row then row = {} end
							addSpan(row, size, xs[i], xs[i + 1], inv)
						end
					end
				end
			end
			if row then
				local base = py * size
				for x, a in pairs(row) do
					local idx = base + x + 1
					local c = cov[idx] or 0
					local v = clamp01(a) * alpha
					cov[idx] = c + v * (1 - c)
				end
			end
		end
	end

	local function strokePolys(cov, size, polys, closed, width, alpha)
		local hw = width * 0.5
		if hw < 0.35 then hw = 0.35 end
		local reach = hw + 1
		local acc = {}
		for pi, p in ipairs(polys) do
			local n = #p
			if n >= 4 then
				local segs = {}
				for i = 1, n - 2, 2 do
					segs[#segs + 1] = { p[i], p[i + 1], p[i + 2], p[i + 3] }
				end
				if closed[pi] and n >= 6 then
					segs[#segs + 1] = { p[n - 1], p[n], p[1], p[2] }
				end
				for _, s in ipairs(segs) do
					local ax, ay, bx, by = s[1], s[2], s[3], s[4]
					local dx, dy = bx - ax, by - ay
					local dd = dx * dx + dy * dy
					local x0 = max(0, floor(min(ax, bx) - reach))
					local x1 = min(size - 1, ceil(max(ax, bx) + reach))
					local yy0 = max(0, floor(min(ay, by) - reach))
					local yy1 = min(size - 1, ceil(max(ay, by) + reach))
					for py = yy0, yy1 do
						local base = py * size
						local fy = py + 0.5
						for px = x0, x1 do
							local fx = px + 0.5
							local t = 0
							if dd > 0 then
								t = ((fx - ax) * dx + (fy - ay) * dy) / dd
								if t < 0 then t = 0 elseif t > 1 then t = 1 end
							end
							local qx = ax + dx * t - fx
							local qy = ay + dy * t - fy
							local dist = sqrt(qx * qx + qy * qy)
							local a = clamp01(hw + 0.5 - dist)
							if a > 0 then
								local idx = base + px + 1
								if (acc[idx] or 0) < a then acc[idx] = a end
							end
						end
					end
				end
			end
		end
		for idx, a in pairs(acc) do
			local c = cov[idx] or 0
			local v = a * alpha
			cov[idx] = c + v * (1 - c)
		end
	end

	--- Renders a parsed document into a size x size coverage table (values 0..1).
	function SVG.Rasterize(doc, size)
		local cov = newArray(size * size, 0)
		local sw = size / doc.width
		local sh = size / doc.height
		local scale = min(sw, sh)
		local offX = (size - doc.width * scale) * 0.5 - doc.minX * scale
		local offY = (size - doc.height * scale) * 0.5 - doc.minY * scale

		for _, shape in ipairs(doc.shapes) do
			local dev = {}
			for i, p in ipairs(shape.polys) do
				local q = {}
				for j = 1, #p, 2 do
					q[#q + 1] = p[j] * scale + offX
					q[#q + 1] = p[j + 1] * scale + offY
				end
				dev[i] = q
			end
			if shape.fill then
				fillPolys(cov, size, dev, shape.evenodd, clamp01(shape.fillAlpha or 1))
			end
			if shape.stroke then
				strokePolys(cov, size, dev, shape.closed, shape.strokeWidth * scale, clamp01(shape.strokeAlpha or 1))
			end
		end
		return cov
	end
end

--=================================================================================================
--  ICON ENGINE  (Solar Icon Set)
--=================================================================================================

local Icons = {}
do
	Icons.Style     = "outline"
	Icons.Size      = 96
	Icons.Cache     = {}      -- key -> { content = Content|string, frames = {..} }
	Icons.Pending   = {}      -- key -> { listeners }
	Icons.Endpoints = {
		"https://api.iconify.design/solar/%s.svg",
		"https://api.iconify.design/solar.svg?icons=%s",
		"https://cdn.jsdelivr.net/gh/iconify/icon-sets@master/svg/solar/%s.svg",
	}

	local KNOWN_STYLES = {
		["linear"] = true, ["outline"] = true, ["bold"] = true,
		["broken"] = true, ["bold-duotone"] = true, ["line-duotone"] = true,
	}

	----------------------------------------------------------------------------------------------
	-- offline vector set. Used when there is no HTTP transport (LocalScript / Studio VM),
	-- or when a remote fetch fails. 24x24 grid, stroked, matches Solar's linear weight.
	----------------------------------------------------------------------------------------------
	local S1 = '<svg viewBox="0 0 24 24"><g fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">'
	local S2 = '</g></svg>'

	local BuiltIn = {
		home     = S1 .. '<path d="M3 10.4 12 3.2l9 7.2V19a2 2 0 0 1-2 2h-3.6v-5.6H8.6V21H5a2 2 0 0 1-2-2z"/>' .. S2,
		settings = S1 .. '<path d="M4 7h6M16 7h4M4 17h4M14 17h6"/><circle cx="13" cy="7" r="2.4"/><circle cx="11" cy="17" r="2.4"/>' .. S2,
		user     = S1 .. '<circle cx="12" cy="8" r="3.6"/><path d="M4.6 20.2c0-3.5 3.3-5.8 7.4-5.8s7.4 2.3 7.4 5.8"/>' .. S2,
		search   = S1 .. '<circle cx="11" cy="11" r="6.6"/><path d="m16.4 16.4 4.1 4.1"/>' .. S2,
		bell     = S1 .. '<path d="M18 9.4a6 6 0 0 0-12 0c0 6.3-2.4 7.8-2.4 7.8h16.8S18 15.7 18 9.4Z"/><path d="M14 20.2a2.2 2.2 0 0 1-4 0"/>' .. S2,
		shield   = S1 .. '<path d="M12 3.2 20 6.2v5.5c0 4.8-3.4 7.9-8 9.3c-4.6-1.4-8-4.5-8-9.3V6.2z"/>' .. S2,
		code     = S1 .. '<path d="M9 8.6 4.6 12 9 15.4M15 8.6 19.4 12 15 15.4M13.4 5.6l-2.8 12.8"/>' .. S2,
		palette  = S1 .. '<path d="M12 3.2a8.8 8.8 0 0 0 0 17.6a2 2 0 0 0 2-2c0-.5-.2-.9-.5-1.2c-.3-.3-.5-.7-.5-1.2a1.9 1.9 0 0 1 1.9-1.9H17a4.9 4.9 0 0 0 4.9-4.9c0-3.6-4.4-6.4-9.9-6.4Z"/><circle cx="7.6" cy="11.4" r=".9"/><circle cx="10.2" cy="7.6" r=".9"/><circle cx="15.2" cy="8.2" r=".9"/>' .. S2,
		bolt     = S1 .. '<path d="M13.6 3 5.2 13.6h5.4L10.4 21l8.4-10.6h-5.6z"/>' .. S2,
		folder   = S1 .. '<path d="M3 7.6A2.6 2.6 0 0 1 5.6 5h3.2c.7 0 1.3.3 1.7.9l1 1.4h6.9A2.6 2.6 0 0 1 21 9.9v7.5A2.6 2.6 0 0 1 18.4 20H5.6A2.6 2.6 0 0 1 3 17.4z"/>' .. S2,
		star     = S1 .. '<path d="m12 3.4 2.7 5.5 6.1.9-4.4 4.3 1 6.1-5.4-2.9-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z"/>' .. S2,
		heart    = S1 .. '<path d="M12 20.3S3.4 15.6 3.4 9.9A4.5 4.5 0 0 1 12 7.5a4.5 4.5 0 0 1 8.6 2.4c0 5.7-8.6 10.4-8.6 10.4Z"/>' .. S2,
		play     = S1 .. '<path d="M8.4 5.5 18.2 11.3a.8.8 0 0 1 0 1.4L8.4 18.5A.8.8 0 0 1 7.2 17.8V6.2a.8.8 0 0 1 1.2-.7Z"/>' .. S2,
		close    = S1 .. '<path d="m6.6 6.6 10.8 10.8M17.4 6.6 6.6 17.4"/>' .. S2,
		check    = S1 .. '<path d="m4.6 12.6 4.9 4.9L19.4 7"/>' .. S2,
		info     = S1 .. '<circle cx="12" cy="12" r="8.8"/><path d="M12 11.2v5.4"/><circle cx="12" cy="8" r=".8"/>' .. S2,
		danger   = S1 .. '<path d="M10.3 4.4 2.9 17.3a2 2 0 0 0 1.7 3h14.8a2 2 0 0 0 1.7-3L13.7 4.4a2 2 0 0 0-3.4 0Z"/><path d="M12 9.4v4.2"/><circle cx="12" cy="16.7" r=".8"/>' .. S2,
		widget   = S1 .. '<rect x="3.4" y="3.4" width="7.2" height="7.2" rx="2.2"/><rect x="13.4" y="3.4" width="7.2" height="7.2" rx="2.2"/><rect x="3.4" y="13.4" width="7.2" height="7.2" rx="2.2"/><rect x="13.4" y="13.4" width="7.2" height="7.2" rx="2.2"/>' .. S2,
		chart    = S1 .. '<path d="M3.4 20.4h17.2M7 20.4v-5.8M12 20.4V6.2M17 20.4v-9"/>' .. S2,
		lock     = S1 .. '<rect x="4.4" y="9.8" width="15.2" height="10.6" rx="3.2"/><path d="M8 9.8V7.6a4 4 0 0 1 8 0v2.2"/>' .. S2,
		eye      = S1 .. '<path d="M2.6 12S6.2 5.8 12 5.8S21.4 12 21.4 12S17.8 18.2 12 18.2S2.6 12 2.6 12Z"/><circle cx="12" cy="12" r="3.1"/>' .. S2,
		key      = S1 .. '<circle cx="8" cy="14" r="4.3"/><path d="m11.2 11 8-8M16.6 5.6 18.8 7.8M14.3 7.9l2.2 2.2"/>' .. S2,
		gamepad  = S1 .. '<rect x="2.4" y="7" width="19.2" height="10.4" rx="4.2"/><path d="M7 10.7v3.6M5.2 12.5h3.6"/><circle cx="16" cy="11.6" r=".95"/><circle cx="18.3" cy="14" r=".95"/>' .. S2,
		rocket   = S1 .. '<path d="M12 3c3.6 2.5 5.1 6.1 5.1 9.6l-2.6 2.7H9.5l-2.6-2.7C6.9 9.1 8.4 5.5 12 3Z"/><path d="m9.5 15.3-1.7 4 2.7-1.2M14.5 15.3l1.7 4-2.7-1.2"/><circle cx="12" cy="10" r="1.7"/>' .. S2,
		plus     = S1 .. '<path d="M12 5.2v13.6M5.2 12h13.6"/>' .. S2,
		minus    = S1 .. '<path d="M5.2 12h13.6"/>' .. S2,
		trash    = S1 .. '<path d="M4.6 6.6h14.8M9.4 6.6V5.4a1.6 1.6 0 0 1 1.6-1.6h2a1.6 1.6 0 0 1 1.6 1.6v1.2M6.6 6.6l.8 12.1a1.8 1.8 0 0 0 1.8 1.7h5.6a1.8 1.8 0 0 0 1.8-1.7l.8-12.1"/>' .. S2,
		refresh  = S1 .. '<path d="M20 12a8 8 0 1 1-2.6-5.9M20.2 3.8v4.4h-4.4"/>' .. S2,
		globe    = S1 .. '<circle cx="12" cy="12" r="8.8"/><path d="M3.4 12h17.2M12 3.2c2.3 2.4 3.5 5.5 3.5 8.8s-1.2 6.4-3.5 8.8c-2.3-2.4-3.5-5.5-3.5-8.8S9.7 5.6 12 3.2Z"/>' .. S2,
		moon     = S1 .. '<path d="M20.2 14.6A8.7 8.7 0 0 1 9.4 3.8a8.9 8.9 0 1 0 10.8 10.8Z"/>' .. S2,
		sun      = S1 .. '<circle cx="12" cy="12" r="4.2"/><path d="M12 2.8v2.4M12 18.8v2.4M21.2 12h-2.4M5.2 12H2.8M18.5 5.5l-1.7 1.7M7.2 16.8l-1.7 1.7M18.5 18.5l-1.7-1.7M7.2 7.2 5.5 5.5"/>' .. S2,
		scaling  = S1 .. '<path d="M20.4 9.6V3.6h-6M3.6 14.4v6h6M20.4 3.6 13.4 10.6M3.6 20.4l7-7"/>' .. S2,
		["chevron-down"]  = S1 .. '<path d="m7 10 5 5 5-5"/>' .. S2,
		["chevron-right"] = S1 .. '<path d="m10 7 5 5-5 5"/>' .. S2,
		["chevron-up"]    = S1 .. '<path d="m7 14 5-5 5 5"/>' .. S2,
	}
	Icons.BuiltIn = BuiltIn

	local ALIASES = {
		["home-2"] = "home", ["home-smile"] = "home", ["home-angle"] = "home", ["home-angle-2"] = "home",
		["settings-minimalistic"] = "settings", ["tuning"] = "settings", ["tuning-2"] = "settings",
		["tuning-square"] = "settings", ["slider-horizontal"] = "settings", ["slider-vertical"] = "settings",
		["user-circle"] = "user", ["user-rounded"] = "user", ["user-hand-up"] = "user",
		["users-group-rounded"] = "user", ["user-id"] = "user",
		["magnifer"] = "search", ["magnifier"] = "search", ["rounded-magnifer"] = "search", ["minimalistic-magnifer"] = "search",
		["bell-bing"] = "bell", ["notification-unread"] = "bell", ["notification-lines-remove"] = "bell",
		["shield-check"] = "shield", ["shield-user"] = "shield", ["shield-minimalistic"] = "shield",
		["shield-keyhole"] = "shield", ["shield-star"] = "shield",
		["code-square"] = "code", ["code-2"] = "code", ["programming"] = "code", ["code-circle"] = "code",
		["palette-round"] = "palette", ["pallete-2"] = "palette", ["paint-roller"] = "palette",
		["bolt-circle"] = "bolt", ["flash"] = "bolt", ["flash-circle"] = "bolt", ["lightning"] = "bolt",
		["folder-with-files"] = "folder", ["folder-open"] = "folder", ["folder-path-connect"] = "folder",
		["star-fall"] = "star", ["stars"] = "star", ["star-circle"] = "star",
		["heart-angle"] = "heart", ["hearts"] = "heart",
		["play-circle"] = "play", ["play-stream"] = "play",
		["close-circle"] = "close", ["close-square"] = "close",
		["check-circle"] = "check", ["check-square"] = "check", ["verified-check"] = "check",
		["info-circle"] = "info", ["question-circle"] = "info", ["help"] = "info",
		["danger-triangle"] = "danger", ["danger-circle"] = "danger", ["danger-square"] = "danger",
		["widget-2"] = "widget", ["widget-3"] = "widget", ["widget-4"] = "widget", ["widget-5"] = "widget",
		["widget-6"] = "widget", ["layers"] = "widget",
		["chart-2"] = "chart", ["chart-square"] = "chart", ["graph"] = "chart", ["graph-up"] = "chart",
		["pie-chart"] = "chart", ["diagram-up"] = "chart",
		["lock-keyhole"] = "lock", ["lock-password"] = "lock", ["lock-keyhole-minimalistic"] = "lock",
		["eye-scan"] = "eye", ["eye-closed"] = "eye",
		["key-minimalistic"] = "key", ["key-square"] = "key", ["password"] = "key",
		["gamepad-old"] = "gamepad", ["gamepad-minimalistic"] = "gamepad", ["joystick"] = "gamepad",
		["rocket-2"] = "rocket", ["rocket-line"] = "rocket",
		["add-circle"] = "plus", ["add-square"] = "plus",
		["minus-circle"] = "minus", ["minus-square"] = "minus",
		["trash-bin-trash"] = "trash", ["trash-bin-minimalistic"] = "trash",
		["refresh-circle"] = "refresh", ["restart"] = "refresh", ["refresh-square"] = "refresh",
		["global"] = "globe", ["planet"] = "globe", ["earth"] = "globe",
		["scale"] = "scaling", ["resize"] = "scaling", ["maximize"] = "scaling",
		["full-screen"] = "scaling", ["quit-full-screen"] = "scaling", ["expand"] = "scaling",
		["moon-stars"] = "moon", ["moon-sleep"] = "moon", ["moon-fog"] = "moon",
		["sun-2"] = "sun", ["sun-fog"] = "sun", ["sunrise"] = "sun", ["black-hole"] = "sun",
		["alt-arrow-down"] = "chevron-down", ["arrow-down"] = "chevron-down", ["double-alt-arrow-down"] = "chevron-down",
		["alt-arrow-right"] = "chevron-right", ["arrow-right"] = "chevron-right",
		["alt-arrow-up"] = "chevron-up", ["arrow-up"] = "chevron-up",
	}

	----------------------------------------------------------------------------------------------
	-- name handling
	----------------------------------------------------------------------------------------------
	local function stripStyle(name)
		for style in pairs(KNOWN_STYLES) do
			local suf = "%-" .. style:gsub("%-", "%%-") .. "$"
			if name:match(suf) then return (name:gsub(suf, "")), style end
		end
		return name, nil
	end

	function Icons.Resolve(name, style)
		name = tostring(name or ""):lower():gsub("^solar[:%s]+", ""):gsub("%s+", "-")
		local base, embedded = stripStyle(name)
		local st = embedded or style or Icons.Style
		if not KNOWN_STYLES[st] then st = "outline" end
		return base .. "-" .. st, base
	end

	--- Best-effort mapping of any Solar name onto the offline set.
	function Icons.Offline(base)
		if BuiltIn[base] then return BuiltIn[base] end
		if ALIASES[base] then return BuiltIn[ALIASES[base]] end
		for key in pairs(BuiltIn) do
			if base:find(key, 1, true) then return BuiltIn[key] end
		end
		for alias, target in pairs(ALIASES) do
			if base:find(alias, 1, true) or alias:find(base, 1, true) then return BuiltIn[target] end
		end
		return BuiltIn.widget
	end

	----------------------------------------------------------------------------------------------
	-- coverage table -> EditableImage
	----------------------------------------------------------------------------------------------
	local editableSupported = nil

	local function createEditable(size)
		local ok, img = pcall(function()
			return AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
		end)
		if ok and img then return img end
		local ok2, img2 = pcall(function()
			return AssetService:CreateEditableImage(Vector2.new(size, size))
		end)
		if ok2 and img2 then return img2 end
		return nil
	end

	local function writePixels(img, size, cov)
		-- modern buffer API
		local ok = pcall(function()
			local buf = buffer.create(size * size * 4)
			for i = 0, size * size - 1 do
				local a = cov[i + 1] or 0
				if a > 1 then a = 1 elseif a < 0 then a = 0 end
				local o = i * 4
				buffer.writeu8(buf, o, 255)
				buffer.writeu8(buf, o + 1, 255)
				buffer.writeu8(buf, o + 2, 255)
				buffer.writeu8(buf, o + 3, math.floor(a * 255 + 0.5))
			end
			img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), buf)
		end)
		if ok then return true end
		-- legacy table API
		local ok2 = pcall(function()
			local px = table.create(size * size * 4, 1)
			for i = 0, size * size - 1 do
				local a = cov[i + 1] or 0
				if a > 1 then a = 1 elseif a < 0 then a = 0 end
				px[i * 4 + 4] = a
			end
			img:WritePixels(Vector2.zero, Vector2.new(size, size), px)
		end)
		return ok2
	end

	function Icons.BuildImage(svgSource, size)
		size = size or Icons.Size
		local doc = SVG.Parse(svgSource)
		if not doc or #doc.shapes == 0 then return nil, nil end
		local cov = SVG.Rasterize(doc, size)

		if editableSupported ~= false then
			local img = createEditable(size)
			if img then
				if writePixels(img, size, cov) then
					editableSupported = true
					local okc, content = pcall(function() return Content.fromObject(img) end)
					if okc and content then return content, doc end
					return img, doc
				end
			end
			editableSupported = false
		end
		return nil, doc
	end

	----------------------------------------------------------------------------------------------
	-- fallback renderer: draw stroked geometry with rotated Frames
	----------------------------------------------------------------------------------------------
	function Icons.RenderFrames(holder, doc, color)
		for _, c in ipairs(holder:GetChildren()) do
			if c:IsA("Frame") then c:Destroy() end
		end
		if not doc then return end
		local U = 100 -- work in a 0..100 percentage space
		local scale = U / math.max(doc.width, doc.height)
		local offX = (U - doc.width * scale) * 0.5 - doc.minX * scale
		local offY = (U - doc.height * scale) * 0.5 - doc.minY * scale

		local budget = 220
		for _, shape in ipairs(doc.shapes) do
			local w = math.max((shape.stroke and shape.strokeWidth or 1.4) * scale, 4.5)
			for pi, p in ipairs(shape.polys) do
				local pts = {}
				for j = 1, #p, 2 do
					pts[#pts + 1] = { p[j] * scale + offX, p[j + 1] * scale + offY }
				end
				if shape.closed and shape.closed[pi] and #pts > 2 then
					pts[#pts + 1] = pts[1]
				end
				for i = 1, #pts - 1 do
					if budget <= 0 then return end
					budget = budget - 1
					local a, b = pts[i], pts[i + 1]
					local dx, dy = b[1] - a[1], b[2] - a[2]
					local len = math.sqrt(dx * dx + dy * dy)
					if len > 0.2 then
						local seg = Instance.new("Frame")
						seg.BorderSizePixel = 0
						seg.BackgroundColor3 = color
						seg.AnchorPoint = Vector2.new(0.5, 0.5)
						seg.Position = UDim2.fromScale((a[1] + b[1]) / 2 / U, (a[2] + b[2]) / 2 / U)
						seg.Size = UDim2.fromScale((len + w * 0.6) / U, w / U)
						seg.Rotation = math.deg(math.atan2(dy, dx))
						local uc = Instance.new("UICorner")
						uc.CornerRadius = UDim.new(1, 0)
						uc.Parent = seg
						seg.Parent = holder
					end
				end
			end
		end
	end

	----------------------------------------------------------------------------------------------
	-- public: attach an icon to an ImageLabel (+ optional frame holder)
	----------------------------------------------------------------------------------------------
	local function assign(target, content)
		if typeof(content) == "string" then
			target.Image = content
			target.ImageTransparency = 0
			return true
		end
		local ok = pcall(function() target.ImageContent = content end)
		if ok then
			target.ImageTransparency = 0
			return true
		end
		return false
	end

	--- name may be "home-2", "solar:home-2-bold", "rbxassetid://123" or a raw number.
	function Icons.Apply(target, name, style, holder, color)
		if not target or not name or name == "" then return end
		holder = holder or target
		local raw = tostring(name)

		-- "builtin:<name>" skips the network entirely and uses the embedded vector set.
		-- Used for the library's own glyphs (chevrons, ticks) which have no Solar equivalent.
		local forceOffline = false
		if raw:sub(1, 8) == "builtin:" then
			forceOffline = true
			raw = raw:sub(9)
		end

		if raw:match("^rbxassetid://") or raw:match("^rbxasset://") or raw:match("^http") then
			target.Image = raw
			return
		end
		if tonumber(raw) then
			target.Image = "rbxassetid://" .. raw
			return
		end

		local key, base = Icons.Resolve(raw, style)
		if forceOffline then key = "builtin:" .. base end
		local cached = Icons.Cache[key]
		if cached then
			if cached.content then
				assign(target, cached.content)
			elseif cached.doc and holder then
				target.ImageTransparency = 1
				Icons.RenderFrames(holder, cached.doc, color or Color3.new(1, 1, 1))
			end
			return
		end

		target.ImageTransparency = 1

		task.spawn(function()
			-- wait (briefly) for the transport probe to settle before deciding
			if not forceOffline then
				local t0 = os.clock()
				while not Http.Probed and os.clock() - t0 < 3 do task.wait(0.1) end
			end

			local source = nil
			if Http.Available and not forceOffline then
				for _, ep in ipairs(Icons.Endpoints) do
					local body = Http.Get(string.format(ep, key))
					if body and (body:find("<path", 1, true) or body:find("<circle", 1, true)
						or body:find("<rect", 1, true)) then
						source = body
						break
					end
				end
			end
			if not source then
				source = Icons.Offline(base)
			end

			local content, doc = Icons.BuildImage(source, Icons.Size)
			Icons.Cache[key] = { content = content, doc = doc }

			if target.Parent then
				if content then
					assign(target, content)
				elseif doc and holder then
					target.ImageTransparency = 1
					Icons.RenderFrames(holder, doc, color or Color3.new(1, 1, 1))
				end
			end
		end)
	end
end

--=================================================================================================
--  THEME
--=================================================================================================

local Themes = {
	Dark = {
		Name           = "Dark",
		Window         = Color3.fromRGB(30, 30, 32),
		WindowStroke   = Color3.fromRGB(70, 70, 76),
		Titlebar       = Color3.fromRGB(44, 44, 47),
		Sidebar        = Color3.fromRGB(38, 38, 41),
		Divider        = Color3.fromRGB(58, 58, 63),
		Card           = Color3.fromRGB(44, 44, 48),
		CardStroke     = Color3.fromRGB(60, 60, 66),
		Element        = Color3.fromRGB(58, 58, 63),
		ElementHover   = Color3.fromRGB(70, 70, 76),
		Popup          = Color3.fromRGB(50, 50, 55),
		PopupStroke    = Color3.fromRGB(78, 78, 84),
		Text           = Color3.fromRGB(245, 245, 247),
		SubText        = Color3.fromRGB(160, 160, 168),
		Muted          = Color3.fromRGB(118, 118, 126),
		Accent         = Color3.fromRGB(10, 132, 255),
		AccentText     = Color3.fromRGB(255, 255, 255),
		Track          = Color3.fromRGB(72, 72, 78),
		Knob           = Color3.fromRGB(255, 255, 255),
		Overlay        = Color3.fromRGB(0, 0, 0),
		Shadow         = Color3.fromRGB(0, 0, 0),
		ShadowAlpha    = 0.45,
	},
	Light = {
		Name           = "Light",
		Window         = Color3.fromRGB(246, 246, 248),
		WindowStroke   = Color3.fromRGB(206, 206, 212),
		Titlebar       = Color3.fromRGB(236, 236, 240),
		Sidebar        = Color3.fromRGB(232, 232, 237),
		Divider        = Color3.fromRGB(214, 214, 220),
		Card           = Color3.fromRGB(255, 255, 255),
		CardStroke     = Color3.fromRGB(222, 222, 228),
		Element        = Color3.fromRGB(238, 238, 242),
		ElementHover   = Color3.fromRGB(228, 228, 234),
		Popup          = Color3.fromRGB(252, 252, 254),
		PopupStroke    = Color3.fromRGB(214, 214, 220),
		Text           = Color3.fromRGB(28, 28, 30),
		SubText        = Color3.fromRGB(110, 110, 118),
		Muted          = Color3.fromRGB(150, 150, 158),
		Accent         = Color3.fromRGB(0, 122, 255),
		AccentText     = Color3.fromRGB(255, 255, 255),
		Track          = Color3.fromRGB(206, 206, 212),
		Knob           = Color3.fromRGB(255, 255, 255),
		Overlay        = Color3.fromRGB(120, 120, 128),
		Shadow         = Color3.fromRGB(60, 60, 70),
		ShadowAlpha    = 0.62,
	},
}

--- Known executors, sourced from the WEAO tracker's exploit list (https://weao.gg).
--- Colours approximate each brand's accent - tweak freely, nothing depends on them.
local ExecutorColors = {
	-- Windows (WEAO)
	wave        = Color3.fromRGB( 56, 148, 255),
	volt        = Color3.fromRGB(150,  90, 255),
	solara      = Color3.fromRGB(255, 168,  60),
	xeno        = Color3.fromRGB( 60, 220, 160),
	potassium   = Color3.fromRGB(185, 150, 255),
	photon      = Color3.fromRGB(255, 220,  90),
	sirhurt     = Color3.fromRGB(235,  70,  90),
	matrixhub   = Color3.fromRGB( 70, 230, 110),
	ronin       = Color3.fromRGB(230,  60,  70),
	melatonin   = Color3.fromRGB(120, 110, 235),
	cosmic      = Color3.fromRGB(225, 100, 220),
	real        = Color3.fromRGB(225, 225, 235),
	dx9ware     = Color3.fromRGB(255, 140,  50),
	velocity    = Color3.fromRGB( 70, 190, 255),
	volcano     = Color3.fromRGB(255,  95,  55),
	serotonin   = Color3.fromRGB(255, 120, 175),
	synapsez    = Color3.fromRGB( 95, 130, 255),
	lumen       = Color3.fromRGB(255, 205, 120),
	matcha      = Color3.fromRGB(140, 200,  90),
	seliware    = Color3.fromRGB( 60, 205, 195),
	severe      = Color3.fromRGB(200,  45,  60),
	rbxcli      = Color3.fromRGB(110, 220, 130),
	madium      = Color3.fromRGB(160, 110, 240),
	-- cross platform / also common in the wild
	delta       = Color3.fromRGB(110, 120, 255),
	codex       = Color3.fromRGB( 90, 210, 140),
	vegax       = Color3.fromRGB(150, 190, 255),
	macsploit   = Color3.fromRGB(200, 200, 210),
	opiumware   = Color3.fromRGB(140,  80, 200),
	zenith      = Color3.fromRGB(  0, 200, 220),
	swift       = Color3.fromRGB(255, 110,  90),
	krnl        = Color3.fromRGB(255, 150,  60),
	fluxus      = Color3.fromRGB( 80, 210, 235),
	hydrogen    = Color3.fromRGB(120, 190, 255),
	arceusx     = Color3.fromRGB(255, 190,  70),
	nihon       = Color3.fromRGB(240,  80,  90),
	bunni       = Color3.fromRGB(255, 150, 200),
	argon       = Color3.fromRGB(110, 200, 255),
	ronix       = Color3.fromRGB(120, 140, 255),
	awp         = Color3.fromRGB(180, 230,  80),
	comet       = Color3.fromRGB( 90, 220, 230),
	nezur       = Color3.fromRGB(150, 100, 240),
	jjsploit    = Color3.fromRGB(250, 180,  60),
	cryptic     = Color3.fromRGB( 60, 200, 170),
	luna        = Color3.fromRGB(190, 210, 255),
}

--- Resolves an identifyexecutor() string to a display label and a brand colour.
--- Falls back to a neutral grey for anything unrecognised.
local function resolveExecutor(raw)
	local pretty = tostring(raw or "Unknown")
	local key = pretty:lower():gsub("[^%w]", "")
	if key == "" then return pretty, nil end
	local color = ExecutorColors[key]
	if not color then
		-- tolerate suffixes and decorations, e.g. "Wave 2.4" or "Xeno (v1)"
		for name, c in pairs(ExecutorColors) do
			if #name >= 4 and key:find(name, 1, true) then
				color = c
				break
			end
		end
	end
	return pretty, color
end

local Traffic = {
	Red    = Color3.fromRGB(255, 95, 87),
	Yellow = Color3.fromRGB(255, 189, 46),
	Green  = Color3.fromRGB(40, 200, 64),
	Idle   = Color3.fromRGB(125, 125, 132),
}

--=================================================================================================
--  UTILITIES
--=================================================================================================

local Util = {}
local ThemeBindings = {}   -- { instance, property, themeKey }

do
	local function tryFont(family, weight)
		local ok, f = pcall(function()
			return Font.new("rbxasset://fonts/families/" .. family .. ".json", weight, Enum.FontStyle.Normal)
		end)
		if ok and f then return f end
		return nil
	end

	local fontCache = {}
	function Util.Font(weight)
		weight = weight or Enum.FontWeight.Medium
		if fontCache[weight] then return fontCache[weight] end
		local f = tryFont("BuilderSans", weight) or tryFont("GothamSSm", weight) or tryFont("SourceSansPro", weight)
		fontCache[weight] = f
		return f
	end

	function Util.SetFont(label, weight)
		local f = Util.Font(weight)
		if f then
			local ok = pcall(function() label.FontFace = f end)
			if ok then return end
		end
		pcall(function() label.Font = Enum.Font.GothamMedium end)
	end

	--- Creates an instance. `props.Theme = { Prop = "ThemeKey" }` binds live theme colours.
	function Util.New(class, props, children)
		local inst = Instance.new(class)
		local themeMap = nil
		if props then
			themeMap = props.Theme
			props.Theme = nil
			local weight = props.Weight
			props.Weight = nil
			for k, v in pairs(props) do
				if k ~= "Parent" then inst[k] = v end
			end
			if weight ~= nil and (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) then
				Util.SetFont(inst, weight)
			end
			if props.Parent then inst.Parent = props.Parent end
		end
		if themeMap then
			for prop, key in pairs(themeMap) do
				ThemeBindings[#ThemeBindings + 1] = { inst, prop, key }
			end
		end
		if children then
			for _, c in ipairs(children) do c.Parent = inst end
		end
		return inst
	end

	function Util.Corner(radius, parent)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = parent
		return c
	end

	function Util.Stroke(parent, themeKey, thickness, transparency)
		local s = Instance.new("UIStroke")
		s.Thickness = thickness or 1
		s.Transparency = transparency or 0
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = parent
		if themeKey then ThemeBindings[#ThemeBindings + 1] = { s, "Color", themeKey } end
		return s
	end

	function Util.Padding(parent, top, right, bottom, left)
		local p = Instance.new("UIPadding")
		p.PaddingTop = UDim.new(0, top or 0)
		p.PaddingRight = UDim.new(0, right or top or 0)
		p.PaddingBottom = UDim.new(0, bottom or top or 0)
		p.PaddingLeft = UDim.new(0, left or right or top or 0)
		p.Parent = parent
		return p
	end

	function Util.List(parent, padding, direction, align)
		local l = Instance.new("UIListLayout")
		l.Padding = UDim.new(0, padding or 0)
		l.FillDirection = direction or Enum.FillDirection.Vertical
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.HorizontalAlignment = align or Enum.HorizontalAlignment.Left
		l.VerticalAlignment = Enum.VerticalAlignment.Top
		l.Parent = parent
		return l
	end

	local EASE = Enum.EasingStyle.Quint
	function Util.Tween(inst, time, props, style, dir)
		local info = TweenInfo.new(time or 0.22, style or EASE, dir or Enum.EasingDirection.Out)
		local t = TweenService:Create(inst, info, props)
		t:Play()
		return t
	end

	function Util.Bind(inst, prop, key)
		ThemeBindings[#ThemeBindings + 1] = { inst, prop, key }
		return inst
	end

	--- macOS-ish soft drop shadow, built from stacked rounded frames.
	--- Asset-free on purpose: uploaded shadow images get moderated and then render as
	--- a flat grey rectangle, which is worse than no shadow at all.
	function Util.Shadow(parent, spread, strength, radius)
		spread   = spread or 50
		strength = strength or 1
		radius   = radius or 12

		local holder = Util.New("Frame", {
			Name = "Shadow",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = 0,
			Parent = parent,
		})

		local layers = 5
		for i = 1, layers do
			local grow = spread * (i / layers)
			local falloff = 1 - (i - 1) / layers
			local f = Util.New("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, math.floor(grow * 0.22)),
				Size = UDim2.new(1, grow, 1, grow),
				BackgroundColor3 = MacLib.Theme.Shadow,
				BackgroundTransparency = 1 - (strength * 0.2 * falloff),
				BorderSizePixel = 0,
				ZIndex = 0,
				Parent = holder,
				Theme = { BackgroundColor3 = "Shadow" },
			})
			Util.Corner(math.floor(radius + grow / 2), f)
		end
		return holder
	end

	function Util.Hoverable(button, target, normalKey, hoverKey)
		button.MouseEnter:Connect(function()
			Util.Tween(target, 0.14, { BackgroundColor3 = MacLib.Theme[hoverKey] })
		end)
		button.MouseLeave:Connect(function()
			Util.Tween(target, 0.18, { BackgroundColor3 = MacLib.Theme[normalKey] })
		end)
	end

	function Util.Scrollbar(sf)
		sf.ScrollBarThickness = 3
		sf.ScrollBarImageTransparency = 0.35
		sf.BorderSizePixel = 0
		sf.BackgroundTransparency = 1
		sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
		sf.CanvasSize = UDim2.new()
		sf.ScrollingDirection = Enum.ScrollingDirection.Y
		sf.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
		ThemeBindings[#ThemeBindings + 1] = { sf, "ScrollBarImageColor3", "Muted" }
		return sf
	end
end

--=================================================================================================
--  SELF TEST
--  Probes every environment capability the library leans on, so the footer can tell the
--  user up front whether this executor will run the UI properly.
--=================================================================================================

local SUPPORT_LABEL = { full = "Full Support", partial = "Partial Support", broken = "Broken" }

function Util.Hex(color)
	if typeof(color) ~= "Color3" then return "FFFFFF" end
	return string.format("%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5))
end

--- Runs every capability probe. `window` is optional; `callback` receives the result table.
--- Result: { Level = "full"|"partial"|"broken", Checks = { {Name, OK, Critical, Detail} } }
function MacLib:RunSelfTest(window, callback)
	task.spawn(function()
		local checks = {}
		local function add(name, ok, critical, detail)
			checks[#checks + 1] = {
				Name = name, OK = ok and true or false,
				Critical = critical and true or false, Detail = detail or "",
			}
		end

		------------------------------------------------------------------ 1. GUI container
		local guiOK, guiWhere = false, "no usable container"
		if window and window.Gui and window.Gui.Parent then
			guiOK, guiWhere = true, "attached"
		else
			local probe = Instance.new("ScreenGui")
			if Env.gethui and pcall(function() probe.Parent = Env.gethui() end) then
				guiOK, guiWhere = true, "gethui"
			elseif pcall(function() probe.Parent = CoreGui end) then
				guiOK, guiWhere = true, "CoreGui"
			elseif pcall(function() probe.Parent = LocalPlayer:WaitForChild("PlayerGui") end) then
				guiOK, guiWhere = true, "PlayerGui"
			end
			pcall(function() probe:Destroy() end)
		end
		add("Interface", guiOK, true, guiWhere)

		------------------------------------------------------------------ 2. instances / layout
		local layoutOK = pcall(function()
			local f = Instance.new("Frame")
			f.Size = UDim2.fromOffset(10, 10)
			local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 6) c.Parent = f
			local st = Instance.new("UIStroke") st.Thickness = 1 st.Parent = f
			local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 4) l.Parent = f
			local sc = Instance.new("UIScale") sc.Scale = 1 sc.Parent = f
			f:Destroy()
		end)
		add("Layout", layoutOK, true, layoutOK and "corners, strokes, layouts" or "instance creation blocked")

		------------------------------------------------------------------ 3. input
		local inputOK = pcall(function()
			local _ = UserInputService.KeyboardEnabled
			local conn = UserInputService.InputBegan:Connect(function() end)
			conn:Disconnect()
		end)
		add("Input", inputOK, true, inputOK and "keybinds and toggle key" or "UserInputService blocked")

		------------------------------------------------------------------ 4. tween
		local tweenOK = pcall(function()
			local f = Instance.new("Frame")
			TweenService:Create(f, TweenInfo.new(0.1), { BackgroundTransparency = 1 }):Play()
			f:Destroy()
		end)
		add("Animation", tweenOK, false, tweenOK and "TweenService" or "tweens unavailable")

		------------------------------------------------------------------ 5. fonts
		local fontOK = Util.Font(Enum.FontWeight.Medium) ~= nil
		add("Fonts", fontOK, false, fontOK and "BuilderSans" or "falling back to legacy fonts")

		------------------------------------------------------------------ 6. vector engine
		local vectorOK, vectorDetail = false, "rasteriser failed"
		local okv, err = pcall(function()
			local doc = SVG.Parse(Icons.BuiltIn.widget)
			assert(doc and #doc.shapes > 0, "no shapes parsed")
			local cov = SVG.Rasterize(doc, 32)
			local ink = 0
			for i = 1, 32 * 32 do ink = ink + (cov[i] or 0) end
			assert(ink > 1, "blank raster")
			vectorDetail = "SVG parser and rasteriser"
		end)
		vectorOK = okv
		if not okv then vectorDetail = tostring(err) end
		add("Vector engine", vectorOK, false, vectorDetail)

		------------------------------------------------------------------ 7. EditableImage
		local content = Icons.BuildImage(Icons.BuiltIn.widget, 32)
		local editableOK = content ~= nil
		add("Icon images", editableOK, false,
			editableOK and "EditableImage" or "EditableImage blocked, drawing icons as frames")

		------------------------------------------------------------------ 8. icon download
		local httpOK, httpDetail = false, "no HTTP transport"
		if Http.Request then
			httpDetail = "request({}) present but no icon returned"
		elseif Env.IsExecutor then
			httpDetail = "no request({}), trying HttpGet"
		end
		local t0 = os.clock()
		while not Http.Probed and os.clock() - t0 < 5 do task.wait(0.1) end
		if Http.Available then
			local body = Http.Get(string.format(Icons.Endpoints[1], "home-2-outline"))
			if body and body:find("<path", 1, true) then
				local doc = SVG.Parse(body)
				if doc and #doc.shapes > 0 then
					httpOK = true
					httpDetail = Http.Request and "request({})" or "HttpGet"
				else
					httpDetail = "downloaded but could not be parsed"
				end
			end
		end
		add("Solar icons", httpOK, false,
			httpOK and (httpDetail .. ", live download") or (httpDetail .. ", using offline set"))

		------------------------------------------------------------------ 9. filesystem
		local fsOK, fsDetail = false, "no file system access"
		if Env.HasFS then
			local folder = (window and window.ConfigFolder) or "MacLib"
			local path = folder .. "/.maclib_probe"
			local ok = pcall(function()
				if Env.makefolder and Env.isfolder and not Env.isfolder(folder) then
					Env.makefolder(folder)
				end
				Env.writefile(path, "ok")
				assert(Env.readfile(path) == "ok", "read back mismatch")
			end)
			pcall(function() if Env.delfile then Env.delfile(path) end end)
			fsOK = ok
			fsDetail = ok and "configs can be saved" or "write or read failed"
		end
		add("File system", fsOK, false, fsDetail)

		------------------------------------------------------------------ 10. blur
		local blurOK = false
		pcall(function()
			local b = Instance.new("BlurEffect")
			b.Size = 0
			b.Parent = Lighting
			blurOK = b.Parent ~= nil
			b:Destroy()
		end)
		add("Background blur", blurOK, false, blurOK and "Lighting writable" or "Lighting not writable")

		------------------------------------------------------------------ verdict
		local level = "full"
		for _, c in ipairs(checks) do
			if not c.OK then
				if c.Critical then
					level = "broken"
					break
				end
				level = "partial"
			end
		end

		local result = { Level = level, Label = SUPPORT_LABEL[level], Checks = checks }
		MacLib.Support = result
		if callback then pcall(callback, result) end
	end)
end

function MacLib:GetSupport()
	return MacLib.Support
end

MacLib.SupportColors = {
	full    = Color3.fromRGB( 48, 209,  88),
	partial = Color3.fromRGB(255, 189,  46),
	broken  = Color3.fromRGB(255,  85,  75),
}

MacLib.ExecutorColors = ExecutorColors
MacLib.ResolveExecutor = function(_, raw) return resolveExecutor(raw) end

MacLib.Theme = Themes.Dark
MacLib.Util = Util
MacLib.Themes = Themes

function MacLib:SetTheme(name)
	local theme = Themes[name] or (type(name) == "table" and name) or Themes.Dark
	MacLib.Theme = theme
	for i = #ThemeBindings, 1, -1 do
		local b = ThemeBindings[i]
		local inst, prop, key = b[1], b[2], b[3]
		if typeof(inst) == "Instance" and inst.Parent ~= nil then
			local value = theme[key]
			if value then
				pcall(function()
					Util.Tween(inst, 0.25, { [prop] = value })
				end)
			end
		elseif typeof(inst) ~= "Instance" then
			table.remove(ThemeBindings, i)
		end
	end
	for _, w in ipairs(MacLib.Windows) do
		if w._OnTheme then
			for _, fn in ipairs(w._OnTheme) do pcall(fn, theme) end
		end
	end
	return theme
end

--=================================================================================================
--  ROOT SCREENGUI
--=================================================================================================

local function createScreenGui(name)
	local gui = Instance.new("ScreenGui")
	gui.Name = name or ("MacLib_" .. tostring(math.random(100000, 999999)))
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local parented = false
	if Env.gethui then
		parented = pcall(function() gui.Parent = Env.gethui() end)
	end
	if not parented and Env.protectgui then
		parented = pcall(function()
			Env.protectgui(gui)
			gui.Parent = CoreGui
		end)
	end
	if not parented then
		parented = pcall(function() gui.Parent = CoreGui end)
	end
	if not parented then
		pcall(function()
			gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
		end)
	end
	return gui
end

--=================================================================================================
--  WINDOW
--=================================================================================================

local Window = {}
Window.__index = Window

local function resolveSize(size)
	if typeof(size) == "UDim2" then return size end
	if typeof(size) == "Vector2" then return UDim2.fromOffset(size.X, size.Y) end
	return UDim2.fromOffset(760, 480)
end

function MacLib:Window(config)
	config = config or {}

	if config.Theme then MacLib:SetTheme(config.Theme) end
	if config.Accent then
		MacLib.Theme.Accent = config.Accent
		Themes.Dark.Accent = config.Accent
		Themes.Light.Accent = config.Accent
	end

	local self = setmetatable({}, Window)
	self.Title       = config.Title or "MacLib"
	self.Subtitle    = config.Subtitle or ("v" .. MacLib.Version)
	self.Tabs        = {}
	self.TabSections = {}
	self.Flags       = MacLib.Flags
	self.Values      = MacLib.Values
	self.Open        = true
	self.Minimized   = false
	self.Maximized   = false
	self.ConfigFolder= config.Folder or config.ConfigFolder or "MacLib"
	self.IconStyle   = config.IconStyle or config.Style or "outline"
	self.ToggleKey   = config.ToggleKey or config.Keybind or Enum.KeyCode.RightShift
	self._OnTheme    = {}
	self._Connections= {}

	Icons.Style = self.IconStyle

	local theme = MacLib.Theme
	local gui = createScreenGui(config.Name)
	self.Gui = gui

	local defaultSize = resolveSize(config.Size)
	self.DefaultSize = defaultSize

	----------------------------------------------------------------------------------------------
	-- root
	----------------------------------------------------------------------------------------------
	local root = Util.New("Frame", {
		Name = "Root",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = defaultSize,
		BackgroundTransparency = 1,
		Parent = gui,
	})
	self.Root = root

	Util.Shadow(root, 64, 1, 12)

	local main = Util.New("Frame", {
		Name = "Main",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = theme.Window,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = root,
		Theme = { BackgroundColor3 = "Window" },
	})
	Util.Corner(12, main)
	Util.Stroke(main, "WindowStroke", 1, 0.35)
	self.Main = main

	----------------------------------------------------------------------------------------------
	-- title bar
	----------------------------------------------------------------------------------------------
	local titlebar = Util.New("Frame", {
		Name = "TitleBar",
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = theme.Titlebar,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = main,
		Theme = { BackgroundColor3 = "Titlebar" },
	})
	Util.Corner(12, titlebar)
	-- ClipsDescendants clips to a rectangle, not to the parent's corner radius, so an
	-- opaque square child squares off the window. Round the bar and mask the edge that
	-- should stay flat instead.
	Util.New("Frame", {
		Name = "SquareOff",
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 1, -14),
		BackgroundColor3 = theme.Titlebar,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = titlebar,
		Theme = { BackgroundColor3 = "Titlebar" },
	})
	Util.New("Frame", {
		Name = "Hairline",
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.new(0, 0, 1, -1),
		BackgroundColor3 = theme.Divider,
		BorderSizePixel = 0,
		ZIndex = 7,
		Parent = titlebar,
		Theme = { BackgroundColor3 = "Divider" },
	})

	local lights = Util.New("Frame", {
		Name = "TrafficLights",
		Size = UDim2.new(0, 60, 0, 13),
		Position = UDim2.new(0, 14, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 8,
		Parent = titlebar,
	})
	Util.List(lights, 8, Enum.FillDirection.Horizontal)

	local function makeLight(color, order)
		local btn = Util.New("TextButton", {
			Size = UDim2.fromOffset(13, 13),
			BackgroundColor3 = color,
			AutoButtonColor = false,
			Text = "",
			BorderSizePixel = 0,
			LayoutOrder = order,
			ZIndex = 8,
			Parent = lights,
		})
		Util.Corner(7, btn)
		-- no hover glyphs: plain dots read cleaner at this size
		btn.MouseEnter:Connect(function()
			Util.Tween(btn, 0.12, { BackgroundColor3 = color:Lerp(Color3.new(0, 0, 0), 0.18) })
		end)
		btn.MouseLeave:Connect(function()
			Util.Tween(btn, 0.16, { BackgroundColor3 = color })
		end)
		return btn
	end

	local closeBtn = makeLight(Traffic.Red, 1)
	local minBtn   = makeLight(Traffic.Yellow, 2)
	local maxBtn   = makeLight(Traffic.Green, 3)

	local titleWrap = Util.New("Frame", {
		Name = "TitleWrap",
		Size = UDim2.new(1, -220, 1, 0),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		ZIndex = 7,
		Parent = titlebar,
	})
	local titleLabel = Util.New("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 0, 8),
		BackgroundTransparency = 1,
		Text = self.Title,
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Weight = Enum.FontWeight.SemiBold,
		ZIndex = 7,
		Parent = titleWrap,
		Theme = { TextColor3 = "Text" },
	})
	local subLabel = Util.New("TextLabel", {
		Name = "Subtitle",
		Size = UDim2.new(1, 0, 0, 12),
		Position = UDim2.new(0, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = self.Subtitle,
		TextSize = 11,
		TextColor3 = theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Weight = Enum.FontWeight.Medium,
		ZIndex = 7,
		Parent = titleWrap,
		Theme = { TextColor3 = "Muted" },
	})
	self.TitleLabel, self.SubtitleLabel = titleLabel, subLabel

	-- right side: theme switch
	local themeBtn = Util.New("TextButton", {
		Name = "ThemeToggle",
		Size = UDim2.fromOffset(26, 26),
		Position = UDim2.new(1, -14, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.Element,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 8,
		Parent = titlebar,
		Theme = { BackgroundColor3 = "Element" },
	})
	Util.Corner(8, themeBtn)
	local themeIcon = Util.New("ImageLabel", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ImageColor3 = theme.SubText,
		ZIndex = 9,
		Parent = themeBtn,
		Theme = { ImageColor3 = "SubText" },
	})
	Icons.Apply(themeIcon, "moon", self.IconStyle, themeIcon, theme.SubText)
	table.insert(self._OnTheme, function(th)
		Icons.Apply(themeIcon, th.Name == "Dark" and "moon" or "sun", self.IconStyle, themeIcon, th.SubText)
	end)
	themeBtn.MouseEnter:Connect(function() Util.Tween(themeBtn, 0.12, { BackgroundTransparency = 0 }) end)
	themeBtn.MouseLeave:Connect(function() Util.Tween(themeBtn, 0.16, { BackgroundTransparency = 1 }) end)
	themeBtn.MouseButton1Click:Connect(function()
		MacLib:SetTheme(MacLib.Theme.Name == "Dark" and "Light" or "Dark")
	end)

	----------------------------------------------------------------------------------------------
	-- body : sidebar + content
	----------------------------------------------------------------------------------------------
	local body = Util.New("Frame", {
		Name = "Body",
		Size = UDim2.new(1, 0, 1, -42),
		Position = UDim2.new(0, 0, 0, 42),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = main,
	})

	local sidebar = Util.New("Frame", {
		Name = "Sidebar",
		Size = UDim2.new(0, 186, 1, 0),
		BackgroundColor3 = theme.Sidebar,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = body,
		Theme = { BackgroundColor3 = "Sidebar" },
	})
	Util.Corner(12, sidebar)
	Util.New("Frame", {
		Name = "SquareOffTop",
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundColor3 = theme.Sidebar,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = sidebar,
		Theme = { BackgroundColor3 = "Sidebar" },
	})
	Util.New("Frame", {
		Name = "SquareOffRight",
		Size = UDim2.new(0, 14, 1, 0),
		Position = UDim2.new(1, -14, 0, 0),
		BackgroundColor3 = theme.Sidebar,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = sidebar,
		Theme = { BackgroundColor3 = "Sidebar" },
	})
	Util.New("Frame", {
		Name = "Edge",
		Size = UDim2.new(0, 1, 1, 0),
		Position = UDim2.new(1, -1, 0, 0),
		BackgroundColor3 = theme.Divider,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = sidebar,
		Theme = { BackgroundColor3 = "Divider" },
	})
	self.Sidebar = sidebar

	local tabList = Util.Scrollbar(Util.New("ScrollingFrame", {
		Name = "TabList",
		Size = UDim2.new(1, -1, 1, -40),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = sidebar,
	}))
	Util.Padding(tabList, 10, 10, 10, 10)
	Util.List(tabList, 3)
	self.TabList = tabList

	-- sidebar footer
	local footer = Util.New("Frame", {
		Name = "Footer",
		Size = UDim2.new(1, -1, 0, 40),
		Position = UDim2.new(0, 0, 1, -40),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = sidebar,
	})
	Util.New("Frame", {
		Size = UDim2.new(1, -20, 0, 1),
		Position = UDim2.new(0, 10, 0, 0),
		BackgroundColor3 = theme.Divider,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = footer,
		Theme = { BackgroundColor3 = "Divider" },
	})
	local exeName, exeColor = resolveExecutor(Env.IsExecutor and Env.Executor or "LocalScript")
	self.ExecutorColor = exeColor

	local exeLabel = Util.New("TextLabel", {
		Name = "Executor",
		Size = UDim2.new(1, -22, 1, 0),
		Position = UDim2.new(0, 12, 0, 0),
		BackgroundTransparency = 1,
		RichText = true,
		Text = "",
		TextSize = 11,
		TextColor3 = theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Weight = Enum.FontWeight.Bold,
		ZIndex = 5,
		Parent = footer,
	})

	local supportBtn = Util.New("TextButton", {
		Name = "SupportHit",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 6,
		Parent = footer,
	})

	--- Repaints the footer badge. Called on load, when the self test finishes and on
	--- every theme change, since RichText bakes its colours into the string.
	local function paintFooter()
		local th = MacLib.Theme
		local res = MacLib.Support
		local nameHex = Util.Hex(exeColor or th.Muted)
		local badgeText, badgeHex
		if res then
			badgeText = res.Label
			badgeHex = Util.Hex(MacLib.SupportColors[res.Level] or th.Muted)
		else
			badgeText = "Checking"
			badgeHex = Util.Hex(th.Muted)
		end
		exeLabel.Text = string.format(
			'<font color="#%s">[ %s ]</font> <font color="#%s">[ %s ]</font>',
			nameHex, exeName, badgeHex, badgeText)

		-- step the size down rather than truncate the badge on long executor names
		exeLabel.TextSize = 11
		pcall(function()
			for _, size in ipairs({ 11, 10, 9 }) do
				exeLabel.TextSize = size
				if exeLabel.TextBounds.X <= exeLabel.AbsoluteSize.X then break end
			end
		end)
	end
	self._PaintFooter = paintFooter
	paintFooter()
	table.insert(self._OnTheme, paintFooter)

	MacLib:RunSelfTest(self, function(result)
		self.Support = result
		paintFooter()
	end)

	supportBtn.MouseButton1Click:Connect(function()
		local res = MacLib.Support
		if not res then
			self:Notify({ Title = "Still checking", Description = "The environment probe has not finished yet.",
				Icon = "refresh", Duration = 3 })
			return
		end
		local lines = {}
		for _, c in ipairs(res.Checks) do
			local hex = c.OK and Util.Hex(MacLib.SupportColors.full)
				or (c.Critical and Util.Hex(MacLib.SupportColors.broken) or Util.Hex(MacLib.SupportColors.partial))
			lines[#lines + 1] = string.format('%s  <font color="#%s">%s</font>',
				c.Name, hex, c.Detail ~= "" and c.Detail or (c.OK and "ok" or "unavailable"))
		end
		self:Dialog({
			Title = "[ " .. exeName .. " ]  " .. res.Label,
			Description = table.concat(lines, "\n"),
			RichText = true,
			Width = 420,
			Buttons = { { Title = "Close", Primary = true } },
		})
	end)

	local container = Util.New("Frame", {
		Name = "Container",
		Size = UDim2.new(1, -186, 1, 0),
		Position = UDim2.new(0, 186, 0, 0),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 3,
		Parent = body,
	})
	self.Container = container

	-- empty state
	local empty = Util.New("TextLabel", {
		Name = "Empty",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "No tabs yet",
		TextSize = 13,
		TextColor3 = theme.Muted,
		Weight = Enum.FontWeight.Medium,
		ZIndex = 3,
		Parent = container,
		Theme = { TextColor3 = "Muted" },
	})
	self.EmptyLabel = empty

	----------------------------------------------------------------------------------------------
	-- overlay (dialogs / dropdown blocker)
	----------------------------------------------------------------------------------------------
	local overlay = Util.New("Frame", {
		Name = "Overlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = theme.Overlay,
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 40,
		Parent = main,
		Theme = { BackgroundColor3 = "Overlay" },
	})
	self.Overlay = overlay

	----------------------------------------------------------------------------------------------
	-- dragging
	----------------------------------------------------------------------------------------------
	do
		local dragging, dragStart, startPos = false, nil, nil
		titlebar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = root.Position
			end
		end)
		titlebar.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
		self._Connections[#self._Connections + 1] = UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				root.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + d.X,
					startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end)
	end

	----------------------------------------------------------------------------------------------
	-- resizing
	----------------------------------------------------------------------------------------------
	do
		local grip = Util.New("TextButton", {
			Name = "Resize",
			Size = UDim2.fromOffset(24, 24),
			Position = UDim2.new(1, -24, 1, -24),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 30,
			Parent = main,
		})
		local gripIcon = Util.New("ImageLabel", {
			Name = "GripIcon",
			Size = UDim2.fromOffset(15, 15),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			ImageColor3 = theme.SubText,
			ImageTransparency = 1,
			ZIndex = 31,
			Parent = grip,
			Theme = { ImageColor3 = "SubText" },
		})
		Icons.Apply(gripIcon, "scaling", self.IconStyle, gripIcon, theme.SubText)
		grip.MouseEnter:Connect(function()
			Util.Tween(gripIcon, 0.12, { Size = UDim2.fromOffset(17, 17) })
		end)
		grip.MouseLeave:Connect(function()
			Util.Tween(gripIcon, 0.16, { Size = UDim2.fromOffset(15, 15) })
		end)
		local resizing, startIn, startSize = false, nil, nil
		grip.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				resizing = true
				startIn = input.Position
				startSize = root.AbsoluteSize
			end
		end)
		grip.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				resizing = false
			end
		end)
		self._Connections[#self._Connections + 1] = UserInputService.InputChanged:Connect(function(input)
			if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - startIn
				local w = math.max(560, startSize.X + d.X)
				local h = math.max(360, startSize.Y + d.Y)
				root.Size = UDim2.fromOffset(w, h)
				self.CurrentSize = root.Size
				self.Maximized = false
			end
		end)
	end

	----------------------------------------------------------------------------------------------
	-- traffic light behaviour
	----------------------------------------------------------------------------------------------
	local minimizedChip
	local blur

	local function buildChip()
		local chip = Util.New("TextButton", {
			Name = "Chip",
			Size = UDim2.fromOffset(190, 38),
			Position = UDim2.new(0.5, 0, 1, -26),
			AnchorPoint = Vector2.new(0.5, 1),
			BackgroundColor3 = theme.Titlebar,
			AutoButtonColor = false,
			Text = "",
			Visible = false,
			ZIndex = 50,
			Parent = gui,
			Theme = { BackgroundColor3 = "Titlebar" },
		})
		Util.Corner(11, chip)
		Util.Stroke(chip, "WindowStroke", 1, 0.4)
		Util.Shadow(chip, 34, 1, 11)
		local dot = Util.New("Frame", {
			Size = UDim2.fromOffset(9, 9),
			Position = UDim2.new(0, 13, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = Traffic.Yellow,
			BorderSizePixel = 0,
			ZIndex = 51,
			Parent = chip,
		})
		Util.Corner(5, dot)
		Util.New("TextLabel", {
			Size = UDim2.new(1, -36, 1, 0),
			Position = UDim2.new(0, 30, 0, 0),
			BackgroundTransparency = 1,
			Text = self.Title,
			TextSize = 12,
			TextColor3 = theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Weight = Enum.FontWeight.SemiBold,
			ZIndex = 51,
			Parent = chip,
			Theme = { TextColor3 = "Text" },
		})
		return chip
	end

	closeBtn.MouseButton1Click:Connect(function()
		self:Unload()
	end)

	minBtn.MouseButton1Click:Connect(function()
		self:Minimize()
	end)

	maxBtn.MouseButton1Click:Connect(function()
		self:Maximize()
	end)

	function self:Minimize()
		if self.Minimized then return end
		self.Minimized = true
		if not minimizedChip then
			minimizedChip = buildChip()
			minimizedChip.MouseButton1Click:Connect(function() self:Restore() end)
		end
		self.CurrentSize = UDim2.fromOffset(root.AbsoluteSize.X, root.AbsoluteSize.Y)
		Util.Tween(root, 0.2, { Size = UDim2.fromOffset(root.AbsoluteSize.X * 0.85, 0) })
		if blur then Util.Tween(blur, 0.2, { Size = 0 }) end
		task.delay(0.2, function()
			root.Visible = false
			root.Size = self.CurrentSize or defaultSize
		end)
		minimizedChip.Visible = true
		minimizedChip.BackgroundTransparency = 1
		Util.Tween(minimizedChip, 0.22, { BackgroundTransparency = 0 })
	end

	function self:Restore()
		self.Minimized = false
		if minimizedChip then minimizedChip.Visible = false end
		root.Visible = true
		root.Size = UDim2.fromOffset((self.CurrentSize or defaultSize).X.Offset, 0)
		Util.Tween(root, 0.26, { Size = self.CurrentSize or defaultSize })
		if blur and self.Open then Util.Tween(blur, 0.26, { Size = 14 }) end
	end

	function self:Maximize()
		local cam = workspace.CurrentCamera
		local view = cam and cam.ViewportSize or Vector2.new(1280, 720)
		if self.Maximized then
			self.Maximized = false
			Util.Tween(root, 0.28, { Size = self.CurrentSize or defaultSize, Position = UDim2.fromScale(0.5, 0.5) })
		else
			self.CurrentSize = UDim2.fromOffset(root.AbsoluteSize.X, root.AbsoluteSize.Y)
			self.Maximized = true
			Util.Tween(root, 0.28, {
				Size = UDim2.fromOffset(math.floor(view.X * 0.92), math.floor(view.Y * 0.9)),
				Position = UDim2.fromScale(0.5, 0.5),
			})
		end
	end
	self.CurrentSize = defaultSize

	----------------------------------------------------------------------------------------------
	-- open / close
	----------------------------------------------------------------------------------------------
	if config.Blur ~= false then
		local ok = pcall(function()
			blur = Instance.new("BlurEffect")
			blur.Name = "MacLibBlur"
			blur.Size = 0
			blur.Parent = Lighting
		end)
		if not ok then blur = nil end
	end
	self.Blur = blur

	local scale = Instance.new("UIScale")
	scale.Scale = 0.94
	scale.Parent = root

	function self:SetOpen(state, instant)
		self.Open = state
		if state and self.Minimized then
			self:Restore()
			return
		end
		if state then
			root.Visible = true
			if instant then
				scale.Scale = 1
				main.BackgroundTransparency = 0
			else
				scale.Scale = 0.94
				Util.Tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			end
			if blur then Util.Tween(blur, 0.3, { Size = 14 }) end
		else
			Util.Tween(scale, 0.22, { Scale = 0.94 })
			if blur then Util.Tween(blur, 0.25, { Size = 0 }) end
			task.delay(0.22, function()
				if not self.Open then root.Visible = false end
			end)
		end
	end

	function self:Toggle()
		self:SetOpen(not self.Open)
	end

	self._Connections[#self._Connections + 1] = UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.KeyCode == self.ToggleKey then
			self:Toggle()
		end
	end)

	function self:Unload()
		for _, c in ipairs(self._Connections) do pcall(function() c:Disconnect() end) end
		if blur then pcall(function() blur:Destroy() end) end
		if minimizedChip then pcall(function() minimizedChip:Destroy() end) end
		pcall(function() gui:Destroy() end)
		for i, w in ipairs(MacLib.Windows) do
			if w == self then table.remove(MacLib.Windows, i) break end
		end
		if self.OnUnload then pcall(self.OnUnload) end
	end
	self.Destroy = self.Unload

	function self:SetTitle(t, s)
		if t then self.Title = t titleLabel.Text = t end
		if s then self.Subtitle = s subLabel.Text = s end
	end

	function self:SetTheme(name)
		return MacLib:SetTheme(name)
	end

	table.insert(MacLib.Windows, self)

	-- entrance
	root.Visible = true
	main.BackgroundTransparency = 0
	scale.Scale = 0.9
	Util.Tween(scale, 0.42, { Scale = 1 }, Enum.EasingStyle.Back)
	if blur then Util.Tween(blur, 0.4, { Size = 14 }) end

	return self
end

--=================================================================================================
--  TAB SECTIONS  /  TABS  /  SECTIONS
--=================================================================================================

local Tab = {}
Tab.__index = Tab

local Section = {}
Section.__index = Section

local function nextOrder(window)
	window._order = (window._order or 0) + 1
	return window._order
end

--- Sidebar group header ("Favourites", "Player", ...)
function Window:TabSection(name)
	local theme = MacLib.Theme
	local holder = Util.New("Frame", {
		Name = "TabSection",
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(self),
		ZIndex = 4,
		Parent = self.TabList,
	})
	Util.New("TextLabel", {
		Size = UDim2.new(1, -8, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		BackgroundTransparency = 1,
		Text = tostring(name or "Section"),
		TextSize = 11,
		TextColor3 = theme.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Weight = Enum.FontWeight.Bold,
		ZIndex = 5,
		Parent = holder,
		Theme = { TextColor3 = "Muted" },
	})

	local group = {
		Window = self,
		Name = name,
		Instance = holder,
	}
	function group:Tab(cfg)
		return Window.Tab(self.Window, cfg)
	end
	function group:SetTitle(t)
		holder:FindFirstChildWhichIsA("TextLabel").Text = tostring(t)
	end
	table.insert(self.TabSections, group)
	return group
end
Window.TabGroup = Window.TabSection

--- Creates a sidebar tab.
function Window:Tab(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local window = self

	local tab = setmetatable({
		Window   = window,
		Title    = cfg.Title or cfg.Name or "Tab",
		Icon     = cfg.Icon,
		Sections = {},
		Selected = false,
	}, Tab)

	----------------------------------------------------------------------------------------------
	-- sidebar button
	----------------------------------------------------------------------------------------------
	local btn = Util.New("TextButton", {
		Name = "Tab_" .. tab.Title,
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = theme.Accent,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = nextOrder(window),
		ZIndex = 4,
		Parent = window.TabList,
		Theme = { BackgroundColor3 = "Accent" },
	})
	Util.Corner(7, btn)
	tab.Button = btn

	local iconHolder = Util.New("Frame", {
		Name = "IconHolder",
		Size = UDim2.fromOffset(17, 17),
		Position = UDim2.new(0, 9, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = btn,
	})
	local icon = Util.New("ImageLabel", {
		Name = "Icon",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ImageColor3 = theme.SubText,
		ImageTransparency = 1,
		ZIndex = 6,
		Parent = iconHolder,
	})
	if cfg.Icon then
		Icons.Apply(icon, cfg.Icon, window.IconStyle, iconHolder, theme.SubText)
	end

	local label = Util.New("TextLabel", {
		Name = "Label",
		Size = UDim2.new(1, cfg.Icon and -36 or -20, 1, 0),
		Position = UDim2.new(0, cfg.Icon and 33 or 10, 0, 0),
		BackgroundTransparency = 1,
		Text = tab.Title,
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Weight = Enum.FontWeight.Medium,
		ZIndex = 5,
		Parent = btn,
	})
	tab.Label = label

	----------------------------------------------------------------------------------------------
	-- page
	----------------------------------------------------------------------------------------------
	local page = Util.Scrollbar(Util.New("ScrollingFrame", {
		Name = "Page_" .. tab.Title,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 3,
		Parent = window.Container,
	}))
	Util.Padding(page, 18, 18, 24, 18)
	Util.List(page, 16)
	tab.Page = page

	----------------------------------------------------------------------------------------------
	-- selection visuals
	----------------------------------------------------------------------------------------------
	local hovering = false

	local function paint(instant)
		local th = MacLib.Theme
		local t = instant and 0 or 0.16
		if tab.Selected then
			Util.Tween(btn, t, { BackgroundTransparency = 0, BackgroundColor3 = th.Accent })
			Util.Tween(label, t, { TextColor3 = th.AccentText })
			Util.Tween(icon, t, { ImageColor3 = th.AccentText })
			for _, c in ipairs(iconHolder:GetChildren()) do
				if c:IsA("Frame") then Util.Tween(c, t, { BackgroundColor3 = th.AccentText }) end
			end
		else
			Util.Tween(btn, t, { BackgroundTransparency = hovering and 0.88 or 1, BackgroundColor3 = th.Text })
			Util.Tween(label, t, { TextColor3 = th.Text })
			Util.Tween(icon, t, { ImageColor3 = th.SubText })
			for _, c in ipairs(iconHolder:GetChildren()) do
				if c:IsA("Frame") then Util.Tween(c, t, { BackgroundColor3 = th.SubText }) end
			end
		end
	end
	tab._Paint = paint
	table.insert(window._OnTheme, function() paint(true) end)

	btn.MouseEnter:Connect(function() hovering = true paint() end)
	btn.MouseLeave:Connect(function() hovering = false paint() end)
	btn.MouseButton1Click:Connect(function() tab:Select() end)

	function tab:Select()
		for _, other in ipairs(window.Tabs) do
			if other ~= self and other.Selected then
				other.Selected = false
				other.Page.Visible = false
				other._Paint()
			end
		end
		self.Selected = true
		window.ActiveTab = self
		window.EmptyLabel.Visible = false
		page.Visible = true
		page.Position = UDim2.fromOffset(0, 10)
		Util.Tween(page, 0.25, { Position = UDim2.fromOffset(0, 0) })
		paint()
	end

	function tab:SetTitle(t)
		self.Title = t
		label.Text = t
	end

	function tab:SetIcon(name)
		Icons.Apply(icon, name, window.IconStyle, iconHolder, MacLib.Theme.SubText)
	end

	table.insert(window.Tabs, tab)
	if #window.Tabs == 1 then tab:Select() end
	paint(true)
	return tab
end

--=================================================================================================
--  SECTION  (a macOS "System Settings" style grouped card)
--=================================================================================================

function Tab:Section(cfg)
	if type(cfg) == "string" then cfg = { Title = cfg } end
	cfg = cfg or {}
	local theme = MacLib.Theme
	local window = self.Window

	local sec = setmetatable({
		Tab = self, Window = window, Elements = {}, _count = 0,
	}, Section)

	local holder = Util.New("Frame", {
		Name = "Section",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = #self.Sections + 1,
		ZIndex = 3,
		Parent = self.Page,
	})
	Util.List(holder, 7)
	sec.Instance = holder

	if cfg.Title then
		Util.New("TextLabel", {
			Name = "Header",
			Size = UDim2.new(1, 0, 0, 17),
			BackgroundTransparency = 1,
			Text = tostring(cfg.Title),
			TextSize = 12,
			TextColor3 = theme.SubText,
			TextXAlignment = Enum.TextXAlignment.Left,
			Weight = Enum.FontWeight.SemiBold,
			LayoutOrder = 1,
			ZIndex = 3,
			Parent = holder,
			Theme = { TextColor3 = "SubText" },
		})
	end

	local card = Util.New("Frame", {
		Name = "Card",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Card,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		ZIndex = 3,
		Parent = holder,
		Theme = { BackgroundColor3 = "Card" },
	})
	Util.Corner(10, card)
	Util.Stroke(card, "CardStroke", 1, 0.15)
	Util.List(card, 0)
	sec.Card = card

	if cfg.Description then
		Util.New("TextLabel", {
			Name = "Footnote",
			Size = UDim2.new(1, 0, 0, 15),
			BackgroundTransparency = 1,
			Text = tostring(cfg.Description),
			TextSize = 11,
			TextColor3 = theme.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Weight = Enum.FontWeight.Regular,
			LayoutOrder = 3,
			ZIndex = 3,
			Parent = holder,
			Theme = { TextColor3 = "Muted" },
		})
	end

	table.insert(self.Sections, sec)
	return sec
end
Tab.Groupbox = Tab.Section

--- Internal: builds a single row inside the section card.
function Section:_Row(opts)
	opts = opts or {}
	local theme = MacLib.Theme
	self._count = self._count + 1

	local hasDesc = opts.Description ~= nil and opts.Description ~= ""
	local height = opts.Height or (hasDesc and 54 or 40)

	local row = Util.New("Frame", {
		Name = "Row",
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = self._count,
		ClipsDescendants = false,
		ZIndex = 4,
		Parent = self.Card,
	})

	if self._count > 1 then
		Util.New("Frame", {
			Name = "Separator",
			Size = UDim2.new(1, -15, 0, 1),
			Position = UDim2.new(0, 15, 0, 0),
			BackgroundColor3 = theme.Divider,
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = row,
			Theme = { BackgroundColor3 = "Divider" },
		})
	end

	local textWidth = opts.TextWidth or -132

	-- Vertical placement: a single-line row centres its label so the padding above and
	-- below always matches, whatever height the caller asked for. Rows that stack extra
	-- controls underneath (sliders) pass an explicit TitleY instead.
	local titleAnchor, titlePos
	if hasDesc then
		titleAnchor = Vector2.new(0, 0)
		titlePos = UDim2.new(0, 15, 0, opts.TitleY or 11)
	elseif opts.TitleY then
		titleAnchor = Vector2.new(0, 0)
		titlePos = UDim2.new(0, 15, 0, opts.TitleY)
	else
		titleAnchor = Vector2.new(0, 0.5)
		titlePos = UDim2.new(0, 15, 0.5, 0)
	end

	local title = Util.New("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, textWidth, 0, 16),
		AnchorPoint = titleAnchor,
		Position = titlePos,
		BackgroundTransparency = 1,
		Text = tostring(opts.Title or ""),
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Weight = Enum.FontWeight.Medium,
		ZIndex = 5,
		Parent = row,
		Theme = { TextColor3 = "Text" },
	})

	local desc
	if hasDesc then
		desc = Util.New("TextLabel", {
			Name = "Description",
			Size = UDim2.new(1, textWidth, 0, 14),
			Position = UDim2.new(0, 15, 0, opts.DescY or 29),
			BackgroundTransparency = 1,
			Text = tostring(opts.Description),
			TextSize = 11,
			TextColor3 = theme.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Weight = Enum.FontWeight.Regular,
			ZIndex = 5,
			Parent = row,
			Theme = { TextColor3 = "Muted" },
		})
	end

	local right = Util.New("Frame", {
		Name = "Right",
		Size = UDim2.new(0, 118, 1, 0),
		Position = UDim2.new(1, -15, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = row,
	})

	return { Row = row, Title = title, Description = desc, Right = right }
end

--- Registers an element against a flag so configs can save/restore it.
function Section:_Register(element, flag)
	if flag then
		element.Flag = flag
		MacLib.Flags[flag] = element
	end
	table.insert(self.Elements, element)
	return element
end

--=================================================================================================
--  ELEMENTS
--=================================================================================================

local function setValue(element, value)
	if element.Flag then MacLib.Values[element.Flag] = value end
	element.Value = value
end

----------------------------------------------------------------------------------------------
-- Button
----------------------------------------------------------------------------------------------
function Section:Button(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local parts = self:_Row({ Title = cfg.Title or "Button", Description = cfg.Description })
	local row = parts.Row

	local hit = Util.New("TextButton", {
		Name = "Hit",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = theme.ElementHover,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 4,
		Parent = row,
		Theme = { BackgroundColor3 = "ElementHover" },
	})
	Util.Corner(9, hit)

	local chev = Util.New("ImageLabel", {
		Size = UDim2.fromOffset(15, 15),
		Position = UDim2.new(1, -15, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundTransparency = 1,
		ImageColor3 = theme.Muted,
		ImageTransparency = 1,
		ZIndex = 6,
		Parent = row,
		Theme = { ImageColor3 = "Muted" },
	})
	Icons.Apply(chev, "builtin:chevron-right", "linear", chev, theme.Muted)

	hit.MouseEnter:Connect(function() Util.Tween(hit, 0.12, { BackgroundTransparency = 0.9 }) end)
	hit.MouseLeave:Connect(function() Util.Tween(hit, 0.16, { BackgroundTransparency = 1 }) end)

	local element = { Type = "Button", Instance = row }
	hit.MouseButton1Click:Connect(function()
		Util.Tween(hit, 0.06, { BackgroundTransparency = 0.78 })
		task.delay(0.09, function() Util.Tween(hit, 0.16, { BackgroundTransparency = 1 }) end)
		if cfg.Callback then task.spawn(cfg.Callback) end
	end)

	function element:SetTitle(t) parts.Title.Text = tostring(t) end
	function element:SetDescription(t) if parts.Description then parts.Description.Text = tostring(t) end end
	function element:Destroy() row:Destroy() end
	return self:_Register(element, cfg.Flag)
end

----------------------------------------------------------------------------------------------
-- Toggle
----------------------------------------------------------------------------------------------
function Section:Toggle(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local parts = self:_Row({ Title = cfg.Title or "Toggle", Description = cfg.Description })
	local row = parts.Row

	local track = Util.New("TextButton", {
		Name = "Track",
		Size = UDim2.fromOffset(42, 25),
		Position = UDim2.new(1, 0, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.Track,
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = parts.Right,
		Theme = { BackgroundColor3 = "Track" },
	})
	Util.Corner(13, track)

	local knob = Util.New("Frame", {
		Name = "Knob",
		Size = UDim2.fromOffset(21, 21),
		Position = UDim2.new(0, 2, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = theme.Knob,
		BorderSizePixel = 0,
		ZIndex = 7,
		Parent = track,
		Theme = { BackgroundColor3 = "Knob" },
	})
	Util.Corner(11, knob)
	Util.Stroke(knob, "Divider", 1, 0.55)

	local element = { Type = "Toggle", Instance = row, Value = false }

	local function render(instant)
		local th = MacLib.Theme
		local t = instant and 0 or 0.18
		Util.Tween(track, t, { BackgroundColor3 = element.Value and th.Accent or th.Track })
		Util.Tween(knob, t, {
			Position = element.Value and UDim2.new(1, -2, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
			AnchorPoint = element.Value and Vector2.new(1, 0.5) or Vector2.new(0, 0.5),
		})
	end

	function element:Set(value, silent)
		setValue(self, value and true or false)
		render()
		if not silent and cfg.Callback then task.spawn(cfg.Callback, self.Value) end
	end
	function element:Get() return self.Value end
	function element:Toggle() self:Set(not self.Value) end
	function element:SetTitle(t) parts.Title.Text = tostring(t) end
	function element:SetDescription(t) if parts.Description then parts.Description.Text = tostring(t) end end
	function element:Destroy() row:Destroy() end

	track.MouseButton1Click:Connect(function() element:Toggle() end)

	setValue(element, cfg.Default and true or false)
	render(true)
	if cfg.Default and cfg.Callback then task.spawn(cfg.Callback, true) end
	return self:_Register(element, cfg.Flag)
end
Section.Switch = Section.Toggle

----------------------------------------------------------------------------------------------
-- Slider
----------------------------------------------------------------------------------------------
function Section:Slider(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local hasDesc = cfg.Description ~= nil and cfg.Description ~= ""
	-- padding above the title and below the bar are both 12, so the row reads balanced
	local parts = self:_Row({
		Title = cfg.Title or "Slider",
		Description = cfg.Description,
		Height = hasDesc and 74 or 60,
		TitleY = hasDesc and 11 or 12,
		TextWidth = -110,
	})
	local row = parts.Row

	local minV = cfg.Min or 0
	local maxV = cfg.Max or 100
	local decimals = cfg.Decimals or cfg.Rounding or 0
	local suffix = cfg.Suffix or ""
	local step = cfg.Increment or cfg.Step

	local valueLabel = Util.New("TextLabel", {
		Name = "Value",
		Size = UDim2.new(0, 92, 0, 16),
		Position = UDim2.new(1, -15, 0, hasDesc and 11 or 12),  -- matches TitleY
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Text = "0",
		TextSize = 12,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Right,
		Weight = Enum.FontWeight.SemiBold,
		ZIndex = 6,
		Parent = row,
		Theme = { TextColor3 = "SubText" },
	})

	local barY = hasDesc and 51 or 36
	local bar = Util.New("TextButton", {
		Name = "Bar",
		Size = UDim2.new(1, -30, 0, 12),
		Position = UDim2.new(0, 15, 0, barY),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 6,
		Parent = row,
	})
	local track = Util.New("Frame", {
		Name = "Track",
		Size = UDim2.new(1, 0, 0, 4),
		Position = UDim2.fromScale(0, 0.5),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = theme.Track,
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = bar,
		Theme = { BackgroundColor3 = "Track" },
	})
	Util.Corner(2, track)
	local fill = Util.New("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = theme.Accent,
		BorderSizePixel = 0,
		ZIndex = 7,
		Parent = track,
		Theme = { BackgroundColor3 = "Accent" },
	})
	Util.Corner(2, fill)
	local knob = Util.New("Frame", {
		Name = "Knob",
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.fromScale(0, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = theme.Knob,
		BorderSizePixel = 0,
		ZIndex = 8,
		Parent = bar,
		Theme = { BackgroundColor3 = "Knob" },
	})
	Util.Corner(7, knob)
	Util.Stroke(knob, "CardStroke", 1, 0.3)

	local element = { Type = "Slider", Instance = row, Value = minV }

	local function format(v)
		if decimals > 0 then
			return string.format("%." .. decimals .. "f", v)
		end
		return tostring(math.floor(v + 0.5))
	end

	local function render()
		local alpha = 0
		if maxV ~= minV then alpha = (element.Value - minV) / (maxV - minV) end
		if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		valueLabel.Text = format(element.Value) .. suffix
	end

	function element:Set(value, silent)
		value = tonumber(value) or minV
		if step and step > 0 then
			value = minV + math.floor((value - minV) / step + 0.5) * step
		end
		if decimals > 0 then
			local m = 10 ^ decimals
			value = math.floor(value * m + 0.5) / m
		else
			value = math.floor(value + 0.5)
		end
		if value < minV then value = minV elseif value > maxV then value = maxV end
		setValue(self, value)
		render()
		if not silent and cfg.Callback then task.spawn(cfg.Callback, value) end
	end
	function element:Get() return self.Value end
	function element:SetTitle(t) parts.Title.Text = tostring(t) end
	function element:SetDescription(t) if parts.Description then parts.Description.Text = tostring(t) end end
	function element:Destroy() row:Destroy() end

	local dragging = false
	local function fromInput(pos)
		local abs = track.AbsolutePosition.X
		local size = track.AbsoluteSize.X
		local alpha = size > 0 and (pos.X - abs) / size or 0
		if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end
		element:Set(minV + (maxV - minV) * alpha)
	end

	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			Util.Tween(knob, 0.12, { Size = UDim2.fromOffset(17, 17) })
			fromInput(input.Position)
		end
	end)
	bar.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			Util.Tween(knob, 0.16, { Size = UDim2.fromOffset(14, 14) })
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			fromInput(input.Position)
		end
	end)

	element:Set(cfg.Default or minV, true)
	if cfg.Default ~= nil and cfg.Callback then task.spawn(cfg.Callback, element.Value) end
	return self:_Register(element, cfg.Flag)
end

----------------------------------------------------------------------------------------------
-- Input
----------------------------------------------------------------------------------------------
function Section:Input(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local parts = self:_Row({ Title = cfg.Title or "Input", Description = cfg.Description })

	local box = Util.New("TextBox", {
		Name = "Box",
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(1, 0, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.Element,
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = cfg.Placeholder or "",
		PlaceholderColor3 = theme.Muted,
		TextColor3 = theme.Text,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Weight = Enum.FontWeight.Medium,
		ZIndex = 6,
		Parent = parts.Right,
		Theme = { BackgroundColor3 = "Element", TextColor3 = "Text", PlaceholderColor3 = "Muted" },
	})
	Util.Corner(7, box)
	Util.Padding(box, 0, 8, 0, 8)
	local stroke = Util.Stroke(box, "CardStroke", 1, 0.3)

	local element = { Type = "Input", Instance = parts.Row, Value = "" }

	function element:Set(value, silent)
		setValue(self, tostring(value or ""))
		box.Text = self.Value
		if not silent and cfg.Callback then task.spawn(cfg.Callback, self.Value) end
	end
	function element:Get() return self.Value end
	function element:SetTitle(t) parts.Title.Text = tostring(t) end
	function element:SetDescription(t) if parts.Description then parts.Description.Text = tostring(t) end end
	function element:Destroy() parts.Row:Destroy() end

	box.Focused:Connect(function()
		Util.Tween(stroke, 0.14, { Color = MacLib.Theme.Accent, Transparency = 0 })
	end)
	box.FocusLost:Connect(function(enter)
		Util.Tween(stroke, 0.18, { Color = MacLib.Theme.CardStroke, Transparency = 0.3 })
		setValue(element, box.Text)
		if cfg.Callback then task.spawn(cfg.Callback, box.Text, enter) end
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if cfg.Live and cfg.Callback then
			setValue(element, box.Text)
			task.spawn(cfg.Callback, box.Text, false)
		end
	end)

	element:Set(cfg.Default or "", true)
	return self:_Register(element, cfg.Flag)
end
Section.Textbox = Section.Input

----------------------------------------------------------------------------------------------
-- Dropdown
----------------------------------------------------------------------------------------------
function Section:Dropdown(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local window = self.Window
	local main = window.Main
	local parts = self:_Row({ Title = cfg.Title or "Dropdown", Description = cfg.Description })

	local multi = cfg.Multi or cfg.MultiSelect or false
	local options = cfg.Options or cfg.Values or {}

	local box = Util.New("TextButton", {
		Name = "Box",
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(1, 0, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.Element,
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		ZIndex = 6,
		Parent = parts.Right,
		Theme = { BackgroundColor3 = "Element" },
	})
	Util.Corner(7, box)
	Util.Stroke(box, "CardStroke", 1, 0.3)

	local display = Util.New("TextLabel", {
		Size = UDim2.new(1, -30, 1, 0),
		Position = UDim2.new(0, 9, 0, 0),
		BackgroundTransparency = 1,
		Text = "None",
		TextSize = 12,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Weight = Enum.FontWeight.Medium,
		ZIndex = 7,
		Parent = box,
		Theme = { TextColor3 = "Text" },
	})
	local arrow = Util.New("ImageLabel", {
		Size = UDim2.fromOffset(13, 13),
		Position = UDim2.new(1, -8, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundTransparency = 1,
		ImageColor3 = theme.Muted,
		ImageTransparency = 1,
		ZIndex = 7,
		Parent = box,
		Theme = { ImageColor3 = "Muted" },
	})
	Icons.Apply(arrow, "builtin:chevron-down", "linear", arrow, theme.Muted)

	----------------------------------------------------------------------------------------------
	-- popup
	----------------------------------------------------------------------------------------------
	local blocker = Util.New("TextButton", {
		Name = "DropdownBlocker",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		ZIndex = 59,
		Parent = main,
	})
	local popup = Util.New("Frame", {
		Name = "DropdownPopup",
		Size = UDim2.fromOffset(180, 0),
		BackgroundColor3 = theme.Popup,
		BorderSizePixel = 0,
		Visible = false,
		ClipsDescendants = true,
		ZIndex = 60,
		Parent = main,
		Theme = { BackgroundColor3 = "Popup" },
	})
	Util.Corner(9, popup)
	Util.Stroke(popup, "PopupStroke", 1, 0.2)

	local list = Util.Scrollbar(Util.New("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 61,
		Parent = popup,
	}))
	Util.Padding(list, 5, 5, 5, 5)
	Util.List(list, 2)

	local element = { Type = "Dropdown", Instance = parts.Row, Value = multi and {} or nil, Options = options }
	local optionButtons = {}
	local isOpen = false

	local function isSelected(opt)
		if multi then
			for _, v in ipairs(element.Value or {}) do
				if v == opt then return true end
			end
			return false
		end
		return element.Value == opt
	end

	local function displayText()
		if multi then
			local v = element.Value or {}
			if #v == 0 then return cfg.Placeholder or "None" end
			if #v <= 2 then return table.concat(v, ", ") end
			return #v .. " selected"
		end
		if element.Value == nil then return cfg.Placeholder or "None" end
		return tostring(element.Value)
	end

	local function refresh()
		display.Text = displayText()
		for opt, entry in pairs(optionButtons) do
			local on = isSelected(opt)
			Util.Tween(entry.Check, 0.12, { ImageTransparency = on and 0 or 1 })
			Util.Tween(entry.Label, 0.12, {
				TextColor3 = on and MacLib.Theme.Accent or MacLib.Theme.Text,
			})
		end
	end

	local function closePopup()
		if not isOpen then return end
		isOpen = false
		blocker.Visible = false
		Util.Tween(popup, 0.16, { Size = UDim2.fromOffset(popup.AbsoluteSize.X, 0) })
		Util.Tween(arrow, 0.16, { Rotation = 0 })
		task.delay(0.17, function() if not isOpen then popup.Visible = false end end)
	end

	local function buildOptions()
		for _, c in ipairs(list:GetChildren()) do
			if c:IsA("TextButton") then c:Destroy() end
		end
		optionButtons = {}
		for i, opt in ipairs(element.Options) do
			local th = MacLib.Theme
			local ob = Util.New("TextButton", {
				Size = UDim2.new(1, 0, 0, 27),
				BackgroundColor3 = th.ElementHover,
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				LayoutOrder = i,
				ZIndex = 62,
				Parent = list,
				Theme = { BackgroundColor3 = "ElementHover" },
			})
			Util.Corner(6, ob)
			local lbl = Util.New("TextLabel", {
				Size = UDim2.new(1, -32, 1, 0),
				Position = UDim2.new(0, 9, 0, 0),
				BackgroundTransparency = 1,
				Text = tostring(opt),
				TextSize = 12,
				TextColor3 = th.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Weight = Enum.FontWeight.Medium,
				ZIndex = 63,
				Parent = ob,
			})
			local check = Util.New("ImageLabel", {
				Size = UDim2.fromOffset(13, 13),
				Position = UDim2.new(1, -9, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
				BackgroundTransparency = 1,
				ImageColor3 = th.Accent,
				ImageTransparency = 1,
				ZIndex = 63,
				Parent = ob,
				Theme = { ImageColor3 = "Accent" },
			})
			Icons.Apply(check, "builtin:check", "linear", check, th.Accent)

			ob.MouseEnter:Connect(function() Util.Tween(ob, 0.1, { BackgroundTransparency = 0.85 }) end)
			ob.MouseLeave:Connect(function() Util.Tween(ob, 0.14, { BackgroundTransparency = 1 }) end)
			ob.MouseButton1Click:Connect(function()
				if multi then
					local v = element.Value or {}
					local found
					for idx, x in ipairs(v) do
						if x == opt then found = idx break end
					end
					if found then table.remove(v, found) else table.insert(v, opt) end
					setValue(element, v)
					refresh()
					if cfg.Callback then task.spawn(cfg.Callback, v) end
				else
					setValue(element, opt)
					refresh()
					closePopup()
					if cfg.Callback then task.spawn(cfg.Callback, opt) end
				end
			end)

			optionButtons[opt] = { Button = ob, Label = lbl, Check = check }
		end
	end

	local function openPopup()
		if isOpen then return end
		isOpen = true
		local count = #element.Options
		local height = math.min(count * 29 + 10, 210)
		if height < 39 then height = 39 end
		local width = math.max(190, box.AbsoluteSize.X)

		local ba = box.AbsolutePosition
		local ma = main.AbsolutePosition
		local x = ba.X - ma.X + box.AbsoluteSize.X - width
		local y = ba.Y - ma.Y + box.AbsoluteSize.Y + 6
		if y + height > main.AbsoluteSize.Y - 10 then
			y = ba.Y - ma.Y - height - 6
		end
		if x < 8 then x = 8 end

		popup.Position = UDim2.fromOffset(x, y)
		popup.Size = UDim2.fromOffset(width, 0)
		popup.Visible = true
		blocker.Visible = true
		refresh()
		Util.Tween(popup, 0.2, { Size = UDim2.fromOffset(width, height) })
		Util.Tween(arrow, 0.2, { Rotation = 180 })
	end

	box.MouseButton1Click:Connect(function()
		if isOpen then closePopup() else openPopup() end
	end)
	blocker.MouseButton1Click:Connect(closePopup)

	function element:Set(value, silent)
		if multi then
			local v = {}
			if type(value) == "table" then
				for _, x in ipairs(value) do v[#v + 1] = x end
			elseif value ~= nil then
				v[1] = value
			end
			setValue(self, v)
		else
			setValue(self, value)
		end
		refresh()
		if not silent and cfg.Callback then task.spawn(cfg.Callback, self.Value) end
	end
	function element:Get() return self.Value end
	function element:SetOptions(newOptions)
		self.Options = newOptions or {}
		buildOptions()
		if not multi and self.Value ~= nil then
			local ok = false
			for _, o in ipairs(self.Options) do if o == self.Value then ok = true break end end
			if not ok then setValue(self, nil) end
		end
		refresh()
	end
	element.Refresh = element.SetOptions
	function element:SetTitle(t) parts.Title.Text = tostring(t) end
	function element:SetDescription(t) if parts.Description then parts.Description.Text = tostring(t) end end
	function element:Destroy() parts.Row:Destroy() popup:Destroy() blocker:Destroy() end

	buildOptions()
	element:Set(cfg.Default, true)
	if cfg.Default ~= nil and cfg.Callback then task.spawn(cfg.Callback, element.Value) end
	return self:_Register(element, cfg.Flag)
end

----------------------------------------------------------------------------------------------
-- Keybind
----------------------------------------------------------------------------------------------
local function keyName(key)
	if typeof(key) == "EnumItem" then
		local n = key.Name
		local map = {
			LeftShift = "LShift", RightShift = "RShift",
			LeftControl = "LCtrl", RightControl = "RCtrl",
			LeftAlt = "LAlt", RightAlt = "RAlt",
			MouseButton1 = "MB1", MouseButton2 = "MB2", MouseButton3 = "MB3",
		}
		return map[n] or n
	end
	return "None"
end

function Section:Keybind(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local parts = self:_Row({ Title = cfg.Title or "Keybind", Description = cfg.Description })

	local btn = Util.New("TextButton", {
		Name = "Bind",
		Size = UDim2.new(0, 84, 0, 26),
		Position = UDim2.new(1, 0, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.Element,
		AutoButtonColor = false,
		Text = "None",
		TextSize = 12,
		TextColor3 = theme.Text,
		BorderSizePixel = 0,
		Weight = Enum.FontWeight.SemiBold,
		ZIndex = 6,
		Parent = parts.Right,
		Theme = { BackgroundColor3 = "Element", TextColor3 = "Text" },
	})
	Util.Corner(7, btn)
	local stroke = Util.Stroke(btn, "CardStroke", 1, 0.3)

	local element = { Type = "Keybind", Instance = parts.Row, Value = nil, Listening = false }

	function element:Set(key, silent)
		if type(key) == "string" then
			local ok, enum = pcall(function() return Enum.KeyCode[key] end)
			key = ok and enum or nil
		end
		setValue(self, key)
		btn.Text = keyName(key)
		if not silent and cfg.OnChanged then task.spawn(cfg.OnChanged, key) end
	end
	function element:Get() return self.Value end
	function element:SetTitle(t) parts.Title.Text = tostring(t) end
	function element:SetDescription(t) if parts.Description then parts.Description.Text = tostring(t) end end
	function element:Destroy() parts.Row:Destroy() end

	btn.MouseButton1Click:Connect(function()
		element.Listening = true
		btn.Text = "..."
		Util.Tween(stroke, 0.14, { Color = MacLib.Theme.Accent, Transparency = 0 })
	end)

	UserInputService.InputBegan:Connect(function(input, gpe)
		if element.Listening then
			task.wait()
			element.Listening = false
			Util.Tween(stroke, 0.18, { Color = MacLib.Theme.CardStroke, Transparency = 0.3 })
			if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Backspace then
				element:Set(nil)
			elseif input.UserInputType == Enum.UserInputType.Keyboard then
				element:Set(input.KeyCode)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3 then
				element:Set(input.UserInputType)
			end
			return
		end
		if gpe or element.Value == nil then return end
		local hit = false
		if typeof(element.Value) == "EnumItem" then
			if element.Value.EnumType == Enum.KeyCode then
				hit = input.KeyCode == element.Value
			else
				hit = input.UserInputType == element.Value
			end
		end
		if hit and cfg.Callback then task.spawn(cfg.Callback, element.Value) end
	end)

	element:Set(cfg.Default, true)
	return self:_Register(element, cfg.Flag)
end

----------------------------------------------------------------------------------------------
-- Paragraph / Label / Divider
----------------------------------------------------------------------------------------------
function Section:Paragraph(cfg)
	if type(cfg) == "string" then cfg = { Title = cfg } end
	cfg = cfg or {}
	local theme = MacLib.Theme
	self._count = self._count + 1

	local row = Util.New("Frame", {
		Name = "Paragraph",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = self._count,
		ZIndex = 4,
		Parent = self.Card,
	})
	if self._count > 1 then
		Util.New("Frame", {
			Size = UDim2.new(1, -15, 0, 1),
			Position = UDim2.new(0, 15, 0, 0),
			BackgroundColor3 = theme.Divider,
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = row,
			Theme = { BackgroundColor3 = "Divider" },
		})
	end
	local inner = Util.New("Frame", {
		Size = UDim2.new(1, -30, 0, 0),
		Position = UDim2.new(0, 15, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = row,
	})
	Util.Padding(inner, 12, 0, 13, 0)
	Util.List(inner, 4)

	local title = Util.New("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = tostring(cfg.Title or ""),
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Weight = Enum.FontWeight.SemiBold,
		LayoutOrder = 1,
		ZIndex = 5,
		Parent = inner,
		Theme = { TextColor3 = "Text" },
	})
	local body = Util.New("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = tostring(cfg.Description or cfg.Content or cfg.Text or ""),
		TextSize = 12,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Weight = Enum.FontWeight.Regular,
		LayoutOrder = 2,
		ZIndex = 5,
		Parent = inner,
		Theme = { TextColor3 = "SubText" },
	})

	local element = { Type = "Paragraph", Instance = row }
	function element:SetTitle(t) title.Text = tostring(t) end
	function element:SetDescription(t) body.Text = tostring(t) end
	element.Set = element.SetDescription
	function element:Destroy() row:Destroy() end
	return self:_Register(element)
end

function Section:Label(cfg)
	if type(cfg) == "string" then cfg = { Title = cfg } end
	cfg = cfg or {}
	local parts = self:_Row({ Title = cfg.Title or "", Height = 34, TextWidth = -30 })
	local element = { Type = "Label", Instance = parts.Row }
	function element:SetTitle(t) parts.Title.Text = tostring(t) end
	element.Set = element.SetTitle
	function element:Destroy() parts.Row:Destroy() end
	return self:_Register(element)
end

function Section:Divider()
	local theme = MacLib.Theme
	self._count = self._count + 1
	local row = Util.New("Frame", {
		Name = "Divider",
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = theme.Divider,
		BorderSizePixel = 0,
		LayoutOrder = self._count,
		ZIndex = 5,
		Parent = self.Card,
		Theme = { BackgroundColor3 = "Divider" },
	})
	local element = { Type = "Divider", Instance = row }
	function element:Destroy() row:Destroy() end
	return element
end

--=================================================================================================
--  NOTIFICATIONS
--=================================================================================================

local NotifGui, NotifHolder

local function ensureNotifications()
	if NotifGui and NotifGui.Parent then return end
	NotifGui = createScreenGui("MacLibNotifications")
	NotifGui.DisplayOrder = 10000
	NotifHolder = Util.New("Frame", {
		Name = "Holder",
		Size = UDim2.new(0, 320, 1, -40),
		Position = UDim2.new(1, -20, 0, 20),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Parent = NotifGui,
	})
	local list = Util.List(NotifHolder, 10)
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
end

function MacLib:Notify(cfg)
	if type(cfg) == "string" then cfg = { Title = cfg } end
	cfg = cfg or {}
	ensureNotifications()
	local theme = MacLib.Theme

	-- the slot is what the UIListLayout owns; the card slides inside it
	local slot = Util.New("Frame", {
		Name = "Slot",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = NotifHolder,
	})
	local card = Util.New("Frame", {
		Name = "Notification",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Popup,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = slot,
		Theme = { BackgroundColor3 = "Popup" },
	})
	Util.Corner(12, card)
	Util.Stroke(card, "PopupStroke", 1, 0.25)

	local iconBg = Util.New("Frame", {
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(0, 13, 0, 13),
		BackgroundColor3 = theme.Accent,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = card,
		Theme = { BackgroundColor3 = "Accent" },
	})
	Util.Corner(9, iconBg)
	local icon = Util.New("ImageLabel", {
		Size = UDim2.fromOffset(17, 17),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ImageColor3 = theme.Accent,
		ImageTransparency = 1,
		ZIndex = 3,
		Parent = iconBg,
		Theme = { ImageColor3 = "Accent" },
	})
	Icons.Apply(icon, cfg.Icon or "bell", Icons.Style, iconBg, theme.Accent)

	local text = Util.New("Frame", {
		Size = UDim2.new(1, -60, 0, 0),
		Position = UDim2.new(0, 53, 0, 13),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = card,
	})
	Util.List(text, 3)
	Util.Padding(text, 0, 0, 20, 0)

	Util.New("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = tostring(cfg.Title or "Notification"),
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Weight = Enum.FontWeight.SemiBold,
		LayoutOrder = 1,
		ZIndex = 3,
		Parent = text,
		Theme = { TextColor3 = "Text" },
	})
	if cfg.Description or cfg.Content then
		Util.New("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = tostring(cfg.Description or cfg.Content),
			TextSize = 12,
			TextColor3 = theme.SubText,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			Weight = Enum.FontWeight.Regular,
			LayoutOrder = 2,
			ZIndex = 3,
			Parent = text,
			Theme = { TextColor3 = "SubText" },
		})
	end

	local duration = cfg.Duration or cfg.Lifetime or 5
	-- inset so it never collides with the card's rounded corners
	local progressTrack = Util.New("Frame", {
		Name = "ProgressTrack",
		Size = UDim2.new(1, -26, 0, 3),
		Position = UDim2.new(0, 13, 1, -10),
		BackgroundColor3 = theme.Track,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = card,
		Theme = { BackgroundColor3 = "Track" },
	})
	Util.Corner(2, progressTrack)
	local progress = Util.New("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = theme.Accent,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = progressTrack,
		Theme = { BackgroundColor3 = "Accent" },
	})
	Util.Corner(2, progress)

	local closed = false
	local function close()
		if closed then return end
		closed = true
		Util.Tween(card, 0.2, { BackgroundTransparency = 1 })
		for _, d in ipairs(card:GetDescendants()) do
			if d:IsA("TextLabel") then Util.Tween(d, 0.18, { TextTransparency = 1 })
			elseif d:IsA("ImageLabel") then Util.Tween(d, 0.18, { ImageTransparency = 1 })
			elseif d:IsA("Frame") then Util.Tween(d, 0.18, { BackgroundTransparency = 1 })
			elseif d:IsA("UIStroke") then Util.Tween(d, 0.18, { Transparency = 1 }) end
		end
		Util.Tween(card, 0.2, { Position = UDim2.fromOffset(40, 0) })
		task.delay(0.26, function() slot:Destroy() end)
	end

	local hit = Util.New("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 5,
		Parent = card,
	})
	hit.MouseButton1Click:Connect(function()
		if cfg.Callback then task.spawn(cfg.Callback) end
		close()
	end)

	card.Position = UDim2.fromOffset(46, 0)
	Util.Tween(card, 0.34, { Position = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Quint)
	Util.Tween(progress, duration, { Size = UDim2.fromScale(0, 1) }, Enum.EasingStyle.Linear)
	task.delay(duration, close)

	return { Close = close, Instance = card, Slot = slot }
end
MacLib.Notification = MacLib.Notify

function Window:Notify(cfg)
	return MacLib:Notify(cfg)
end

--=================================================================================================
--  DIALOG  (macOS sheet)
--=================================================================================================

function Window:Dialog(cfg)
	cfg = cfg or {}
	local theme = MacLib.Theme
	local overlay = self.Overlay
	overlay.Visible = true
	overlay.BackgroundTransparency = 1
	Util.Tween(overlay, 0.2, { BackgroundTransparency = 0.55 })

	local sheet = Util.New("Frame", {
		Name = "Dialog",
		Size = UDim2.fromOffset(cfg.Width or 330, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.new(0.5, 0, 0, -20),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = theme.Popup,
		BorderSizePixel = 0,
		ZIndex = 41,
		Parent = overlay,
		Theme = { BackgroundColor3 = "Popup" },
	})
	Util.Corner(14, sheet)
	Util.Stroke(sheet, "PopupStroke", 1, 0.25)
	Util.Shadow(sheet, 60, 0.5)
	Util.List(sheet, 0)
	Util.Padding(sheet, 22, 20, 16, 20)

	Util.New("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Text = tostring(cfg.Title or "Alert"),
		TextSize = 14,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
		Weight = Enum.FontWeight.Bold,
		LayoutOrder = 1,
		ZIndex = 42,
		Parent = sheet,
		Theme = { TextColor3 = "Text" },
	})
	Util.New("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = tostring(cfg.Description or cfg.Content or ""),
		TextSize = 12,
		TextColor3 = theme.SubText,
		TextXAlignment = cfg.RichText and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center,
		TextWrapped = true,
		RichText = cfg.RichText == true,
		LineHeight = cfg.RichText and 1.35 or 1,
		Weight = Enum.FontWeight.Regular,
		LayoutOrder = 2,
		ZIndex = 42,
		Parent = sheet,
		Theme = { TextColor3 = "SubText" },
	})
	Util.New("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = sheet,
	})

	local btnRow = Util.New("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		ZIndex = 42,
		Parent = sheet,
	})
	local btnList = Util.List(btnRow, 8, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Center)

	local function dismiss()
		Util.Tween(overlay, 0.18, { BackgroundTransparency = 1 })
		Util.Tween(sheet, 0.18, { Position = UDim2.new(0.5, 0, 0, -20) })
		task.delay(0.2, function()
			sheet:Destroy()
			overlay.Visible = false
		end)
	end

	local buttons = cfg.Buttons or { { Title = "OK" } }
	for i, b in ipairs(buttons) do
		local primary = b.Primary or (i == #buttons and #buttons > 1) or #buttons == 1
		local bb = Util.New("TextButton", {
			Size = UDim2.new(0, 120, 1, 0),
			BackgroundColor3 = primary and theme.Accent or theme.Element,
			AutoButtonColor = false,
			Text = tostring(b.Title or b.Name or "OK"),
			TextSize = 12,
			TextColor3 = primary and theme.AccentText or theme.Text,
			BorderSizePixel = 0,
			Weight = Enum.FontWeight.SemiBold,
			LayoutOrder = i,
			ZIndex = 43,
			Parent = btnRow,
			Theme = primary and { BackgroundColor3 = "Accent", TextColor3 = "AccentText" }
				or { BackgroundColor3 = "Element", TextColor3 = "Text" },
		})
		Util.Corner(8, bb)
		bb.MouseButton1Click:Connect(function()
			dismiss()
			if b.Callback then task.spawn(b.Callback) end
		end)
	end

	Util.Tween(sheet, 0.3, { Position = UDim2.new(0.5, 0, 0, 60) }, Enum.EasingStyle.Back)
	return { Close = dismiss, Instance = sheet }
end

--=================================================================================================
--  CONFIG SAVE / LOAD
--=================================================================================================

local function encodeValue(v)
	if typeof(v) == "EnumItem" then
		return { __enum = tostring(v.EnumType), value = v.Name }
	elseif typeof(v) == "Color3" then
		return { __color = true, r = v.R, g = v.G, b = v.B }
	elseif type(v) == "table" then
		local out = {}
		for k, x in pairs(v) do out[k] = encodeValue(x) end
		return out
	end
	return v
end

local function decodeValue(v)
	if type(v) == "table" then
		if v.__enum then
			local ok, e = pcall(function()
				if v.__enum:find("KeyCode") then return Enum.KeyCode[v.value] end
				if v.__enum:find("UserInputType") then return Enum.UserInputType[v.value] end
				return nil
			end)
			return ok and e or nil
		elseif v.__color then
			return Color3.new(v.r, v.g, v.b)
		end
		local out = {}
		for k, x in pairs(v) do out[k] = decodeValue(x) end
		return out
	end
	return v
end

function Window:SetFolder(path)
	self.ConfigFolder = path
	return self
end

function Window:_EnsureFolder()
	if not Env.HasFS then return false end
	local parts = {}
	for seg in tostring(self.ConfigFolder):gmatch("[^/\\]+") do parts[#parts + 1] = seg end
	local acc = ""
	for _, seg in ipairs(parts) do
		acc = (acc == "") and seg or (acc .. "/" .. seg)
		if (not Env.isfolder) or (not Env.isfolder(acc)) then
			pcall(Env.makefolder, acc)
		end
	end
	if (not Env.isfolder) or (not Env.isfolder(self.ConfigFolder .. "/configs")) then
		pcall(Env.makefolder, self.ConfigFolder .. "/configs")
	end
	return true
end

function Window:SaveConfig(name)
	if not Env.HasFS then return false, "no filesystem access" end
	name = tostring(name or "default")
	self:_EnsureFolder()
	local data = {}
	for flag, element in pairs(MacLib.Flags) do
		if element.Get then
			data[flag] = encodeValue(element:Get())
		end
	end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
	if not ok then return false, "encode failed" end
	local ok2 = pcall(Env.writefile, self.ConfigFolder .. "/configs/" .. name .. ".json", encoded)
	return ok2
end

function Window:LoadConfig(name)
	if not Env.HasFS then return false, "no filesystem access" end
	name = tostring(name or "default")
	local path = self.ConfigFolder .. "/configs/" .. name .. ".json"
	if Env.isfile and not Env.isfile(path) then return false, "config not found" end
	local ok, raw = pcall(Env.readfile, path)
	if not ok then return false, "read failed" end
	local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok2 or type(data) ~= "table" then return false, "decode failed" end
	for flag, value in pairs(data) do
		local element = MacLib.Flags[flag]
		if element and element.Set then
			pcall(function() element:Set(decodeValue(value)) end)
		end
	end
	return true
end

function Window:ListConfigs()
	local out = {}
	if not Env.HasFS or not Env.listfiles then return out end
	self:_EnsureFolder()
	local ok, files = pcall(Env.listfiles, self.ConfigFolder .. "/configs")
	if not ok then return out end
	for _, f in ipairs(files) do
		local n = tostring(f):match("([^/\\]+)%.json$")
		if n then out[#out + 1] = n end
	end
	return out
end

function Window:DeleteConfig(name)
	if not Env.HasFS or not Env.delfile then return false end
	return (pcall(Env.delfile, self.ConfigFolder .. "/configs/" .. tostring(name) .. ".json"))
end

--=================================================================================================
--  LIBRARY LEVEL HELPERS
--=================================================================================================

function MacLib:GetFlag(flag)
	return MacLib.Values[flag]
end

function MacLib:SetFlag(flag, value)
	local el = MacLib.Flags[flag]
	if el and el.Set then el:Set(value) end
end

function MacLib:Unload()
	for i = #MacLib.Windows, 1, -1 do
		pcall(function() MacLib.Windows[i]:Unload() end)
	end
	if NotifGui then pcall(function() NotifGui:Destroy() end) end
	MacLib.Unloaded = true
end

MacLib.Icons = Icons
MacLib.SVG   = SVG
MacLib.Http  = Http
MacLib.Env   = Env

return MacLib

--[==[
=================================================================================================
  EXAMPLE SCRIPT
  Everything below is a comment so it will not run when the library is loaded.
  Copy it into its own script to try it out.
=================================================================================================

--=================================================================================================
--  EXAMPLE  ~  everything MacLib can do
--
--  Source: https://github.com/JSWorth/Maclib/blob/main/main.lua
--  Note the raw.githubusercontent.com host below - the github.com/blob/ URL serves the
--  syntax-highlighted HTML page, not the Lua, so HttpGet on it will not compile.
--=================================================================================================

local MacLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/JSWorth/Maclib/main/main.lua"))()

--=================================================================================================
--  WINDOW
--=================================================================================================

local Window = MacLib:Window({
	Title     = "Aurora",
	Subtitle  = "v2.4.0  •  Universal",
	Size      = UDim2.fromOffset(780, 500),
	Theme     = "Dark",                       -- "Dark" | "Light"
	Accent    = Color3.fromRGB(10, 132, 255), -- macOS blue
	IconStyle = "outline",                    -- linear | outline | bold | broken | bold-duotone
	ToggleKey = Enum.KeyCode.RightShift,
	Folder    = "Aurora",                     -- where configs are written
	Blur      = true,
})

--=================================================================================================
--  SIDEBAR GROUPS + TABS
--  Icon names come straight from the Solar set (https://solar-icons.vercel.app).
--=================================================================================================

local General = Window:TabSection("General")

local HomeTab    = General:Tab({ Title = "Home",    Icon = "home-2" })
local PlayerTab  = General:Tab({ Title = "Player",  Icon = "user-rounded" })
local VisualsTab = General:Tab({ Title = "Visuals", Icon = "palette" })

local Combat = Window:TabSection("Combat")

local AimTab  = Combat:Tab({ Title = "Aim Assist", Icon = "bolt" })
local ESPTab  = Combat:Tab({ Title = "ESP",        Icon = "eye" })

local System = Window:TabSection("System")

local ConfigTab   = System:Tab({ Title = "Configs",  Icon = "folder" })
local SettingsTab = System:Tab({ Title = "Settings", Icon = "settings-minimalistic" })

--=================================================================================================
--  HOME
--=================================================================================================

local welcome = HomeTab:Section({ Title = "Welcome" })

welcome:Paragraph({
	Title = "Aurora is loaded",
	Description = "Everything below is live. Press Right Shift to hide the window, drag the "
		.. "title bar to move it, and grab the bottom-right corner to resize.",
})

welcome:Button({
	Title = "Open the changelog",
	Description = "Shows a macOS style alert sheet",
	Callback = function()
		Window:Dialog({
			Title = "What's new in 2.4.0",
			Description = "Rebuilt the icon pipeline, added multi-select dropdowns and "
				.. "reworked config saving.",
			Buttons = {
				{ Title = "Not now" },
				{ Title = "Got it", Primary = true, Callback = function()
					Window:Notify({ Title = "Nice", Description = "Enjoy the update.", Icon = "check-circle" })
				end },
			},
		})
	end,
})

welcome:Button({
	Title = "Send a test notification",
	Callback = function()
		Window:Notify({
			Title = "Heads up",
			Description = "This toast dismisses itself in five seconds, or click it to close.",
			Icon = "bell",
			Duration = 5,
		})
	end,
})

local status = HomeTab:Section({ Title = "Status", Description = "Values update in real time." })

local fpsLabel = status:Label("FPS: --")
local pingLabel = status:Label("Ping: --")

task.spawn(function()
	local RunService = game:GetService("RunService")
	local Stats = game:GetService("Stats")
	while task.wait(1) do
		fpsLabel:Set(("FPS: %d"):format(math.floor(1 / RunService.RenderStepped:Wait())))
		local ok, ping = pcall(function()
			return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())
		end)
		pingLabel:Set("Ping: " .. (ok and (ping .. " ms") or "--"))
	end
end)

--=================================================================================================
--  PLAYER
--=================================================================================================

local movement = PlayerTab:Section({ Title = "Movement" })

movement:Toggle({
	Title = "Infinite jump",
	Description = "Jump again while airborne",
	Default = false,
	Flag = "player.infjump",
	Callback = function(state)
		print("[Aurora] infinite jump:", state)
	end,
})

movement:Slider({
	Title = "Walk speed",
	Description = "Applied to your humanoid",
	Min = 16, Max = 250, Default = 16, Increment = 1, Suffix = " studs/s",
	Flag = "player.walkspeed",
	Callback = function(value)
		local char = game.Players.LocalPlayer.Character
		local hum = char and char:FindFirstChildWhichIsA("Humanoid")
		if hum then hum.WalkSpeed = value end
	end,
})

movement:Slider({
	Title = "Jump power",
	Min = 50, Max = 500, Default = 50, Suffix = " studs",
	Flag = "player.jumppower",
	Callback = function(value)
		local char = game.Players.LocalPlayer.Character
		local hum = char and char:FindFirstChildWhichIsA("Humanoid")
		if hum then hum.UseJumpPower = true hum.JumpPower = value end
	end,
})

movement:Divider()

movement:Keybind({
	Title = "Speed boost",
	Description = "Hold to sprint",
	Default = Enum.KeyCode.LeftShift,
	Flag = "player.sprintkey",
	Callback = function(key)
		print("[Aurora] sprint pressed:", key.Name)
	end,
	OnChanged = function(key)
		print("[Aurora] sprint rebound to:", key and key.Name or "nothing")
	end,
})

local character = PlayerTab:Section({ Title = "Character" })

character:Dropdown({
	Title = "Movement mode",
	Options = { "Default", "Flight", "Noclip", "Spider" },
	Default = "Default",
	Flag = "player.mode",
	Callback = function(mode)
		print("[Aurora] mode:", mode)
	end,
})

character:Input({
	Title = "Teleport to player",
	Placeholder = "username",
	Flag = "player.tptarget",
	Callback = function(text, pressedEnter)
		if pressedEnter then print("[Aurora] teleporting to", text) end
	end,
})

--=================================================================================================
--  VISUALS
--=================================================================================================

local world = VisualsTab:Section({ Title = "World" })

world:Toggle({
	Title = "Fullbright",
	Default = false,
	Flag = "visuals.fullbright",
	Callback = function(on)
		game:GetService("Lighting").Ambient = on and Color3.new(1, 1, 1) or Color3.new(0, 0, 0)
	end,
})

world:Slider({
	Title = "Field of view",
	Min = 40, Max = 120, Default = 70, Suffix = "\u{00B0}",
	Flag = "visuals.fov",
	Callback = function(v)
		local cam = workspace.CurrentCamera
		if cam then cam.FieldOfView = v end
	end,
})

world:Dropdown({
	Title = "Removed effects",
	Description = "Multi-select",
	Options = { "Blur", "Bloom", "Sun rays", "Colour correction", "Depth of field" },
	Multi = true,
	Default = { "Blur", "Sun rays" },
	Flag = "visuals.removed",
	Callback = function(list)
		print("[Aurora] removing:", table.concat(list, ", "))
	end,
})

--=================================================================================================
--  COMBAT
--=================================================================================================

local aim = AimTab:Section({ Title = "Aim assist" })

aim:Toggle({ Title = "Enabled", Default = false, Flag = "aim.enabled" })
aim:Slider({ Title = "Smoothing", Min = 0, Max = 1, Default = 0.35, Decimals = 2, Flag = "aim.smooth" })
aim:Slider({ Title = "FOV radius", Min = 20, Max = 600, Default = 140, Suffix = " px", Flag = "aim.fov" })
aim:Dropdown({
	Title = "Target part",
	Options = { "Head", "UpperTorso", "HumanoidRootPart" },
	Default = "Head",
	Flag = "aim.part",
})
aim:Keybind({ Title = "Hold key", Default = Enum.KeyCode.C, Flag = "aim.key" })

local esp = ESPTab:Section({ Title = "Players" })

esp:Toggle({ Title = "Boxes", Default = true, Flag = "esp.boxes" })
esp:Toggle({ Title = "Names", Default = true, Flag = "esp.names" })
esp:Toggle({ Title = "Health bars", Default = false, Flag = "esp.health" })
esp:Toggle({ Title = "Tracers", Description = "Draw a line from the bottom of the screen",
	Default = false, Flag = "esp.tracers" })
esp:Slider({ Title = "Max distance", Min = 100, Max = 5000, Default = 1500,
	Increment = 50, Suffix = " studs", Flag = "esp.distance" })

--=================================================================================================
--  CONFIGS
--=================================================================================================

local cfgSection = ConfigTab:Section({
	Title = "Configuration",
	Description = "Configs are written to your executor's workspace folder.",
})

local nameBox = cfgSection:Input({ Title = "Config name", Placeholder = "default", Default = "default" })

local configList = cfgSection:Dropdown({
	Title = "Saved configs",
	Options = Window:ListConfigs(),
	Placeholder = "None saved",
})

cfgSection:Button({
	Title = "Save",
	Callback = function()
		local ok = Window:SaveConfig(nameBox:Get())
		configList:SetOptions(Window:ListConfigs())
		Window:Notify({
			Title = ok and "Config saved" or "Could not save",
			Description = ok and ("Wrote " .. nameBox:Get() .. ".json")
				or "This environment has no file system access.",
			Icon = ok and "check-circle" or "danger-triangle",
		})
	end,
})

cfgSection:Button({
	Title = "Load",
	Callback = function()
		local ok = Window:LoadConfig(configList:Get() or nameBox:Get())
		Window:Notify({
			Title = ok and "Config loaded" or "Could not load",
			Icon = ok and "check-circle" or "danger-triangle",
		})
	end,
})

cfgSection:Button({
	Title = "Refresh list",
	Callback = function()
		configList:SetOptions(Window:ListConfigs())
	end,
})

--=================================================================================================
--  SETTINGS
--=================================================================================================

local ui = SettingsTab:Section({ Title = "Interface" })

ui:Dropdown({
	Title = "Theme",
	Options = { "Dark", "Light" },
	Default = "Dark",
	Callback = function(name)
		Window:SetTheme(name)
	end,
})

ui:Dropdown({
	Title = "Icon style",
	Description = "Solar ships six weights",
	Options = { "linear", "outline", "bold", "broken", "bold-duotone", "line-duotone" },
	Default = "outline",
	Callback = function(style)
		MacLib.Icons.Style = style
		Window:Notify({
			Title = "Icon style set to " .. style,
			Description = "New icons will use this weight.",
			Icon = "palette",
		})
	end,
})

ui:Keybind({
	Title = "Toggle UI",
	Default = Enum.KeyCode.RightShift,
	OnChanged = function(key)
		Window.ToggleKey = key
	end,
})

local about = SettingsTab:Section({ Title = "About" })

about:Paragraph({
	Title = "Environment",
	Description = ("Executor: %s\nHTTP: %s\nMacLib: v%s"):format(
		MacLib.Env.Executor,
		MacLib.Http.Available and "available" or "unavailable (using offline icons)",
		MacLib.Version
	),
})

about:Button({
	Title = "Unload Aurora",
	Description = "Destroys the interface and disconnects everything",
	Callback = function()
		Window:Dialog({
			Title = "Unload Aurora?",
			Description = "The interface will be removed. Unsaved settings are lost.",
			Buttons = {
				{ Title = "Cancel" },
				{ Title = "Unload", Primary = true, Callback = function()
					MacLib:Unload()
				end },
			},
		})
	end,
})

--=================================================================================================
--  READY
--=================================================================================================

HomeTab:Select()

Window:Notify({
	Title = "Aurora loaded",
	Description = "Right Shift toggles the interface.",
	Icon = "rocket",
	Duration = 6,
})

]==]
