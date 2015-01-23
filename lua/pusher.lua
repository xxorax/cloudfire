-- web socket handler
-- see https://github.com/openresty/lua-resty-redis/issues/46 near end

local MAX_WS_PER_FID = 3
local server = require "resty.websocket.server"
local RDB = get_RDB()

local wb, err = server:new({
	timeout = 1000,  				-- milliseconds
	max_payload_len = 4095,
})
if not wb then
	ngx.log(ngx.ERR, "failed to make new websocket: ", err)
	return ngx.exit(444)
end

local fid = 'fid|' .. ngx.ctx.ACTIVE_FID

-- make a fully unique id, as handle for this specific connection
local wsid = pick_token()

local function die(msg, fid, wsid)
	-- connection is over.
	LOG(wsid .. ": WS die: " .. msg)
	wb:send_close()

	-- must unsubscribe first! Can't do redis otherwise.
	RDB:unsubscribe()

	-- clean up records; might not be rock solid, but okay
	RDB:lrem('sockets|' .. fid, 0, wsid)
	RDB:del('sockets|wsid|', wsid)
	RDB:srem('sockets', wsid)

	return ngx.exit(ngx.OK)
end

-- check this user isn't using too many windows, and provide mapping
local count = RDB:rpush('sockets|' .. fid, wsid)
if count and count > MAX_WS_PER_FID then
	return die("too many", fid, wsid)
end

-- validate channel string, because it's unclean
local subchan = ngx.var.query_string or 'none'
local cleaned, n, err = ngx.re.sub(subchan, '^([a-z0-9A-Z]{1,100})$', '$1')
if cleaned ~= subchan or n ~= 1 or err then
	LOG("got chan: " .. subchan .. " => " .. cleaned)
	return die("bad chan", fid, wsid)
end

-- document our status
local status = { wsid = wsid, fid = ngx.ctx.ACTIVE_FID, chan=subchan }
RDB:sadd('sockets', wsid)
RDB:hmset('sockets|wsid|' .. wsid, status)

wb:send_text(cjson.encode(status))

-- see https://github.com/openresty/lua-resty-websocket/issues/1#issuecomment-24816008
local function client_rx(wb, fid, wsid)
	LOG("listen on ", wsid)
	local RDB = get_RDB()

	wb:set_timeout(0)
	while true do
		local bytes, typ, err = wb:recv_frame()
		if wb.fatal or err then
			LOG("rx err: ", err)
			return die("ws error", fid, wsid)
		elseif typ == "close" then
			return die("client close", fid, wsid)
		elseif typ == "text" then
			LOG("rx=" ..  bytes)
			RDB:rpush("websocket_rx", cjson.encode({wsid=wsid, msg=bytes}))
		end
	end
end

-- start another thread is listen for traffic from caller
ngx.thread.spawn(client_rx, wb, fid, wsid)


-- SUBSCRIBE -- cannot do normal redis after this.
local ok, err = RDB:subscribe("bcast", fid,
								"chan|"..subchan,
								"wsid|"..wsid
							)
if not ok then
	LOG("subscribe: " .. err)
	wb:send_close()
	return
end

while true do 
	-- read and wait for next event on subscription channel
	local res, err = RDB:read_reply()
	if not res then
		return die('read sub: ' .. err, fid, wsid)
	end

 	local mtype = res[1]
 	local chan = res[2]
 	local msg = res[3]
	LOG("Got msg: " .. mtype)

 	if mtype == "message" then
 		-- normal traffic on the channel; copy to websocket
 		local ok, err = wb:send_text(msg)
 		if not ok then
 			die("Couldn't write: " .. err, fid, wsid)
		end
	end
			
--x-- 	elseif mtype == "unsubscribe" then
--x-- 		break
--x-- 	end
end


wb:send_text("First msg")
wb:send_text("2nd msg")
while true do
 	wb:send_text("hello world")
 	ngx.sleep(5)
end

local data, typ, err = wb:recv_frame()

if not data then
	ngx.log(ngx.ERR, "failed to receive a frame: ", err)
	return ngx.exit(444)
end
