--[[--
Background work: jobs that run while the reader stays usable.

A job is a coroutine driven by the reader's event loop. It gives the reader
its turn regularly (`Bg.pause`, called from the progress reports), and it
waits for the network without blocking anything: each request is carried out
by a child process (`Bg.run`), several at once where they do not depend on
each other.

Work that must not be interleaved with what the user does - a document's
annotations are read, merged, uploaded and written back - runs as a critical
section (`Bg.critical`): inside one the job does not pause, and requests are
made right here, holding up the reader for their duration.

Outside a job (and when `Bg.async` is false, as in most tests) everything
simply runs at once, here.
]]

local logger = require("logger")

-- slice: how long a job may run before it lets the reader handle input
local Bg = { fork = "0.6", async = true, max_children = 4, slice = 0.08 }

-- how long a job then waits (input is only read when no task is due)
local GAP = 0.015

local jobs = {}     -- coroutine -> job
local running = {}  -- jobs, in the order they were started
local listeners = {}
local children = 0  -- child processes running, all jobs together

local function now()
    local ok, time = pcall(require, "ui/time")
    if ok and time and time.now then return time.to_s(time.now()) end
    return os.time()
end

local function UI()
    return require("ui/uimanager")
end

local function changed(job)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, job)
        if not ok then logger.warn("Zotero: job listener failed:", tostring(err)) end
    end
end

--- Be told when a job starts, reports, or ends. fn(job)
function Bg.listen(fn) listeners[#listeners + 1] = fn end
function Bg.unlisten(fn)
    for i = #listeners, 1, -1 do if listeners[i] == fn then table.remove(listeners, i) end end
end

--- The job the running code belongs to, or nil.
function Bg.current()
    local co = coroutine.running()
    return co and jobs[co] or nil
end

--- Jobs that are running (optionally only those of one kind).
function Bg.jobs(kind)
    local out = {}
    for _, job in ipairs(running) do
        if not job.done and (kind == nil or job.kind == kind) then out[#out + 1] = job end
    end
    return out
end

function Bg.busy(kind) return #Bg.jobs(kind) > 0 end

--- Seconds since the job started.
function Bg.age(job) return now() - (job.started_at or now()) end

local function finish(job)
    if job.finished then return end
    job.finished = true
    job.done = true
    jobs[job.co] = nil
    for i = #running, 1, -1 do if running[i] == job then table.remove(running, i) end end
    if job.prevent_standby then pcall(function() UI():allowStandby() end) end
    changed(job)
    if job.on_done then
        local ok, err = xpcall(job.on_done, debug.traceback, job)
        if not ok then logger.err("Zotero: after the job", job.name, ":", tostring(err)) end
    end
end

local function step(job, ...)
    if job.done then return end
    job.slice_started = now()
    local ok, err = coroutine.resume(job.co, ...)
    if not ok then
        job.ok, job.error = false, tostring(err)
        logger.err("Zotero: job", job.name, "failed:", job.error)
    end
    if coroutine.status(job.co) == "dead" then finish(job) end
end

--- Start a job. fn(job) runs in it; whatever it returns is job.result.
-- opts.kind: what sort of job ("sync", "download", ...)
-- opts.on_done(job): when it has ended (job.ok, job.error, job.result, job.stopped)
-- @return the job
function Bg.start(name, fn, opts)
    opts = opts or {}
    local job = {
        name = name, kind = opts.kind or name, status = opts.status or "", fraction = nil,
        started = os.time(), started_at = now(), on_done = opts.on_done, critical = 0, data = opts.data or {},
    }
    job.co = coroutine.create(function()
        local ok, res = xpcall(fn, debug.traceback, job)
        job.ok = ok
        if ok then job.result = res else job.error = tostring(res) end
    end)
    jobs[job.co] = job
    running[#running + 1] = job
    if opts.prevent_standby ~= false then
        job.prevent_standby = pcall(function() UI():preventStandby() end)
    end
    changed(job)
    UI():nextTick(function() step(job) end)
    return job
end

--- Ask a job to stop. It stops at its next pause, between two complete
-- pieces of work; requests it is waiting for are abandoned.
function Bg.stop(job)
    if job and not job.done then
        job.stopped = true
        changed(job)
    end
end

--- Has the running job been asked to stop?
function Bg.stopped()
    local job = Bg.current()
    return job ~= nil and job.stopped == true
end

--- What the job is doing, for the indicator. fraction: 0..1 or nil
function Bg.status(text, fraction)
    local job = Bg.current()
    if not job then return end
    if text ~= nil then job.status = tostring(text) end
    job.fraction = fraction
    changed(job)
end

local function yield_for(job, seconds)
    local co = job.co
    UI():scheduleIn(seconds, function()
        if jobs[co] then step(job) end
    end)
    coroutine.yield()
end

--- Give the reader its turn, if the job has had the processor long enough.
-- Does nothing outside a job and inside a critical section.
-- @return false when the job has been asked to stop
function Bg.pause(force)
    local job = Bg.current()
    if not job then return true end
    if job.critical == 0 and (force or now() - (job.slice_started or 0) >= Bg.slice) then
        yield_for(job, GAP)
    end
    return not job.stopped
end

--- Wait without holding up the reader (outside a job: sleep).
function Bg.sleep(seconds)
    local job = Bg.current()
    if job and job.critical == 0 then
        yield_for(job, seconds)
    else
        local ok, ffiutil = pcall(require, "ffi/util")
        if ok and ffiutil.usleep then ffiutil.usleep(math.floor(seconds * 1e6)) end
    end
end

--- Run fn(...) without pausing: nothing the user does can happen in between.
function Bg.critical(fn, ...)
    local job = Bg.current()
    if job then job.critical = job.critical + 1 end
    local res = table.pack(pcall(fn, ...))
    if job then job.critical = job.critical - 1 end
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

-- ---------------------------------------------------------------------------
-- Child processes
-- ---------------------------------------------------------------------------

local function spawn(task)
    local ffiutil = require("ffi/util")
    local buffer = require("string.buffer")
    local fn, args = task.fn, task.args or {}
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, res = pcall(fn, unpack(args, 1, args.n or #args))
        if not ok then res = { err = tostring(res) } end
        if type(res) ~= "table" then res = { value = res } end
        local eok, data = pcall(buffer.encode, res)
        if not eok then data = buffer.encode({ err = "result could not be passed on: " .. tostring(data) }) end
        ffiutil.writeToFD(write_fd, data, true)
    end, true)
    if not pid then return nil, fd end
    return { pid = pid, fd = fd, task = task }
end

-- child processes that ended without a usable answer (a crash): after two,
-- requests are made in the reader for the rest of the session
local broken_children = 0

local function run_here(task)
    local args = task.args or {}
    local ok, res = pcall(task.fn, unpack(args, 1, args.n or #args))
    if not ok then return { err = tostring(res) } end
    return type(res) == "table" and res or { value = res }
end

local function collect(child)
    local ffiutil = require("ffi/util")
    local buffer = require("string.buffer")
    local data = child.fd and ffiutil.readAllFromFD(child.fd) or ""
    child.fd = nil
    ffiutil.isSubProcessDone(child.pid, true)
    local ok, res = false, nil
    if data ~= "" then ok, res = pcall(buffer.decode, data) end
    if not ok or type(res) ~= "table" then
        broken_children = broken_children + 1
        logger.warn("Zotero: a background request ended without an answer; it is made here instead",
            broken_children >= 2 and "(and so are all others from now on)" or "")
        if broken_children >= 2 then Bg.async = false end
        return run_here(child.task)
    end
    return res
end

local function abandon(child)
    local ffiutil = require("ffi/util")
    pcall(ffiutil.terminateSubProcess, child.pid)
    local function reap()
        if child.fd and ffiutil.getNonBlockingReadSize(child.fd) ~= 0 then
            pcall(ffiutil.readAllFromFD, child.fd)
            child.fd = nil
        end
        if ffiutil.isSubProcessDone(child.pid) then
            if child.fd then pcall(ffiutil.readAllFromFD, child.fd); child.fd = nil end
        else
            UI():scheduleIn(2, reap)
        end
    end
    UI():scheduleIn(0.5, reap)
end

--- Carry out tasks, each fn(args...) -> table, at most `limit` at once.
-- In a job (and not in a critical section) every task runs in a child
-- process while the job waits; elsewhere they run one after the other, here.
-- task = { fn = f, args = { ... }, poll = function() end (called while it runs),
--         done = function(result) end (called as soon as it has ended) }
-- @return results, in the order of the tasks ({ err = "stopped" } for those
--         abandoned because the job was stopped)
function Bg.run(tasks, limit)
    local job = Bg.current()
    local results = {}
    local inline = not (Bg.async and job and job.critical == 0)
    if inline then
        for i, task in ipairs(tasks) do
            if job and job.stopped and job.critical == 0 then
                results[i] = { err = "stopped" }
            else
                local args = task.args or {}
                local ok, res = pcall(task.fn, unpack(args, 1, args.n or #args))
                if not ok then res = { err = tostring(res) } end
                results[i] = type(res) == "table" and res or { value = res }
                if task.done then task.done(results[i]) end
            end
        end
        return results
    end
    limit = math.max(1, limit or 1)
    local next_task, active, interval = 1, {}, 0.03
    while true do
        -- start what may be started
        while next_task <= #tasks and #active < limit and children < Bg.max_children and not job.stopped do
            local child, err = spawn(tasks[next_task])
            if child then
                child.index = next_task
                children = children + 1
                active[#active + 1] = child
            else
                -- no child process to be had: do it here
                logger.warn("Zotero: no child process (", tostring(err), "); the request is made here")
                local task = tasks[next_task]
                local args = task.args or {}
                local ok, res = pcall(task.fn, unpack(args, 1, args.n or #args))
                results[next_task] = ok and (type(res) == "table" and res or { value = res }) or { err = tostring(res) }
                if task.done then task.done(results[next_task]) end
            end
            next_task = next_task + 1
        end
        if #active == 0 then
            if next_task > #tasks or job.stopped then break end
            -- (other jobs' children fill the quota: wait for a place)
        end
        if job.stopped then
            for _, child in ipairs(active) do
                children = children - 1
                abandon(child)
                results[child.index] = { err = "stopped" }
            end
            active = {}
            break
        end
        yield_for(job, interval)
        interval = math.min(interval * 1.3, 0.25)
        local ffiutil = require("ffi/util")
        for i = #active, 1, -1 do
            local child = active[i]
            if child.task.poll then pcall(child.task.poll) end
            local ready = child.fd and ffiutil.getNonBlockingReadSize(child.fd) ~= 0
            if ready or ffiutil.isSubProcessDone(child.pid) then
                results[child.index] = collect(child)
                children = children - 1
                table.remove(active, i)
                interval = 0.03
                if child.task.done then child.task.done(results[child.index]) end
            end
        end
    end
    for i = 1, #tasks do
        if results[i] == nil then results[i] = { err = "stopped" } end
    end
    return results
end

--- One task (see Bg.run). @return its result table
function Bg.call(fn, ...)
    return Bg.run({ { fn = fn, args = table.pack(...) } }, 1)[1]
end

-- for tests: run the reader's task queue until no job is left (or timeout)
function Bg._drain(timeout)
    local UIManager = UI()
    local ffiutil = require("ffi/util")
    local deadline = now() + (timeout or 60)
    while #Bg.jobs() > 0 and now() < deadline do
        UIManager:_checkTasks()
        ffiutil.usleep(2000)
    end
    UIManager:_checkTasks()
    return #Bg.jobs() == 0
end

return Bg
