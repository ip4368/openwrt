-- Travel-router setup wizard: page + JSON API over the tw-* helpers.
module("luci.controller.travelwizard", package.seeall)

local http = require("luci.http")
local util = require("luci.util")
local uci = require("luci.model.uci").cursor()

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
	entry({ "admin", "travelwizard", "api", "health" }, post("api_health")).leaf = true
	entry({ "admin", "travelwizard", "api", "wifi_get" }, post("api_wifi_get")).leaf = true
	entry({ "admin", "travelwizard", "api", "wifi_set" }, post("api_wifi_set")).leaf = true
	entry({ "admin", "travelwizard", "api", "upstream" }, post("api_upstream")).leaf = true
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

-- One-time: fold the legacy single-config sections into profiles, keeping
-- the effectively-active setup active. After this, profiles are the only
-- source of truth (legacy vpn_mode is parked at off).
local function migrate_legacy()
	local has = false
	uci:foreach("travelwizard", "profile", function() has = true end)
	if has then return end
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
	if sb_sub ~= "" or has_file(sb_src) then
		local id = mkprof("singbox", "Proxy")
		local dst = "/etc/sing-box/tw-" .. id .. ".json"
		if has_file(sb_src) then
			nixio.fs.writefile(dst, nixio.fs.readfile(sb_src))
			uci:set("travelwizard", id, "config_file", dst)
		end
		uci:set("travelwizard", id, "sub_url", sb_sub)
		if legacy_mode == "singbox" then activate = id end
	end
	if n > 0 then
		if activate ~= nil then
			uci:set("travelwizard", "main", "active_profile", activate)
		end
		uci:set("travelwizard", "main", "vpn_mode", "off")
		uci:commit("travelwizard")
	end
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
		local path = "/etc/sing-box/tw-" .. id .. ".json"
		local function run_import(src, default_tag)
			local env = ""
			if default_tag ~= nil and #default_tag > 0 then
				env = "TW_DEFAULT_TAG=" .. util.shellquote(default_tag) .. " "
			end
			return util.exec(env .. "/usr/sbin/tw-sub-import - %s < %s" % {
				util.shellquote(path), util.shellquote(src) })
		end
		if input ~= "" then
			local tmp = "/tmp/tw-import.txt"
			nixio.fs.writefile(tmp, input)
			local out = run_import(tmp, server)
			nixio.fs.unlink(tmp)
			if out == nil or out:find('"error"') ~= nil then
				http.write(out and #out > 0 and out
					or '{"error":"import failed"}')
				return
			end
			uci:set("travelwizard", id, "config_file", path)
			uci:set("travelwizard", id, "sub_url", sub)
		elseif server ~= "" then
			local src = "/etc/sing-box/tw-" .. id .. ".src"
			if not has_file(src) then
				http.write('{"error":"no subscription saved yet"}')
				return
			end
			local tags = nixio.fs.readfile((src:gsub("%.src$", ".tags"))) or ""
			local found = false
			for line in tags:gmatch("[^\r\n]+") do
				if line == server then found = true; break end
			end
			if not found then
				http.write('{"error":"unknown server"}')
				return
			end
			local out = run_import(src, server)
			if out == nil or out:find('"error"') ~= nil then
				http.write(out and #out > 0 and out
					or '{"error":"import failed"}')
				return
			end
			uci:set("travelwizard", id, "config_file", path)
		end
	end
	uci:commit("travelwizard")
	if http.formvalue("use") == "1" then
		uci:set("travelwizard", "main", "active_profile", id)
		uci:commit("travelwizard")
		local out = util.exec("/usr/sbin/tw-vpn-apply")
		local ok, jsonc = pcall(require, "luci.jsonc")
		local res = ok and jsonc.parse(out or "") or nil
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


