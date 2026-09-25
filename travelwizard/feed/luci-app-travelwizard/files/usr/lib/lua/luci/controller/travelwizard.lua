-- Travel-router setup wizard: page + JSON API over the tw-* helpers.
module("luci.controller.travelwizard", package.seeall)

local http = require("luci.http")
local util = require("luci.util")
local uci = require("luci.model.uci").cursor()
require("nixio.util") -- File:writeall

function index()
	-- First entry under Status so users land here, not in power-user pages.
	entry({ "admin", "travelwizard" }, template("travelwizard/wizard"),
		_("Setup Wizard"), 1).dependent = false
	-- post(): LuCI enforces POST + a valid session token, so another site
	-- cannot drive these endpoints (CSRF) from a logged-in browser.
	entry({ "admin", "travelwizard", "api", "scan" }, post("api_scan")).leaf = true
	entry({ "admin", "travelwizard", "api", "join" }, post("api_join")).leaf = true
	entry({ "admin", "travelwizard", "api", "captive" }, post("api_captive")).leaf = true
	entry({ "admin", "travelwizard", "api", "vpn_get" }, post("api_vpn_get")).leaf = true
	entry({ "admin", "travelwizard", "api", "profiles" }, post("api_profiles")).leaf = true
	entry({ "admin", "travelwizard", "api", "profile_save" }, post("api_profile_save")).leaf = true
	entry({ "admin", "travelwizard", "api", "profile_delete" }, post("api_profile_delete")).leaf = true
	entry({ "admin", "travelwizard", "api", "profile_activate" }, post("api_profile_activate")).leaf = true
	entry({ "admin", "travelwizard", "api", "profile_server" }, post("api_profile_server")).leaf = true
	entry({ "admin", "travelwizard", "api", "profile_refresh" }, post("api_profile_refresh")).leaf = true
	entry({ "admin", "travelwizard", "api", "probe" }, post("api_probe")).leaf = true
	entry({ "admin", "travelwizard", "api", "health" }, post("api_health")).leaf = true
	entry({ "admin", "travelwizard", "api", "wifi_get" }, post("api_wifi_get")).leaf = true
	entry({ "admin", "travelwizard", "api", "wifi_set" }, post("api_wifi_set")).leaf = true
	entry({ "admin", "travelwizard", "api", "upstream" }, post("api_upstream")).leaf = true
	entry({ "admin", "travelwizard", "api", "wlan_saved" }, post("api_wlan_saved")).leaf = true
	entry({ "admin", "travelwizard", "api", "wlan_rejoin" }, post("api_wlan_rejoin")).leaf = true
	entry({ "admin", "travelwizard", "api", "wlan_forget" }, post("api_wlan_forget")).leaf = true
	entry({ "admin", "travelwizard", "api", "wlan_disconnect" }, post("api_wlan_disconnect")).leaf = true
	entry({ "admin", "travelwizard", "api", "wifi_qr" }, post("api_wifi_qr")).leaf = true
end

local function run_json(cmd)
	http.prepare_content("application/json")
	local out = util.exec(cmd)
	http.write(out and #out > 0 and out or '{"error":"helper failed"}')
end

function api_scan()
	run_json("/usr/sbin/tw-wan-scan")
end

function api_join()
	local ssid = http.formvalue("ssid")
	local key = http.formvalue("key") or ""
	if not ssid or #ssid == 0 then
		http.prepare_content("application/json")
		http.write('{"error":"missing ssid"}')
		return
	end
	local band = http.formvalue("band") or ""
	local enc = http.formvalue("enc") or ""
	local bssid = http.formvalue("bssid") or ""
	run_json("/usr/sbin/tw-wan-join %s %s %s %s %s" % {
		util.shellquote(ssid), util.shellquote(key),
		util.shellquote(band), util.shellquote(enc), util.shellquote(bssid)
	})
end

function api_upstream()
	local mode = http.formvalue("mode")
	if mode ~= nil and mode ~= "" and mode ~= "wifi"
		and mode ~= "ethernet" and mode ~= "auto" then
		http.prepare_content("application/json")
		http.write('{"error":"bad mode"}')
		return
	end
	if mode ~= nil and mode ~= "" then
		run_json("/usr/sbin/tw-upstream %s" % util.shellquote(mode))
	else
		run_json("/usr/sbin/tw-upstream")
	end
end

function api_captive()
	run_json("/usr/sbin/tw-captive-check")
end

function api_wlan_disconnect()
	run_json("/usr/sbin/tw-wan-disconnect")
end

function api_wifi_qr()
	local net = http.formvalue("net") or ""
	if net ~= "mgmt" and net ~= "vault" then
		http.prepare_content("application/json")
		http.write('{"error":"bad network"}')
		return
	end
	run_json("/usr/sbin/tw-wifi-qr %s" % util.shellquote(net))
end

-- Saved upstream networks (SSID + metadata only; keys stay on the router).
function api_wlan_saved()
	local out = {}
	uci:foreach("travelwizard", "savednet", function(s)
		out[#out + 1] = { ssid = s.ssid, band = s.band,
			last_used = tonumber(s.last_used) or 0 }
	end)
	table.sort(out, function(a, b) return a.last_used > b.last_used end)
	http.prepare_content("application/json")
	http.write_json({ saved = out })
end

-- One-tap reconnect to a saved network (key looked up server-side).
-- The saved BSSID is deliberately not passed: hotels and airports run many
-- access points under one name, and pinning the one seen last time would
-- fail wherever that AP is out of range. The scan row may supply the band
-- it saw the network on now; otherwise the saved band is used.
function api_wlan_rejoin()
	local ssid = http.formvalue("ssid") or ""
	local band = http.formvalue("band") or ""
	http.prepare_content("application/json")
	if ssid == "" then
		http.write('{"error":"missing ssid"}')
		return
	end
	if band ~= "" and band ~= "2g" and band ~= "5g" then
		http.write('{"error":"bad band"}')
		return
	end
	local sec = nil
	uci:foreach("travelwizard", "savednet", function(s)
		if s.ssid == ssid then sec = s[".name"] end
	end)
	if sec == nil then
		http.write('{"error":"unknown network"}')
		return
	end
	if band == "" then band = uci:get("travelwizard", sec, "band") or "" end
	run_json("/usr/sbin/tw-wan-join %s %s %s %s ''" % {
		util.shellquote(ssid),
		util.shellquote(uci:get("travelwizard", sec, "key") or ""),
		util.shellquote(band),
		util.shellquote(uci:get("travelwizard", sec, "enc") or "")
	})
end

function api_wlan_forget()
	local ssid = http.formvalue("ssid") or ""
	http.prepare_content("application/json")
	if ssid == "" then
		http.write('{"error":"missing ssid"}')
		return
	end
	local found = false
	uci:foreach("travelwizard", "savednet", function(s)
		if s.ssid == ssid then
			uci:delete("travelwizard", s[".name"])
			found = true
		end
	end)
	if not found then
		http.write('{"error":"unknown network"}')
		return
	end
	uci:commit("travelwizard")
	http.write_json({ forgotten = ssid })
end

function api_health()
	run_json("/usr/sbin/tw-vpn-health")
end

function api_vpn_get()
	http.prepare_content("application/json")
	local m = uci:get_all("travelwizard", "main") or {}
	-- Effective mode mirrors tw_active_mode: active profile wins, else legacy.
	local mode = m.vpn_mode or "off"
	local sec = m.active_profile
	if sec ~= nil and #sec > 0 then
		local t = uci:get("travelwizard", sec, "type")
		if t ~= nil and #t > 0 then mode = t end
	end
	http.write_json({
		mgmt_ssid = m.mgmt_ssid, vault_ssid = m.vault_ssid,
		lan_net = m.lan_net, vault_net = m.vault_net,
		vpn_mode = mode, active_profile = sec,
	})
end

local function has_file(path)
	return path ~= nil and #path > 0 and nixio.fs.access(path) or false
end

local function read_default_server(path)
	if path == nil or #path == 0 then return nil end
	local txt = nixio.fs.readfile(path)
	if txt == nil then return nil end
	-- our own tw-sub-import emits `"default": "tag"` on the proxy selector
	return txt:match('"default"%s*:%s*"([^"]+)"')
end

-- Per-endpoint protocol details from a proxy config, keyed by tag:
-- { type = "vless", transport = "ws"|nil, security = "reality"|"tls"|nil }.
local function read_endpoint_protocols(path)
	local out = {}
	if path == nil or #path == 0 then return out end
	local ok, jsonc = pcall(require, "luci.jsonc")
	local conf = ok and jsonc.parse(nixio.fs.readfile(path) or "") or nil
	if type(conf) ~= "table" or type(conf.outbounds) ~= "table" then return out end
	for _, o in ipairs(conf.outbounds) do
		if type(o) == "table" and type(o.tag) == "string" and type(o.server) == "string" then
			local tls = type(o.tls) == "table" and o.tls.enabled and o.tls or nil
			out[o.tag] = {
				type = o.type,
				transport = type(o.transport) == "table" and o.transport.type or nil,
				security = tls and (type(tls.reality) == "table" and tls.reality.enabled
					and "reality" or "tls") or nil
			}
		end
	end
	return out
end

-- Proxy-endpoint helpers (connect/test/refresh live outside the edit form).
local function valid_profile_id(id)
	return id ~= nil and id:match("^[%w_.-]+$") ~= nil
end

local function singbox_paths(id)
	return "/etc/sing-box/tw-" .. id .. ".json",
		"/etc/sing-box/tw-" .. id .. ".src",
		"/etc/sing-box/tw-" .. id .. ".tags",
		"/etc/sing-box/tw-" .. id .. ".map"
end

local function profile_tags(id)
	local _, _, tags = singbox_paths(id)
	local out = {}
	local txt = nixio.fs.readfile(tags)
	if txt ~= nil then
		for line in txt:gmatch("[^\r\n]+") do
			out[#out + 1] = line
		end
	end
	return out
end

local function profile_default(id)
	local conf = singbox_paths(id)
	local tags = profile_tags(id)
	return read_default_server(conf) or tags[1] or ""
end

local function run_import(src, path, default_tag)
	local env = ""
	if default_tag ~= nil and #default_tag > 0 then
		env = "TW_DEFAULT_TAG=" .. util.shellquote(default_tag) .. " "
	end
	return util.exec(env .. "/usr/sbin/tw-sub-import - %s < %s" % {
		util.shellquote(path), util.shellquote(src) })
end

-- Hand user input (subscription URLs carry access tokens) to the importer
-- through a fresh private file: 0600, O_EXCL, unguessable name, so neither
-- another local user nor a concurrent request can read or swap it.
local function private_tmpfile(text)
	for _ = 1, 5 do
		local path = string.format("/tmp/tw-input.%d.%d",
			nixio.getpid(), math.random(1, 999999999))
		local f = nixio.open(path,
			nixio.open_flags("wronly", "creat", "excl"), 600)
		if f then
			local ok = f:writeall(text)
			f:close()
			if ok then return path end
			nixio.fs.unlink(path)
		end
	end
	return nil
end

local function import_text(text, path, default_tag)
	local tmp = private_tmpfile(text)
	if tmp == nil then return '{"error":"could not stage the import"}' end
	local out = run_import(tmp, path, default_tag)
	nixio.fs.unlink(tmp)
	return out
end

local function parse_json(out)
	local ok, jsonc = pcall(require, "luci.jsonc")
	if not ok then return nil end
	return jsonc.parse(out or "")
end

-- One-time: fold the legacy single-config sections into profiles, keeping
-- the effectively-active setup active. After this, profiles are the only
-- source of truth (legacy vpn_mode is parked at off).
local function migrate_legacy()
	if uci:get("travelwizard", "main", "migrated") == "1" then return end
	local has = false
	uci:foreach("travelwizard", "profile", function() has = true end)
	if has then
		uci:set("travelwizard", "main", "migrated", "1")
		uci:commit("travelwizard")
		return
	end
	local n = 0
	local function mkprof(ptype, name)
		n = n + 1
		local id = "p" .. n
		uci:section("travelwizard", "profile", id)
		uci:set("travelwizard", id, "name", name)
		uci:set("travelwizard", id, "type", ptype)
		return id
	end
	local legacy_mode = uci:get("travelwizard", "main", "vpn_mode") or "off"
	local activate = nil
	if (uci:get("travelwizard", "wg", "endpoint_host") or "") ~= "" then
		local id = mkprof("wireguard", "WireGuard")
		for _, k in ipairs({ "private_key", "addresses", "dns",
			"peer_public_key", "preshared_key", "endpoint_host",
			"endpoint_port", "allowed_ips" }) do
			local v = uci:get("travelwizard", "wg", k)
			if v ~= nil then uci:set("travelwizard", id, k, v) end
		end
		if legacy_mode == "wireguard" then activate = id end
	end
	local ovpn_src = uci:get("travelwizard", "ovpn", "config_file")
		or "/etc/openvpn/tw.conf"
	if has_file(ovpn_src) then
		local id = mkprof("openvpn", "OpenVPN")
		local dst = "/etc/openvpn/tw-" .. id .. ".conf"
		nixio.fs.writefile(dst, nixio.fs.readfile(ovpn_src))
		uci:set("travelwizard", id, "config_file", dst)
		uci:set("travelwizard", id, "username",
			uci:get("travelwizard", "ovpn", "username") or "")
		uci:set("travelwizard", id, "password",
			uci:get("travelwizard", "ovpn", "password") or "")
		if legacy_mode == "openvpn" then activate = id end
	end
	local sb_src = uci:get("travelwizard", "sb", "config_file")
		or "/etc/sing-box/config.json"
	local sb_sub = uci:get("travelwizard", "sb", "sub_url") or ""
	-- NOTE: a bare config file is not enough: the sing-box package ships
	-- a stock /etc/sing-box/config.json, which must not conjure an empty
	-- "Proxy" profile on every fresh install. Only migrate a subscription
	-- or a config our own importer wrote (it always has a tun-in inbound).
	local sb_mine = false
	if has_file(sb_src) then
		local txt = nixio.fs.readfile(sb_src) or ""
		sb_mine = txt:find('"tun-in"', 1, true) ~= nil
	end
	if sb_sub ~= "" or sb_mine then
		local id = mkprof("singbox", "Proxy")
		local dst = "/etc/sing-box/tw-" .. id .. ".json"
		if has_file(sb_src) then
			nixio.fs.writefile(dst, nixio.fs.readfile(sb_src))
			uci:set("travelwizard", id, "config_file", dst)
		end
		uci:set("travelwizard", id, "sub_url", sb_sub)
		if legacy_mode == "singbox" then activate = id end
	end
	uci:set("travelwizard", "main", "migrated", "1")
	if n > 0 then
		if activate ~= nil then
			uci:set("travelwizard", "main", "active_profile", activate)
		end
		uci:set("travelwizard", "main", "vpn_mode", "off")
	end
	uci:commit("travelwizard")
end

function api_profiles()
	migrate_legacy()
	local active = uci:get("travelwizard", "main", "active_profile") or ""
	local out = {}
	uci:foreach("travelwizard", "profile", function(s)
		local id = s[".name"]
		-- Never ship secrets to the browser; only values needed for
		-- display/edit plus presence flags (empty secret field = keep).
		local p = { id = id, name = s.name, type = s.type,
			active = (id == active) }
		if s.type == "wireguard" then
			p.endpoint_host = s.endpoint_host
			p.endpoint_port = s.endpoint_port
			p.addresses = s.addresses; p.dns = s.dns
			p.peer_public_key = s.peer_public_key
			p.has_private_key = s.private_key ~= nil and #s.private_key > 0
			p.has_preshared_key = s.preshared_key ~= nil and #s.preshared_key > 0
			p.summary = s.endpoint_host or ""
		elseif s.type == "openvpn" then
			p.username = s.username
			p.has_password = s.password ~= nil and #s.password > 0
			p.has_config = has_file(s.config_file)
			p.summary = p.has_config and "config uploaded" or "no config"
		elseif s.type == "singbox" then
			p.sub_url = s.sub_url
			p.has_config = has_file(s.config_file)
			p.has_map = has_file(("/etc/sing-box/tw-" .. id .. ".map"))
			p.servers = {}
			if s.config_file ~= nil and #s.config_file > 0 then
				-- parens: gsub's second return (count) would cap readfile's length
				local tagtxt = nixio.fs.readfile(
					(s.config_file:gsub("%.json$", ".tags")))
				if tagtxt ~= nil then
					for line in tagtxt:gmatch("[^\r\n]+") do
						p.servers[#p.servers + 1] = line
					end
				end
			end
			p.server = read_default_server(s.config_file) or p.servers[1]
			p.protocols = read_endpoint_protocols(s.config_file)
			p.summary = (#p.servers > 0)
				and (#p.servers .. " servers")
				or (p.has_config and "imported" or "empty")
			if s.sub_url ~= nil and #s.sub_url > 0 then
				p.summary = p.summary .. " · sub"
			end
		end
		out[#out + 1] = p
	end)
	http.prepare_content("application/json")
	http.write_json({ profiles = out, active = active })
end

local function new_profile_id()
	local n = 0
	uci:foreach("travelwizard", "profile", function() n = n + 1 end)
	local id = string.format("p%d_%d", os.time(), n + 1)
	while uci:get("travelwizard", id, "type") ~= nil do
		id = id .. math.random(0, 9)
	end
	return id
end

function api_profile_save()
	local id = http.formvalue("id") or ""
	local name = http.formvalue("name") or ""
	local ptype = http.formvalue("type") or ""
	http.prepare_content("application/json")
	-- Drop this request's pending (uncommitted) changes before answering
	-- with an error, so a half-made profile never lingers in the session's
	-- change set to be committed by some later, unrelated save.
	local function fail(out, fallback)
		uci:revert("travelwizard")
		http.write(out and #out > 0 and out or fallback)
	end
	if #name < 1 or #name > 64 then
		http.write('{"error":"name must be 1-64 characters"}')
		return
	end
	if ptype ~= "wireguard" and ptype ~= "openvpn" and ptype ~= "singbox" then
		http.write('{"error":"bad type"}')
		return
	end
	if id == "" then
		id = new_profile_id()
		uci:section("travelwizard", "profile", id)
	elseif uci:get("travelwizard", id, "type") == nil then
		http.write('{"error":"unknown profile"}')
		return
	end
	uci:set("travelwizard", id, "name", name)
	uci:set("travelwizard", id, "type", ptype)
	if ptype == "wireguard" then
		for _, k in ipairs({ "addresses", "dns", "peer_public_key",
			"endpoint_host", "endpoint_port" }) do
			local v = http.formvalue("wg_" .. k)
			if v ~= nil then uci:set("travelwizard", id, k, v) end
		end
		local aip = http.formvalue("wg_allowed_ips")
		if aip == nil or #aip == 0 then aip = "0.0.0.0/0" end
		uci:set("travelwizard", id, "allowed_ips", aip)
		for _, k in ipairs({ "private_key", "preshared_key" }) do
			local v = http.formvalue("wg_" .. k)
			if v ~= nil and #v > 0 then uci:set("travelwizard", id, k, v) end
		end
	elseif ptype == "openvpn" then
		local u = http.formvalue("ovpn_username")
		if u ~= nil then uci:set("travelwizard", id, "username", u) end
		local pw = http.formvalue("ovpn_password")
		if pw ~= nil and #pw > 0 then uci:set("travelwizard", id, "password", pw) end
		local conf = http.formvalue("ovpn_config")
		if conf ~= nil and #conf > 0 then
			local path = "/etc/openvpn/tw-" .. id .. ".conf"
			nixio.fs.writefile(path, (conf:gsub("\r\n", "\n")))
			uci:set("travelwizard", id, "config_file", path)
		end
	elseif ptype == "singbox" then
		local sub = http.formvalue("sub_url") or ""
		local links = http.formvalue("links") or ""
		local server = http.formvalue("server") or ""
		local input = sub ~= "" and sub or links
		local path, src = singbox_paths(id)
		if input ~= "" then
			local out = import_text(input, path, server)
			if out == nil or out:find('"error"') ~= nil then
				fail(out, '{"error":"import failed"}')
				return
			end
			uci:set("travelwizard", id, "config_file", path)
			uci:set("travelwizard", id, "sub_url", sub)
		elseif server ~= "" then
			if not has_file(src) then
				fail(nil, '{"error":"no subscription saved yet"}')
				return
			end
			local found = false
			for _, t in ipairs(profile_tags(id)) do
				if t == server then found = true; break end
			end
			if not found then
				fail(nil, '{"error":"unknown server"}')
				return
			end
			local out = run_import(src, path, server)
			if out == nil or out:find('"error"') ~= nil then
				fail(out, '{"error":"import failed"}')
				return
			end
			uci:set("travelwizard", id, "config_file", path)
		end
	end
	uci:commit("travelwizard")
	-- Editing the profile that is already in use must take effect too,
	-- not wait for the next reconnect.
	local active = uci:get("travelwizard", "main", "active_profile") or ""
	if http.formvalue("use") == "1" or active == id then
		uci:set("travelwizard", "main", "active_profile", id)
		uci:commit("travelwizard")
		local out = util.exec("/usr/sbin/tw-vpn-apply")
		local res = parse_json(out)
		if res ~= nil then
			res.saved = id
			http.write_json(res)
		else
			http.write(out and #out > 0 and out or '{"error":"apply failed"}')
		end
	else
		http.write_json({ saved = id })
	end
end

function api_profile_delete()
	local id = http.formvalue("id") or ""
	http.prepare_content("application/json")
	if id == "" or uci:get("travelwizard", id, "type") == nil then
		http.write('{"error":"unknown profile"}')
		return
	end
	nixio.fs.unlink("/etc/openvpn/tw-" .. id .. ".conf")
	nixio.fs.unlink("/etc/sing-box/tw-" .. id .. ".json")
	nixio.fs.unlink("/etc/sing-box/tw-" .. id .. ".src")
	nixio.fs.unlink("/etc/sing-box/tw-" .. id .. ".tags")
	nixio.fs.unlink("/etc/sing-box/tw-" .. id .. ".map")
	uci:delete("travelwizard", id)
	local was_active = uci:get("travelwizard", "main", "active_profile") == id
	if was_active then
		uci:set("travelwizard", "main", "active_profile", "")
		uci:set("travelwizard", "main", "vpn_mode", "off")
	end
	uci:commit("travelwizard")
	if was_active then
		run_json("/usr/sbin/tw-vpn-apply")
	else
		http.write_json({ deleted = id })
	end
end

function api_profile_activate()
	local id = http.formvalue("id") or ""
	http.prepare_content("application/json")
	if id ~= "" and uci:get("travelwizard", id, "type") == nil then
		http.write('{"error":"unknown profile"}')
		return
	end
	uci:set("travelwizard", "main", "active_profile", id)
	if id == "" then
		uci:set("travelwizard", "main", "vpn_mode", "off")
	end
	uci:commit("travelwizard")
	local out = util.exec("/usr/sbin/tw-vpn-apply")
	http.write(out and #out > 0 and out or '{"error":"apply failed"}')
end

-- Switch a proxy profile's active endpoint (connect, not edit). When the
-- profile is the active one the tunnel is re-applied so the change is live.
function api_profile_server()
	local id = http.formvalue("id") or ""
	local server = http.formvalue("server") or ""
	http.prepare_content("application/json")
	if not valid_profile_id(id)
		or uci:get("travelwizard", id, "type") ~= "singbox" then
		http.write('{"error":"unknown proxy profile"}')
		return
	end
	local found = false
	for _, t in ipairs(profile_tags(id)) do
		if t == server then found = true; break end
	end
	if not found then
		http.write('{"error":"unknown endpoint"}')
		return
	end
	local path, src = singbox_paths(id)
	if not has_file(src) then
		http.write('{"error":"no subscription saved yet"}')
		return
	end
	local out = run_import(src, path, server)
	if out == nil or out:find('"error"') ~= nil then
		http.write(out and #out > 0 and out or '{"error":"import failed"}')
		return
	end
	uci:set("travelwizard", id, "config_file", path)
	uci:commit("travelwizard")
	local active = uci:get("travelwizard", "main", "active_profile") or ""
	if active == id then
		local res = parse_json(util.exec("/usr/sbin/tw-vpn-apply"))
		if res ~= nil then
			res.server = server
			http.write_json(res)
		else
			http.write('{"error":"apply failed"}')
		end
	else
		http.write_json({ saved = id, server = server })
	end
end

-- Re-fetch a proxy profile's subscription (or re-import its saved links),
-- keeping the current endpoint when it still exists. Re-applies when active.
function api_profile_refresh()
	local id = http.formvalue("id") or ""
	http.prepare_content("application/json")
	if not valid_profile_id(id)
		or uci:get("travelwizard", id, "type") ~= "singbox" then
		http.write('{"error":"unknown proxy profile"}')
		return
	end
	local path, src = singbox_paths(id)
	local sub = uci:get("travelwizard", id, "sub_url") or ""
	local default = profile_default(id)
	local out
	if sub ~= "" then
		out = import_text(sub, path, default)
	elseif has_file(src) then
		out = run_import(src, path, default)
	else
		http.write('{"error":"no subscription saved yet"}')
		return
	end
	if out == nil or out:find('"error"') ~= nil then
		http.write(out and #out > 0 and out or '{"error":"refresh failed"}')
		return
	end
	uci:set("travelwizard", id, "config_file", path)
	uci:commit("travelwizard")
	local active = uci:get("travelwizard", "main", "active_profile") or ""
	local imp = parse_json(out) or {}
	if active == id then
		local res = parse_json(util.exec("/usr/sbin/tw-vpn-apply"))
		if res == nil then
			http.write('{"error":"apply failed"}')
			return
		end
		res.refreshed = id
		res.count = imp.count
		res.servers = imp.tags
		http.write_json(res)
	else
		http.write_json({ refreshed = id, count = imp.count,
			servers = imp.tags })
	end
end

-- Full end-to-end latency probe of one endpoint (see tw-probe).
function api_probe()
	local id = http.formvalue("id") or ""
	local server = http.formvalue("server") or ""
	http.prepare_content("application/json")
	if not valid_profile_id(id)
		or uci:get("travelwizard", id, "type") ~= "singbox" then
		http.write('{"error":"unknown proxy profile"}')
		return
	end
	local found = false
	for _, t in ipairs(profile_tags(id)) do
		if t == server then found = true; break end
	end
	if not found then
		http.write('{"error":"unknown endpoint"}')
		return
	end
	local out = util.exec("/usr/sbin/tw-probe %s %s" % {
		util.shellquote(id), util.shellquote(server) })
	http.write(out and #out > 0 and out or '{"error":"probe failed"}')
end

function api_wifi_get()
	http.prepare_content("application/json")
	-- Live values from the AP sections (first mgmt/vault found).
	local out = { mgmt_ssid = "", mgmt_key = "", vault_ssid = "", vault_key = "" }
	uci:foreach("wireless", "wifi-iface", function(s)
		if s.mode == "ap" and s.network == "lan" and out.mgmt_ssid == "" then
			out.mgmt_ssid, out.mgmt_key = s.ssid or "", s.key or ""
		elseif s.mode == "ap" and s.network == "vault" and out.vault_ssid == "" then
			out.vault_ssid, out.vault_key = s.ssid or "", s.key or ""
		end
	end)
	http.write_json(out)
end

function api_wifi_set()
	local ms = http.formvalue("mgmt_ssid") or ""
	local mk = http.formvalue("mgmt_key") or ""
	local vs = http.formvalue("vault_ssid") or ""
	local vk = http.formvalue("vault_key") or ""
	local function ok_ssid(s) return #s >= 1 and #s <= 32 end
	local function ok_key(k) return #k >= 8 and #k <= 63 end
	http.prepare_content("application/json")
	if not ok_ssid(ms) or not ok_ssid(vs) then
		http.write('{"error":"names must be 1-32 characters"}')
		return
	end
	if ms == vs then
		http.write('{"error":"the two network names must differ"}')
		return
	end
	if not ok_key(mk) or not ok_key(vk) then
		http.write('{"error":"passwords must be 8-63 characters"}')
		return
	end
	uci:set("travelwizard", "main", "mgmt_ssid", ms)
	uci:set("travelwizard", "main", "mgmt_key", mk)
	uci:set("travelwizard", "main", "vault_ssid", vs)
	uci:set("travelwizard", "main", "vault_key", vk)
	uci:commit("travelwizard")
	local out = util.exec("/usr/sbin/tw-wifi-apply")
	http.write(out and #out > 0 and out or '{"error":"apply failed"}')
end


