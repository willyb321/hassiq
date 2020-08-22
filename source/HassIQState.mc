using Toybox.Communications as Comm;
using Toybox.Graphics;
using Toybox.WatchUi;
using Toybox.Time;

class HassIQState {
	var serviceCallback = null;
	var updateCallback = null;
	var status = 0;
	var entities = null;
	var selected = null;
	var host = null;
	var headers = null;
	var visibilityGroup = null;
	var llat = null;
	var token = null;
	var refreshToken = null;
	var expireTime = null;
	var textsize = 0;
	var code = null;

	static var on = "on";
	static var off = "off";
	static var unknown = "unknown";

	function initialize() {
	}

	function setHost(host) {
		var length = host.length();
		if (host.substring(length - 1, length).equals("/")) {
			self.host = host.substring(0, length - 1);
		} else {
			self.host = host;
		}
	}

	function setLlat(llat) {
		if (llat != null && llat.length() == 0) {
			llat = null;
		}
		self.llat = llat;
	}

	function setToken(token) {
		self.token = token;
	}

	function getToken() {
		return self.token;
	}

	function setRefreshToken(token) {
		self.refreshToken = token;
	}

	function getRefreshToken() {
		return self.refreshToken;
	}

	function setExpireTime(time) {
		self.expireTime = time;
	}

	function getExpireTime() {
		return self.expireTime;
	}

	function setTextsize(textsize) {
		self.textsize = textsize;
	}

	function setGroup(group) {
		self.visibilityGroup = group;
	}

	function save() {
		if (entities == null) {
			return null;
		}

		var size = entities.size();
		var stored = new [size];

		for (var i=0; i<size; ++i) {
			var entity = entities[i];
			stored[i] = { "entity_id" => entity[:entity_id], "name" => entity[:name], "state" => entity[:state] };
		}

		return stored;
	}

	function load(stored) {
		if (!(stored instanceof Array)) {
			return;
		}

		var size = stored.size();
		entities = new [size];

		for (var i=0; i<size; ++i) {
			var store = stored[i];
			entities[i] = { :entity_id => store["entity_id"], :name => store["name"], :state => store["state"] };
			if (entities[i][:state] != null) {
				updateEntityState(entities[i], entities[i][:state]);
			}
		}
	}

	function destroy() {
		self.updateCallback = null;
		self.serviceCallback = null;
	}

	function api() {
		return host + "/api";
	}

	function update(callback) {
		self.updateCallback = callback;

		System.println("llat: " + llat);
		System.println("token: " + token);
		if (expireTime != null) {
			System.println("expireTime: " + expireTime.value());
		}

		if (llat != null || (token != null && (expireTime == null || expireTime.compare(Time.now()) > 0))) {
			requestUpdate();
		} else if (code != null || refreshToken != null) {
			requestToken();
		} else {
			requestOAuth();
		}

		return true;
	}

	function requestOAuth() {
		System.println("requesting OAuth");

		Comm.registerForOAuthMessages(method(:onOAuthMessage));

		Comm.makeOAuthRequest(
			host + "/auth/authorize",
			{ "redirect_uri" => "https://www.hass-iq.net/auth", "client_id" => "https://www.hass-iq.net", "response_type" => "code" },
			"https://www.hass-iq.net",
			Comm.OAUTH_RESULT_TYPE_URL,
			{ "code" => "code", "error" => "error" }
		);
	}

	function onOAuthMessage(message) {
		if (message.data != null) {
			System.println("oauth data:" + message.data);

			var code = message.data["code"];
			var error = message.data["error"];

			self.code = code;

			requestToken();
		} else {
			log("Failed to oauth\nError: " + message);
		}
	}

	function requestToken() {
		var data = {};
		if (code != null) {
			System.println("Requesting token with code");

			data = {
				"grant_type" => "authorization_code",
				"code" => code,
				"client_id" => "https://www.hass-iq.net"
			};

			code = null;
		} else {
			System.println("Requesting token with refresh_token");

			data = {
				"grant_type" => "refresh_token",
				"refresh_token" => refreshToken,
				"client_id" => "https://www.hass-iq.net"
			};
		}

		var options = {
			:method => Comm.HTTP_REQUEST_METHOD_POST,
			:headers => { "Content-Type" => Comm.REQUEST_CONTENT_TYPE_URL_ENCODED },
		};

		if (Comm has :makeWebRequest) {
			Comm.makeWebRequest(host + "/auth/token", data, options, method(:onTokenReceive) );
		} else {
			Comm.makeJsonRequest(host + "/auth/token", data, options, method(:onTokenReceive) );
		}
	}

	function onTokenReceive(responseCode, data) {
		System.println("onTokenReceive:" + responseCode);

		self.status = responseCode;

		if (responseCode == 200) {
			log("Received token:" + data);

			setToken(data["access_token"]);

			var refreshToken = data["refresh_token"];
			if (refreshToken != null) {
				setRefreshToken(refreshToken);
			}

			var expiresIn = data["expires_in"];
			if (expiresIn != null) {
			    setExpireTime(Time.now().add(new Time.Duration(expiresIn)));
			}

			requestUpdate();
		} else if (responseCode == 401 || responseCode == 400) {
			log("Unauthorized");

			requestOAuth();
		} else {
			log("Failed to load\nError: " + responseCode.toString());
		}
	}

	function requestUpdate() {
		if (llat != null) {
			System.println("Requesting update with llat");

			headers = {
				"Content-Type" => Comm.REQUEST_CONTENT_TYPE_JSON, "Authorization" => "Bearer " + llat
			};
		} else if (token != null) {
			System.println("Requesting update with token");

			headers = {
				"Content-Type" => Comm.REQUEST_CONTENT_TYPE_JSON, "Authorization" => "Bearer " + token
			};
		}

		var options = {
			:method => Comm.HTTP_REQUEST_METHOD_GET,
			:headers => headers
		};

		if (Comm has :makeWebRequest) {
			Comm.makeWebRequest(api() + "/states/" + visibilityGroup, null, options, method(:onUpdateReceive) );
		} else {
			Comm.makeJsonRequest(api() + "/states/" + visibilityGroup, null, options, method(:onUpdateReceive) );
		}
	}

	function onUpdateReceive(responseCode, data) {
		self.status = responseCode;

		if (responseCode == 200) {
			log("Received data:" + data);

			var selected_id = self.selected != null ? self.selected[:entity_id] : null;
			self.selected = null;

			self.entities = buildEntities(data, entities);

			var size = entities.size();
			for (var i=0; i<size; ++i) {
				var entity = entities[i];

				if (selected_id != null && selected_id.equals(entity[:entity_id])) {
					self.selected = entity;
					break;
				}
			}

			if (size > 0) {
				singleUpdate(entities[0]);
			}
		} else if (responseCode == 401 || responseCode == 400) {
			log("Unauthorized");

			llat = null;

			requestToken();
		} else {
			log("Failed to load\nError: " + responseCode.toString());
		}

		if (self.updateCallback != null) {
			self.updateCallback.invoke(self);
		}
	}

	function singleUpdate(entity) {
		log("Fetching:" + entity[:entity_id]);

		var options = {
			:method => Comm.HTTP_REQUEST_METHOD_GET,
			:headers => headers
		};

		if (Comm has :makeWebRequest) {
			Comm.makeWebRequest(api() + "/states/" + entity[:entity_id], null, options, method(:onSingleUpdateReceive) );
		} else {
			Comm.makeJsonRequest(api() + "/states/" + entity[:entity_id], null, options, method(:onSingleUpdateReceive) );
		}
	}

	function onSingleUpdateReceive(responseCode, data) {
		if (responseCode == 200) {
			log("Received data:"+data);

			var entity = buildEntity(data, entities);
			if (entity == null) {
				return;
			}

			var size = entities.size();
			for (var i=0; i<size-1; ++i) {
				if (entity[:entity_id].equals(entities[i][:entity_id])) {
					singleUpdate(entities[i+1]);
				}
			}
		} else {
			log("Failed to load\nError: " + responseCode.toString());
		}

		if (self.updateCallback != null) {
			self.updateCallback.invoke(self);
		}
	}

	function callService(domain, service, entity, callback) {
		if(self.serviceCallback != null) {
			return false;
		}

		self.serviceCallback = callback;

		var data = {};
		if (domain != "script") {
			data = { "entity_id" => entity[:entity_id] };
		}

		var options = {
			:method => Comm.HTTP_REQUEST_METHOD_POST,
			:headers => headers
		};

		if (Comm has :makeWebRequest) {
			Comm.makeWebRequest(api() + "/services/" + domain + "/" + service, data, options, method(:onServiceReceive) );
		} else {
			Comm.makeJsonRequest(api() + "/services/" + domain + "/" + service, data, options, method(:onServiceReceive) );
		}

		return true;
	}

	function onServiceReceive(responseCode, data) {
		if (responseCode == 200) {
			log("Received data:"+data);

			var size = data.size();
			for (var i=0; i<size; ++i) {
				buildEntity(data[i], entities);
			}
		} else {
			log("Failed to load\nError: " + responseCode.toString());
		}

		if (self.serviceCallback != null) {
			self.serviceCallback.invoke(self);
			self.serviceCallback = null;
		}
	}

	function updateEntityState(entity, state) {
		var domain = getEntityDomain(entity);

		if (state == null) {
			state = entity[:state] != null ? entity[:state] : unknown;
		}
		var drawable = null;
		if (domain.equals("sun")) {
			if (state.equals("above_horizon") ) {
				drawable = new WatchUi.Bitmap({:rezId=>Rez.Drawables.sun});
			} else {
				drawable = new WatchUi.Bitmap({:rezId=>Rez.Drawables.moon});
			}
			entity[:drawable] = drawable;
		} else {
			if (state.equals(on)) {
				state = on;
			} else if(state.equals(off)) {
				state = off;
			} else if(state.equals(unknown)) {
				state = unknown;
			}

			var title = entity[:name] ? entity[:name] : entity[:entity_id];
			var color = Graphics.COLOR_WHITE;
			var font = null;

			if (textsize == 0) {
			    font = Graphics.FONT_XTINY;
			} else {
			    font = Graphics.FONT_TINY;
			}

			if (state.length() == 0 || state.equals(off) || state.equals(unknown)) {
				color = Graphics.COLOR_DK_GRAY ;
			} else if (state.equals(on)) {
				color = Graphics.COLOR_WHITE;
			} else {
				title = title + ": " + state;
 				color = Graphics.COLOR_WHITE;
			}

			entity[:title] = title;
			if (entity[:drawable]) {
				entity[:drawable].setText(title);
				entity[:drawable].setColor(color);
				entity[:drawable].setFont(font);
			} else {
				drawable = new WatchUi.Text({:text=>title, :font=>textsize, :locX=>WatchUi.LAYOUT_HALIGN_CENTER, :locY=>0, :color=>color});
				entity[:drawable] = drawable;
			}
		}

		entity[:state] = state;
	}

	function buildEntity(item, previous) {
		var entity_id = item["entity_id"];
		var state = item["state"];
		var attributes = item["attributes"];
		var name = null;
		var hid = false;
		if (attributes != null) {
			name = attributes["friendly_name"];
			hid = attributes["hidden"];
			if (hid) {
				var view = attributes["view"];
				if (view != null && view == true) {
					hid = false;
				}
			}
		}

		if (hid == true) {
			return null;
		}

		var entity = null;
		if (previous != null) {
			for (var j=0; j<previous.size(); ++j) {
				if (previous[j][:entity_id].equals(entity_id)) {
					entity = previous[j];
					break;
				}
			}
		}
		if (entity == null) { entity = {:entity_id=>entity_id, :name=>name}; }
		else if (name != null) { entity[:name] = name; }

		updateEntityState(entity, state);

		return entity;
	}

	function buildEntities(data, previous) {
		var size = 0;
		var entities;
		if (data instanceof Array) {
			var entities_size = data.size();
			entities = new [entities_size];
			for (var i=0; i<entities_size; ++i) {
				var entity = buildEntity(data[i], previous);

				if (entity == null) {
					continue;
				}

				entities[size] = entity;
				size++;
			}
		} else {
			var entities_list = data["attributes"]["entity_id"];
			var entities_size = entities_list.size();
			entities = new [entities_size];
			for (var i=0; i<entities_size; ++i) {
				var entity = buildEntity({"entity_id" => entities_list[i]}, previous);

				if (entity == null) {
					continue;
				}

				entities[size] = entity;
				size++;
			}
		}

		var sorted = new [size];
		var s = 0;
		for (var p=0; p<2; ++p) {
			for (var i=0; i<size; ++i) {
				var entity = entities[i];
				var domain = getEntityDomain(entity);
				if (domain.equals("sun")) {
					if (p == 0) {
						sorted[s] = entity;
						s++;
					}
				} else {
					if (p == 1) {
						sorted[s] = entity;
						s++;
					}
				}
			}
		}

		return sorted;
	}

	function getEntityDomain(entity) {
		var entity_id = entity[:entity_id] ? entity[:entity_id] : entity["entity_id"];
		return split(entity_id, ".")[0];
	}

	function getEntityId(entity) {
		var entity_id = entity[:entity_id] ? entity[:entity_id] : entity["entity_id"];
		return split(entity_id, ".")[1];
	}

	function split(s, sep) {
		var tokens = [];

		var found = s.find(sep);
		while (found != null) {
			var token = s.substring(0, found);
			tokens.add(token);
			s = s.substring(found + sep.length(), s.length());
			found = s.find(sep);
		}

		tokens.add(s);

		return tokens;
	}

	function inArray(a, item) {
		var size = a.size();
		for (var i=0; i<size; ++i) {
			if (a[i].equals(item)) {
				return true;
			}
		}
		return false;
	}

	function log(message) {
		System.println(message);
	}

	(:test)
	function assert(condition) { if(!condition) { oh_no(); }}
	(:test)
	function test_buildEntities(logger) {
		var data = [
			{
				"attributes" => {
					"hidden" => true,
					"friendly_name" => "item1"
				},
				"entity_id" => "test.item1"
			},
			{
				"attributes" => {
					"friendly_name" => "item2"
				},
				"entity_id" => "test.item2"
			}
		];

		var entities = buildEntities(data, null);
		assert(entities.size() == 1);
		assert(getEntityDomain(entities[0]).equals("test"));
	}
}
