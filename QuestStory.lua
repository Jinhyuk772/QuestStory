-- QuestStory 0.3.0: 퀘스트를 받을 때 / 완료할 때 한국어 세 줄 이야기 팝업.
-- 저절로 사라지지 않음: 줄이기(–) / 닫기(×) 로 직접. 새 퀘스트가 잡히면 줄여 둔 창도 다시 펼쳐짐.
-- 일반 프레임만 씀 (보안 프레임·후킹 없음 = taint 없음). OnUpdate 는 페이드 인·자동 줄이기 때만 돈다.
-- 데이터: Data.lua 의 QuestStoryData (없어도 동작: 제목 + 목표만 보여 줌).
local ADDON = "QuestStory"
local VERSION = "0.3.2"
QuestStory = QuestStory or {}
local QS = QuestStory
QS.history = QS.history or {}   -- 이번 접속에서 본 팝업들 (새것이 뒤, 최대 HIST_MAX)
QS.index = 0                    -- 지금 보이는 것의 순번
QS.current = nil                -- 지금 보이는 팝업

local W, PAD = 440, 14
local FADE_IN = 0.25
local MINW, MINH = 260, 26
local HIST_MAX = 20
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
local BTN = {1, 0.9, 0.62}
local FOOT = {0.5, 0.48, 0.44}

local cache = {}       -- [questID] = {title=, obj=}  (QUEST_DETAIL / QUEST_COMPLETE 에서 채움)
local recent = {}      -- [questID] = GetTime() (중복 QUEST_ACCEPTED 거르기)
local fading, fadeT, autoT = false, 0, 0
local dragging, dragEnd = false, -100
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
local NO_STORY = "이 퀘스트는 아직 이야기가 준비되지 않았어요."
local function buildDone(id, always)
  local d = qdata(id)
  if not d then
    if not always then return nil end
    return {kind = "done", id = id, title = titleFor(id) or apiTitle(id) or "퀘스트", lines = {NO_STORY},
            label = "그 뒤 이야기", tag = "퀘스트 완료"}
  end
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
local function isMin() local d = QuestStoryDB; return d ~= nil and d.min == true end
local function autoSecs()
  local d = QuestStoryDB
  local a = d and d.auto
  if type(a) == "number" and a > 0 then return a end
  return 0
end

local function build()
  local fT = mkFont("QuestStoryFontTitle", 16, "GameFontNormalLarge")
  local fB = mkFont("QuestStoryFontBody", 13, "GameFontHighlight")
  local fS = mkFont("QuestStoryFontSmall", 11, "GameFontHighlightSmall")
  local f = CreateFrame("Frame", "QuestStoryFrame", nil)   -- 부모 없음: 대화 창이 UIParent 를 숨겨도 보임
  ui = f
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetWidth(W); f:SetHeight(120)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetPoint("TOPRIGHT", UIParent, "RIGHT", -60, 220)
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
  local function fs(font, col, parent)
    local s = (parent or f):CreateFontString(nil, "OVERLAY")
    s:SetFontObject(font); s:SetJustifyH("LEFT"); s:SetJustifyV("TOP")
    if s.SetNonSpaceWrap then s:SetNonSpaceWrap(true) end
    s:SetTextColor(col[1], col[2], col[3])
    return s
  end
  f.tag = fs(fS, GOLD)
  f.counter = fs(fS, MUTED); f.counter:SetJustifyH("CENTER"); f.counter:SetWidth(40)
  f.title = fs(fT, WARM)
  f.objLabel = fs(fS, MUTED); f.objLabel:SetText("목표")
  f.objText = fs(fB, DIM)
  f.storyLabel = fs(fS, MUTED)
  f.lines = {}
  for i = 1, 3 do f.lines[i] = fs(fB, WARM); if f.lines[i].SetSpacing then f.lines[i]:SetSpacing(2) end end
  f.nextLine = fs(fB, GOLD)
  f.footer = fs(fS, FOOT)

  -- 줄인 상태(작은 막대)용: 색 점 + 한 줄 제목
  f.dot = f:CreateTexture(nil, "ARTWORK")
  f.dot:SetWidth(8); f.dot:SetHeight(8); f.dot:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
  f.dot:ClearAllPoints(); f.dot:SetPoint("LEFT", f, "LEFT", 9, -1)
  f.minTitle = fs(fB, WARM); f.minTitle:SetJustifyV("MIDDLE")
  if f.minTitle.SetWordWrap then f.minTitle:SetWordWrap(false) end
  f.minTitle:SetWidth(MINW - 22 - 58)
  f.minTitle:ClearAllPoints(); f.minTitle:SetPoint("LEFT", f, "LEFT", 22, -1)

  -- 머리 단추 (일반 Button + 글자)
  -- 0.3.1: 기호(◀ ▶ – × +)가 한글 글꼴에 없어 단추가 안 보였음 → 한글 글자 + 눈에 보이는 바탕
  local function mkBtn(label, font, point, x, y, onClick, w)
    local b = CreateFrame("Button", nil, f)
    b:SetWidth(w or 40); b:SetHeight(18)
    b:ClearAllPoints(); b:SetPoint(point, f, point, x, y)
    if b.SetFrameLevel and f.GetFrameLevel then pcall(b.SetFrameLevel, b, (f:GetFrameLevel() or 1) + 5) end
    local bgt = b:CreateTexture(nil, "BACKGROUND")
    bgt:SetAllPoints(b); bgt:SetColorTexture(0.30, 0.24, 0.13, 0.95)
    b.bg = bgt
    local t = b:CreateFontString(nil, "OVERLAY")
    t:SetFontObject(font); t:SetJustifyH("CENTER")
    t:SetPoint("CENTER", b, "CENTER", 0, 0)
    t:SetText(label); t:SetTextColor(BTN[1], BTN[2], BTN[3])
    b.text = t
    b:SetScript("OnClick", function(self) if not self.off then onClick() end end)
    b:SetScript("OnEnter", function(self) if not self.off then self.text:SetTextColor(1, 0.95, 0.7); self.bg:SetColorTexture(0.45, 0.36, 0.2, 1) end end)
    b:SetScript("OnLeave", function(self)
      local c = self.off and FOOT or BTN
      self.text:SetTextColor(c[1], c[2], c[3]); self.bg:SetColorTexture(0.30, 0.24, 0.13, 0.95)
    end)
    return b
  end
  f.btnClose = mkBtn("닫기", fS, "TOPRIGHT", -8, -9, function() QS.Close() end, 36)
  f.btnMin = mkBtn("줄이기", fS, "TOPRIGHT", -48, -9, function() QS.SetMin(true) end, 46)
  f.btnBig = mkBtn("크게", fS, "TOPRIGHT", -98, -9, function() QS.Bump(0.1) end, 36)
  f.btnSmall = mkBtn("작게", fS, "TOPRIGHT", -138, -9, function() QS.Bump(-0.1) end, 36)
  f.btnNext = mkBtn("다음", fS, "TOPRIGHT", -184, -9, function() QS.Step(1) end, 36)
  f.counter:ClearAllPoints(); f.counter:SetPoint("TOPRIGHT", f, "TOPRIGHT", -222, -13)
  f.btnPrev = mkBtn("이전", fS, "TOPRIGHT", -264, -9, function() QS.Step(-1) end, 36)
  f.btnMax = mkBtn("펼치기", fS, "RIGHT", -5, 0, function() QS.SetMin(false) end, 46)

  f:SetScript("OnMouseUp", function(self, button)
    if dragging or now() - dragEnd < 0.25 then return end   -- 끌고 난 직후의 클릭은 무시
    if isMin() then
      if button == "LeftButton" then QS.SetMin(false) end
    elseif button == "RightButton" then
      QS.SetMin(true)
    end
  end)
  if f.SetMovable then f:SetMovable(true) end
  if f.RegisterForDrag then f:RegisterForDrag("LeftButton") end
  f:SetScript("OnDragStart", function(self)
    dragging = true
    if self.StartMoving then self:StartMoving() end
  end)
  f:SetScript("OnDragStop", function(self)
    if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    dragging = false; dragEnd = now()
    QS.SavePos()
  end)
  return f
end

local function applyScale()
  if not ui then return end
  local d = QuestStoryDB
  local base = try(UIParent and UIParent.GetEffectiveScale, UIParent)
  if type(base) ~= "number" or base <= 0 then base = 1 end
  ui:SetScale(base * ((d and type(d.scale) == "number") and d.scale or 1))
end
local function applyPos()
  local d = QuestStoryDB
  if not ui then return end
  applyScale()
  local p = d and d.pos
  if type(p) == "table" and type(p[1]) == "string" then
    ui:ClearAllPoints()
    ui:SetPoint(p[1], UIParent, type(p[2]) == "string" and p[2] or p[1], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
  end
end
-- 오른쪽 위 모서리를 기준으로 저장 (줄이거나 펼쳐도 그 모서리는 그대로)
function QS.SavePos()
  if not ui then return end
  local r = try(ui.GetRight, ui)
  local t = try(ui.GetTop, ui)
  if type(r) ~= "number" or type(t) ~= "number" then return end
  ui:ClearAllPoints()
  ui:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", r, t)
  initDB().pos = {"TOPRIGHT", "BOTTOMLEFT", r, t}
end

-- 크게/작게 단추: 창 전체(글자 포함) 크기를 0.1 씩. 오른쪽 위 모서리는 제자리에 둠.
function QS.Bump(delta)
  if not ui then return end
  local d = initDB()
  local old = try(ui.GetScale, ui)
  local r, t = try(ui.GetRight, ui), try(ui.GetTop, ui)
  local n = math.floor(((d.scale or 1) + delta) * 10 + 0.5) / 10
  if n < 0.6 then n = 0.6 elseif n > 1.6 then n = 1.6 end
  d.scale = n
  applyScale()
  local new = try(ui.GetScale, ui)
  if type(old) == "number" and type(new) == "number" and new > 0 and type(r) == "number" and type(t) == "number" then
    r, t = r * old / new, t * old / new
    ui:ClearAllPoints(); ui:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", r, t)
    d.pos = {"TOPRIGHT", "BOTTOMLEFT", r, t}
  end
end

local function setText(s, text)
  if text then s:SetText(text); s:SetWidth(W - 2 * PAD); s:Show() else s:Hide() end
end
local function hOf(s) local h = s:GetStringHeight(); if type(h) ~= "number" or h < 1 then h = 14 end return h end
local function place(s, y)
  s:ClearAllPoints(); s:SetPoint("TOPLEFT", ui, "TOPLEFT", PAD, -y)
  return y + hOf(s)
end

local function setBtnOff(b, off)
  b.off = off and true or false
  local c = off and FOOT or BTN
  b.text:SetTextColor(c[1], c[2], c[3])
end
function QS.RefreshCounter()
  if not ui then return end
  local n = #QS.history
  -- 0.3.2: 이야기가 하나뿐이어도 이전·다음 단추는 늘 보임(흐리게) — 숨기니 '단추가 없다'로 보였음
  if not isMin() then
    if n < 1 then n = 1 end
    local i = QS.index or 1
    if i < 1 then i = 1 end
    ui.counter:SetText(i .. "/" .. n); ui.counter:Show()
    ui.btnPrev:Show(); ui.btnNext:Show(); ui.btnSmall:Show(); ui.btnBig:Show()
    setBtnOff(ui.btnPrev, i <= 1); setBtnOff(ui.btnNext, i >= n)
  else
    ui.counter:SetText(""); ui.counter:Hide()
    ui.btnPrev:Hide(); ui.btnNext:Hide(); ui.btnSmall:Hide(); ui.btnBig:Hide()
  end
end

local function render(p)
  local f = ui
  local col = (p.kind == "done") and GREEN or GOLD
  f.accent:SetColorTexture(col[1], col[2], col[3], 1)
  f.dot:SetColorTexture(col[1], col[2], col[3], 1)
  f.minTitle:SetText(p.title or "퀘스트")
  if isMin() then
    for _, r in ipairs({f.tag, f.counter, f.title, f.objLabel, f.objText, f.storyLabel, f.lines[1], f.lines[2],
        f.lines[3], f.nextLine, f.footer, f.divider, f.btnMin, f.btnClose, f.btnPrev, f.btnNext, f.btnSmall, f.btnBig}) do r:Hide() end
    f.dot:Show(); f.minTitle:Show(); f.btnMax:Show()
    f:SetWidth(MINW); f:SetHeight(MINH)
    return
  end
  f.dot:Hide(); f.minTitle:Hide(); f.btnMax:Hide()
  f.btnMin:Show(); f.btnClose:Show(); f.divider:Show()
  f:SetWidth(W)
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
  f.footer:SetText("창을 끌면 옮겨져요 · 우클릭하면 줄어들어요")
  f.footer:SetWidth(W - 2 * PAD); f.footer:Show()
  QS.RefreshCounter()
  -- 배치
  local y = 13
  f.tag:ClearAllPoints(); f.tag:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
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

-- ---------- OnUpdate: 페이드 인 · (선택) 자동 줄이기 때만 돈다 ----------
local ticking = false
local function wantTick()
  if fading then return true end
  return autoSecs() > 0 and ui ~= nil and not isMin() and ui:IsShown() and true or false
end
local function ticker()
  if not ui then return end
  local want = wantTick()
  if want == ticking then return end
  ticking = want
  if want then
    local updErr
    ui:SetScript("OnUpdate", function(self, elapsed)
      local ok, err = pcall(QS.OnUpdate, elapsed)
      if not ok and not updErr then updErr = true; say("창 갱신 중 오류: " .. tostring(err)) end
    end)
  else
    ui:SetScript("OnUpdate", nil)
  end
end
function QS.OnUpdate(elapsed)
  elapsed = elapsed or 0
  if ui and ui:IsShown() then
    if fading then
      fadeT = fadeT + elapsed
      if fadeT >= FADE_IN then fading = false; ui:SetAlpha(1) else ui:SetAlpha(fadeT / FADE_IN) end
    end
    local a = autoSecs()
    if a > 0 and not isMin() then
      if QS.pin or try(ui.IsMouseOver, ui) then autoT = 0
      else
        autoT = autoT + elapsed
        if autoT >= a then QS.SetMin(true) end
      end
    end
  else
    fading = false
  end
  ticker()
end

-- ---------- 기록 · 보이기 ----------
local function display()
  local ok, err = pcall(render, QS.current)
  if not ok then say("창을 그리다 오류: " .. tostring(err)) end
end
local function reveal()
  local was = ui:IsShown()
  autoT = 0
  if not was then fading = true; fadeT = 0; ui:SetAlpha(0) else ui:SetAlpha(1) end
  ui:Show()
  ticker()
  if not try(ui.IsVisible, ui) then say("창을 띄웠는데 화면에 안 보여요. /qs 상태 를 알려 주세요.") end
end

-- 새 팝업: 기록에 붙이고 바로 펼쳐서 보여 줌 (줄여 뒀거나 닫아 뒀어도)
function QS.Present(p)
  if not p or not isOn() then return false end
  local d = initDB()
  local h = QS.history
  local last = h[#h]
  if last and last.kind == p.kind and last.id == p.id and last.tag == p.tag and not p.sample and not last.sample then
    h[#h] = p      -- 같은 퀘스트 창을 다시 연 것: 새로 쌓지 않고 바꿈
  else
    h[#h + 1] = p
    while #h > HIST_MAX do table.remove(h, 1) end
  end
  QS.index = #h
  QS.current = p
  d.min = false
  display()
  reveal()
  if not p.sample then
    d.last = {kind = p.kind, id = p.id, title = p.title, obj = p.obj}
  end
  return true
end

function QS.Goto(i)
  if type(i) ~= "number" or i < 1 or i > #QS.history then return false end
  QS.index = i
  QS.current = QS.history[i]
  autoT = 0
  display()
  return true
end
function QS.Step(dir)
  return QS.Goto(QS.index + dir)
end
function QS.SetMin(v)
  local d = initDB()
  d.min = v and true or false
  autoT = 0
  if QS.current then display() end
  ticker()
end
function QS.Close()
  if ui then ui:Hide() end
  fading = false
  ticker()
end
function QS.Open()   -- 지금 보던 것을 펼쳐서 다시 보여 줌
  if not (QS.current and ui) then return false end
  initDB().min = false
  display()
  reveal()
  return true
end

-- 공개: kind "accept"|"done", 캐시/로그에서 내용을 모아 큐에 넣음
function QS.Push(kind, id, title, obj)
  if kind == "done" then return QS.Present(buildDone(id)) end
  if not title or not obj then
    local t2, o2 = gather(id)
    title, obj = title or t2, obj or o2
  end
  return QS.Present(buildAccept(id, title, obj))
end

-- ---------- 이벤트 ----------
local function dialogQuestID()
  local id = try(GetQuestID)
  if type(id) == "number" and id > 0 then return id end
  local title = str(try(GetTitleText))
  if not (title and GetNumQuestLogEntries and GetQuestLogTitle) then return nil end
  local n = try(GetNumQuestLogEntries)
  for i = 1, (type(n) == "number" and n or 0) do
    local t, _, _, isHeader, _, _, _, qid = try(GetQuestLogTitle, i)
    if not isHeader and t == title and type(qid) == "number" and qid > 0 then return qid end
  end
end
local function onDetail()
  local id = dialogQuestID()
  if type(id) ~= "number" or id <= 0 then return end
  local e = cache[id] or {}
  cache[id] = e
  e.title = str(try(GetTitleText)) or e.title
  e.obj = str(try(GetObjectiveText)) or e.obj
  -- 0.2.0: 수락을 누르기 전, 퀘스트 내용 창이 열릴 때 바로 보여 줌
  if QS.Present(buildAccept(id, e.title, e.obj)) then recent[id] = now(); QS.pin = id end
end
local doneAt = {}       -- [questID] = GetTime() (완료 창 중복 거르기)
local pendingDone      -- 보상 창이 열린 퀘스트 (QUEST_TURNED_IN 이 안 올 때 대비)
local function pushDone(id)
  if type(id) ~= "number" or id <= 0 then return end
  local t = now()
  if pendingDone == id then pendingDone = nil end
  if doneAt[id] and t - doneAt[id] < 120 then return end   -- 보상 창에서 이미 보여 줬으면 다시 안 띄움
  doneAt[id] = t
  QS.Present(buildDone(id))
end
local function onComplete()
  local id = dialogQuestID()
  if type(id) ~= "number" or id <= 0 then return end
  local e = cache[id] or {}
  cache[id] = e
  e.title = str(try(GetTitleText)) or e.title
  pendingDone = id
  -- 0.2.0: 보상을 받기 전, 완료(보상) 창이 열릴 때 바로 보여 줌
  if QS.Present(buildDone(id, true)) then doneAt[id] = now(); QS.pin = id end
end
-- 0.2.1: 진행 창(목표 확인 · "계속" 단추가 있는 창). 목표를 다 채웠으면 완료 이야기, 아니면 받을 때 이야기를 다시
local function onProgress()
  local id = dialogQuestID()
  if type(id) ~= "number" or id <= 0 then return end
  local e = cache[id] or {}
  cache[id] = e
  e.title = str(try(GetTitleText)) or e.title
  local p
  if try(IsQuestCompletable) then
    pendingDone = id
    p = buildDone(id, true)
    if p then doneAt[id] = now() end
  else
    local _, obj = gather(id)
    p = buildAccept(id, e.title, obj)
    if p then p.tag = "진행 중인 퀘스트"; recent[id] = now() end
  end
  if QS.Present(p) then QS.pin = id end
end
local function onFinished() QS.pin = nil; autoT = 0 end   -- 대화 창이 닫힘: (자동 줄이기를 켰다면) 이제부터 시간이 감
-- QUEST_TURNED_IN 이 안 오는 클라이언트 대비: 보상 창이 열렸던 퀘스트가 목록에서 빠지면 완료로 봄
local function onRemoved(id)
  if id and id == pendingDone then pushDone(id) end
end
local function onAccepted(a, b)
  local id = b or a
  if type(id) ~= "number" or id <= 0 then return end
  local t = now()
  if recent[id] and t - recent[id] < 120 then return end   -- 내용 창에서 이미 보여 줬으면 다시 안 띄움
  recent[id] = t
  local title, obj = gather(id)
  if (not title or not obj) and C_Timer and C_Timer.After then
    C_Timer.After(0.3, function()
      local t2, o2 = gather(id)
      QS.Present(buildAccept(id, t2, o2))
    end)
    return
  end
  QS.Present(buildAccept(id, title, obj))
end
local function onTurnedIn(id)
  pushDone(id)
end

local function rebuildLast(l)
  if type(l) ~= "table" then return nil end
  if l.kind == "done" then
    cache[l.id or 0] = cache[l.id or 0] or {title = l.title}
    local p = buildDone(l.id)
    if p then p.title = l.title or p.title end
    return p
  end
  return buildAccept(l.id, l.title, l.obj)
end
-- /reload 뒤: 마지막 이야기를 줄인 상태로 올려 둠 (새로 잡힌 퀘스트가 아니므로 펼치지 않음)
function QS.RestoreLast()
  if not ui or #QS.history > 0 or not isOn() then return end
  local d = QuestStoryDB
  local p = d and rebuildLast(d.last)
  if not p then return end
  QS.history = {p}; QS.index = 1; QS.current = p
  d.min = true
  display()
  reveal()
end

local handlers = {
  ADDON_LOADED = function(name)
    if name ~= ADDON then return end
    initDB()
    if not ui then build() end
    applyPos()
    QS.RestoreLast()
  end,
  QUEST_DETAIL = onDetail,
  QUEST_ACCEPTED = onAccepted,
  QUEST_COMPLETE = onComplete,
  QUEST_PROGRESS = onProgress,
  QUEST_TURNED_IN = onTurnedIn,
  QUEST_REMOVED = onRemoved,
  QUEST_FINISHED = onFinished,
}

ui = nil
build()
local seen, lastEv = {}, nil     -- /qs 상태 용: 이벤트별 받은 횟수
local function dataCount()
  local d, n = QuestStoryData, 0
  if type(d) == "table" and type(d.q) == "table" then for _ in pairs(d.q) do n = n + 1 end end
  return n
end
handlers.PLAYER_LOGIN = function()
  applyPos()
  say(VERSION .. " 켜짐 · 이야기 " .. dataCount() .. "개 · /qs 테스트 로 창 확인")
end
handlers.UI_SCALE_CHANGED = function() applyScale() end
local ev = CreateFrame("Frame")
for name in pairs(handlers) do pcall(ev.RegisterEvent, ev, name) end
ev:SetScript("OnEvent", function(self, event, a, b, ...)
  seen[event] = (seen[event] or 0) + 1
  if event:find("^QUEST_") then lastEv = event .. " " .. tostring(a) .. " " .. tostring(b) end
  local h = handlers[event]
  if h then
    local ok, err = pcall(h, a, b, ...)
    if not ok then say(event .. " 처리 중 오류: " .. tostring(err)) end
  end
end)
function QS.Status()
  say("버전 " .. VERSION .. " · " .. (isOn() and "켜짐" or "꺼짐") .. " · 이야기 " .. dataCount() .. "개 · 언어 " .. tostring(try(GetLocale)))
  local parts = {}
  for _, n in ipairs({"QUEST_DETAIL", "QUEST_ACCEPTED", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_TURNED_IN", "QUEST_REMOVED"}) do
    parts[#parts + 1] = n:gsub("QUEST_", "") .. " " .. (seen[n] or 0)
  end
  print("  받은 신호: " .. table.concat(parts, " · "))
  print("  마지막 신호: " .. (lastEv or "없음") .. " · 대화 창 퀘스트 번호 " .. tostring(try(GetQuestID)) .. " · 제목 " .. tostring(try(GetTitleText)))
  if ui then
    local x, y = try(ui.GetCenter, ui)
    print("  창: " .. (try(ui.IsShown, ui) and "켜짐" or "꺼짐") .. " · 보임 " .. tostring(try(ui.IsVisible, ui) and true or false)
      .. " · 투명도 " .. tostring(try(ui.GetAlpha, ui)) .. " · 배율 " .. tostring(try(ui.GetEffectiveScale, ui))
      .. " · 위치 " .. tostring(x and math.floor(x)) .. "," .. tostring(y and math.floor(y))
      .. " · 화면 " .. tostring(try(GetScreenWidth) and math.floor(GetScreenWidth())) .. "x" .. tostring(try(GetScreenHeight) and math.floor(GetScreenHeight())))
  end
  local l = QuestStoryDB and QuestStoryDB.last
  if type(l) == "table" then print("  마지막 창: " .. tostring(l.kind) .. " " .. tostring(l.id) .. " " .. tostring(l.title)) end
end

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

local function help()
  say("명령어 (/qs 또는 /queststory)")
  print("  on / 켜기 - 켜기   off / 끄기 - 끄기 (창도 닫아요)")
  print("  min / 최소화 - 줄이기·펼치기 (창의 줄이기 단추, 오른쪽 클릭도 같아요)")
  print("  show / 열기 - 지금 이야기를 펼쳐서 다시 보기   last / 마지막 - 마지막 팝업 다시 띄우기")
  print("  auto <5~120> / 자동 <초> - 그 시간 동안 마우스를 안 올리면 저절로 줄이기 (0 = 끄기)")
  print("  move / 이동 - 샘플을 띄워 위치 잡기 (창을 드래그하면 저장돼요)")
  print("  scale <0.6~1.6> / 크기 <값> - 팝업 크기")
  print("  test / 테스트 - 샘플 팝업   reset / 초기화 - 위치·크기·자동 줄이기 처음으로")
  print("  status / 상태 - 버전 · 받은 신호 수 (안 뜰 때 확인용)")
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
    d.on = false; QS.Close(); say("껐어요. (/qs on 으로 다시 켜요)")
  elseif cmd == "move" or cmd == "이동" then
    local s = copyTable(SAMPLE_A); s.move = true
    if QS.Present(s) then say("드래그해서 원하는 곳에 놓으면 저장돼요.") end
  elseif cmd == "scale" or cmd == "크기" then
    local n = tonumber(arg)
    if not n then say("크기는 0.6~1.6 사이 숫자로 적어 주세요. 예: /qs scale 1.2"); return end
    if n < 0.6 then n = 0.6 elseif n > 1.6 then n = 1.6 end
    d.scale = n; applyScale(); say("크기 " .. n .. " 로 바꿨어요.")
  elseif cmd == "last" or cmd == "마지막" then
    local l = d.last
    if type(l) ~= "table" then say("아직 보여 준 팝업이 없어요."); return end
    local p = rebuildLast(l)
    if not (p and QS.Present(p)) then say("다시 보여 줄 내용이 없어요.") end
  elseif cmd == "test" or cmd == "테스트" then
    if QS.Present(copyTable(SAMPLE_A)) and QS.Present(copyTable(SAMPLE_C)) then QS.Goto(#QS.history - 1) end
  elseif cmd == "min" or cmd == "최소화" then
    if not QS.current then say("아직 보여 줄 이야기가 없어요."); return end
    QS.SetMin(not isMin())
  elseif cmd == "show" or cmd == "열기" then
    if not isOn() then say("꺼져 있어요. /qs on 으로 켜 주세요."); return end
    if not QS.Open() then say("아직 보여 줄 이야기가 없어요.") end
  elseif cmd == "auto" or cmd == "자동" then
    local n = tonumber(arg)
    if not n then
      say("예: /qs auto 15 (15초 뒤 저절로 줄이기), /qs auto 0 (끄기). 지금: " .. (autoSecs() > 0 and (autoSecs() .. "초") or "꺼짐"))
      return
    end
    if n <= 0 then d.auto = 0
    else
      if n < 5 then n = 5 elseif n > 120 then n = 120 end
      d.auto = n
    end
    autoT = 0; ticker()
    if d.auto == 0 then say("자동 줄이기를 껐어요.")
    else say("마우스를 올리지 않고 " .. d.auto .. "초가 지나면 저절로 줄어들어요.") end
  elseif cmd == "status" or cmd == "상태" then
    QS.Status()
  elseif cmd == "reset" or cmd == "초기화" then
    d.pos = nil; d.scale = 1; d.auto = 0; d.min = false
    applyScale(); ui:ClearAllPoints(); ui:SetPoint("TOPRIGHT", UIParent, "RIGHT", -60, 220)
    autoT = 0
    if QS.current then display() end
    ticker()
    say("위치·크기·자동 줄이기를 처음으로 되돌렸어요.")
  else
    help()
  end
end
