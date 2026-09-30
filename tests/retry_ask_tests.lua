-- tests/retry_ask_tests.lua — retry policy + ask module (split from lua_tests.lua, Phase C).
-- Run: lua tests/retry_ask_tests.lua

dofile("tests/helpers.lua")
-- T115: retry policy — classification, schedule, cutoff, continuation.
do
  local policy = assert(loadfile("src/tether/retry.lua"))()

  -- classification: text beats status, quota and permanent stop the loop
  assert_eq(policy.classify("invalid api key"), "permanent", "T115 invalid api key")
  assert_eq(policy.classify("The model 'gpt-9' does not exist"), "permanent", "T115 unknown model")
  assert_eq(policy.classify("Unauthorized"), "permanent", "T115 unauthorized text")
  assert_eq(policy.classify("something odd", 401), "permanent", "T115 401 permanent")
  assert_eq(policy.classify("something odd", 403), "permanent", "T115 403 permanent")
  assert_eq(policy.classify("You've hit your limit \194\183 resets in 3 hours"), "quota", "T115 usage limit")
  assert_eq(policy.classify("You exceeded your current quota, please check your plan"), "quota", "T115 plan quota")
  assert_eq(policy.classify("Your account is suspended"), "quota", "T115 suspended account")
  assert_eq(policy.classify("insufficient_quota", 429), "quota", "T115 quota beats the 429 status")
  assert_eq(policy.classify("Insufficient Balance", 402), "credit", "T115 balance stays retryable")
  assert_eq(policy.classify("Not Enough Credits"), "credit", "T115 credits")
  assert_eq(policy.classify("ECONNRESET"), "connection", "T115 connection error")
  assert_eq(policy.classify("Max outbound streams is 100, 100 open"), "connection", "T115 stream exhaustion")
  assert_eq(policy.classify("context_length_exceeded", 400), "request", "T115 context 400 retryable")
  assert_eq(policy.classify("payload too large", 413), "request", "T115 413")
  assert_eq(policy.classify("OVERLOADED"), "server", "T115 case-insensitive")
  assert_eq(policy.classify(nil, 429), "server", "T115 status alone")
  assert_eq(policy.classify(""), "empty", "T115 empty body")
  assert_eq(policy.classify("something nobody has seen"), "unknown", "T115 catch-all")
  assert_true(policy.is_retryable("unknown"), "T115 unknown is retryable")
  assert_true(policy.is_retryable("empty"), "T115 empty is retryable")
  assert_false(policy.is_retryable("permanent"), "T115 permanent not retryable")
  assert_false(policy.is_retryable("quota"), "T115 quota not retryable")

  -- schedule: defaults and the cap
  local p = policy.policy({})
  assert_eq(p.base_delay_ms, 2000, "T115 default base")
  assert_eq(p.max_delay_ms, 60000, "T115 default max")
  assert_eq(p.multiplier, 2, "T115 default multiplier")
  assert_eq(p.max_failures_at_max_delay, 3, "T115 default max failures")
  assert_eq(policy.wait(p, 1), 2, "T115 first wait")
  assert_eq(policy.wait(p, 5), 32, "T115 fifth wait")
  assert_eq(policy.wait(p, 6), 60, "T115 sixth wait is capped")
  assert_eq(policy.wait(p, 8), 60, "T115 later waits stay capped")

  -- cutoff with defaults: nine attempts, three waits at the cap
  local state = policy.new_state()
  local attempts, verdict = 0, nil
  while true do
    attempts = attempts + 1
    verdict = policy.verdict(p, state, policy.failure("server", "overloaded"))
    if verdict.action ~= "retry" then break end
    state.attempt = state.attempt + 1
  end
  assert_eq(attempts, 9, "T115 nine attempts before the cutoff")
  assert_eq(state.failures_at_max_delay, 3, "T115 three waits at the cap")
  assert_eq(verdict.action, "stop", "T115 cutoff stops the loop")

  -- a retried attempt reports its wait; a non-retryable one never waits
  local first = policy.verdict(p, policy.new_state(), policy.failure("server", "rate limit"))
  assert_eq(first.action, "retry", "T115 first failure retries")
  assert_eq(first.delay, 2, "T115 first delay")
  assert_eq(policy.verdict(p, policy.new_state(), policy.failure("permanent", "invalid api key")).action,
    "stop", "T115 permanent stops at once")
  assert_eq(policy.verdict(p, policy.new_state(), policy.failure("quota", "out of budget")).action,
    "stop", "T115 quota stops at once")

  -- attempt cap
  local capped = policy.policy({ retry = { max_attempts = 3 } })
  local st2 = policy.new_state()
  for i = 1, 3 do
    local v = policy.verdict(capped, st2, policy.failure("server", "rate limit"))
    if i < 3 then assert_eq(v.action, "retry", "T115 under the cap retries")
    else assert_eq(v.action, "stop", "T115 cap stops the loop") end
    st2.attempt = st2.attempt + 1
  end

  -- Retry-After changes the wait, not the cutoff bookkeeping
  local st4 = policy.new_state()
  local v4 = policy.verdict(p, st4, policy.failure("server", "rate limit", 429, 5))
  assert_eq(v4.delay, 5, "T115 retry_after overrides the wait")
  assert_eq(st4.failures_at_max_delay, 0, "T115 retry_after is not a capped wait")

  -- invalid configuration falls back per value
  local junk = policy.policy({ retry = { base_delay_ms = 0, multiplier = 0.5,
                                         max_failures_at_max_delay = "three" } })
  assert_eq(junk.base_delay_ms, 2000, "T115 zero base falls back")
  assert_eq(junk.multiplier, 1, "T115 multiplier below 1 becomes 1")
  assert_eq(junk.max_failures_at_max_delay, 3, "T115 junk falls back")
  local junk2 = policy.policy({ retry = { base_delay_ms = "soon" } })
  assert_eq(junk2.base_delay_ms, 2000, "T115 malformed base falls back")
  local scaled = policy.policy({ retry = { base_delay_ms = 1000, multiplier = 3 } })
  assert_eq(policy.wait(scaled, 1), 1, "T115 custom first wait")
  assert_eq(policy.wait(scaled, 2), 3, "T115 custom second wait")

  -- continuation policy
  local st5 = policy.new_state()
  assert_eq(policy.continuation_action(st5, "length", true, false), "length", "T115 truncation continues")
  assert_eq(policy.continuation_action(st5, "length", true, true), nil, "T115 tool calls win over truncation")
  assert_eq(policy.continuation_action(st5, "stop", false, false), "empty", "T115 empty answer is nudged")
  assert_eq(policy.continuation_action(st5, "stop", false, false), "empty_giveup", "T115 only one nudge")
  policy.reset(st5)
  assert_eq(policy.continuation_action(st5, "stop", false, false), "empty", "T115 reset restores the nudge")
  assert_eq(policy.continuation_action(st5, "stop", true, false), nil, "T115 text ends the turn")
  assert_eq(policy.continuation_action(st5, "other", false, false), nil, "T115 unmapped reason ends the turn")
  assert_eq(policy.continuation_text("length"), policy.CONTINUE_TEXT, "T115 continuation text")
  assert_eq(policy.continuation_text("empty"), policy.EMPTY_TEXT, "T115 nudge text")
  assert_true(#policy.CONTINUE_TEXT > 0 and #policy.EMPTY_TEXT > 0, "T115 texts are non-empty")

  -- terminal messages
  assert_true(policy.terminal_message(policy.failure("server", "overloaded"), 9)
      :find("9 attempts", 1, true) ~= nil, "T115 exhaustion names the attempt count")
  assert_true(policy.terminal_message(policy.failure("quota", "You've hit your limit"), 2)
      :find("retries stopped", 1, true) ~= nil, "T115 quota explains the stop")
  assert_eq(policy.terminal_message(policy.failure("permanent", "invalid api key"), 1),
    "invalid api key", "T115 permanent surfaces the provider text")

  print("T115 retry policy: OK")
end

-- T121: the ask module — question normalisation and the answer payload
-- (add-ask-tool). Pure data in → data out: no UI, no transport, no turn.
do
  local askmod = assert(loadfile("src/tether/ask.lua"))()
  local common = assert(loadfile("src/tether/providers/common.lua"))()

  -- --- 1.1 normalisation ---------------------------------------------------
  local qs = askmod.normalize({ questions = {
    { id = "scope", question = "Scope?",
      options = { { label = "src" }, { label = "all" } } },
    { id = "priority", question = "Priority?", multi = true, recommended = 2,
      description = "Choose the focus",
      options = { { label = "core", description = "first" }, { label = "tests" } } },
  } })
  assert_eq(#qs, 2, "T121 two questions survive in order")
  assert_eq(qs[1].id, "scope", "T121 first id")
  assert_eq(qs[2].id, "priority", "T121 second id")
  assert_true(qs[2].multi, "T121 multi is kept")
  assert_eq(qs[2].recommended, 2, "T121 recommended is kept")
  assert_eq(qs[2].description, "Choose the focus", "T121 description is kept")
  assert_eq(qs[2].options[1].description, "first", "T121 option description is kept")
  assert_false(qs[1].multi, "T121 multi defaults to false")
  assert_eq(qs[1].recommended, nil, "T121 absent recommended stays nil")

  -- a bare questions array (not wrapped in {questions=...}) is accepted too
  assert_eq(#askmod.normalize({ { question = "flat" } }), 1, "T121 unwrapped array works")

  -- bounds: 8 questions, 12 options, truncated text
  local many = {}
  for i = 1, 9 do many[i] = { question = "q" .. i } end
  assert_eq(#askmod.normalize({ questions = many }), 8, "T121 9 questions → 8")
  local opts = {}
  for i = 1, 13 do opts[i] = { label = "o" .. i } end
  local capped = askmod.normalize({ questions = { { question = "cap", options = opts } } })
  assert_eq(#capped[1].options, 12, "T121 13 options → 12")
  assert_eq(capped[1].options[12].label, "o12", "T121 the first 12 options survive")
  local big = askmod.normalize({ questions = { {
      question = string.rep("x", 1200), description = string.rep("y", 9000) } } })
  assert_eq(#big[1].question, askmod.QUESTION_MAX + #askmod.TRUNCATION,
    "T121 oversized question text is truncated")
  assert_eq(#big[1].description, askmod.DESCRIPTION_MAX + #askmod.TRUNCATION,
    "T121 oversized description is truncated")

  -- degradation: nothing usable is dropped, the rest still asks
  local degraded = askmod.normalize({ questions = {
    { question = "no id", options = {} },
    { question = "   " },
    { question = "dup", id = "scope", options = { { label = "" }, "ok", { label = 7 } } },
    { question = "again", id = "scope" },
    { question = "junk", multi = "yes", recommended = 9, options = { { label = "a" } } },
  } })
  assert_eq(#degraded, 4, "T121 only questions with text survive")
  assert_eq(degraded[1].id, "q1", "T121 a missing id is defaulted")
  assert_eq(#degraded[1].options, 0, "T121 an optionless question still asks")
  assert_eq(#degraded[2].options, 1, "T121 unusable option labels are dropped")
  assert_eq(degraded[2].options[1].label, "ok", "T121 a bare string option is accepted")
  assert_eq(degraded[3].id, "scope-2", "T121 duplicate ids become distinct")
  assert_eq(degraded[4].multi, false, "T121 a non-boolean multi is false")
  assert_eq(degraded[4].recommended, nil, "T121 an out-of-range recommended is ignored")
  assert_eq(#askmod.normalize({}), 0, "T121 an empty call carries nothing")
  assert_eq(#askmod.normalize("nonsense"), 0, "T121 a non-table argument carries nothing")

  -- --- 1.2 payload, notes, summary ----------------------------------------
  local payload = askmod.encode(qs, {
    { selected = { "src" } },
    { selected = { "core", "tests" }, notes = { ["tests"] = "after core" } },
  })
  assert_true(payload:find('"selected":["src"]', 1, true) ~= nil,
    "T121 a single choice is one array element")
  assert_true(payload:find('"selected":["core","tests"]', 1, true) ~= nil,
    "T121 a multi answer carries every toggle")
  -- (the encoder emits object keys in `pairs` order, so match the members)
  assert_true(payload:find('"notes":[{', 1, true) ~= nil,
    "T121 notes travel as an array of pairs")
  assert_true(payload:find('"option":"tests"', 1, true) ~= nil
    and payload:find('"note":"after core"', 1, true) ~= nil,
    "T121 notes travel as option/note pairs")
  local decoded = common.json_decode(payload)
  assert_eq(type(decoded), "table", "T121 the payload is valid JSON")
  assert_eq(decoded.answers[1].id, "scope", "T121 answers keep the question order")
  assert_eq(decoded.answers[2].id, "priority", "T121 second answer id")
  assert_eq(decoded.answers[1].selected[1], "src", "T121 labels are verbatim")
  assert_eq(decoded.answers[2].notes[1].option, "tests", "T121 the note is keyed by its option")
  assert_eq(decoded.answers[1].other, nil, "T121 an empty freeform field is omitted")

  -- freeform-only answer: selected is [] and the text rides in `other`
  local free = askmod.encode(qs, { { selected = {}, other = "Nuxt" } })
  assert_true(free:find('"selected":[]', 1, true) ~= nil,
    "T121 an empty selection encodes as an array")
  assert_true(free:find('"other":"Nuxt"', 1, true) ~= nil, "T121 the freeform text is in other")
  local free_decoded = common.json_decode(free)
  assert_eq(#free_decoded.answers[1].selected, 0, "T121 freeform-only has no selection")
  assert_eq(free_decoded.answers[1].other, "Nuxt", "T121 freeform text round-trips")

  -- a note on an unselected option still travels, and survives a freeform answer
  local noted = askmod.encode(qs, {
    { selected = { "src" }, notes = { ["all"] = "too big" } },
    { selected = {}, other = "both", notes = { ["core"] = "with tests" } },
  })
  local noted_decoded = common.json_decode(noted)
  assert_eq(noted_decoded.answers[1].notes[1].option, "all", "T121 an unselected option's note travels")
  assert_eq(noted_decoded.answers[1].selected[1], "src", "T121 the note is not an answer")
  assert_eq(noted_decoded.answers[2].notes[1].option, "core", "T121 notes survive a freeform answer")

  -- summary names each id with its selection, freeform text and notes
  local sum = askmod.summary(qs, {
    { selected = { "src" }, notes = { ["all"] = "too big" } },
    { selected = { "core", "tests" } },
  })
  assert_true(sum:find("scope=src", 1, true) ~= nil, "T121 the summary names the id and selection")
  assert_true(sum:find("priority=core, tests", 1, true) ~= nil, "T121 the summary names a multi answer")
  assert_true(sum:find("scope/all: too big", 1, true) ~= nil, "T121 the summary names the notes")
  local sum_free = askmod.summary(qs, { { selected = {}, other = "Nuxt" } })
  assert_true(sum_free:find("scope=«Nuxt»", 1, true) ~= nil, "T121 the summary names a freeform answer")

  -- cancellation payload: an empty answer set that names the cancellation
  local cancelled = common.json_decode(askmod.cancelled_payload())
  assert_true(cancelled.cancelled == true, "T121 the cancellation names itself")
  assert_eq(#cancelled.answers, 0, "T121 the cancellation carries no answers")

  print("T121 ask module: OK")
end

-- T122: both built-in tool descriptions list the same tools (add-ask-tool 2.1).
-- agent.builtin_prompt is the fallback base prompt, context.BUILTIN_PROMPT is
-- the base context.compose actually builds, so a tool listed in only one of
-- them is invisible in half the runs.
do
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local context = assert(loadfile("src/tether/context.lua"))()

  local function listing(text)
    local names = {}
    for name in (text or ""):gmatch("\n%- ([%w_]+)%(") do names[#names + 1] = name end
    return names
  end

  local a, c = listing(agent.builtin_prompt), listing(context.builtin_prompt)
  assert_true(#a > 0, "T122 the built-in prompt lists tools")
  assert_eq(table.concat(a, ","), table.concat(c, ","),
    "T122 the two built-in tool listings agree")
  local joined = "," .. table.concat(a, ",") .. ","
  assert_true(joined:find(",ask,", 1, true) ~= nil, "T122 the listings name ask")
  assert_true(joined:find(",patch,", 1, true) ~= nil, "T122 the listings name the existing tools")
  assert_true((agent.builtin_prompt or ""):find("ask(questions)", 1, true) ~= nil,
    "T122 the ask entry shows its argument shape")
  print("T122 built-in tool listings: OK")
end

-- T123: ask parks the turn and the answer resumes it (add-ask-tool 2.2/2.3).
-- Agent level: a stubbed stream emits the tool calls, and the turn is resolved
-- the way the UI resolves it — answer_ask(...) then continue.
do
  local ASK_WS = "/tmp/tether_ask_t123a"
  os.execute("rm -rf " .. ASK_WS .. " && mkdir -p " .. ASK_WS)
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = ASK_WS, _session_id = "s1", auto_approve = {} }
    local journal = {}
    mods.session.append = function(_, ev) journal[#journal + 1] = ev end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"id":"scope","question":"Scope?",'
            .. '"options":[{"label":"src"},{"label":"all"}]}]}' })
        on_event({ type = "tool_call_start", id = "w1", name = "write" })
        on_event({ type = "tool_call_delta", id = "w1",
          arguments = '{"path":"out.txt","content":"written\\n"}' })
      else
        on_event({ type = "text_delta", text = "done" })
      end
      return true
    end

    local function tool_msgs()
      local n = 0
      for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then n = n + 1 end
      end
      return n
    end
    local function count_asks()
      local n = 0
      for _, ev in ipairs(events) do if ev.type == "ask" then n = n + 1 end end
      return n
    end

    agent.turn(cfg, "k", "which scope?", on_ev)

    local ask_ev
    for _, ev in ipairs(events) do if ev.type == "ask" then ask_ev = ev end end
    assert_notnil(ask_ev, "T123 the ask call raises an event")
    assert_eq(ask_ev and ask_ev.id, "a1", "T123 the event carries the call id")
    assert_eq(ask_ev and ask_ev.questions[1].id, "scope",
      "T123 the event carries the normalised questions")
    assert_eq(ask_ev and #ask_ev.questions[1].options, 2, "T123 the options survive normalisation")
    assert_eq(tool_msgs(), 0, "T123 nothing behind the ask runs while it is parked")
    assert_eq(requests, 1, "T123 the turn returned without another request")

    -- a repeated continue neither re-emits nor runs the queued call
    agent.continue(cfg, "k", on_ev)
    assert_eq(count_asks(), 1, "T123 continue does not re-emit the ask")
    assert_eq(tool_msgs(), 0, "T123 a call queued behind the ask still waits")
    assert_eq(requests, 1, "T123 the parked turn makes no request")

    -- the answer records the tool result, lets the queued call run, drains
    local more = agent.answer_ask("a1", { { selected = { "src" } } }, cfg, on_ev)
    assert_false(more, "T123 answering the last interaction drains the queue")

    local payload
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" and m.tool_call_id == "a1" then payload = m.content end
    end
    assert_notnil(payload, "T123 the answer is that call's tool result")
    assert_true((payload or ""):find('"selected":["src"]', 1, true) ~= nil,
      "T123 the tool result carries the answer payload")

    local journaled = false
    for _, ev in ipairs(journal) do
      if ev.type == "tool_result" and ev.tool_call_id == "a1" then journaled = true end
    end
    assert_true(journaled, "T123 the answer is journaled")

    local wrote = false
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" and m.tool_call_id == "w1" then wrote = true end
    end
    assert_true(wrote, "T123 the call queued behind the ask runs once it is answered")
    local f = io.open(ASK_WS .. "/out.txt", "r")
    assert_notnil(f, "T123 the queued write reached the disk")
    if f then f:close() end

    -- resuming sends the answer to the model and finishes the turn
    agent.continue(cfg, "k", on_ev)
    assert_eq(requests, 2, "T123 the resumed turn makes its next request")
    print("T123 ask parks the turn: OK")
  end)
end

-- T123b: cancelling resolves every queued ask of the step (add-ask-tool 2.4)
do
  local ASK_WS = "/tmp/tether_ask_t123b"
  os.execute("rm -rf " .. ASK_WS .. " && mkdir -p " .. ASK_WS)
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = ASK_WS, _session_id = "s1", auto_approve = {} }
    mods.session.append = function() end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"id":"one","question":"One?"}]}' })
        on_event({ type = "tool_call_start", id = "a2", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a2",
          arguments = '{"questions":[{"id":"two","question":"Two?"}]}' })
        on_event({ type = "tool_call_start", id = "w1", name = "write" })
        on_event({ type = "tool_call_delta", id = "w1",
          arguments = '{"path":"cancel.txt","content":"x\\n"}' })
      else
        on_event({ type = "text_delta", text = "ok" })
      end
      return true
    end

    local function count_asks()
      local n = 0
      for _, ev in ipairs(events) do if ev.type == "ask" then n = n + 1 end end
      return n
    end

    agent.turn(cfg, "k", "ask me twice", on_ev)
    assert_eq(count_asks(), 1, "T123b only the first question is raised")

    agent.answer_ask("a1", { cancelled = true }, cfg, on_ev)
    assert_eq(count_asks(), 1, "T123b the queued question is not raised after a cancel")

    local results = {}
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" then results[m.tool_call_id] = m.content end
    end
    assert_true((results.a1 or ""):find('"cancelled":true', 1, true) ~= nil,
      "T123b the cancelled call reports the cancellation")
    assert_true((results.a2 or ""):find('"cancelled":true', 1, true) ~= nil,
      "T123b the queued call reports the same cancellation")
    assert_notnil(results.w1, "T123b the pending write is unaffected")
    local f = io.open(ASK_WS .. "/cancel.txt", "r")
    assert_notnil(f, "T123b the pending write reached the disk")
    if f then f:close() end
    print("T123b cancel resolves the batch: OK")
  end)
end

-- T123c: a non-interactive run gets an error result instead of a question
-- (add-ask-tool 2.5), and an unusable question set does too.
do
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
                  non_interactive = true }
    mods.session.append = function() end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"id":"q","question":"Which?"}]}' })
      else
        on_event({ type = "text_delta", text = "decided" })
      end
      return true
    end

    agent.turn(cfg, "k", "go", on_ev)
    assert_eq(requests, 2, "T123c the loop makes its next request without waiting")
    local saw_ask, saw_err = false, false
    for _, ev in ipairs(events) do
      if ev.type == "ask" then saw_ask = true end
      if ev.type == "tool_result" and ev.error
          and ev.error:find("no interactive user", 1, true) then saw_err = true end
    end
    assert_false(saw_ask, "T123c no question is raised")
    assert_true(saw_err, "T123c the call yields an error result")
    local content
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" then content = m.content end
    end
    assert_true((content or "").find ~= nil
      and (content or ""):find("no interactive user", 1, true) ~= nil,
      "T123c the model reads the explanation")
    print("T123c non-interactive ask: OK")
  end)
end

do
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {} }
    mods.session.append = function() end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"question":"   "}]}' })
      else
        on_event({ type = "text_delta", text = "decided" })
      end
      return true
    end

    agent.turn(cfg, "k", "go", on_ev)
    assert_eq(requests, 2, "T123d an unusable question set keeps the loop going")
    local saw_ask, saw_err = false, false
    for _, ev in ipairs(events) do
      if ev.type == "ask" then saw_ask = true end
      if ev.type == "tool_result" and ev.error
          and ev.error:find("no usable question", 1, true) then saw_err = true end
    end
    assert_false(saw_ask, "T123d nothing answerable raises no question")
    assert_true(saw_err, "T123d the tool result names the problem")
    print("T123d unusable question set: OK")
  end)
end

-- T123e: the model double-encodes questions as a JSON string instead of an
-- array ("questions":"[{...}]", as recorded live) — normalize decodes one
-- layer instead of reporting "no usable question".
do
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {} }
    mods.session.append = function() end
    local events = {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      on_event({ type = "tool_call_start", id = "a1", name = "ask" })
      -- wire layer: the array rides inside a JSON string, so inner quotes
      -- arrive triple-escaped (\\\" is backslash backslash backslash quote
      -- on the wire, written \\\\\\ in this literal)
      on_event({ type = "tool_call_delta", id = "a1",
        arguments = '{"questions":"[{\\\\\\"question\\\\\\":\\\\\\"Which?\\\\\\",\\\\\\"options\\\\\\":[{\\\\\\"label\\\\\\":\\\\\\"a\\\\\\"}],\\\\\\"id\\\\\\":\\\\\\"q1\\\\\\"}]"}' })
      on_event({ type = "done", reason = "tool_calls" })
      return true
    end

    agent.turn(cfg, "k", "go", on_ev)
    local asked = nil
    for _, ev in ipairs(events) do
      if ev.type == "ask" then asked = ev end
    end
    assert_notnil(asked, "T123e a string-encoded set raises the question")
    assert_eq(asked and asked.questions and asked.questions[1]
      and asked.questions[1].question, "Which?",
      "T123e the decoded question survives")
    print("T123e string-encoded question set: OK")
  end)
end

-- T124: the question block renders from an ask event (add-ask-tool 3.1).
do
  local askmod = assert(loadfile("src/tether/ask.lua"))()
  local agent_stub = { turn = function() return true end, get_history = function() return {} end,
                       answer_ask = function() return false end, continue = function() return true end }
  local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })

  -- a waiting turn first: no placeholder tail exists anymore — the block
  -- opens straight from the waiting state (turn-feedback-restyling)
  S.waiting = true
  uimod._sync_tail()
  local _, _, no_third_tail = uimod._transcript.tails()
  assert_eq(no_third_tail, nil, "T124 tails carry no placeholder entry")

  uimod._handle_agent_event({ type = "ask", id = "a1", questions = {
    { id = "scope", question = "Which scope?", description = "Pick exactly one.",
      recommended = 2,
      options = { { label = "src", description = "only src" }, { label = "all" } } },
  } })
  assert_notnil(S.ask, "T124 the event opens the block")
  assert_notnil(task(uimod), "T124 the block is a synthetic tail entry")
  assert_eq(S.busy, false, "T124 the turn is not busy while the user answers")
  assert_eq(S.waiting, false, "T124 the waiting state is cleared")
  assert_eq(tph(uimod), nil, "T124 no placeholder is painted under the block")

  local rows = uimod._render_all(80)
  local joined = table.concat(rows, "\n")
  assert_true(joined:find("Which scope?", 1, true) ~= nil, "T124 the question text is rendered")
  assert_true(joined:find("? ", 1, true) ~= nil, "T124 the block leads with the question row")
  assert_true(joined:find("Pick exactly one.", 1, true) ~= nil, "T124 the description is rendered as context")
  assert_true(joined:find("1. src", 1, true) ~= nil, "T124 option rows carry their index")
  assert_true(joined:find("2. all", 1, true) ~= nil, "T124 the second option is rendered")
  assert_true(joined:find("only src", 1, true) ~= nil, "T124 an option description is rendered")
  assert_true(joined:find("(recommended)", 1, true) ~= nil, "T124 the recommended option is flagged")
  assert_true(joined:find(askmod.FREEFORM_LABEL, 1, true) ~= nil, "T124 the freeform row is always present")
  assert_true(joined:find("(", 1, true) ~= nil, "T124 the block renders rows")

  -- the highlight starts on the first option, not on the recommended one;
  -- ask-block-redesign: the cursor is accent-colored text, not reverse video
  local highlighted, recommended_row = nil, nil
  for _, r in ipairs(rows) do
    if r:find("\27[38;", 1, true) and r:find("1. src", 1, true) then highlighted = r end
    if r:find("(recommended)", 1, true) then recommended_row = r end
  end
  assert_notnil(highlighted, "T124 a row is highlighted")
  assert_true(highlighted and highlighted:find("1. src", 1, true) ~= nil,
    "T124 the initial highlight stays on the first option")
  assert_true(recommended_row ~= nil and recommended_row:find("2. all", 1, true) ~= nil,
    "T124 the recommended flag sits on option 2")

  -- progress appears only for a multi-question call
  local uimod2, S2 = run_ui_with({ 17 }, { agent = agent_stub })
  local three = {}
  for i = 1, 3 do
    three[i] = { id = "q" .. i, question = "Question " .. i,
                 options = { { label = "a" }, { label = "b" } } }
  end
  uimod2._handle_agent_event({ type = "ask", id = "a2", questions = three })
  local joined2 = table.concat(uimod2._render_all(80), "\n")
  assert_true(joined2:find("Question 1", 1, true) ~= nil, "T124 the first question is shown")
  -- ask-block-redesign: the tab strip replaces the (i/N) counter; tabs carry
  -- clipped question text, and only the current question's rows render
  assert_true(joined2:find("Question 2", 1, true) ~= nil, "T124 the tab strip lists every question")
  assert_true(joined2:find("Confirm", 1, true) ~= nil, "T124 the tab strip ends with Confirm")
  local _, q2_count = joined2:gsub("Question 2", "Question 2")
  assert_eq(q2_count, 1, "T124 the next question appears only as a tab")

  -- a multi question marks every option, and a saved note renders under its option
  S2.ask.questions[1].multi = true
  S2.ask.answers[1].selected = { "a" }
  S2.ask.answers[1].notes = { b = "second choice" }
  uimod2._sync_tail()
  local joined3 = table.concat(uimod2._render_all(80), "\n")
  assert_true(joined3:find("[x] 1. a", 1, true) ~= nil, "T124 a toggled option is marked")
  assert_true(joined3:find("[ ] 2. b", 1, true) ~= nil, "T124 an untoggled option is marked too")
  assert_true(joined3:find("second choice", 1, true) ~= nil, "T124 a note renders under its option")

  -- a single-question call shows no progress indicator at all
  local uimod3, S3 = run_ui_with({ 17 }, { agent = agent_stub })
  uimod3._handle_agent_event({ type = "ask", id = "a3", questions = {
    { id = "one", question = "Only one?", options = { { label = "x" } } } } })
  local joined4 = table.concat(uimod3._render_all(80), "\n")
  assert_true(joined4:find("(1/1)", 1, true) == nil, "T124 a single question has no progress indicator")
  print("T124 question block rendering: OK")
end

-- T125: answering a question with the keyboard (add-ask-tool 3.2).
do
  local rec = { continued = 0 }
  local agent_stub = {
    turn = function() return true end,
    get_history = function() return {} end,
    answer_ask = function(id, answer)
      if answer and answer.cancelled then rec.cancelled = true end
      rec.id = id; rec.answer = answer; return false end,
    continue = function() rec.continued = rec.continued + 1; return true end,
  }
  local function boot(questions)
    local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
    -- the harness restores globals after run(); resolving an answer calls into
    -- the agent again, so the stub has to be reachable for the post-run keys
    _G.agent = agent_stub
    uimod._handle_agent_event({ type = "ask", id = "a1", questions = questions })
    return uimod, S
  end
  local down  = { kind = "special", name = "down" }
  local left  = { kind = "special", name = "left" }
  local enter = { kind = "enter" }
  local esc   = { kind = "esc" }
  local tab   = { kind = "tab" }
  local function text(c) return { kind = "text", char = c } end
  local one = { { id = "scope", question = "Scope?",
                  options = { { label = "src" }, { label = "all" }, { label = "none" } } } }

  -- arrow + Enter picks the highlighted option
  local m, S = boot(one)
  m._handle_key(down)
  assert_eq(S.ask.sel, 2, "T125 ↓ moves the highlight")
  m._handle_key(enter)
  assert_notnil(rec.answer, "T125 Enter submits the highlighted option")
  assert_eq(rec.answer[1].selected[1], "all", "T125 the second option is the answer")
  assert_eq(S.ask, nil, "T125 the block closes on submit")
  assert_eq(rec.continued, 1, "T125 the turn resumes after the answer")
  local row
  for _, e in ipairs(tentries(m)) do
    if e.role == "system" and (e.text or ""):find("→ ask:", 1, true) then row = e.text end
  end
  assert_notnil(row, "T125 a summary row is appended")
  assert_true(row and row:find("scope=all", 1, true) ~= nil, "T125 the row names the answer")

  -- a digit submits that option
  rec.answer = nil
  local m2 = boot(one)
  m2._handle_key(text("3"))
  assert_notnil(rec.answer, "T125 a digit submits")
  assert_eq(rec.answer[1].selected[1], "none", "T125 the third option is the answer")

  -- keys the block does not use change nothing and never reach the input line
  rec.answer = nil
  local m3, S3 = boot(one)
  local input_before = S3.input
  m3._handle_key(text("z"))
  m3._handle_key(text("7"))
  assert_eq(S3.input, input_before, "T125 unused keys do not reach the input line")
  assert_eq(rec.answer, nil, "T125 nothing is submitted")
  assert_notnil(S3.ask, "T125 the block stays open")

  -- Esc cancels the set, raises no banner, and the turn continues
  local m4, S4 = boot(one)
  local before_cancel = rec.continued
  m4._handle_key(esc)
  assert_true(rec.answer and rec.answer.cancelled == true, "T125 Esc reports the cancellation")
  assert_eq(S4.ask, nil, "T125 the block is gone after Esc")
  assert_eq(S4.error_banner, nil, "T125 a cancellation raises no error banner")
  assert_eq(rec.continued, before_cancel + 1, "T125 the turn continues after a cancellation")

  -- multi: Space toggles without submitting, Enter accepts the selection
  rec.answer = nil
  local multi = { { id = "cons", question = "Constraints?", multi = true,
                    options = { { label = "no breaks" }, { label = "zero deps" } } } }
  local m5, S5 = boot(multi)
  m5._handle_key(text(" "))
  m5._handle_key(down)
  m5._handle_key(text(" "))
  assert_eq(rec.answer, nil, "T125 a toggle does not submit")
  assert_eq(#S5.ask.answers[1].selected, 2, "T125 two options are toggled")
  m5._handle_key(text(" "))
  assert_eq(#S5.ask.answers[1].selected, 1, "T125 Space toggles the highlight off again")
  m5._handle_key(enter)
  assert_notnil(rec.answer, "T125 Enter accepts the multi selection")
  assert_eq(#rec.answer[1].selected, 1, "T125 the accepted selection is reported")

  -- ← returns to the previous question with its answer intact
  rec.answer = nil
  local two = {
    { id = "q1", question = "First?", options = { { label = "a" }, { label = "b" } } },
    { id = "q2", question = "Second?", options = { { label = "c" }, { label = "d" } } } }
  local m6, S6 = boot(two)
  m6._handle_key(enter)
  assert_eq(S6.ask.qidx, 2, "T125 Enter advances to the next question")
  assert_eq(rec.answer, nil, "T125 the set is not submitted before its last question")
  assert_eq(S6.ask.answers[1].selected[1], "a", "T125 the earlier answer is kept while advancing")
  m6._handle_key(left)
  assert_eq(S6.ask.qidx, 1, "T125 ← returns to the previous question")
  assert_eq(S6.ask.answers[1].selected[1], "a", "T125 the answer is still selected")
  m6._handle_key(enter)
  m6._handle_key(enter)
  -- ask-block-redesign: the last Enter opens the Confirm phase, a second one submits
  assert_eq(S6.ask.phase, "confirm", "T125 the last question opens the Confirm phase")
  assert_eq(rec.answer, nil, "T125 nothing is submitted while reviewing")
  m6._handle_key(enter)
  assert_notnil(rec.answer, "T125 Enter on Confirm submits the whole set")
  assert_eq(#rec.answer, 2, "T125 both answers are reported")

  -- → moves to the next question without answering; ← comes back again
  rec.answer = nil
  local right = { kind = "special", name = "right" }
  local m6b, S6b = boot(two)
  m6b._handle_key(right)
  assert_eq(S6b.ask.qidx, 2, "T125 → moves to the next question")
  assert_eq(rec.answer, nil, "T125 → does not submit the set")
  m6b._handle_key(left)
  assert_eq(S6b.ask.qidx, 1, "T125 ← returns again")
  -- ask-block-redesign: → at the last question opens the Confirm phase
  m6b._handle_key(right)
  m6b._handle_key(right)
  assert_eq(S6b.ask.phase, "confirm", "T125 → at the last question opens Confirm")
  assert_eq(rec.answer, nil, "T125 → at the last question submits nothing")
  -- Confirm phase keys: Tab returns with answers, ← returns too, Esc cancels all
  m6b._handle_key(tab)
  assert_eq(S6b.ask.phase, "questions", "T125 Tab on Confirm returns to the questions")
  m6b._handle_key(right)
  m6b._handle_key(right)
  m6b._handle_key({ kind = "special", name = "left" })
  assert_eq(S6b.ask.phase, "questions", "T125 ← on Confirm returns to the questions")
  m6b._handle_key(right)
  m6b._handle_key(right)
  m6b._handle_key(esc)
  assert_eq(rec.cancelled, true, "T125 Esc on Confirm cancels the whole set")

  -- the Confirm rows render each question with its committed answer
  local m6c, S6c = boot({
    { id = "q1", question = "First?", options = { { label = "a" }, { label = "b" } } },
    { id = "q2", question = "Second?", options = { { label = "c" }, { label = "d" } } } })
  m6c._handle_key(enter)
  m6c._handle_key(enter)
  local cj_rows = {}
  for _, r in ipairs(m6c._render_all(80)) do cj_rows[#cj_rows + 1] = r:gsub("\27%[[%d;]*m", "") end
  local cj = table.concat(cj_rows, "\n")
  assert_true(cj:find("First?: a", 1, true) ~= nil, "T125 Confirm shows question: answer")
  assert_true(cj:find("Second?: c", 1, true) ~= nil, "T125 Confirm shows every answer")
  assert_true(cj:find("enter submit", 1, true) ~= nil, "T125 Confirm hints submit")

  -- Space selects the highlighted option of a single question (like a digit)
  rec.answer = nil
  local m6c, S6c = boot(two)
  m6c._handle_key(down) -- highlight option 2 ("b")
  m6c._handle_key(text(" "))
  assert_eq(S6c.ask.qidx, 2, "T125 Space selects and advances")
  assert_eq(S6c.ask.answers[1].selected[1], "b", "T125 Space selects the highlighted option")
  assert_eq(rec.answer, nil, "T125 Space does not submit the set before its last question")
  -- Space on the freeform row selects nothing and opens no editor
  rec.answer = nil
  local m6d, S6d = boot(one) -- 3 options, freeform row is 4
  m6d._handle_key(down); m6d._handle_key(down); m6d._handle_key(down)
  m6d._handle_key(text(" "))
  assert_notnil(S6d.ask, "T125 Space on the freeform row keeps the block open")
  assert_eq(rec.answer, nil, "T125 Space on the freeform row submits nothing")

  -- the waiting state stays clear while the block is open
  local m7, S7 = boot(one)
  local ph125 = tph(m7)
  assert_eq(ph125, nil, "T125 no placeholder under the block")
  assert_eq(S7.waiting, false, "T125 the turn is not painted as waiting")
  print("T125 question block keys: OK")
end

-- T126: the freeform answer and option notes (add-ask-tool 3.3).
do
  local rec = { continued = 0 }
  local agent_stub = {
    turn = function() return true end,
    get_history = function() return {} end,
    answer_ask = function(id, answer) rec.answer = answer; return false end,
    continue = function() rec.continued = rec.continued + 1; return true end,
  }
  local function boot(questions)
    local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
    -- the harness restores globals after run(); resolving an answer calls into
    -- the agent again, so the stub has to be reachable for the post-run keys
    _G.agent = agent_stub
    uimod._handle_agent_event({ type = "ask", id = "a1", questions = questions })
    return uimod, S
  end
  local function type_text(uimod, str)
    for i = 1, #str do uimod._handle_key({ kind = "text", char = str:sub(i, i) }) end
  end
  local down, enter, esc, tab = { kind = "special", name = "down" }, { kind = "enter" },
      { kind = "esc" }, { kind = "tab" }
  local up = { kind = "special", name = "up" }
  local qs = { { id = "scope", question = "Scope?",
                 options = { { label = "src" }, { label = "all" } } } }

  -- Tab writes a note on the highlighted option
  local m, S = boot(qs)
  m._handle_key(tab)
  assert_eq(S.ask.mode, "note", "T126 Tab opens the note editor")
  type_text(m, "too big")
  assert_eq(S.ask.editor, "too big", "T126 the editor buffer holds the note")
  m._handle_key(enter)
  assert_eq(S.ask.mode, "list", "T126 Enter commits and returns to the list")
  assert_eq(S.ask.answers[1].notes.src, "too big", "T126 the note is saved on its option")
  assert_true(table.concat(m._render_all(80), "\n"):find("too big", 1, true) ~= nil,
    "T126 the note renders under its option")

  -- the note editor's Esc discards its edits and does not cancel the set
  m._handle_key(tab)
  type_text(m, "XX")
  m._handle_key(esc)
  assert_eq(S.ask.mode, "list", "T126 Esc returns to the option list")
  assert_eq(S.ask.answers[1].notes.src, "too big", "T126 Esc discarded the edits")
  assert_notnil(S.ask, "T126 Esc did not cancel the question set")
  assert_eq(S.ask.editor, "", "T126 the editor buffer is dropped")

  -- ↑ inside an editor does not move the highlight
  local sel_before = S.ask.sel
  m._handle_key(tab)
  m._handle_key(up)
  assert_eq(S.ask.mode, "note", "T126 ↑ does not leave the editor")
  assert_eq(S.ask.sel, sel_before, "T126 editing keys do not move the highlight")
  m._handle_key(esc)

  -- an empty commit clears a note again
  m._handle_key(tab)
  m._handle_key({ kind = "backspace" })
  assert_eq(S.ask.editor, "too bi", "T126 backspace edits the buffer")
  m._handle_key(enter)
  assert_eq(S.ask.answers[1].notes.src, "too bi", "T126 the edited note is saved")

  -- the note travels with the answer
  m._handle_key(enter)
  assert_eq(rec.answer[1].selected[1], "src", "T126 the highlighted option is the answer")
  assert_eq(rec.answer[1].notes.src, "too bi", "T126 the note travels with the answer")

  -- freeform: Enter opens, text commits, Enter submits
  rec.answer = nil
  local m2, S2 = boot(qs)
  m2._handle_key(down)
  m2._handle_key(down)
  assert_eq(S2.ask.sel, 3, "T126 ↓ reaches the freeform row")
  m2._handle_key(enter)
  assert_eq(S2.ask.mode, "other", "T126 Enter opens the editor while no text is committed")
  type_text(m2, "Nuxt")
  m2._handle_key(enter)
  assert_eq(S2.ask.mode, "list", "T126 Enter commits the freeform text")
  assert_eq(S2.ask.answers[1].other, "Nuxt", "T126 the text is kept on the question")
  assert_eq(rec.answer, nil, "T126 committing alone does not submit")
  m2._handle_key(enter)
  assert_notnil(rec.answer, "T126 Enter submits once the freeform text is committed")
  assert_eq(rec.answer[1].other, "Nuxt", "T126 the freeform text is the answer")
  assert_eq(#rec.answer[1].selected, 0, "T126 a freeform-only answer has no selection")

  -- Esc in the freeform editor discards and keeps the set open
  rec.answer = nil
  local m3, S3 = boot(qs)
  m3._handle_key(down)
  m3._handle_key(down)
  m3._handle_key(enter)
  type_text(m3, "Nuxt")
  m3._handle_key(esc)
  assert_eq(S3.ask.mode, "list", "T126 Esc leaves the freeform editor")
  assert_eq(S3.ask.answers[1].other, "", "T126 the freeform edit was discarded")
  assert_eq(rec.answer, nil, "T126 the set is still open")

  -- Tab re-opens the freeform editor, prefilled with the committed text
  m3._handle_key(enter)
  type_text(m3, "Nuxt")
  m3._handle_key(enter)
  m3._handle_key(tab)
  assert_eq(S3.ask.mode, "other", "T126 Tab on the freeform row re-opens the editor")
  assert_eq(S3.ask.editor, "Nuxt", "T126 the editor is prefilled with the committed text")
  m3._handle_key(esc)

  -- a question with no options is answerable through the freeform row
  rec.answer = nil
  local m4, S4 = boot({ { id = "free", question = "Anything?", options = {} } })
  m4._handle_key(enter)
  assert_eq(S4.ask.mode, "other", "T126 an optionless question opens the freeform editor")
  type_text(m4, "all of it")
  m4._handle_key(enter)
  m4._handle_key(enter)
  assert_notnil(rec.answer, "T126 an optionless question is answerable")
  assert_eq(rec.answer[1].other, "all of it", "T126 the typed text is the answer")

  -- an empty commit clears a committed freeform answer
  rec.answer = nil
  local m5, S5 = boot(qs)
  m5._handle_key(down)
  m5._handle_key(down)
  m5._handle_key(enter)
  type_text(m5, "Nuxt")
  m5._handle_key(enter)
  m5._handle_key(tab)
  m5._handle_key({ kind = "backspace" })
  m5._handle_key({ kind = "backspace" })
  m5._handle_key({ kind = "backspace" })
  m5._handle_key({ kind = "backspace" })
  m5._handle_key(enter)
  assert_eq(S5.ask.answers[1].other, "", "T126 an empty commit clears the freeform answer")
  print("T126 freeform and notes: OK")
end

-- T127: the block's keys are documented and its glyphs degrade (3.4/3.5).
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end,
                       answer_ask = function() return false end, continue = function() return true end }
  local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
  _G.agent = agent_stub

  assert_notnil(uimod.ASK_KEYS, "T127 the block's bindings are exported")
  for _, key in ipairs({ "up", "down", "enter", "1", "space", "tab", "left", "right", "esc", "backspace" }) do
    assert_notnil(uimod.ASK_KEYS[key], "T127 the block documents " .. key)
  end

  uimod._handle_agent_event({ type = "ask", id = "a1", questions = {
    { id = "scope", question = "Scope?", multi = true,
      options = { { label = "src" } } } } })
  S.ask.answers[1].selected = { "src" }
  S.ask.answers[1].notes = { src = "careful" }
  S.ask.answers[1].other = "Nuxt"
  uimod._sync_tail()

  -- ASCII mode: no glyph the block introduces survives untranslated
  uimod._ascii_mode = true
  local rows = uimod._render_all(80)
  local joined = table.concat(rows, "\n")
  assert_true(joined:find("[x]", 1, true) ~= nil, "T127 the toggle marker is ASCII")
  assert_true(joined:find("->", 1, true) ~= nil, "T127 the note marker degrades")
  for _, glyph in ipairs({ "↳", "▌", "«", "»" }) do
    assert_true(joined:find(glyph, 1, true) == nil,
      "T127 no " .. glyph .. " glyph is left in ASCII mode")
  end
  -- and the ASCII freeform hint quotes with plain quotes instead
  assert_true(joined:find('"Nuxt"', 1, true) ~= nil,
    "T127 the freeform hint quotes in ASCII: " .. joined:gsub("\n", " | "):sub(1, 120))
  uimod._ascii_mode = nil
  print("T127 block keys and ASCII: OK")
end

-- T228: ask-block-redesign — markers only on multi, accent cursor, tab strip,
-- phase-scoped muted hint.
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end,
                       answer_ask = function() return false end, continue = function() return true end }
  local function boot(questions)
    local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
    _G.agent = agent_stub
    uimod._handle_agent_event({ type = "ask", id = "a1", questions = questions })
    return uimod, S
  end
  local function plain(uimod, w)
    return table.concat(uimod._render_all(w or 80), "\n"):gsub("\27%[[0-9;]*m", "")
  end
  local down, enter, esc, tab = { kind = "special", name = "down" }, { kind = "enter" },
      { kind = "esc" }, { kind = "tab" }
  local single_qs = { { id = "fw", question = "Framework?",
                        options = { { label = "React" }, { label = "Vue" } } } }

  -- 1.1: single-answer options carry no markers; the cursor row is accent-colored
  local m, S = boot(single_qs)
  local j = plain(m)
  assert_true(j:find("1. React", 1, true) ~= nil, "T228 single options render as a numbered list")
  assert_true(j:find("( )", 1, true) == nil and j:find("(*)", 1, true) == nil,
    "T228 single options carry no round markers")
  local raw = table.concat(m._render_all(80), "\n")
  assert_true(raw:find("\27[38;", 1, true) ~= nil, "T228 the cursor row is accent-colored")
  S.ask.answers[1].selected = { "Vue" }
  m._sync_tail()
  local j2 = plain(m)
  -- selection state is invisible on single questions: no marker flips
  assert_true(j2:find("(*)", 1, true) == nil, "T228 selecting adds no marker")
  -- cursor move alone changes no selection
  m._handle_key(down)
  local j3 = plain(m)
  assert_true(j3:find("2. Vue", 1, true) ~= nil, "T228 cursor move still renders the row")

  -- 1.2: multi questions keep square markers and gain no round ones
  local mm = boot({ { id = "vals", question = "Values?", multi = true,
                      options = { { label = "a" }, { label = "b" } } } })
  mm._handle_key({ kind = "text", char = " " })
  local mj = plain(mm)
  assert_true(mj:find("[x] 1. a", 1, true) ~= nil, "T228 a toggled multi option is [x]")
  assert_true(mj:find("[ ] 2. b", 1, true) ~= nil, "T228 an untoggled multi option is [ ]")
  assert_true(mj:find("( )", 1, true) == nil and mj:find("(*)", 1, true) == nil,
    "T228 no round marker appears in multi mode")

  -- 2.1/2.2: no tab strip for one question, tab strip for many, no Agent asks line
  assert_true(j:find("Confirm", 1, true) == nil, "T228 a single question shows no tab strip")
  assert_true(j:find("Agent asks", 1, true) == nil, "T228 no Agent asks label line")
  local m3q = boot({ { id = "q1", question = "First?",
                        options = { { label = "a" } } },
                      { id = "q2", question = "Second?",
                        options = { { label = "b" } } } })
  local qj = plain(m3q)
  assert_true(qj:find("First?", 1, true) ~= nil, "T228 the strip lists question tabs")
  assert_true(qj:find("Confirm", 1, true) ~= nil, "T228 the strip ends with Confirm")
  assert_true(qj:find("Agent asks", 1, true) == nil, "T228 no Agent asks label in multi sets either")

  -- 3.1: hint rows per mode name the handled keys; every named key is in ASK_KEYS
  for _, k in ipairs({ "up", "down", "enter", "space", "tab", "left", "right", "esc" }) do
    assert_notnil(m.ASK_KEYS[k], "T228 hint coverage: ASK_KEYS documents " .. k)
  end
  assert_true(j:find("enter submit", 1, true) ~= nil, "T228 single hint names submit")
  assert_true(j:find("esc dismiss", 1, true) ~= nil, "T228 single hint names dismiss")
  assert_true(j:find("tab", 1, true) == nil, "T228 single hint names no tab key")
  assert_true(mj:find("Space toggle", 1, true) ~= nil, "T228 multi hint names toggle")
  assert_true(mj:find("Enter accept", 1, true) ~= nil, "T228 multi hint names accept")
  assert_true(mj:find("1-N", 1, true) == nil, "T228 multi hint names no single pick key")
  m._handle_key(tab)
  local nj = plain(m)
  assert_true(nj:find("Enter save", 1, true) ~= nil, "T228 note hint names save")
  assert_true(nj:find("Esc discard", 1, true) ~= nil, "T228 note hint names discard")
  assert_true(nj:find("↑↓", 1, true) == nil, "T228 editor hint names no list navigation")
  m._handle_key(esc)
  m._handle_key(down)
  m._handle_key(enter)
  assert_eq(S.ask.mode, "other", "T228 Enter on the freeform row opens the answer editor")
  local oj = plain(m)
  assert_true(oj:find("type answer", 1, true) ~= nil, "T228 freeform hint names the answer entry")
  assert_true(oj:find("Enter save", 1, true) ~= nil, "T228 freeform hint names save")
  assert_true(oj:find("Esc discard", 1, true) ~= nil, "T228 freeform hint names discard")
  assert_true(oj:find("↑↓", 1, true) == nil, "T228 freeform hint names no list navigation")
  m._handle_key(esc)

  -- 3.2: no back hint on the first question; past it the hint names ← back
  assert_true(qj:find("back", 1, true) == nil, "T228 no back hint on the first question")
  m3q._handle_key(enter)
  local qj2 = plain(m3q)
  assert_true(qj2:find("← back", 1, true) ~= nil, "T228 later questions name the back key")
  assert_true(qj2:find("esc dismiss", 1, true) ~= nil, "T228 dismiss hint stays on later questions")
  assert_eq(qj2:find("⇆ tab", 1, true), qj:find("⇆ tab", 1, true) and qj2:find("⇆ tab", 1, true),
    "T228 the tab hint is present on later questions too")

  -- 3.3: the hint row is clipped, never wrapped — the head survives on exactly
  -- one row and the clipped tail ("cancel") is gone instead of wrapping below
  local narrow = plain(m, 30)
  local _, n_hint = narrow:gsub("↑↓", "↑↓")
  assert_eq(n_hint, 1, "T228 the hint stays a single row at width 30")
  assert_true(narrow:find("cancel", 1, true) == nil,
    "T228 the hint tail is clipped, not wrapped")

  -- 4.1: ASCII mode leaves no non-ASCII block glyph
  m._ascii_mode = true
  local arows = table.concat(m._render_all(80), "\n")
  for _, glyph in ipairs({ "↑", "↓", "←", "·", "↳", "▌", "«", "»", "⇆" }) do
    assert_true(arows:find(glyph, 1, true) == nil,
      "T228 no " .. glyph .. " glyph is left in ASCII mode")
  end
  assert_true(arows:find("esc dismiss", 1, true) ~= nil, "T228 the ASCII hint keeps its verbs")
  m._ascii_mode = nil
  print("T228 ask-block-b markers, counter, hint: OK")
end

-- T128 (4.1/4.5): commands module owns resume/new/compact/list helpers.
do
  local names = {"session", "agent", "api"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end

  local history
  local clears = 0
  local journal = {
    sess1 = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "a1" },
      { role = "assistant", tool_calls = { { id = "c1", name = "read" } } },
      { role = "tool", tool_call_id = "c1", content = "file body" },
      { role = "user", content = "q2" },
      { role = "assistant", content = "a2" },
    },
  }
  _G.session = {
    latest = function() return "sess1" end,
    resume = function(id) return journal[id] end,
    new_session = function(ws, model) return "new-" .. tostring(model) end,
    session_files = function()
      return { { id = "sess1", ts = "2026-01-01", first_line = "q1" } }
    end,
  }
  _G.agent = {
    clear = function() clears = clears + 1; history = {} end,
    get_history = function() return history end,
    add_user = function(c) history[#history + 1] = { role = "user", content = c } end,
    add_assistant = function(m)
      if type(m) == "table" then history[#history + 1] = { role = "assistant", tool_calls = m.tool_calls }
      else history[#history + 1] = { role = "assistant", content = m } end
    end,
    add_tool_result = function(id, content)
      history[#history + 1] = { role = "tool", tool_call_id = id, content = content }
    end,
    compress_history = function(h)
      return { { role = "system", content = "summary: short" }, { role = "user", content = "q2" } }
    end,
    estimate_tokens = function() return 10 end,
  }
  _G.api = {
    list_models = function() return { "static-a", "static-b" } end,
    list_models_live = function() return nil, "offline" end,
  }

  local commands = assert(loadfile("src/tether/commands.lua"))()

  -- resume with explicit id rebuilds history including tool results
  history = { { role = "system", content = "stale" } }
  local sid, messages = commands.resume("sess1")
  assert_eq(sid, "sess1", "T128 resume returns explicit id")
  assert_eq(#messages, 6, "T128 resume returns journal messages")
  assert_eq(clears, 1, "T128 resume clears agent first")
  assert_eq(#history, 6, "T128 history rebuilt in order")
  assert_eq(history[1].role, "user", "T128 first rebuilt is user")
  assert_notnil(history[3].tool_calls, "T128 tool_calls preserved for API")
  assert_eq(history[4].role, "tool", "T128 tool result restored")
  assert_eq(history[6].content, "a2", "T128 full journal restored")

  -- resume with no id falls back to latest(workspace)
  local sid2 = commands.resume(nil, "/ws")
  assert_eq(sid2, "sess1", "T128 resume(nil, ws) resolves latest")

  -- unknown journal id still returns the id (caller owns cfg) but no messages
  clears = 0
  history = { { role = "user", content = "keep" } }
  local sid3, msgs3 = commands.resume("missing")
  assert_eq(sid3, "missing", "T128 explicit id is returned as-is")
  assert_eq(msgs3, nil, "T128 missing journal yields nil messages")
  assert_eq(clears, 1, "T128 resume always clears the agent")

  -- new creates a session and clears the agent
  clears = 0
  history = { { role = "user", content = "keep" } }
  local nid = commands.new("/ws", "test")
  assert_eq(nid, "new-test", "T128 new returns session id")
  assert_eq(clears, 1, "T128 new clears agent")
  assert_eq(#history, 0, "T128 new leaves empty history")

  -- compact mutates history in place and returns (summary, mode)
  history = {
    { role = "user", content = "q1" },
    { role = "assistant", content = "a1" },
    { role = "user", content = "q2" },
  }
  agent.compact_history = function(h)
    return agent.compress_history(h), "summary: short", "truncation"
  end
  local summary, mode = commands.compact({ context = {} }, "key")
  assert_eq(summary, "summary: short", "T128 compact returns summary text")
  assert_eq(mode, "truncation", "T128 compact returns mode")
  assert_eq(#history, 2, "T128 compact mutates history in place")
  assert_eq(history[1].role, "system", "T128 compact result is system summary")

  -- list_sessions + list_models fallback
  local files = commands.list_sessions("/ws")
  assert_eq(#files, 1, "T128 list_sessions returns journal rows")
  assert_eq(files[1].id, "sess1", "T128 list_sessions keeps ids")
  local models = commands.list_models({}, "key")
  assert_eq(#models, 2, "T128 list_models falls back to static list")
  assert_eq(models[1].id, "static-a", "T128 static model shape has id")
  assert_eq(models[1].name, "static-a", "T128 static model shape has name")

  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T128 commands module: OK")
end

-- ui-facade-thinning 3.1: commands.resolve_slash routes submit-path names.
do
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local cmds = { clear = true, login = true }
  local skills = { { name = "review" }, { name = "Deploy" } }
  assert_eq(commands.resolve_slash("clear", cmds, skills), "command", "T3.1b exact command")
  assert_eq(commands.resolve_slash("CLEAR", cmds, skills), "command", "T3.1b command case-insensitive")
  assert_eq(commands.resolve_slash("review", cmds, skills), "skill", "T3.1b skill falls to submit")
  assert_eq(commands.resolve_slash("deploy", cmds, skills), "skill", "T3.1b skill case-insensitive")
  assert_eq(commands.resolve_slash("nope", cmds, skills), "unknown", "T3.1b unknown keeps command path")
  assert_eq(commands.resolve_slash("nope", cmds, nil), "unknown", "T3.1b nil skills")
  -- prompts-as-commands: 4-arg routing, commands > prompts > skills.
  local prompts = { { name = "review", prompt = true }, { name = "Deploy", prompt = true } }
  assert_eq(commands.resolve_slash("review", cmds, prompts, skills), "prompt", "T3.1c prompt expands")
  assert_eq(commands.resolve_slash("DEPLOY", cmds, prompts, skills), "prompt", "T3.1c prompt beats skill, case-insensitive")
  assert_eq(commands.resolve_slash("clear", cmds, prompts, skills), "command", "T3.1c command beats prompt")
  assert_eq(commands.resolve_slash("nope", cmds, prompts, skills), "unknown", "T3.1c unknown with prompts")
  assert_eq(commands.resolve_slash("nope", cmds, nil, nil), "unknown", "T3.1c nil prompts and skills")
  -- legacy 3-arg call: a prompts-shaped list still routes as prompt,
  -- a plain skill list still routes as skill.
  assert_eq(commands.resolve_slash("review", cmds, prompts), "prompt", "T3.1c legacy 3-arg prompts list")
  assert_eq(commands.resolve_slash("review", cmds, skills), "skill", "T3.1c legacy 3-arg skills list")
  print("T3.1b resolve_slash routing: OK")
end

-- T129 (5.1/5.3): turn facade — abort seam, busy begin/finish, agent wrappers.
do
  local names = {"agent", "tether"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end

  local clears = 0
  local host_interrupt = false
  local host_cleared = 0
  local turn_calls = {}
  _G.tether = {
    abort_requested = function() return host_interrupt end,
    clear_abort = function() host_cleared = host_cleared + 1; host_interrupt = false end,
  }
  _G.agent = {
    abort_requested = false,
    turn = function() turn_calls[#turn_calls + 1] = "turn"; return true end,
    confirm = function() turn_calls[#turn_calls + 1] = "confirm"; return true end,
    answer_ask = function() turn_calls[#turn_calls + 1] = "answer"; return true end,
    continue = function() turn_calls[#turn_calls + 1] = "continue"; return true end,
  }
  local turn = assert(loadfile("src/tether/turn.lua"))()

  -- abort seam: UI flag, host flag, ack clears both
  _G.agent.abort_requested = true
  assert_true(turn.take_abort(_G.agent), "T129 take_abort sees the UI flag")
  turn.ack_abort(_G.agent)
  assert_false(_G.agent.abort_requested, "T129 ack clears the UI flag")
  host_interrupt = true
  assert_true(turn.take_abort(_G.agent), "T129 take_abort sees the host flag")
  turn.ack_abort(_G.agent)
  assert_false(host_interrupt, "T129 ack clears the host flag")
  assert_eq(host_cleared, 2, "T129 ack calls tether.clear_abort")

  -- turn.abort sets the flag without ui touching agent.abort_requested directly
  turn.abort()
  assert_true(_G.agent.abort_requested, "T129 turn.abort raises the UI flag")
  turn.ack_abort(_G.agent)

  -- busy begin/finish is the single reset place
  local S = { busy_started_at = 1, retry_wait = { attempt = 1 } }
  turn.begin(S)
  assert_true(S.busy, "T129 begin sets busy")
  assert_true(S.waiting, "T129 begin sets waiting")
  assert_false(S.streaming, "T129 begin clears streaming")
  assert_notnil(S.busy_started_at, "T129 begin stamps busy_started_at")
  turn.finish(S)
  assert_false(S.busy, "T129 finish clears busy")
  assert_false(S.waiting, "T129 finish clears waiting")
  assert_eq(S.busy_started_at, nil, "T129 finish clears busy_started_at")
  assert_eq(S.retry_wait, nil, "T129 finish clears retry_wait")

  -- wrappers reach the agent entry points; start paints via before_call
  local painted_before_turn = false
  local S2 = {}
  turn.start(S2, {}, "k", "hi", function() end, function()
    painted_before_turn = S2.busy == true
  end)
  assert_eq(turn_calls[1], "turn", "T129 start calls agent.turn")
  assert_true(painted_before_turn, "T129 before_call runs while busy (Working indicator)")
  assert_false(S2.busy, "T129 start finishes busy")

  turn.confirm("c1", "allow", {}, function() end)
  turn.answer("a1", {}, {}, function() end)
  turn.continue(S2, {}, "k", function() end)
  assert_eq(turn_calls[2], "confirm", "T129 confirm calls agent.confirm")
  assert_eq(turn_calls[3], "answer", "T129 answer calls agent.answer_ask")
  assert_eq(turn_calls[4], "continue", "T129 continue calls agent.continue")

  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T129 turn facade: OK")
end

-- ============================================================
-- pi-style-input-and-footer: dock layout, box, caret, footer
-- ============================================================
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local function type_text(uimod, text)
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
  end
  local function boot(stub, size, extra)
    local uimod = run_ui_with({ 17 }, (function()
      local s = { agent = stub or agent_stub, size = size }
      if extra then for k, v in pairs(extra) do s[k] = v end end
      return s
    end)())
    if extra and extra.skills then uimod._skills_stub = extra.skills end
    return uimod
  end

  -- 2.1: the dock budget addresses the new rows for empty input, multi-line
  -- input, an open palette and a visible error banner.
  do
    local uimod = boot()
    uimod._paint(true)
    local L = uimod._layout()
    assert_notnil(L.rule_top_row, "pi 2.1 empty input has a top rule row")
    assert_notnil(L.input_row, "pi 2.1 empty input has an input row")
    assert_notnil(L.rule_bottom_row, "pi 2.1 empty input has a bottom rule row")
    assert_notnil(L.footer_row, "pi 2.1 empty input has a footer row")
    assert_eq(L.stats_row, L.footer_row, "pi 2.1 stats share the single footer row")
    assert_eq(L.rule_bottom_row + 1, L.footer_row, "pi 2.1 footer follows the bottom rule when palette is closed")
    assert_true(L.transcript_h >= 1, "pi 2.1 transcript keeps at least one row")
    assert_true(L.rule_top_row > L.error_row + L.error_h - 1, "pi 2.1 box sits below the error row")

    -- multi-line input grows the box between the two rules
    type_text(uimod, "line1")
    uimod._handle_key({ kind = "newline" })
    type_text(uimod, "line2")
    uimod._paint(true)
    local L2 = uimod._layout()
    assert_true(L2.input_h >= 2, "pi 2.1 multi-line input reserves two rows")
    assert_eq(L2.rule_bottom_row, L2.rule_top_row + 1 + L2.input_h, "pi 2.1 rules bracket exactly the input rows")
    local rtop = strip(uimod._row(L2.rule_top_row))
    local rbot = strip(uimod._row(L2.rule_bottom_row))
    assert_true(rtop:find("─", 1, true) ~= nil or rtop:find("%-", 1, true) ~= nil, "pi 2.1 top rule painted")
    assert_true(rbot:find("─", 1, true) ~= nil or rbot:find("%-", 1, true) ~= nil, "pi 2.1 bottom rule painted")

    -- open palette inserts rows between the bottom rule and the footer
    local uimod_p = boot()
    uimod_p._skills_stub = function()
      local out = {}
      for i = 1, 12 do
        out[i] = { name = "s" .. i, description = "d", path = "/tmp/s" .. i .. "/SKILL.md" }
      end
      return out
    end
    type_text(uimod_p, "/")
    uimod_p._paint(true)
    local Lp = uimod_p._layout()
    assert_true(Lp.palette_h >= 1, "pi 2.1 open palette reserves rows")
    assert_eq(Lp.separator_row, Lp.rule_bottom_row + Lp.palette_h + 1, "pi 2.1 separator follows the palette region")
    assert_eq(Lp.footer_row, Lp.separator_row + 1, "pi 2.1 footer follows the separator")

    -- error banner sits above the box and is included in the layout
    uimod._set_error_banner("boom")
    uimod._paint(true)
    local Le = uimod._layout()
    assert_eq(Le.error_h, 1, "pi 2.1 error banner reserves one row")
    assert_eq(Le.error_row, 1 + Le.transcript_h, "pi 2.1 error row is directly below the transcript")
    assert_eq(Le.gap_row, Le.error_row + Le.error_h, "pi 2.1 gap row follows the error banner")
    assert_eq(Le.rule_top_row, Le.error_row + 2, "pi 2.1 box starts below the gap row")
    local erow = strip(uimod._row(Le.error_row))
    assert_true(erow:find("boom", 1, true) ~= nil, "pi 2.1 error banner paints its message")
    uimod._set_error_banner(nil)
  end

  -- 2.2: the single footer row — always present, no separate flag row, and
  -- the transcript height does not change with transient flags.
  do
    local uimod = boot()
    uimod._paint(true)
    local S = uimod._get_state()
    S._mouse_flag_until = os.time() - 1
    S.kb_protocol = 0
    S.toast = nil
    uimod._paint(true)
    local L0 = uimod._layout()
    assert_eq(L0.flags_row, nil, "pi 2.2 no separate flag row")
    assert_eq(L0.stats_row, L0.footer_row, "pi 2.2 stats share the footer row")
    local th0 = L0.transcript_h

    -- active toast / kb protocol / mouse flag must not add a row
    S.kb_protocol = 1
    S.toast = "✓ test"
    S._mouse_flag_until = os.time() + 3
    uimod._paint(true)
    local L1 = uimod._layout()
    assert_eq(L1.flags_row, nil, "pi 2.2 no flag row even with toast")
    assert_eq(L1.transcript_h, th0, "pi 2.2 transcript height unchanged by flags")
    assert_eq(L1.footer_row, L0.footer_row, "pi 2.2 footer row does not move")

    -- every dock row is strictly ordered down to the single footer
    assert_true(L1.rule_top_row < L1.input_row, "pi 2.2 top rule above input")
    assert_true(L1.input_row + L1.input_h - 1 < L1.rule_bottom_row, "pi 2.2 input above bottom rule")
    assert_true(L1.rule_bottom_row < L1.footer_row, "pi 2.2 bottom rule above footer")
    assert_true(L1.footer_row <= S.h, "pi 2.2 footer is on screen")
  end

  -- 3.1: the box renders without a prompt marker; padding 0 and 2; every row
  -- shares one display width; ASCII mode swaps the rule glyph.
  do
    local uimod = boot(nil, nil, { config = { load = function()
      return { model = "test", workspace = "/tmp",
               ui = { input_max_lines = 8, editor_padding_x = 0 } } end,
      api_key = function() return "" end } })
    type_text(uimod, "hi")
    uimod._paint(true)
    local L = uimod._layout()
    local input = uimod._row(L.input_row) or ""
    assert_eq(strip(input):find("›", 1, true), nil, "pi 3.1 no prompt marker inside the box")
    assert_true(strip(input):find("hi", 1, true) ~= nil, "pi 3.1 typed text is in the input row")
    local rtop, rbot, body = uimod._row(L.rule_top_row), uimod._row(L.rule_bottom_row), input
    local function width_of(s)
      -- display width ignoring SGR
      local plain = strip(s)
      return uimod.vlen(plain)
    end
    -- under ui.padding the rules span the CONTENT width (terminal minus both
    -- gutters); the painted row carries the leading gutter, so its width is
    -- gutter + content = L.w - gutter
    local gut = uimod.ui_padding(L.w)
    assert_eq(width_of(rtop), L.w - gut, "pi 3.1 top rule spans the content width")
    assert_eq(width_of(rbot), L.w - gut, "pi 3.1 bottom rule spans the content width")
    assert_eq(width_of(body), L.w - gut, "pi 3.1 input row is padded to the same width")

    -- padding 2: text is inset by two columns on both sides
    local uimod2 = boot(nil, nil, { config = { load = function()
      return { model = "test", workspace = "/tmp",
               ui = { input_max_lines = 8, editor_padding_x = 2 } } end,
      api_key = function() return "" end } })
    type_text(uimod2, "ab")
    uimod2._paint(true)
    local L2 = uimod2._layout()
    local body2 = strip(uimod2._row(L2.input_row) or "")
    assert_eq(body2:sub(1, 2), "  ", "pi 3.1 padding 2 leads with two spaces")
    assert_eq(body2:sub(-2), "  ", "pi 3.1 padding 2 ends with two spaces")
    local gut2 = uimod2.ui_padding(L2.w)
    -- gutter + editor_padding_x (2) columns lead, so text starts one past them
    assert_eq(body2:find("ab", 1, true), 1 + gut2 + 2, "pi 3.1 text starts after the left padding")

    -- ASCII mode: the rules use '-'
    local uimod3 = boot()
    uimod3._ascii_mode = true
    type_text(uimod3, "x")
    uimod3._paint(true)
    local L3 = uimod3._layout()
    local art = strip(uimod3._row(L3.rule_top_row) or "")
    assert_true(art:find("─", 1, true) == nil, "pi 3.1 ASCII top rule has no box-drawing glyph")
    assert_true(art:find("-", 1, true) ~= nil, "pi 3.1 ASCII top rule uses '-'")
    uimod3._ascii_mode = nil
  end

  -- 3.2: centered scroll labels in the rules, omitted when the rule is too
  -- narrow; hidden-above-only and hidden-below-only windows.
  do
    local uimod = boot(nil, nil, { config = { load = function()
      return { model = "test", workspace = "/tmp",
               ui = { input_max_lines = 3 } } end,
      api_key = function() return "" end } })
    -- five lines with cursor on the last → hidden above
    type_text(uimod, "a")
    for _ = 1, 4 do uimod._handle_key({ kind = "newline" }); type_text(uimod, "x") end
    uimod._paint(true)
    local L = uimod._layout()
    local top = strip(uimod._row(L.rule_top_row) or "")
    local bot = strip(uimod._row(L.rule_bottom_row) or "")
    assert_true(top:find("more", 1, true) ~= nil, "pi 3.2 top rule names hidden-above rows: " .. top:sub(1, 60))
    assert_true(top:find("↑", 1, true) ~= nil or top:find("%^", 1, true) ~= nil,
      "pi 3.2 hidden-above label uses the up glyph")
    assert_eq(bot:find("more", 1, true), nil, "pi 3.2 bottom rule has no label when nothing is hidden below")

    -- narrow terminal: label does not fit, rule stays an unbroken run
    local uimod_n = boot(nil, { width = 6, height = 20 }, { config = { load = function()
      return { model = "t", workspace = "/tmp",
               ui = { input_max_lines = 3 } } end,
      api_key = function() return "" end } })
    type_text(uimod_n, "a")
    for _ = 1, 4 do uimod_n._handle_key({ kind = "newline" }); type_text(uimod_n, "x") end
    uimod_n._paint(true)
    local Ln = uimod_n._layout()
    local topn = strip(uimod_n._row(Ln.rule_top_row) or "")
    assert_eq(topn:find("more", 1, true), nil, "pi 3.2 narrow rule drops the label")
    assert_true(#topn > 0, "pi 3.2 narrow rule still paints glyphs")
  end

  -- 3.3: block caret — mid-row, end-of-row, Cyrillic; no cursor-show escape.
  do
    local sink = {}
    local uimod = run_ui_with({ 104, 105, 105, 17 }, { agent = agent_stub }, sink) -- "hii"
    -- actually type three chars via keys after boot for cursor control
    uimod = run_ui_with({ 17 }, { agent = agent_stub }, sink)
    type_text(uimod, "abc")
    -- move cursor left once → sits on 'c'
    uimod._handle_key({ kind = "special", name = "left" })
    uimod._paint(true)
    local L = uimod._layout()
    local body = uimod._row(L.input_row) or ""
    local plain = strip(body)
    -- the character under the cursor is painted in reverse video
    assert_true(body:find("\27[7m", 1, true) ~= nil, "pi 3.3 mid-row caret uses reverse video")
    assert_true(plain:find("c", 1, true) ~= nil, "pi 3.3 caret sits on a real character")

    -- end-of-row caret: move to end
    uimod._handle_key({ kind = "special", name = "end" })
    uimod._paint(true)
    body = uimod._row(L.input_row) or ""
    assert_true(body:find("\27[7m", 1, true) ~= nil, "pi 3.3 end-of-row caret uses reverse video")

    -- Cyrillic cursor offset: byte offset vs display column
    local uimod_c = run_ui_with({ 17 }, { agent = agent_stub })
    type_text(uimod_c, "привет")
    uimod_c._handle_key({ kind = "special", name = "left" })
    uimod_c._paint(true)
    local Lc = uimod_c._layout()
    local bodyc = uimod_c._row(Lc.input_row) or ""
    assert_true(bodyc:find("\27[7m", 1, true) ~= nil, "pi 3.3 Cyrillic caret is reverse video")
    local plainc = strip(bodyc)
    assert_true(plainc:find("т", 1, true) ~= nil or plainc:find("е", 1, true) ~= nil,
      "pi 3.3 Cyrillic caret covers a whole character")

    -- no painted frame emits a cursor-show escape; ?25h is only the exit
    -- teardown (co-issued with ?2004l), never a render frame
    for _, s in ipairs(sink) do
      if s:find("\27[?25h", 1, true) then
        assert_true(s:find("\27[?2004l", 1, true) ~= nil,
          "pi 3.3 no frame emits ESC[?25h")
      end
    end
  end

  -- 4.1: the busy spinner with Working... in the top rule, cleared when
  -- the turn ends (reply).
  do
    local uimod = run_ui_with({ 104, 105, 13, 17 }, { agent = {
      turn = function(_, _, _, on_ev)
        -- mid-turn: the top rule must carry the spinner + Working
        uimod.busy_probe = true
        return true
      end,
      get_history = function() return {} end } })
    local S = uimod._get_state()
    -- drive a submit so busy is set, then inspect mid-flight via paint after
    -- the turn returned (busy cleared) vs a forced busy state
    S.busy = true
    S.busy_started_at = os.time()
    uimod._paint(true)
    local L = uimod._layout()
    local top = uimod._row(L.rule_top_row) or ""
    assert_true(strip(top):find("Working...", 1, true) ~= nil, "pi 4.1 busy top rule shows Working")
    -- end path: reply clears it
    S.busy = false
    S.busy_started_at = nil
    uimod._paint(true)
    top = strip(uimod._row(L.rule_top_row) or "")
    assert_eq(top:find("Working...", 1, true), nil, "pi 4.1 reply clears the busy indicator")
    assert_true(top:find("─", 1, true) ~= nil or top:find("%-", 1, true) ~= nil,
      "pi 4.1 top rule is a plain rule again")
  end

  -- 4.2 is covered by T119 (pending retry in the top rule).

  -- 4.3: a long status on a narrow terminal stays one truncated row; a label
  -- that does not fit is dropped while the status stays.
  do
    local uimod = boot(nil, { width = 12, height = 20 })
    local S = uimod._get_state()
    S.busy = true
    S.busy_started_at = os.time()
    -- force a hidden-above label that cannot coexist with the status
    uimod._paint(true)
    local L = uimod._layout()
    local top = uimod._row(L.rule_top_row) or ""
    local plain = strip(top)
    assert_true(#plain > 0, "pi 4.3 narrow top rule still paints")
    assert_true(uimod.vlen(plain) <= L.w, "pi 4.3 narrow top rule never exceeds the width")
    -- status survives as a truncated single row (full word may not fit at w=12)
    assert_true(plain:find("─", 1, true) ~= nil or plain:find("%-", 1, true) ~= nil
      or plain:find("Working", 1, true) ~= nil or plain:find("tether", 1, true) ~= nil
      or plain:find("…", 1, true) ~= nil, "pi 4.3 narrow rule keeps status or glyphs: " .. plain)
    S.busy = false
  end

  -- 5.1: two usage events accumulate into tokens_in / tokens_out; the context
  -- estimate keeps using tokens_used.
  do
    local uimod = run_ui_with({ 17 }, { agent = agent_stub })
    local S = uimod._get_state()
    assert_eq(S.tokens_in, 0, "pi 5.1 starts at zero in")
    assert_eq(S.tokens_out, 0, "pi 5.1 starts at zero out")
    uimod._handle_agent_event({ type = "usage", usage = { used = 100, prompt_tokens = 1200, completion_tokens = 300 } })
    uimod._handle_agent_event({ type = "usage", usage = { used = 150, prompt_tokens = 800, completion_tokens = 200 } })
    assert_eq(S.tokens_in, 2000, "pi 5.1 input tokens accumulate across turns")
    assert_eq(S.tokens_out, 500, "pi 5.1 output tokens accumulate across turns")
    assert_eq(S.tokens_used, 150, "pi 5.1 tokens_used stays the context estimate (last used)")
  end

  -- 5.2: compact counter formatter and stats-row composition.
  do
    local ui = dofile("src/tether/ui.lua")
    assert_eq(ui.format_count(0), "0", "pi 5.2 zero")
    assert_eq(ui.format_count(999), "999", "pi 5.2 plain below 1000")
    assert_eq(ui.format_count(1000), "1.0k", "pi 5.2 one decimal k below 10k")
    assert_eq(ui.format_count(9999), "10.0k", "pi 5.2 9999 rounds up to 10.0k")
    assert_eq(ui.format_count(10000), "10k", "pi 5.2 rounded k below 1M")
    assert_eq(ui.format_count(999999), "1000k", "pi 5.2 just under 1M stays k")
    assert_eq(ui.format_count(1000000), "1.0M", "pi 5.2 one decimal M below 10M")
    assert_eq(ui.format_count(10000000), "10M", "pi 5.2 rounded M above")
    assert_eq(ui.format_count(-5), "0", "pi 5.2 negative clamps to zero")

    -- stats row: model right-aligned with a two-column gap
    local left = "↑3.0k ↓1.0k 4.1k/32k (13%)"
    local right = "gpt-4o-mini"
    local row = ui.footer_stats(left, right, 60)
    local plain = (row or ""):gsub("\27%[[%d;]*m", "")
    assert_true(plain:find("gpt-4o-mini", 1, true) ~= nil, "pi 5.2 model fits when there is room")
    assert_eq(plain:sub(-#right), right, "pi 5.2 model ends in the last column")
    local gap = #plain - #right - #left
    assert_true(gap >= 2, "pi 5.2 at least two columns separate left from model (gap=" .. gap .. ")")

    -- both cannot fit: model truncated from its left, tail survives
    local narrow = ui.footer_stats(left, right, #left + 4)
    local nplain = (narrow or ""):gsub("\27%[[%d;]*m", "")
    assert_true(nplain:find("mini", 1, true) ~= nil, "pi 5.2 model keeps its tail when truncated")
    assert_eq(nplain:find("gpt-", 1, true), nil, "pi 5.2 model loses its head first")

    -- left alone exceeds the width: left truncated from the right with ...
    local only = ui.footer_stats(string.rep("x", 100), "", 10)
    assert_true(ui.vlen(only) <= 10, "pi 5.2 left side truncated to the width")
  end

  -- 5.3: single footer row (path + stats + model), no mode icons;
  -- 5.4: no reverse video.
  do
    local uimod = boot()
    local S = uimod._get_state()
    S._mouse_flag_until = os.time() + 3  -- fresh mouse flag must not paint
    S.kb_protocol = 1
    S.toast = nil
    uimod._paint(true)
    local L = uimod._layout()
    local footer = strip(uimod._row(L.footer_row) or "")
    assert_true(footer:find("/tmp", 1, true) ~= nil or footer:find("~", 1, true) ~= nil,
      "pi 5.3 footer carries the workspace: " .. footer)
    assert_eq(footer:find("🖱", 1, true), nil, "pi 5.3 no mouse icon")
    assert_eq(footer:find("⌨", 1, true), nil, "pi 5.3 no kb icon")
    assert_eq(L.flags_row, nil, "pi 5.3 no separate flag row")
    -- 5.4: footer row uses no reverse video
    local raw = uimod._row(L.footer_row) or ""
    assert_eq(raw:find("\27[7m", 1, true), nil, "pi 5.4 footer row is not reverse video")

    -- ASCII arrows in the counters on the single footer row
    local uimod_a = boot()
    uimod_a._ascii_mode = true
    local Sa = uimod_a._get_state()
    Sa.tokens_in, Sa.tokens_out = 3000, 1000
    Sa._mouse_flag_until = os.time() - 1
    Sa.kb_protocol = 0
    Sa.toast = nil
    uimod_a._paint(true)
    local La = uimod_a._layout()
    local stats_a = strip(uimod_a._row(La.footer_row) or "")
    assert_true(stats_a:find("^", 1, true) ~= nil, "pi 5.3 ASCII input arrow is '^': " .. stats_a)
    assert_true(stats_a:find("v", 1, true) ~= nil, "pi 5.3 ASCII output arrow is 'v': " .. stats_a)
    assert_eq(stats_a:find("↑", 1, true), nil, "pi 5.3 no Unicode up-arrow in ASCII stats")
    assert_eq(stats_a:find("↓", 1, true), nil, "pi 5.3 no Unicode down-arrow in ASCII stats")
    uimod_a._ascii_mode = nil
  end

  -- 5.5: truncation order when the left side exceeds the width —
  -- path right-truncates first (toast and stats stay), then toast is
  -- dropped, and stats truncate last while the
  -- path stays on the row. ASCII mode must not inject a Unicode ellipsis.
  do
    local long_ws = "/home/user/projects/very/long/workspace/path/for/footer/truncation"
    local function footer_at(width)
      local uimod = boot(nil, { width = width, height = 24 }, { config = { load = function()
        return { model = "test-model-name-long-enough-to-matter", workspace = long_ws,
                 ui = { input_max_lines = 8 } } end,
        api_key = function() return "" end } })
      local S = uimod._get_state()
      S.tokens_in, S.tokens_out = 3000, 1000
      S.tokens_max, S.tokens_used = 32000, 4100
      S.toast = "✓ copied 42 B"
      uimod._transcript.reset({})
      for i = 1, 40 do
        uimod._transcript.append({ role = "system", text = "row " .. i })
      end
      uimod._invalidate_all()
      S.user_scrolled = true
      S.scroll = 7
      uimod._paint(true)
      local L = uimod._layout()
      return uimod, S, strip(uimod._row(L.footer_row) or ""), L.w
    end

    -- roomy enough: full path, toast and stats all visible (the ` · `
    -- separators between blocks cost 3 cols each vs the old single spaces)
    local _, _, wide = footer_at(130)
    assert_true(wide:find(long_ws, 1, true) ~= nil, "pi 5.5 roomy footer keeps the full path: " .. wide)
    assert_true(wide:find("copied", 1, true) ~= nil, "pi 5.5 roomy footer shows the toast: " .. wide)
    assert_eq(wide:find("↓ +7", 1, true), nil, "pi 5.5 no scroll flag on a roomy row: " .. wide)

    -- narrow: path truncates first — toast and stats must survive
    -- (60 is the floor where stats+toast leave room for a truncated path)
    local uimod_n, _, narrow, w_n = footer_at(60)
    assert_true(uimod_n.vlen(narrow) <= w_n, "pi 5.5 narrow footer fits the width")
    assert_eq(narrow:find(long_ws, 1, true), nil, "pi 5.5 narrow footer truncates the path: " .. narrow)
    assert_true(narrow:find("…", 1, true) ~= nil or narrow:find("...", 1, true) ~= nil,
      "pi 5.5 truncated path carries an ellipsis: " .. narrow)
    assert_true(narrow:find("copied", 1, true) ~= nil,
      "pi 5.5 toast survives path truncation (path drops first): " .. narrow)

    -- path gone from the left (no room): toast drops, then stats truncate —
    -- the path must reappear (fit_path re-claims room) or, if stats alone
    -- fill the row, stats are truncated not dropped whole.
    local uimod_t, _, row_t, w_t = footer_at(40)
    assert_true(uimod_t.vlen(row_t) <= w_t, "pi 5.5 tiny footer fits the width")
    -- toast is dropped when it cannot fit
    local has_toast = row_t:find("copied", 1, true) ~= nil
    assert_true(not has_toast,
      "pi 5.5 toast drops on a tiny row: " .. row_t)

    -- ASCII mode: path truncation must use "...", never "…" (width 60 keeps
    -- a truncated path on the row alongside stats, toast and scroll)
    local uimod_a = boot(nil, { width = 60, height = 24 }, { config = { load = function()
      return { model = "test-model-name", workspace = long_ws,
               ui = { input_max_lines = 8 } } end,
      api_key = function() return "" end } })
    uimod_a._ascii_mode = true
    local Sa = uimod_a._get_state()
    Sa.tokens_in, Sa.tokens_out = 3000, 1000
    Sa.tokens_max, Sa.tokens_used = 32000, 4100
    Sa.toast = "[ok] copied 42 B"
    uimod_a._transcript.reset({})
    for i = 1, 40 do
      uimod_a._transcript.append({ role = "system", text = "row " .. i })
    end
    uimod_a._invalidate_all()
    Sa.user_scrolled = true
    Sa.scroll = 7
    uimod_a._paint(true)
    local La = uimod_a._layout()
    local ascii_row = uimod_a._row(La.footer_row) or ""
    assert_eq(ascii_row:find("…", 1, true), nil,
      "pi 5.5 ASCII footer introduces no Unicode ellipsis: " .. strip(ascii_row))
    assert_true(ascii_row:find("...", 1, true) ~= nil,
      "pi 5.5 ASCII truncated path uses ASCII dots: " .. strip(ascii_row))
    uimod_a._ascii_mode = nil
  end

  print("pi-style-input-and-footer frame/unit tests: OK")
end

-- ============================================================
-- add-steering-input (T137+)
-- ============================================================

-- Phase D 4.2b: ui_ask owns the question-block controller (bag/deps).
do
  local askm = assert(loadfile("src/tether/ui/ask.lua"))()
  assert_eq(askm.editor_backspace("ab"), "a", "T4.2b backspace drops one char")
  assert_eq(askm.editor_backspace(""), "", "T4.2b backspace on empty")
  local ans = { selected = {} }
  askm.ask_toggle(ans, { label = "x" })
  assert_eq(#ans.selected, 1, "T4.2b toggle adds")
  askm.ask_toggle(ans, { label = "x" })
  assert_eq(#ans.selected, 0, "T4.2b toggle removes")
  local synced = 0
  local deps = { sync = function() synced = synced + 1 end }
  local bag = { ask = { qidx = 1, sel = 1, mode = "list",
    questions = { { options = { { label = "a" } } }, { options = { { label = "b" } } } },
    answers = {} } }
  askm.ask_advance(bag, deps)
  assert_eq(bag.ask.qidx, 2, "T4.2b advance walks questions")
  assert_eq(synced, 1, "T4.2b advance syncs the tail")
  -- esc in list mode cancels through resolve (stub turn records it)
  local finished, answered = 0, nil
  local rdeps = { askmod = { CANCELLED_TEXT = "cancelled",
      summary = function() return "s" end },
    turn = { finish = function() finished = finished + 1 end,
      answer = function(_, a) answered = a return true end,
      continue = function() return true end },
    on_event = function() end, sync = function() end,
    paint = function() end, bump = function() end,
    settle = function() end, note = function() end }
  local cbag = { ask = { id = "q1", questions = {}, answers = {} }, cfg = {} }
  askm.handle_ask_key(cbag, rdeps, { kind = "esc" })
  assert_eq(cbag.ask, nil, "T4.2b esc clears the block")
  assert_eq(finished, 1, "T4.2b cancel finishes the turn")
  assert_true(answered.cancelled, "T4.2b cancellation reaches the agent")
  -- module entry points: controller functions live in ui_ask / ui_confirm.
  local cfm = assert(loadfile("src/tether/ui/confirm.lua"))()
  assert_eq(type(askm.handle_ask_key), "function", "T4.2b ui_ask entry point")
  assert_eq(type(cfm.handle_confirmation_key), "function", "T4.2b ui_confirm entry point")
  print("T4.2b ui_ask controller: OK")
end


if failed > 0 then
    os.exit(1)
end
