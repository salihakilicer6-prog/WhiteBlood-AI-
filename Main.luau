--!strict
-- Main.luau
-- WHITEBLOD AI Bootstrap & Entry Point
-- Simple, mobile-friendly AI assistant interface for Roblox Studio Lite.

local Main = {}
Main.version = "v1.0.0"

-- Virtual module registry and singleton cache table for standalone support
local Modules = {}
local moduleCache = {}

local function requireModule(modulePath)
	if moduleCache[modulePath] then
		return moduleCache[modulePath]
	end
	if Modules[modulePath] then
		local m = Modules[modulePath]()
		moduleCache[modulePath] = m
		return m
	end
	if typeof(require) == "function" then
		return require(modulePath)
	end
	error("Module not found: " .. tostring(modulePath))
end

-- 1. Core/JSON
Modules["./Core/JSON"] = function()
	local okGame, gameObj = pcall(function() return game end)
	local HttpService = (okGame and gameObj) and gameObj:GetService("HttpService") or nil

	local JSON = {}
	function JSON.encode(value)
		if HttpService then
			local ok, result = pcall(function() return HttpService:JSONEncode(value) end)
			return ok and result or error("JSON encode error: " .. tostring(result))
		end
		return "{}"
	end
	function JSON.decode(raw)
		if not raw or raw == "" then return nil end
		if HttpService then
			local ok, result = pcall(function() return HttpService:JSONDecode(raw) end)
			return ok and result or error("JSON decode error: " .. tostring(result))
		end
		return nil
	end
	return JSON
end

-- 2. Core/FS
Modules["./Core/FS"] = function()
	local FS = {}
	local memoryFS = {}
	local g = getgenv and getgenv() or _G or {}

	local function hasExecutorFS()
		return typeof(g.readfile) == "function" and typeof(g.writefile) == "function"
	end

	function FS.read(path)
		if hasExecutorFS() then
			local ok, result = pcall(g.readfile, path)
			if ok then return result end
		end
		return memoryFS[path] or ""
	end

	function FS.write(path, content)
		memoryFS[path] = content
		if hasExecutorFS() then
			pcall(function()
				if typeof(g.makefolder) == "function" then
					local dir = path:match("^(.+)/[^/]+$")
					if dir and #dir > 0 then pcall(g.makefolder, dir) end
				end
				g.writefile(path, content)
			end)
		end
		return true
	end

	function FS.list(dir)
		local results = {}
		if hasExecutorFS() and typeof(g.listfiles) == "function" then
			local ok, files = pcall(g.listfiles, dir)
			if ok and type(files) == "table" then
				for _, f in ipairs(files) do table.insert(results, f) end
				return results
			end
		end
		local prefix = dir:sub(-1) == "/" and dir or (dir .. "/")
		for path, _ in pairs(memoryFS) do
			if path:sub(1, #prefix) == prefix or dir == "" or dir == "." then
				table.insert(results, path)
			end
		end
		return results
	end

	function FS.exists(path)
		if hasExecutorFS() and typeof(g.isFile) == "function" then
			local ok, res = pcall(g.isFile, path)
			if ok then return res end
		end
		return memoryFS[path] ~= nil or #FS.read(path) > 0
	end

	function FS.remove(path)
		memoryFS[path] = nil
		if hasExecutorFS() and typeof(g.delfile) == "function" then pcall(g.delfile, path) end
		return true
	end

	return FS
end

-- 3. Core/Device
Modules["./Core/Device"] = function()
	local Device = {}
	function Device.viewportSize()
		local okGame, gameObj = pcall(function() return game end)
		if okGame and gameObj then
			local camera = workspace.CurrentCamera
			if camera then
				local viewport = camera.ViewportSize
				return viewport.X, viewport.Y
			end
		end
		return 800, 600
	end
	function Device.isTouch()
		local okGame, gameObj = pcall(function() return game end)
		if okGame and gameObj then
			local UserInputService = gameObj:GetService("UserInputService")
			if UserInputService then
				return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
			end
		end
		return false
	end
	function Device.isCompact()
		local vx, vy = Device.viewportSize()
		return vx <= 768 or Device.isTouch()
	end
	return Device
end

-- 4. Core/Glass
Modules["./Core/Glass"] = function()
	local Glass = {}
	function Glass.setEnabled(enabled, depth) end
	return Glass
end

-- 5. AI/Provider
Modules["./AI/Provider"] = function()
	local JSON = requireModule("./Core/JSON")

	local Provider = {}
	local config = {
		baseUrl = "https://api.openai.com/v1",
		apiKey = "",
		model = "gpt-4o-mini",
		providerType = "openai",
	}

	function Provider.setConfig(newConfig)
		if type(newConfig) == "table" then
			if type(newConfig.baseUrl) == "string" and #newConfig.baseUrl > 0 then
				config.baseUrl = newConfig.baseUrl:gsub("/+$", "")
			end
			if type(newConfig.apiKey) == "string" then
				config.apiKey = newConfig.apiKey
			end
			if type(newConfig.model) == "string" and #newConfig.model > 0 then
				config.model = newConfig.model
			end
			if type(newConfig.providerType) == "string" and #newConfig.providerType > 0 then
				config.providerType = newConfig.providerType
			end
		end
	end

	function Provider.getConfig()
		return {
			baseUrl = config.baseUrl,
			apiKey = config.apiKey,
			model = config.model,
			providerType = config.providerType,
		}
	end

	local g = getgenv and getgenv() or _G or {}

	local function httpRequest(options)
		local reqFn = g.request or g.http_request or (g.syn and g.syn.request)
		if type(reqFn) == "function" then
			local ok, response = pcall(reqFn, options)
			if ok and type(response) == "table" then
				local status = response.StatusCode or response.Status or 200
				local body = response.Body or response.ResponseBody or ""
				return status >= 200 and status < 300, status, body
			else
				return false, 0, "Executor HTTP Request hatası: " .. tostring(response)
			end
		end

		local okGame, gameObj = pcall(function() return game end)
		if not okGame or not gameObj then
			return false, 0, "Roblox environment not found"
		end

		local HttpService = gameObj:GetService("HttpService")
		local ok, result = pcall(function()
			return HttpService:RequestAsync({
				Url = options.Url,
				Method = options.Method or "GET",
				Headers = options.Headers or {},
				Body = options.Body,
			})
		end)

		if not ok then
			local errStr = tostring(result)
			if errStr:find("Http requests are not enabled") or errStr:find("HttpEnabled") then
				return false, 0, "Roblox Studio Settings -> Security -> Allow HTTP Requests seçeneği kapalı! Lütfen HTTP isteklerine izin verin."
			end
			return false, 0, "HTTP Bağlantı Hatası: " .. errStr
		end

		local status = result.StatusCode or (result.Success and 200 or 500)
		local body = result.Body or ""
		return status >= 200 and status < 300, status, body
	end

	function Provider.testConnection()
		local cfg = Provider.getConfig()
		if not cfg.apiKey or cfg.apiKey == "" then
			return false, "API Anahtarı girilmedi. Lütfen Ayarlar sayfasından API anahtarınızı tanımlayın."
		end

		local url = cfg.baseUrl .. "/models"
		local headers = {
			["Authorization"] = "Bearer " .. cfg.apiKey,
			["Content-Type"] = "application/json",
		}

		local success, status, body = httpRequest({
			Url = url,
			Method = "GET",
			Headers = headers,
		})

		if success then
			return true, "API Bağlantısı Başarılı! (" .. cfg.baseUrl .. ")"
		else
			if status == 401 then
				return false, "Hata [401]: Geçersiz API Anahtarı."
			elseif status == 404 then
				return false, "Hata [404]: URL bulunamadı (" .. url .. ")."
			else
				return false, "Bağlantı Başarısız [" .. tostring(status) .. "]: " .. tostring(body)
			end
		end
	end

	function Provider.chatCompletion(messages, tools, callback)
		local cfg = Provider.getConfig()
		if not cfg.apiKey or cfg.apiKey == "" then
			return false, "API Anahtarı ayarlanmamış! Lütfen Ayarlar sekmesinden API anahtarınızı girin.", nil
		end

		local url = cfg.baseUrl .. "/chat/completions"
		local payload = {
			model = cfg.model,
			messages = messages,
			stream = false,
		}

		if tools and #tools > 0 then
			payload.tools = tools
		end

		local headers = {
			["Authorization"] = "Bearer " .. cfg.apiKey,
			["Content-Type"] = "application/json",
		}

		local okEncode, jsonBody = pcall(JSON.encode, payload)
		if not okEncode then
			return false, "JSON Kodlama Hatası: " .. tostring(jsonBody), nil
		end

		local success, status, body = httpRequest({
			Url = url,
			Method = "POST",
			Headers = headers,
			Body = jsonBody,
		})

		if not success then
			local errMsg = "API Bağlantı Hatası [" .. tostring(status) .. "]"
			if #body > 0 then
				local okDec, dec = pcall(JSON.decode, body)
				if okDec and type(dec) == "table" and dec.error and dec.error.message then
					errMsg = "API Hatası: " .. tostring(dec.error.message)
				else
					errMsg = errMsg .. ": " .. string.sub(body, 1, 200)
				end
			end
			return false, errMsg, nil
		end

		local okDec, decoded = pcall(JSON.decode, body)
		if not okDec or type(decoded) ~= "table" then
			return false, "Geçersiz API Yanıtı (JSON okunamadı)", nil
		end

		local choice = decoded.choices and decoded.choices[1]
		if not choice then
			return false, "API boş yanıt döndürdü", nil
		end

		local content = choice.message and choice.message.content or ""
		local toolCalls = choice.message and choice.message.tool_calls or nil

		return true, content, toolCalls
	end

	return Provider
end

-- 6. Agent/Session
Modules["./Agent/Session"] = function()
	local FS = requireModule("./Core/FS")
	local JSON = requireModule("./Core/JSON")
	local Session = {}

	function Session.new(name, model)
		return {
			id = "session_" .. tostring(os.time()),
			name = name or "WHITEBLOD Chat",
			model = model or "gpt-4o-mini",
			messages = {},
			createdAt = os.time(),
			updatedAt = os.time(),
		}
	end

	function Session.save(sessionData)
		if not sessionData or not sessionData.id then return false end
		local path = "whiteblood/sessions/" .. sessionData.id .. ".json"
		local ok, raw = pcall(JSON.encode, sessionData)
		if ok then return FS.write(path, raw) end
		return false
	end

	function Session.load(sessionId)
		local path = "whiteblood/sessions/" .. sessionId .. ".json"
		if not FS.exists(path) then
			path = "opencode/sessions/" .. sessionId .. ".json"
		end
		if FS.exists(path) then
			local raw = FS.read(path)
			local ok, data = pcall(JSON.decode, raw)
			if ok then return data end
		end
		return nil
	end

	return Session
end

-- 7. Agent/Skill
Modules["./Agent/Skill"] = function()
	local FS = requireModule("./Core/FS")
	local Skill = {}

	local defaultTools = {
		{
			type = "function",
			["function"] = {
				name = "create_part",
				description = "Creates a 3D Part in Roblox Workspace with position, size, and color.",
				parameters = {
					type = "object",
					properties = {
						name = { type = "string", description = "Name of the Part" },
						className = { type = "string", description = "Part, WedgePart, CornerWedgePart, Cylinder, Sphere, MeshPart" },
						position = { type = "array", items = { type = "number" }, description = "[X, Y, Z] position" },
						size = { type = "array", items = { type = "number" }, description = "[X, Y, Z] size" },
						color = { type = "array", items = { type = "number" }, description = "[R, G, B] color values 0-255" },
						anchored = { type = "boolean", description = "Anchored state" },
						material = { type = "string", description = "SmoothPlastic, Neon, Wood, Metal, Glass, Concrete, Brick, Marble" },
					},
					required = { "name", "position" },
				},
			},
		},
		{
			type = "function",
			["function"] = {
				name = "run_luau",
				description = "Executes Luau code in Roblox Studio environment.",
				parameters = {
					type = "object",
					properties = {
						code = { type = "string", description = "Luau code string to run" },
					},
					required = { "code" },
				},
			},
		},
		{
			type = "function",
			["function"] = {
				name = "read_file",
				description = "Reads text content from a file path.",
				parameters = {
					type = "object",
					properties = {
						path = { type = "string", description = "File path to read" },
					},
					required = { "path" },
				},
			},
		},
		{
			type = "function",
			["function"] = {
				name = "write_file",
				description = "Writes text content to a file path.",
				parameters = {
					type = "object",
					properties = {
						path = { type = "string", description = "File path" },
						content = { type = "string", description = "Text content to write" },
					},
					required = { "path", "content" },
				},
			},
		},
	}

	function Skill.getTools()
		return defaultTools
	end

	function Skill.executeTool(toolName, args)
		if toolName == "create_part" then
			local ok, result = pcall(function()
				local className = args.className or "Part"
				local part = Instance.new(className)
				part.Name = args.name or "AIPart"

				if type(args.position) == "table" and #args.position >= 3 then
					part.Position = Vector3.new(args.position[1], args.position[2], args.position[3])
				else
					part.Position = Vector3.new(0, 5, 0)
				end

				if type(args.size) == "table" and #args.size >= 3 then
					part.Size = Vector3.new(args.size[1], args.size[2], args.size[3])
				end

				if type(args.color) == "table" and #args.color >= 3 then
					part.Color = Color3.fromRGB(args.color[1], args.color[2], args.color[3])
				end

				if args.anchored ~= nil then
					part.Anchored = args.anchored
				else
					part.Anchored = true
				end

				if args.material and Enum.Material[args.material] then
					part.Material = Enum.Material[args.material]
				end

				part.Parent = workspace
				return "Workspace nesnesi oluşturuldu: '" .. part.Name .. "' (" .. tostring(part.Position) .. ")"
			end)
			return ok, ok and result or ("create_part hatası: " .. tostring(result))

		elseif toolName == "run_luau" then
			local code = args.code or ""
			local fn, syntaxErr = loadstring(code)
			if not fn then
				return false, "Luau Sözdizimi Hatası: " .. tostring(syntaxErr)
			end
			local ok, execErr = pcall(fn)
			if ok then
				return true, "Luau kodu çalıştırıldı."
			else
				return false, "Çalıştırma Hatası: " .. tostring(execErr)
			end

		elseif toolName == "read_file" then
			local path = args.path or ""
			if FS.exists(path) then
				return true, FS.read(path)
			else
				return false, "Dosya bulunamadı: " .. path
			end

		elseif toolName == "write_file" then
			local path = args.path or ""
			local content = args.content or ""
			local ok = FS.write(path, content)
			return ok, ok and ("Yazıldı: " .. path) or "Dosya yazılamadı."
		end

		return false, "Bilinmeyen araç: " .. tostring(toolName)
	end

	function Skill.list()
		return {
			{ name = "create_part", description = "Roblox Workspace objesi oluşturur." },
			{ name = "run_luau", description = "Roblox Studio içinde Luau kodu çalıştırır." },
			{ name = "read_file", description = "Dosya oku." },
			{ name = "write_file", description = "Dosya yaz." },
		}
	end

	function Skill.install(url)
		return true, { name = "CustomSkill", description = "Downloaded from " .. url }
	end

	return Skill
end

-- 8. Agent/Agent
Modules["./Agent/Agent"] = function()
	local Provider = requireModule("./AI/Provider")
	local Skill = requireModule("./Agent/Skill")
	local JSON = requireModule("./Core/JSON")

	local Agent = {}

	function Agent.turn(history, onEvent, opts)
		local maxIterations = (opts and opts.maxToolIterations) or 8
		local currentIteration = 0

		local systemPrompt = "Sen WHITEBLOD AI asistanısın. Roblox Studio, Luau kodlama ve oyun geliştirme konularında uzmansın. Türkçe ve nazik bir dille yanıt ver."

		local hasSystem = false
		for _, msg in ipairs(history) do
			if msg.role == "system" then
				hasSystem = true
				if not msg.content or #msg.content == 0 then
					msg.content = systemPrompt
				end
				break
			end
		end

		if not hasSystem then
			table.insert(history, 1, { role = "system", content = systemPrompt })
		end

		while currentIteration < maxIterations do
			currentIteration = currentIteration + 1

			local tools = Skill.getTools()
			local success, responseContent, toolCalls = Provider.chatCompletion(history, tools, function(chunk)
				onEvent({ kind = "delta", text = chunk })
			end)

			if not success then
				onEvent({ kind = "error", error = responseContent })
				onEvent({ kind = "message", text = "⚠️ **Bağlantı Hatası**: " .. tostring(responseContent) })
				onEvent({ kind = "done" })
				return
			end

			if responseContent and #responseContent > 0 then
				onEvent({ kind = "message", text = responseContent })
				table.insert(history, { role = "assistant", content = responseContent })
			end

			if toolCalls and #toolCalls > 0 then
				for _, toolCall in ipairs(toolCalls) do
					local fnName = toolCall["function"] and toolCall["function"].name or ""
					local rawArgs = toolCall["function"] and toolCall["function"].arguments or "{}"

					onEvent({ kind = "tool_start", toolName = fnName })

					local parsedArgs = {}
					if type(rawArgs) == "string" then
						local ok, res = pcall(JSON.decode, rawArgs)
						if ok and type(res) == "table" then
							parsedArgs = res
						end
					elseif type(rawArgs) == "table" then
						parsedArgs = rawArgs
					end

					local toolOk, toolResult = Skill.executeTool(fnName, parsedArgs)

					if toolOk then
						onEvent({ kind = "tool_end", toolName = fnName, result = toolResult })
						table.insert(history, {
							role = "tool",
							tool_call_id = toolCall.id or fnName,
							name = fnName,
							content = tostring(toolResult),
						})
					else
						onEvent({ kind = "tool_error", toolName = fnName, error = toolResult })
						table.insert(history, {
							role = "tool",
							tool_call_id = toolCall.id or fnName,
							name = fnName,
							content = "Error: " .. tostring(toolResult),
						})
					end
				end
			else
				break
			end
		end

		onEvent({ kind = "done" })
	end

	return Agent
end

-- 9. UI Modules
Modules["./UI/Theme"] = function()
	local Theme = {}
	local palette = {
		bg = Color3.fromRGB(10, 10, 10),
		bg2 = Color3.fromRGB(18, 18, 18),
		bg3 = Color3.fromRGB(28, 28, 28),
		text = Color3.fromRGB(255, 255, 255),
		textDim = Color3.fromRGB(170, 170, 170),
		textFaint = Color3.fromRGB(100, 100, 100),
		accent = Color3.fromRGB(0, 200, 83),
		accentHover = Color3.fromRGB(0, 230, 118),
		accentDim = Color3.fromRGB(15, 55, 25),
		border = Color3.fromRGB(38, 38, 38),
		error = Color3.fromRGB(244, 67, 54),
		success = Color3.fromRGB(76, 175, 80),
		transparent = Color3.fromRGB(0, 0, 0),
	}

	Theme.sizes = {
		sidebarWidth = 120,
		topBarHeight = 44,
		buttonHeight = 42,
		inputHeight = 42,
		padding = 10,
		gap = 8,
		radius = 6,
		fontSize = 14,
		fontSizeSmall = 12,
		fontSizeTitle = 16,
		uiScale = 1.0,
	}
	Theme.glass = { blur = 0 }

	function Theme.color(name) return palette[name] or palette.bg end
	function Theme.configure(compact)
		Theme.sizes.sidebarWidth = compact and 60 or 120
		Theme.sizes.buttonHeight = compact and 44 or 42
	end
	function Theme.setGlass(enabled) end
	function Theme.setUIScale(scale) Theme.sizes.uiScale = math.clamp(scale, 0.5, 2.0) end
	return Theme
end

Modules["./UI/Ui"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = {}
	function Ui.full() return UDim2.new(1, 0, 1, 0) end
	function Ui.new(className, parent, props)
		local inst = Instance.new(className)
		if props then for k, v in pairs(props) do inst[k] = v end end
		if parent then inst.Parent = parent end
		return inst
	end

	function Ui.frame(parent, props)
		props = props or {}
		local f = Instance.new("Frame")
		f.Name = props.name or "Frame"
		f.Size = props.size or UDim2.new(1, 0, 0, 100)
		f.Position = props.position or UDim2.fromOffset(0, 0)
		f.BackgroundColor3 = Theme.color(props.bg or "bg2")
		f.BackgroundTransparency = props.transparency or (props.bg == "transparent" and 1 or 0)
		f.BorderSizePixel = props.borderSize or 0
		f.LayoutOrder = props.layoutOrder or 0

		if props.radius and props.radius > 0 then
			Ui.new("UICorner", f, { CornerRadius = UDim.new(0, props.radius) })
		end
		if props.borderColor then
			Ui.new("UIStroke", f, {
				Color = Theme.color(props.borderColor),
				Thickness = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			})
		end
		if parent then f.Parent = parent end
		return f
	end

	function Ui.glass(parent, props)
		props = props or {}
		props.bg = props.bg or "bg"
		props.radius = props.radius or Theme.sizes.radius
		return Ui.frame(parent, props)
	end

	function Ui.text(parent, props)
		props = props or {}
		local t = Instance.new("TextLabel")
		t.Name = props.name or "Text"
		t.Text = props.text or ""
		t.TextColor3 = Theme.color(props.fg or "text")
		t.TextSize = props.textSize or Theme.sizes.fontSize
		t.Font = props.font == "bold" and Enum.Font.GothamBold or (props.font == "medium" and Enum.Font.GothamMedium or (props.font == "mono" and Enum.Font.Code or Enum.Font.Gotham))
		t.TextXAlignment = props.alignX or Enum.TextXAlignment.Center
		t.TextYAlignment = props.alignY or Enum.TextYAlignment.Center
		t.Size = props.size or UDim2.new(1, 0, 0, 24)
		t.Position = props.position or UDim2.fromOffset(0, 0)
		t.BackgroundTransparency = props.transparency or 1
		t.TextWrapped = props.wraps or false
		t.LayoutOrder = props.layoutOrder or 0

		if parent then t.Parent = parent end
		return t
	end

	function Ui.listLayoutVertical(parent, gap, alignment)
		return Ui.new("UIListLayout", parent, {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap or Theme.sizes.gap),
			HorizontalAlignment = alignment or Enum.HorizontalAlignment.Left,
		})
	end

	function Ui.listLayoutHorizontal(parent, gap)
		return Ui.new("UIListLayout", parent, {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap or Theme.sizes.gap),
			VerticalAlignment = Enum.VerticalAlignment.Center,
		})
	end

	return Ui
end

Modules["./UI/Components"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = requireModule("./UI/Ui")
	local Components = {}

	function Components.button(parent, opts)
		local btn = Instance.new("TextButton")
		btn.Name = opts and opts.text or "Button"
		btn.Text = opts and opts.text or ""
		btn.TextColor3 = Theme.color((opts and opts.textColor) or "text")
		btn.TextSize = Theme.sizes.fontSize
		btn.Font = Enum.Font.GothamMedium
		btn.BackgroundColor3 = Theme.color((opts and opts.bg) or "bg3")
		btn.BorderSizePixel = 0
		btn.Size = (opts and opts.size) or UDim2.new(1, 0, 0, Theme.sizes.buttonHeight)
		btn.Position = (opts and opts.position) or UDim2.fromOffset(0, 0)
		btn.LayoutOrder = (opts and opts.layoutOrder) or 0
		btn.AutoButtonColor = true

		Ui.new("UICorner", btn, { CornerRadius = UDim.new(0, Theme.sizes.radius) })

		if opts and opts.onClick then btn.Activated:Connect(opts.onClick) end
		if parent then btn.Parent = parent end
		return btn
	end

	function Components.textInput(parent, opts)
		local height = (opts and opts.height) or Theme.sizes.inputHeight
		local container = Ui.frame(parent, {
			name = "InputContainer",
			size = (opts and opts.size) or UDim2.new(1, 0, 0, height),
			position = (opts and opts.position) or UDim2.fromOffset(0, 0),
			bg = "bg2",
			borderColor = "border",
			radius = Theme.sizes.radius,
			layoutOrder = (opts and opts.layoutOrder) or 0,
		})

		local box = Instance.new("TextBox")
		box.Name = "Box"
		box.Text = (opts and opts.text) or ""
		box.PlaceholderText = (opts and opts.placeholder) or ""
		box.PlaceholderColor3 = Theme.color("textFaint")
		box.TextColor3 = Theme.color("text")
		box.TextSize = Theme.sizes.fontSize
		box.Font = Enum.Font.Gotham
		box.ClearTextOnFocus = false
		box.MultiLine = (opts and opts.multiLine) or false
		box.TextWrapped = (opts and opts.multiLine) or false
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.TextYAlignment = (opts and opts.multiLine) and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
		box.BackgroundTransparency = 1
		box.Size = UDim2.new(1, -16, 1, 0)
		box.Position = UDim2.fromOffset(8, 0)
		box.Parent = container

		if opts and opts.onChanged then
			box:GetPropertyChangedSignal("Text"):Connect(function()
				opts.onChanged(box.Text)
			end)
		end

		return { container = container, box = box }
	end

	function Components.scroll(parent, opts)
		local sc = Instance.new("ScrollingFrame")
		sc.Name = (opts and opts.name) or "Scroll"
		sc.Size = (opts and opts.size) or Ui.full()
		sc.Position = (opts and opts.position) or UDim2.fromOffset(0, 0)
		sc.BackgroundColor3 = Theme.color((opts and opts.bg) or "transparent")
		sc.BackgroundTransparency = (opts and opts.bg) == "transparent" and 1 or 0
		sc.BorderSizePixel = 0
		sc.ScrollBarThickness = (opts and opts.scrollThickness) or 6
		sc.ScrollBarImageColor3 = Theme.color((opts and opts.scrollbarColor) or "accentDim")
		sc.CanvasSize = UDim2.new(0, 0, 0, 0)
		sc.AutomaticCanvasSize = Enum.AutomaticSize.Y

		if parent then sc.Parent = parent end
		return sc
	end

	function Components.toast(parent, message, kind)
		local bgCol = kind == "success" and "accentDim" or (kind == "error" and "error" or "bg3")
		local toastFrame = Ui.frame(parent, {
			name = "Toast",
			size = UDim2.new(0.8, 0, 0, 36),
			position = UDim2.new(0.1, 0, 0.02, 0),
			bg = bgCol,
			borderColor = "accent",
			radius = Theme.sizes.radius,
			layoutOrder = 9999,
		})
		Ui.text(toastFrame, {
			text = message,
			fg = "text",
			textSize = Theme.sizes.fontSizeSmall,
			font = "medium",
		})
		task.delay(2.5, function()
			if toastFrame and toastFrame.Parent then toastFrame:Destroy() end
		end)
	end

	return Components
end

Modules["./UI/Window"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = requireModule("./UI/Ui")
	local Components = requireModule("./UI/Components")
	local Window = {}

	function Window.create(parent, opts)
		local titleText = "WHITEBLOD AI"

		local screenGui = parent or Instance.new("ScreenGui")
		if screenGui:IsA("ScreenGui") then
			screenGui.Name = "WhiteBloodAI_GUI"
			screenGui.ResetOnSpawn = false
		end

		local mainContainer = Ui.frame(screenGui, {
			name = "WhiteBloodWindow",
			size = UDim2.fromOffset((opts and opts.width) or 720, (opts and opts.height) or 520),
			position = UDim2.fromOffset((opts and opts.x) or 20, (opts and opts.y) or 20),
			bg = "bg",
			borderColor = "border",
			radius = Theme.sizes.radius,
		})

		local topBar = Ui.frame(mainContainer, {
			name = "TopBar",
			size = UDim2.new(1, 0, 0, Theme.sizes.topBarHeight),
			bg = "bg2",
			borderColor = "border",
		})

		Ui.text(topBar, {
			name = "Title",
			text = titleText,
			fg = "accent",
			textSize = Theme.sizes.fontSizeTitle,
			font = "bold",
			alignX = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(14, 0),
			size = UDim2.new(0.6, 0, 1, 0),
		})

		local closeBtn = Components.button(topBar, {
			text = "X",
			size = UDim2.fromOffset(32, 32),
			position = UDim2.new(1, -38, 0.5, -16),
			bg = "bg3",
			textColor = "textDim",
			onClick = function()
				if opts and opts.onClose then opts.onClose() else mainContainer:Destroy() end
			end,
		})

		local content = Ui.frame(mainContainer, {
			name = "Content",
			size = UDim2.new(1, 0, 1, -Theme.sizes.topBarHeight),
			position = UDim2.fromOffset(0, Theme.sizes.topBarHeight),
			bg = "transparent",
		})

		return {
			ScreenGui = screenGui,
			Frame = mainContainer,
			Content = content,
			setScale = function(scale) Theme.setUIScale(scale) end,
			destroy = function() if mainContainer and mainContainer.Parent then mainContainer:Destroy() end end,
		}
	end

	return Window
end

Modules["./UI/Markdown"] = function()
	local Markdown = {}
	function Markdown.plain(text)
		if not text then return "" end
		return text:gsub("```%w*", ""):gsub("```", "")
	end
	return Markdown
end

Modules["./UI/Views/Chat"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = requireModule("./UI/Ui")
	local Components = requireModule("./UI/Components")
	local ChatView = {}

	function ChatView.create(parent, opts)
		local root = Ui.frame(parent, { name = "ChatView", size = Ui.full(), bg = "transparent" })

		local scroll = Components.scroll(root, {
			name = "ChatScroll",
			size = UDim2.new(1, -20, 1, -(Theme.sizes.inputHeight + 24)),
			position = UDim2.fromOffset(10, 10),
		})
		Ui.listLayoutVertical(scroll, 8, Enum.HorizontalAlignment.Left)

		local inputRow = Ui.frame(root, {
			name = "InputRow",
			size = UDim2.new(1, -20, 0, Theme.sizes.inputHeight),
			position = UDim2.new(0, 10, 1, -(Theme.sizes.inputHeight + 10)),
			bg = "transparent",
		})

		local input = Components.textInput(inputRow, {
			placeholder = (opts and opts.placeholder) or "WHITEBLOD AI'a soru sorun...",
			size = UDim2.new(1, -70, 1, 0),
		})

		local sendBtn = Components.button(inputRow, {
			text = "Gönder",
			size = UDim2.new(0, 64, 1, 0),
			position = UDim2.new(1, -64, 0, 0),
			bg = "accent",
			textColor = "bg",
		})

		local api = {
			root = root,
			onSubmit = nil,
			currentAssistantLabel = nil,
			isStreaming = false,
		}

		local function submitText()
			local text = input.box.Text:gsub("^%s+", ""):gsub("%s+$", "")
			if #text > 0 and api.onSubmit and not api.isStreaming then
				input.box.Text = ""
				api.addMessage("user", text)
				api.onSubmit(text)
			end
		end

		sendBtn.Activated:Connect(submitText)
		input.box.FocusLost:Connect(function(enterPressed)
			if enterPressed then submitText() end
		end)

		function api.addMessage(role, text)
			local bubbleBg = role == "user" and "bg3" or (role == "tool" and "bg2" or "accentDim")
			local textColor = role == "user" and "text" or (role == "system" and "error" or "text")

			local bubble = Ui.frame(scroll, {
				name = "MessageBubble_" .. role,
				size = UDim2.new(1, 0, 0, 0),
				bg = bubbleBg,
				radius = Theme.sizes.radius,
				borderColor = role == "tool" and "border" or nil,
			})

			local label = Ui.text(bubble, {
				text = text,
				fg = textColor,
				textSize = Theme.sizes.fontSize,
				alignX = Enum.TextXAlignment.Left,
				alignY = Enum.TextYAlignment.Top,
				position = UDim2.fromOffset(10, 8),
				size = UDim2.new(1, -20, 0, 0),
				wraps = true,
			})

			label:GetPropertyChangedSignal("TextBounds"):Connect(function()
				local bounds = label.TextBounds
				label.Size = UDim2.new(1, -20, 0, math.max(20, bounds.Y))
				bubble.Size = UDim2.new(1, 0, 0, bounds.Y + 16)
				scroll.CanvasPosition = Vector2.new(0, scroll.AbsoluteCanvasSize.Y)
			end)

			if role == "assistant" then api.currentAssistantLabel = label end
			scroll.CanvasPosition = Vector2.new(0, scroll.AbsoluteCanvasSize.Y)
		end

		function api.addDelta(text)
			if api.currentAssistantLabel then
				api.currentAssistantLabel.Text = api.currentAssistantLabel.Text .. text
			end
		end

		function api.finishDelta() api.currentAssistantLabel = nil end

		function api.setStreaming(streaming)
			api.isStreaming = streaming
			sendBtn.Text = streaming and "..." or "Gönder"
		end

		local greetingMsg = (opts and opts.greeting) or "**WHITEBLOD AI** - Roblox Studio Lite AI Asistanı.\n\nKod yazabilir, Roblox oyun objeleri oluşturabilir, dosyaları düzenleyebilir ve sorularınızı yanıtlayabilirim."
		api.addMessage("assistant", greetingMsg)

		return api
	end

	return ChatView
end

Modules["./UI/Views/Console"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = requireModule("./UI/Ui")
	local Components = requireModule("./UI/Components")
	local ConsoleView = {}

	function ConsoleView.create(parent, opts)
		local root = Ui.frame(parent, { name = "ConsoleView", size = Ui.full(), bg = "transparent" })
		local scroll = Components.scroll(root, {
			name = "LogScroll",
			size = UDim2.new(1, -20, 1, -20),
			position = UDim2.fromOffset(10, 10),
		})
		Ui.listLayoutVertical(scroll, 4, Enum.HorizontalAlignment.Left)

		local api = { root = root }
		function api.log(msg, kind)
			local col = kind == "warn" and "accent" or (kind == "error" and "error" or "textDim")
			Ui.text(scroll, {
				text = "[" .. os.date("%X") .. "] " .. msg,
				fg = col,
				textSize = Theme.sizes.fontSizeSmall,
				font = "mono",
				alignX = Enum.TextXAlignment.Left,
				size = UDim2.new(1, 0, 0, 18),
			})
		end
		api.log("WHITEBLOD AI Konsol Başlatıldı.", "info")
		return api
	end

	return ConsoleView
end

Modules["./UI/Views/Files"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = requireModule("./UI/Ui")
	local Components = requireModule("./UI/Components")
	local FS = requireModule("./Core/FS")
	local FilesView = {}

	function FilesView.create(parent, opts)
		local rootDir = opts and opts.root or "whiteblood"
		local root = Ui.frame(parent, { name = "FilesView", size = Ui.full(), bg = "transparent" })

		local scroll = Components.scroll(root, {
			name = "FilesScroll",
			size = UDim2.new(1, -20, 1, -20),
			position = UDim2.fromOffset(10, 10),
		})
		Ui.listLayoutVertical(scroll, 6, Enum.HorizontalAlignment.Left)

		local api = { root = root, onOpen = nil }

		function api.refresh()
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("Frame") or child:IsA("TextButton") then child:Destroy() end
			end

			local files = FS.list(rootDir)
			if #files == 0 then
				Ui.text(scroll, { text = "Kayıtlı dosya yok (" .. rootDir .. ")", fg = "textFaint" })
				return
			end

			for idx, path in ipairs(files) do
				local name = path:match("([^/]+)$") or path
				Components.button(scroll, {
					text = "📄 " .. name,
					size = UDim2.new(1, 0, 0, 36),
					bg = "bg2",
					layoutOrder = idx,
					onClick = function()
						if api.onOpen then api.onOpen(path, name) end
					end,
				})
			end
		end

		api.refresh()
		return api
	end

	return FilesView
end

Modules["./UI/Views/Editor"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = requireModule("./UI/Ui")
	local Components = requireModule("./UI/Components")
	local FS = requireModule("./Core/FS")
	local EditorView = {}

	function EditorView.create(parent, opts)
		local root = Ui.frame(parent, { name = "EditorView", size = Ui.full(), bg = "transparent" })

		local topRow = Ui.frame(root, {
			name = "EditorTopRow",
			size = UDim2.new(1, -20, 0, 36),
			position = UDim2.fromOffset(10, 10),
			bg = "transparent",
		})

		local titleLabel = Ui.text(topRow, {
			text = opts and opts.fileName or "untitled.luau",
			fg = "accent",
			textSize = Theme.sizes.fontSize,
			font = "bold",
			alignX = Enum.TextXAlignment.Left,
			size = UDim2.new(0.6, 0, 1, 0),
		})

		local saveBtn = Components.button(topRow, {
			text = "Kaydet",
			size = UDim2.fromOffset(80, 36),
			position = UDim2.new(1, -80, 0, 0),
			bg = "accent",
			textColor = "bg",
		})

		local input = Components.textInput(root, {
			placeholder = "-- Luau kodunuzu buraya yazın...",
			size = UDim2.new(1, -20, 1, -66),
			position = UDim2.fromOffset(10, 56),
			multiLine = true,
		})

		local api = { root = root, currentPath = "whiteblood/untitled.luau" }

		saveBtn.Activated:Connect(function()
			local content = input.box.Text
			if api.currentPath then
				FS.write(api.currentPath, content)
				if opts and opts.onSaved then opts.onSaved() end
			end
		end)

		function api.load(path)
			api.currentPath = path
			titleLabel.Text = path:match("([^/]+)$") or path
			if FS.exists(path) then
				input.box.Text = FS.read(path)
			else
				input.box.Text = ""
			end
		end

		return api
	end

	return EditorView
end

Modules["./UI/Views/Settings"] = function()
	local Theme = requireModule("./UI/Theme")
	local Ui = requireModule("./UI/Ui")
	local Components = requireModule("./UI/Components")
	local Provider = requireModule("./AI/Provider")
	local FS = requireModule("./Core/FS")
	local JSON = requireModule("./Core/JSON")
	local SettingsView = {}

	function SettingsView.create(parent, opts)
		local root = Ui.frame(parent, { name = "SettingsView", size = Ui.full(), bg = "transparent" })
		local scroll = Components.scroll(root, {
			name = "SettingsScroll",
			size = UDim2.new(1, -20, 1, -20),
			position = UDim2.fromOffset(10, 10),
		})
		Ui.listLayoutVertical(scroll, 10, Enum.HorizontalAlignment.Left)

		Ui.text(scroll, {
			text = "WHITEBLOD AI - Yapılandırma",
			fg = "accent",
			textSize = Theme.sizes.fontSizeTitle,
			font = "bold",
			alignX = Enum.TextXAlignment.Left,
			size = UDim2.new(1, 0, 0, 24),
		})

		local cfg = Provider.getConfig()

		Ui.text(scroll, { text = "Base URL (API Adresi):", fg = "textDim", textSize = Theme.sizes.fontSizeSmall, alignX = Enum.TextXAlignment.Left })
		local urlInput = Components.textInput(scroll, { placeholder = "https://api.openai.com/v1", text = cfg.baseUrl, size = UDim2.new(1, 0, 0, 40) })

		Ui.text(scroll, { text = "API Anahtarı (API Key):", fg = "textDim", textSize = Theme.sizes.fontSizeSmall, alignX = Enum.TextXAlignment.Left })
		local keyInput = Components.textInput(scroll, { placeholder = "sk-...", text = cfg.apiKey, size = UDim2.new(1, 0, 0, 40) })

		Ui.text(scroll, { text = "Model İsmi:", fg = "textDim", textSize = Theme.sizes.fontSizeSmall, alignX = Enum.TextXAlignment.Left })
		local modelInput = Components.textInput(scroll, { placeholder = "gpt-4o-mini / deepseek-chat", text = cfg.model, size = UDim2.new(1, 0, 0, 40) })

		local statusBox = Ui.frame(scroll, {
			name = "StatusBox",
			size = UDim2.new(1, 0, 0, 60),
			bg = "bg2",
			borderColor = "border",
			radius = Theme.sizes.radius,
		})
		local statusLabel = Ui.text(statusBox, {
			text = "Durum: Bağlantı testi için aşağıdaki butona basın.",
			fg = "textDim",
			textSize = Theme.sizes.fontSizeSmall,
			alignX = Enum.TextXAlignment.Left,
			alignY = Enum.TextYAlignment.Top,
			position = UDim2.fromOffset(10, 8),
			size = UDim2.new(1, -20, 1, -16),
			wraps = true,
		})

		local btnRow = Ui.frame(scroll, { name = "BtnRow", size = UDim2.new(1, 0, 0, 42), bg = "transparent" })

		local testBtn = Components.button(btnRow, {
			text = "API Bağlantısını Test Et",
			size = UDim2.new(0.48, 0, 1, 0),
			position = UDim2.fromOffset(0, 0),
			bg = "bg3",
		})

		local saveBtn = Components.button(btnRow, {
			text = "Kaydet",
			size = UDim2.new(0.48, 0, 1, 0),
			position = UDim2.new(0.52, 0, 0, 0),
			bg = "accent",
			textColor = "bg",
		})

		testBtn.Activated:Connect(function()
			statusLabel.Text = "Bağlantı test ediliyor..."
			statusLabel.TextColor3 = Theme.color("textDim")

			Provider.setConfig({
				baseUrl = urlInput.box.Text,
				apiKey = keyInput.box.Text,
				model = modelInput.box.Text,
			})

			task.spawn(function()
				local ok, msg = Provider.testConnection()
				statusLabel.Text = msg
				statusLabel.TextColor3 = ok and Theme.color("accent") or Theme.color("error")
			end)
		end)

		saveBtn.Activated:Connect(function()
			local updatedConfig = {
				baseUrl = urlInput.box.Text,
				apiKey = keyInput.box.Text,
				model = modelInput.box.Text,
			}
			Provider.setConfig(updatedConfig)

			pcall(function()
				local jsonStr = JSON.encode(updatedConfig)
				FS.write("whiteblood/config.json", jsonStr)
				FS.write("opencode/config.json", jsonStr)
			end)

			statusLabel.Text = "Ayarlar kaydedildi!"
			statusLabel.TextColor3 = Theme.color("accent")
			if opts and opts.onSave then opts.onSave() end
		end)

		return { root = root }
	end

	return SettingsView
end

-- Load Core & UI Modules
local Theme = requireModule("./UI/Theme")
local Ui = requireModule("./UI/Ui")
local Components = requireModule("./UI/Components")
local Window = requireModule("./UI/Window")
local ChatView = requireModule("./UI/Views/Chat")
local EditorView = requireModule("./UI/Views/Editor")
local SettingsView = requireModule("./UI/Views/Settings")

local Agent = requireModule("./Agent/Agent")
local Session = requireModule("./Agent/Session")
local Provider = requireModule("./AI/Provider")
local FS = requireModule("./Core/FS")
local JSON = requireModule("./Core/JSON")
local Device = requireModule("./Core/Device")

-- 3 Simple Menu Navigation Items
local NAV = {
	{ id = "chat", name = "Sohbet" },
	{ id = "kod", name = "Kod" },
	{ id = "settings", name = "Ayarlar" },
}

function Main.start(parent, opts)
	opts = opts or {}

	local compact = opts.compact
	if compact == nil then compact = Device.isCompact() end
	Theme.configure(compact)

	-- Load Persisted Config
	local persisted = {}
	local okRead, rawConfig = pcall(FS.read, "whiteblood/config.json")
	if not okRead or #rawConfig == 0 then
		okRead, rawConfig = pcall(FS.read, "opencode/config.json")
	end
	if okRead and rawConfig and #rawConfig > 0 then
		local okDec, parsed = pcall(JSON.decode, rawConfig)
		if okDec and type(parsed) == "table" then
			persisted = parsed
		end
	end
	Provider.setConfig(persisted)

	-- Create Main Window
	local width, height = opts.width, opts.height
	if compact then
		local vw, vh = Device.viewportSize()
		width = math.min(width or (vw - 16), vw - 16)
		height = math.min(height or (vh - 16), vh - 16)
	end

	local win = Window.create(parent, {
		title = "WHITEBLOD AI",
		width = width or 720,
		height = height or 520,
		x = opts.x,
		y = opts.y,
		onClose = function() win.destroy() end,
	})

	-- Sidebar Navigation Layout
	local sidebarWidth = compact and 64 or 120
	local sidebar = Ui.frame(win.Content, {
		name = "Sidebar",
		size = UDim2.new(0, sidebarWidth, 1, 0),
		position = UDim2.fromOffset(0, 0),
		bg = "bg2",
		borderColor = "border",
	})

	local navList = Ui.frame(sidebar, {
		name = "NavList",
		size = UDim2.new(1, -12, 1, -20),
		position = UDim2.fromOffset(6, 10),
		bg = "transparent",
	})
	Ui.listLayoutVertical(navList, 8, Enum.HorizontalAlignment.Center)

	local mainArea = Ui.frame(win.Content, {
		name = "MainArea",
		size = UDim2.new(1, -sidebarWidth, 1, 0),
		position = UDim2.fromOffset(sidebarWidth, 0),
		bg = "bg",
	})

	local viewHost = Ui.frame(mainArea, { name = "ViewHost", size = Ui.full(), bg = "transparent" })

	local views = {}
	local navButtons = {}
	local activeView = "chat"

	local function showView(id)
		activeView = id
		for k, v in pairs(views) do
			if v.root then
				v.root.Visible = (k == id)
			end
		end
		for navId, btn in pairs(navButtons) do
			local sel = (navId == id)
			btn.BackgroundColor3 = sel and Theme.color("accent") or Theme.color("bg3")
			btn.TextColor3 = sel and Theme.color("bg") or Theme.color("text")
		end
	end

	for idx, item in ipairs(NAV) do
		local btn = Components.button(navList, {
			text = item.name,
			size = UDim2.new(1, 0, 0, Theme.sizes.buttonHeight),
			layoutOrder = idx,
			bg = "bg3",
			onClick = function() showView(item.id) end,
		})
		navButtons[item.id] = btn
	end

	-- ---- Create Views ----
	local chat = ChatView.create(viewHost, {
		placeholder = "WHITEBLOD AI'a komut veya soru yazın...",
		greeting = "**WHITEBLOD AI** - Roblox Studio Lite AI Asistanı.\n\nRoblox Studio objeleri oluşturabilir, Luau script yazabilir, dosyaları yönetebilir ve sorularınızı yanıtlayabilirim.",
	})
	views.chat = chat

	local editor = EditorView.create(viewHost, {
		fileName = "whiteblood/script.luau",
		onSaved = function() Components.toast(viewHost, "Kod kaydedildi!", "success") end,
	})
	views.kod = editor
	editor.root.Visible = false

	local settingsView = SettingsView.create(viewHost, {
		onSave = function() Components.toast(viewHost, "Ayarlar kaydedildi!", "success") end,
	})
	views.settings = settingsView
	settingsView.root.Visible = false

	-- ---- Wire Agent to Chat ----
	local history = {}
	local sessionId = opts and opts.session or "default"
	local loadedSession = Session.load(sessionId)
	if loadedSession and type(loadedSession.messages) == "table" then
		history = loadedSession.messages
	end

	local isBusy = false

	chat.onSubmit = function(text)
		if isBusy then
			chat.addMessage("system", "Asistan çalışıyor. Lütfen tamamlanmasını bekleyin.")
			return
		end
		isBusy = true
		table.insert(history, { role = "user", content = text })
		chat.setStreaming(true)

		task.spawn(function()
			local ok, err = pcall(function()
				Agent.turn(history, function(ev)
					if ev.kind == "delta" then
						chat.addDelta(ev.text or "")
					elseif ev.kind == "tool_start" then
						chat.addMessage("tool", "⚙️ Araç çalıştırılıyor: **" .. tostring(ev.toolName) .. "**...")
					elseif ev.kind == "tool_end" then
						chat.finishDelta()
						chat.addMessage("tool", "✅ **" .. tostring(ev.toolName) .. "** tamamlandı:\n`" .. tostring(ev.result) .. "`")
					elseif ev.kind == "tool_error" then
						chat.addMessage("tool", "❌ Araç hatası (**" .. tostring(ev.toolName) .. "**): " .. tostring(ev.error))
					elseif ev.kind == "message" then
						chat.addMessage("assistant", ev.text or "")
					elseif ev.kind == "done" then
						chat.setStreaming(false)
						isBusy = false
						local data = Session.load(sessionId) or Session.new("WHITEBLOD AI", Provider.getConfig().model)
						data.messages = history
						data.updatedAt = os.time()
						Session.save(data)
					end
				end, { maxToolIterations = opts and opts.maxIterations or 8 })
			end)

			if not ok then
				chat.setStreaming(false)
				isBusy = false
				chat.addMessage("system", "Hata oluştu: " .. tostring(err))
			end
		end)
	end

	showView("chat")

	return {
		window = win,
		chat = chat,
		showView = showView,
		getActiveView = function() return activeView end,
	}
end

-- Auto-start if loaded as standalone script in Roblox workspace
local okGame, gameObj = pcall(function() return rawget(getfenv(), "game") or game end)
if okGame and gameObj and typeof(gameObj) == "Instance" then
	local okRun, runService = pcall(function() return gameObj:GetService("RunService") end)
	if okRun and runService and (runService:IsStudio() or runService:IsClient()) then
		pcall(function()
			local player = gameObj:GetService("Players").LocalPlayer
			if player then
				local playerGui = player:FindFirstChildOfClass("PlayerGui")
				if playerGui then
					Main.start(playerGui)
				end
			end
		end)
	end
end

return Main
