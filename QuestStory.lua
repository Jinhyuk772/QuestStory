-- QuestStory 0.1.1: 퀘스트를 받을 때 / 완료할 때 한국어 세 줄 이야기 팝업.
-- 일반 프레임만 씀 (보안 프레임·후킹 없음 = taint 없음). OnUpdate 는 팝업이 보일 때만 돈다.
-- 데이터: Data.lua 의 QuestStoryData (없어도 동작: 제목 + 목표만 보여 줌).
local ADDON = "QuestStory"
QuestStory = QuestStory or {}
local QS = QuestStory
QS.queue = {}          -- 대기 중인 팝업 (FIFO)
QS.current = nil       -- 화면에 떠 있는 팝업
QS.moveMode = false
QS.t = 0               -- 현재 팝업이 보인 시간(초, 호버 중엔 멈춤)

local W, PAD = 440, 14
local FADE_IN, FADE_OUT = 0.25, 0.6
local PFX = "|cffffd24a[QuestStory]|r "
local FONT_FILES = {
  "Interface\\AddOns\\QuestStory\\Fonts\\2002.ttf",
  "Interface\\AddOns\\QuestCue\\Fonts\\2002.ttf",
  "Interface\\AddOns\\NameLens_Font\\2002.ttf",
  "Interface\\AddOns\\NameLens\\Fonts\\2002.ttf",
}
local GOLD = {1, 0.82, 0.29}
local GREEN = {0.45, 0.85, 0.45}
local WARM = {0.93, 0.9, 0.82}
local DIM = {0.78, 0.75, 0.68}
local MUTED = {0.72, 0.62, 0.38}
local FOOT = {0.5, 0.48, 0.44}

local cache = {}       -- [questID] = {title=, obj=}  (QUEST_DETAIL / QUEST_COMPLETE 에서 채움)
local recent = {}      -- [questID] = GetTime() (중복 QUEST_ACCEPTED 거르기)
local burstTotal, burstPos = 0, 0
local ui

local function say(msg) print(PFX .. msg) end
local function str(s) if type(s) == "string" and s:find("%S") then return s end end
local function try(f, ...)
  if type(f) ~= "function" then return nil end
  local r = {pcall(f, ...)}
  if not r[1] then return nil end
  return unpack(r, 2, 9)
end
local function ulen(s) return (select(2, s:gsub("[^\128-\191]", ""))) end
local function now() return (GetTime and GetTime()) or 0 end

local function initDB()
  QuestStoryDB = QuestStoryDB or {}
  local d = QuestStoryDB
  if d.on == nil then d.on = true end
  if type(d.scale) ~= "number" then d.scale = 1 end
  return d
end
local function isOn() local d = QuestStoryDB; return not d or d.on ~= false end
local function qdata(id)
  local d = QuestStoryData
  return type(d) == "table" and type(d.q) == "table" and d.q[id] or nil
end

-- ---------- 글꼴 ----------
local function fontOk(f, path, size)
  local ok, r = pcall(f.SetFont, f, path, size, "")
  if not ok or r == false then return false end
  local got = try(f.GetFont, f)
  return type(got) == "string" and got ~= ""
end
local function mkFont(name, size, fallback)
  local f = _G[name] or CreateFont(name)
  local ok = false
  if GetLocale and GetLocale() == "koKR" then
    local path = try(GameFontNormal and GameFontNormal.GetFont, GameFontNormal)
    ok = fontOk(f, str(path) or "Fonts\\2002.TTF", size)
  else
    for _, p in ipairs(FONT_FILES) do
      if fontOk(f, p, size) then ok = true; break end
    end
  end
  if not ok and _G[fallback] then pcall(f.SetFontObject, f, _G[fallback]) end
  return f
end

-- ---------- 팝업 만들기 (데이터 -> 표시용 테이블) ----------
local function titleFor(id)
  local c = cache[id]
  if c and str(c.title) then return c.title end
  return nil
end
local function apiTitle(id)
  local q = C_QuestLog
  return str(try(q and q.GetTitleForQuestID, id)) or str(try(q and q.GetQuestInfo, id))
end
local function apiObjective(id)
  local q = C_QuestLog
  local objs = try(q and q.GetQuestObjectives, id)
  if type(objs) ~= "table" then return nil end
  local out = {}
  for _, o in ipairs(objs) do
    if type(o) == "table" and str(o.text) then out[#out + 1] = o.text end
  end
  return str(table.concat(out, "\n"))
end
local function logIndex(id)
  if not (GetNumQuestLogEntries and GetQuestLogTitle) then return nil end
  local n = try(GetNumQuestLogEntries)
  if type(n) ~= "number" then return nil end
  for i = 1, n do
    local title, _, _, isHeader, _, _, _, qid = try(GetQuestLogTitle, i)
    if not isHeader and qid == id then return i, title end
  end
end
local function logObjective(i)
  local sel = try(GetQuestLogSelection)
  try(SelectQuestLogEntry, i)
  local _, obj = try(GetQuestLogQuestText)
  if sel ~= nil then try(SelectQuestLogEntry, sel) end
  return str(obj)
end
local function gather(id)
  local c = cache[id] or {}
  local title, obj = str(c.title), str(c.obj)
  if not (title and obj) then
    local i, lt = logIndex(id)
    if i then
      title = title or str(lt)
      obj = obj or logObjective(i)
    end
  end
  return title or apiTitle(id), obj or apiObjective(id)
end

local function copyLines(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for _, l in ipairs(t) do
    if str(l) and #out < 3 then out[#out + 1] = l end
  end
  if #out > 0 then return out end
end

local function buildAccept(id, title, obj)
  local d = qdata(id)
  local story = d and copyLines(d.a)
  obj = str(obj)
  if not story and not obj then return nil end
  return {kind = "accept", id = id, title = str(title) or "퀘스트", obj = obj, lines = story,
          label = "이야기", tag = "새 퀘스트"}
end
local function buildDone(id)
  local d = qdata(id)
  if not d then return nil end
  local lines = copyLines(d.c)
  local nxt
  if d.nx then
    nxt = apiTitle(d.nx) or str(d.nt)
  end
  -- 완료 뒤 이야기가 없는 퀘스트는 받을 때 이야기를 다시 보여 줌 (0.1.1: 완료 때 아무것도 안 뜨던 것)
  local label = "그 뒤 이야기"
  if not lines then lines = copyLines(d.a); label = "이런 이야기였어요" end
  if not lines and not d.nx then return nil end
  local title = titleFor(id) or apiTitle(id) or "퀘스트"
  return {kind = "done", id = id, title = title, lines = lines, label = label,
          nextTitle = nxt, tag = "퀘스트 완료"}
end

-- ---------- UI ----------
local function build()
  local fT = mkFont("QuestStoryFontTitle", 16, "GameFontNormalLarge")
  local fB = mkFont("QuestStoryFontBody", 13, "GameFontHighlight")
  local fS = mkFont("QuestStoryFontSmall", 11, "GameFontHighlightSmall")
  local f = CreateFrame("Frame", "QuestStoryFrame", UIParent)
  ui = f
  f:SetFrameStrata("HIGH")
  f:SetWidth(W); f:SetHeight(120)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetPoint("RIGHT", UIParent, "RIGHT", -60, 80)
  f:Hide()
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f); bg:SetColorTexture(0.06, 0.05, 0.04, 0.92)
  local function edge(p1, p2, w, h)
    local t = f:CreateTexture(nil, "BORDER")
    t:SetPoint(p1, f, p1, 0, 0); t:SetPoint(p2, f, p2, 0, 0)
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
    t:SetColorTexture(0.45, 0.36, 0.2, 0.95)
  end
  edge("TOPLEFT", "TOPRIGHT", nil, 1); edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
  edge("TOPLEFT", "BOTTOMLEFT", 1, nil); edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
  f.accent = f:CreateTexture(nil, "ARTWORK")
  f.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1); f.accent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  f.accent:SetHeight(3); f.accent:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
  f.divider = f:CreateTexture(nil, "ARTWORK")
  f.divider:SetHeight(1); f.divider:SetColorTexture(0.45, 0.36, 0.2, 0.35)
  local function fs(font, col)
    local s = f:CreateFontString(nil, "OVERLAY")
    s:SetFontObject(font); s:SetJustifyH("LEFT"); s:SetJustifyV("TOP")
    if s.SetNonSpaceWrap then s:SetNonSpaceWrap(true) end
    s:SetTextColor(col[1], col[2], col[3])
    return s
  end
  f.tag = fs(fS, GOLD)
  f.counter = fs(fS, MUTED); f.counter:SetJustifyH("RIGHT")
  f.title = fs(fT, WARM)
  f.objLabel = fs(fS, MUTED); f.objLabel:SetText("목표")
  f.objText = fs(fB, DIM)
  f.storyLabel = fs(fS, MUTED)
  f.lines = {}
  for i = 1, 3 do f.lines[i] = fs(fB, WARM); if f.lines[i].SetSpacing then f.lines[i]:SetSpacing(2) end end
  f.nextLine = fs(fB, GOLD)
  f.footer = fs(fS, FOOT)

  f:SetScript("OnUpdate", function(self, elapsed) QS.OnUpdate(elapsed) end)
  f:SetScript("OnMouseUp", function(self, button)
    if QS.moveMode then return end
    if button == "RightButton" then QS.DismissAll() else QS.Advance() end
  end)
  f:SetScript("OnDragStart", function(self)
    if QS.moveMode and self.StartMoving then self:StartMoving() end
  end)
  f:SetScript("OnDragStop", function(self)
    if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    if QS.moveMode then QS.SavePos() end
  end)
  return f
end

local function applyPos()
  local d = QuestStoryDB
  if not ui then return end
  if d and type(d.scale) == "number" then ui:SetScale(d.scale) end
  local p = d and d.pos
  if type(p) == "table" and type(p[1]) == "string" then
    ui:ClearAllPoints()
    ui:SetPoint(p[1], UIParent, type(p[2]) == "string" and p[2] or p[1], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
  end
end
function QS.SavePos()
  if not ui then return end
  local point, _, rel, x, y = ui:GetPoint(1)
  if not point then return end
  initDB().pos = {point, rel or point, x or 0, y or 0}
end

local function setText(s, text)
  if text then s:SetText(text); s:SetWidth(W - 2 * PAD); s:Show() else s:Hide() end
end
local function hOf(s) local h = s:GetStringHeight(); if type(h) ~= "number" or h < 1 then h = 14 end return h end
local function place(s, y)
  s:ClearAllPoints(); s:SetPoint("TOPLEFT", ui, "TOPLEFT", PAD, -y)
  return y + hOf(s)
end

local function render(p)
  local f = ui
  local col = (p.kind == "done") and GREEN or GOLD
  f.accent:SetColorTexture(col[1], col[2], col[3], 1)
  f.tag:SetTextColor(col[1], col[2], col[3])
  f.tag:SetText(p.tag or ""); f.tag:Show()
  f.title:SetText(p.title or "퀘스트"); f.title:SetWidth(W - 2 * PAD); f.title:Show()
  setText(f.objText, p.obj)
  if p.obj then f.objLabel:Show() else f.objLabel:Hide() end
  if p.lines then f.storyLabel:SetText(p.label or "이야기"); f.storyLabel:Show() else f.storyLabel:Hide() end
  for i = 1, 3 do
    local l = p.lines and p.lines[i]
    setText(f.lines[i], l and ("· " .. l) or nil)
  end
  setText(f.nextLine, p.nextTitle and ("다음 이야기: " .. p.nextTitle) or nil)
  f.footer:SetText(QS.moveMode and "드래그해서 옮긴 뒤 /qs move 로 고정" or "클릭하면 닫혀요")
  f.footer:SetWidth(W - 2 * PAD); f.footer:Show()
  QS.RefreshCounter()
  -- 배치
  local y = 13
  f.tag:ClearAllPoints(); f.tag:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
  f.counter:ClearAllPoints(); f.counter:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
  y = y + 17
  y = place(f.title, y) + 8
  f.divider:ClearAllPoints()
  f.divider:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y); f.divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
  y = y + 9
  if p.obj then
    y = place(f.objLabel, y) + 2
    y = place(f.objText, y) + 10
  end
  if p.lines then
    y = place(f.storyLabel, y) + 3
    for i = 1, #p.lines do y = place(f.lines[i], y) + 4 end
    y = y + 4
  end
  if p.nextTitle then y = place(f.nextLine, y) + 8 end
  y = place(f.footer, y + 2)
  f:SetHeight(y + PAD - 4)
end

function QS.RefreshCounter()
  if not ui then return end
  if burstTotal > 1 then ui.counter:SetText(burstPos .. "/" .. burstTotal); ui.counter:Show()
  else ui.counter:SetText(""); ui.counter:Hide() end
end

-- ---------- 큐 ----------
local function visibleChars(p)
  local n = ulen(p.title or "") + ulen(p.obj or "") + ulen(p.nextTitle or "")
  for _, l in ipairs(p.lines or {}) do n = n + ulen(l) end
  return n
end
local function holdFor(p)
  local h = 4 + 0.09 * visibleChars(p)
  if h < 8 then h = 8 elseif h > 15 then h = 15 end
  return h
end

function QS.Show(p)
  QS.current = p
  QS.t = 0
  burstPos = burstPos + 1
  render(p)
  ui:SetAlpha(0)
  ui:Show()
  if not p.sample and not p.move then
    initDB().last = {kind = p.kind, id = p.id, title = p.title, obj = p.obj}
  end
end
function QS.Advance()
  local nxt = table.remove(QS.queue, 1)
  if nxt then QS.Show(nxt) else QS.current = nil; if ui then ui:Hide() end end
end
function QS.DismissAll()
  for i = #QS.queue, 1, -1 do QS.queue[i] = nil end
  burstTotal = burstPos
  QS.current = nil
  if ui then ui:Hide() end
end
function QS.Enqueue(p)
  if not p or not isOn() then return false end
  p.hold = holdFor(p)
  if not QS.current and #QS.queue == 0 then burstTotal, burstPos = 0, 0 end
  burstTotal = burstTotal + 1
  QS.queue[#QS.queue + 1] = p
  if not QS.current then QS.Advance() else QS.RefreshCounter() end
  return true
end

function QS.OnUpdate(elapsed)
  local p = QS.current
  if not p then if ui then ui:Hide() end return end
  if QS.moveMode then ui:SetAlpha(1) return end
  local hold = p.hold or 8
  if #QS.queue > 0 and hold > 6 then hold = 6 end
  local over = try(ui.IsMouseOver, ui)
  if over then
    if QS.t > hold then QS.t = hold end
    ui:SetAlpha(1)
    return
  end
  QS.t = QS.t + (elapsed or 0)
  local t = QS.t
  if t >= hold + FADE_OUT then QS.Advance() return end
  if t < FADE_IN then ui:SetAlpha(t / FADE_IN)
  elseif t <= hold then ui:SetAlpha(1)
  else ui:SetAlpha((hold + FADE_OUT - t) / FADE_OUT) end
end

-- 공개: kind "accept"|"done", 캐시/로그에서 내용을 모아 큐에 넣음
function QS.Push(kind, id, title, obj)
  if kind == "done" then return QS.Enqueue(buildDone(id)) end
  if not title or not obj then
    local t2, o2 = gather(id)
    title, obj = title or t2, obj or o2
  end
  return QS.Enqueue(buildAccept(id, title, obj))
end

-- ---------- 이벤트 ----------
local function onDetail()
  local id = try(GetQuestID)
  if type(id) ~= "number" or id <= 0 then return end
  local e = cache[id] or {}
  cache[id] = e
  e.title = str(try(GetTitleText)) or e.title
  e.obj = str(try(GetObjectiveText)) or e.obj
end
local doneAt = {}       -- [questID] = GetTime() (완료 창 중복 거르기)
local pendingDone      -- 보상 창이 열린 퀘스트 (QUEST_TURNED_IN 이 안 올 때 대비)
local function pushDone(id)
  if type(id) ~= "number" or id <= 0 then return end
  local t = now()
  if doneAt[id] and t - doneAt[id] < 5 then return end
  doneAt[id] = t
  if pendingDone == id then pendingDone = nil end
  QS.Enqueue(buildDone(id))
end
local function onComplete()
  local id = try(GetQuestID)
  if type(id) ~= "number" or id <= 0 then return end
  local e = cache[id] or {}
  cache[id] = e
  e.title = str(try(GetTitleText)) or e.title
  pendingDone = id
end
-- QUEST_TURNED_IN 이 안 오는 클라이언트 대비: 보상 창이 열렸던 퀘스트가 목록에서 빠지면 완료로 봄
local function onRemoved(id)
  if id and id == pendingDone then pushDone(id) end
end
local function onAccepted(a, b)
  local id = b or a
  if type(id) ~= "number" or id <= 0 then return end
  local t = now()
  if recent[id] and t - recent[id] < 2 then return end
  recent[id] = t
  local title, obj = gather(id)
  if (not title or not obj) and C_Timer and C_Timer.After then
    C_Timer.After(0.3, function()
      local t2, o2 = gather(id)
      QS.Enqueue(buildAccept(id, t2, o2))
    end)
    return
  end
  QS.Enqueue(buildAccept(id, title, obj))
end
local function onTurnedIn(id)
  pushDone(id)
end

local handlers = {
  ADDON_LOADED = function(name)
    if name ~= ADDON then return end
    initDB()
    if not ui then build() end
    applyPos()
  end,
  QUEST_DETAIL = onDetail,
  QUEST_ACCEPTED = onAccepted,
  QUEST_COMPLETE = onComplete,
  QUEST_TURNED_IN = onTurnedIn,
  QUEST_REMOVED = onRemoved,
}

ui = nil
build()
local ev = CreateFrame("Frame")
for name in pairs(handlers) do pcall(ev.RegisterEvent, ev, name) end
ev:SetScript("OnEvent", function(self, event, ...)
  local h = handlers[event]
  if h then h(...) end
end)

-- ---------- 슬래시 ----------
local SAMPLE_A = {kind = "accept", sample = true, id = 0, tag = "새 퀘스트", label = "이야기",
  title = "[샘플] 곰 사냥꾼의 부탁",
  obj = "숲속 곰을 잡아 곰 가죽을 가져가야 합니다.",
  lines = {"마을 사냥꾼은 올겨울 추위가 걱정이에요.", "곰이 늘어나 혼자서는 사냥을 못 나간대요.", "대신 곰 가죽을 구해 달라고 부탁해요. (샘플)"}}
local SAMPLE_C = {kind = "done", sample = true, id = 0, tag = "퀘스트 완료", label = "그 뒤 이야기",
  title = "[샘플] 곰 사냥꾼의 부탁",
  lines = {"사냥꾼은 가죽을 받고 한시름 놓았어요.", "이번 겨울은 따뜻하게 나겠대요. (샘플)"},
  nextTitle = "[샘플] 대장장이의 칼"}
local function copyTable(t) local o = {}; for k, v in pairs(t) do o[k] = v end return o end

function QS.ToggleMove()
  if QS.moveMode then
    QS.SavePos()
    QS.moveMode = false
    if ui.SetMovable then ui:SetMovable(false) end
    if ui.RegisterForDrag then ui:RegisterForDrag() end
    QS.current = nil
    QS.Advance()
    say("위치를 저장했어요.")
  else
    QS.moveMode = true
    if QS.current and not QS.current.sample then table.insert(QS.queue, 1, QS.current) end
    if ui.SetMovable then ui:SetMovable(true) end
    if ui.RegisterForDrag then ui:RegisterForDrag("LeftButton") end
    local s = copyTable(SAMPLE_A); s.move = true
    QS.Show(s)
    ui:SetAlpha(1)
    say("팝업을 드래그해서 옮긴 뒤 /qs move 로 고정하세요.")
  end
end

local function help()
  say("명령어 (/qs 또는 /queststory)")
  print("  on / 켜기 - 켜기   off / 끄기 - 끄기")
  print("  move / 이동 - 위치 옮기기 (다시 입력하면 고정)")
  print("  scale <0.6~1.6> / 크기 <값> - 팝업 크기")
  print("  last / 마지막 - 마지막 팝업 다시 보기")
  print("  test / 테스트 - 샘플 팝업   reset / 초기화 - 위치·크기 처음으로")
end

SLASH_QUESTSTORY1 = "/qs"
SLASH_QUESTSTORY2 = "/queststory"
SlashCmdList = SlashCmdList or {}
SlashCmdList["QUESTSTORY"] = function(msg)
  local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  local d = initDB()
  if cmd == "" or cmd == "help" or cmd == "도움말" then
    help()
  elseif cmd == "on" or cmd == "켜기" then
    d.on = true; say("켰어요.")
  elseif cmd == "off" or cmd == "끄기" then
    d.on = false; QS.DismissAll(); say("껐어요. (/qs on 으로 다시 켜요)")
  elseif cmd == "move" or cmd == "이동" then
    QS.ToggleMove()
  elseif cmd == "scale" or cmd == "크기" then
    local n = tonumber(arg)
    if not n then say("크기는 0.6~1.6 사이 숫자로 적어 주세요. 예: /qs scale 1.2"); return end
    if n < 0.6 then n = 0.6 elseif n > 1.6 then n = 1.6 end
    d.scale = n; ui:SetScale(n); say("크기 " .. n .. " 로 바꿨어요.")
  elseif cmd == "last" or cmd == "마지막" then
    local l = d.last
    if type(l) ~= "table" then say("아직 보여 준 팝업이 없어요."); return end
    local p
    if l.kind == "done" then
      cache[l.id or 0] = cache[l.id or 0] or {title = l.title}
      p = buildDone(l.id)
      if p then p.title = l.title or p.title end
    else
      p = buildAccept(l.id, l.title, l.obj)
    end
    if not (p and QS.Enqueue(p)) then say("다시 보여 줄 내용이 없어요.") end
  elseif cmd == "test" or cmd == "테스트" then
    QS.Enqueue(copyTable(SAMPLE_A)); QS.Enqueue(copyTable(SAMPLE_C))
  elseif cmd == "reset" or cmd == "초기화" then
    d.pos = nil; d.scale = 1
    ui:SetScale(1); ui:ClearAllPoints(); ui:SetPoint("RIGHT", UIParent, "RIGHT", -60, 80)
    say("위치와 크기를 처음으로 되돌렸어요.")
  else
    help()
  end
end
