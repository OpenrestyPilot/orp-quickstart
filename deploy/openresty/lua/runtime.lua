-- Runtime configuration client for ORP.
-- The last verified snapshot is held in lua_shared_dict, so a temporary
-- control-plane outage never changes request handling.
local cjson = require "cjson"
local _M = {}
local cache = ngx.shared.runtime_configuration
local polling_started = false

local function getenv(name, fallback)
  local value = os.getenv(name)
  if value == nil or value == "" then return fallback end
  return value
end

local function configuration_url()
  local base = getenv("RUNTIME_CONTROL_PLANE_URL", "http://control-plane:8081")
  local center_id = getenv("RUNTIME_CENTER_ID", "")
  if center_id == "" then return nil, "RUNTIME_CENTER_ID is not configured" end
  return base:gsub("/+$", "") .. "/api/centers/" .. center_id .. "/runtime-configurations/current"
end

local function fetch_snapshot()
  local url, url_err = configuration_url()
  if not url then return nil, url_err end
  local host, port, path = url:match("^http://([^/:]+):?(%d*)(/.*)$")
  if not host then return nil, "only http control-plane URLs are supported" end
  local sock = ngx.socket.tcp()
  sock:settimeouts(1000, 1000, 2000)
  local ok, connect_err = sock:connect(host, tonumber(port) or 80)
  if not ok then return nil, "connect control plane: " .. (connect_err or "unknown") end
  local request = "GET " .. path .. " HTTP/1.1\r\nHost: " .. host
      .. "\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
  local sent, send_err = sock:send(request)
  if not sent then return nil, "send control plane request: " .. (send_err or "unknown") end
  local response, receive_err = sock:receive("*a")
  sock:close()
  if not response then return nil, "read control plane response: " .. (receive_err or "unknown") end
  local status = tonumber(response:match("^HTTP/%d%.%d%s+(%d%d%d)"))
  local body = response:match("\r\n\r\n(.*)")
  if status ~= 200 or not body then return nil, "control plane returned HTTP " .. tostring(status) end
  local decoded_ok, decoded, decode_err = pcall(cjson.decode, body)
  if not decoded_ok then decoded, decode_err = nil, decoded end
  if not decoded or type(decoded.content) ~= "table" or decoded.versionNo == nil then
    return nil, "invalid runtime snapshot: " .. tostring(decode_err or "missing content/versionNo")
  end
  return decoded
end

local function sync(premature)
  if premature then return end
  local snapshot, fetch_err = fetch_snapshot()
  if snapshot then
    local version = tostring(snapshot.versionNo)
    if cache:get("version") ~= version then
      local encoded, encode_err = cjson.encode(snapshot.content)
      local stored, store_err = encoded and cache:set("content", encoded)
      if stored then
        cache:set("version", version)
        cache:set("updated_at", ngx.now())
        cache:delete("last_error")
        ngx.log(ngx.NOTICE, "runtime snapshot updated to version ", version)
      else
        ngx.log(ngx.ERR, "runtime snapshot storage failed: ", store_err or encode_err)
      end
    end
  else
    cache:set("last_error", fetch_err)
    ngx.log(ngx.WARN, "runtime snapshot refresh failed: ", fetch_err)
  end
  local ok, timer_err = ngx.timer.at(tonumber(getenv("RUNTIME_POLL_INTERVAL_SECONDS", "5")) or 5, sync)
  if not ok then ngx.log(ngx.ERR, "runtime snapshot timer failed: ", timer_err) end
end

function _M.start()
  if polling_started then return end
  -- lua_shared_dict is common to every worker, so one worker performs the
  -- network poll and all workers enforce the resulting snapshot.
  if ngx.worker.id() ~= 0 then return end
  polling_started = true
  local ok, timer_err = ngx.timer.at(0, sync)
  if not ok then ngx.log(ngx.ERR, "runtime snapshot initial timer failed: ", timer_err) end
end

function _M.status()
  return {version = cache:get("version"), updatedAt = cache:get("updated_at"), lastError = cache:get("last_error")}
end

local function current_snapshot()
  local encoded = cache:get("content")
  if not encoded then return nil end
  local ok, decoded = pcall(cjson.decode, encoded)
  return ok and decoded or nil
end

local function match_ipv4(ip, cidr)
  local address, bits = cidr:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
  address, bits = address or cidr, tonumber(bits) or 32
  if bits < 0 or bits > 32 then return false end
  local function number(value)
    local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return a * 16777216 + b * 65536 + c * 256 + d
  end
  local left, right = number(ip), number(address)
  if not left or not right then return false end
  if bits == 0 then return true end
  local divisor = 2 ^ (32 - bits)
  return math.floor(left / divisor) == math.floor(right / divisor)
end

local function ip_matches(ip, rules)
  if type(rules) ~= "table" then return false end
  for _, rule in ipairs(rules) do
    if type(rule) == "string" then
      if ip:find(":", 1, true) then
        if rule:lower() == ip:lower() then return true end
      elseif match_ipv4(ip, rule) then return true end
    end
  end
  return false
end

local function current_target(content)
  local host, port = (ngx.var.host or ""):lower(), tonumber(ngx.var.server_port)
  local selected
  for _, item in ipairs(content.httpServers or {}) do
    local server = item.server or {}
    if server.domain and server.domain:lower() == host and tonumber(server.listenPort) == port then selected = item; break end
  end
  if not selected then return nil, nil end
  local path, location_id, best_length = ngx.var.uri or "/", nil, -1
  local selected_location
  for _, location in ipairs(selected.locations or {}) do
    local prefix = location.path or ""
    if path:sub(1, #prefix) == prefix and #prefix > best_length then
      location_id, best_length, selected_location = location.id, #prefix, location
    end
  end
  return selected.server.id, location_id, selected_location, selected.server
end

local function has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if tostring(value):upper() == expected:upper() then return true end
  end
  return false
end

local function header_length()
  local total = 0
  for name, value in pairs(ngx.req.get_headers(0, true)) do
    if type(value) == "table" then
      for _, item in ipairs(value) do total = total + #tostring(name) + #tostring(item) + 4 end
    else
      total = total + #tostring(name) + #tostring(value) + 4
    end
  end
  return total
end

local function request_matches_location(location)
  if not location then return false end
  local methods = location.methods or {}
  if #methods > 0 and not has_value(methods, ngx.req.get_method()) then return false end

  local content_types = location.contentTypes or {}
  if #content_types > 0 then
    local actual = (ngx.var.http_content_type or ""):lower():match("^%s*([^;]+)") or ""
    local matched = false
    for _, expected in ipairs(content_types) do
      if actual == tostring(expected):lower() then matched = true; break end
    end
    if not matched then return false end
  end

  local headers = header_length()
  if headers < (tonumber(location.headerLengthMin) or 0)
      or headers > (tonumber(location.headerLengthMax) or math.huge) then return false end

  local body = tonumber(ngx.var.content_length) or 0
  if body < (tonumber(location.bodyLengthMin) or 0)
      or body > (tonumber(location.bodyLengthMax) or math.huge) then return false end
  return true
end

local function reject(reason)
  ngx.header["X-ORP-Policy"] = reason
  return ngx.exit(ngx.HTTP_FORBIDDEN)
end

local function applies_to_http(policy, server_id, location_id)
  if policy.scope == "HTTP_SERVER" then return tostring(policy.targetResourceId) == tostring(server_id) end
  if policy.scope == "HTTP_LOCATION" then return tostring(policy.targetResourceId) == tostring(location_id) end
  return false
end

local function enforce_mode_policies(policies, matcher, order, blacklist_reason, whitelist_reason)
  local blacklist_match, whitelist_configured, whitelist_match = false, false, false
  for _, policy in ipairs(policies) do
    if policy.enabled then
      local matches = matcher(policy)
      if policy.mode == "BLACKLIST" and matches then blacklist_match = true end
      if policy.mode == "WHITELIST" then
        whitelist_configured = true
        if matches then whitelist_match = true end
      end
    end
  end
  if order == "WHITELIST_FIRST" and whitelist_match then return "allow" end
  if blacklist_match then return reject(blacklist_reason) end
  if whitelist_configured and not whitelist_match then return reject(whitelist_reason) end
  return "allow"
end

local function enforce_ip_policies(content, server_id, location_id, server, location)
  local client_ip = ngx.var.remote_addr or ""
  local policies = {}
  for _, policy in ipairs(content.ipPolicies or {}) do
    local target_enabled = (policy.scope == "HTTP_SERVER" and server.ipPolicyEnabled ~= false)
        or (policy.scope == "HTTP_LOCATION" and location and location.ipPolicyEnabled ~= false)
    if target_enabled and applies_to_http(policy, server_id, location_id) then policies[#policies + 1] = policy end
  end
  table.sort(policies, function(left, right)
    local lp, rp = tonumber(left.priority) or 0, tonumber(right.priority) or 0
    if lp ~= rp then return lp < rp end
    return tostring(left.id or "") < tostring(right.id or "")
  end)
  return enforce_mode_policies(policies, function(policy) return ip_matches(client_ip, policy.ipRules) end,
    server.ipPolicyModeOrder or "BLACKLIST_FIRST", "ip-blacklist", "ip-whitelist")
end

local function api_matches(policy)
  local method, path = ngx.req.get_method(), ngx.var.uri or "/"
  for _, rule in ipairs(policy.rules or {}) do
    -- Snapshot uses the Java model property name pathPattern. Accept path as
    -- well so a future compact Lua DTO remains backward compatible.
    local pattern = rule.pathPattern or rule.path
    if rule.method == method and (path == pattern or (type(pattern) == "string" and pattern:sub(-1) == "*" and path:sub(1, -2) == pattern:sub(1, -2))) then return true end
  end
  return false
end

function _M.enforce()
  local content = current_snapshot()
  if not content then return end -- no snapshot: fail open during bootstrap/outage
  local server_id, location_id, location, server = current_target(content)
  if not server_id then return end
  if location and not request_matches_location(location) then
    return ngx.exit(ngx.HTTP_NOT_FOUND)
  end
  enforce_ip_policies(content, server_id, location_id, server, location)
  if server.apiPolicyEnabled == false then return end
  local policies = {}
  for _, policy in ipairs(content.apiPolicies or {}) do
    local applies = (policy.scope == "HTTP_SERVER" and tostring(policy.targetResourceId) == tostring(server_id))
      or (policy.scope == "HTTP_LOCATION" and location and location.apiPolicyEnabled ~= false
        and tostring(policy.targetResourceId) == tostring(location_id))
    if applies then policies[#policies + 1] = policy end
  end
  table.sort(policies, function(left, right)
    local lp, rp = tonumber(left.priority) or 0, tonumber(right.priority) or 0
    if lp ~= rp then return lp < rp end
    return tostring(left.id or "") < tostring(right.id or "")
  end)
  return enforce_mode_policies(policies, api_matches, server.apiPolicyModeOrder or "BLACKLIST_FIRST", "api-blacklist", "api-whitelist")
end

return _M
