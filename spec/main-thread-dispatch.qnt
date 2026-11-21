// main-thread-dispatch.qnt -- ON-MAIN, the task table and the application loop
// (src/window.lisp: REGISTER-TASK, TAKE-TASK, RUN-TASK, DISPATCH-TO-MAIN, ON-MAIN,
// RUN-APPLICATION, STOP-APPLICATION).
//
// What is modelled
//   * Two worker threads call ON-MAIN, each up to CALLS times, with :WAIT T or :WAIT NIL,
//     or call STOP-APPLICATION (an ON-MAIN :WAIT T whose function sends -stop:).
//   * A worker's call is three steps, as in the code: register the function in the
//     task table under the lock (REGISTER-TASK), hand the id to dispatch_async_f
//     (DISPATCH-TO-MAIN), then wait on the semaphore (WAIT-ON-SEMAPHORE).
//   * GCD's main queue is a FIFO list of ids. It is drained only while the main thread
//     is inside [NSApp run]; each drain pops one id and runs RUN-TASK (TAKE-TASK, then
//     the function, then the semaphore signal) as one atomic main-thread step.
//   * -stop: takes effect after the next event, so after the stop job runs the loop is
//     Stopping: it may still drain more jobs before [NSApp run] returns.
//   * The main thread may call ON-MAIN itself while it is not in the loop (a REPL on
//     the main thread, or ON-LAUNCH before [NSApp run]): :WAIT T runs in place,
//     :WAIT NIL only queues. RUN-APPLICATION may be called again after it returned.
//
// Designs (const DESIGN)
//   "now"        -- the code as it is.
//   "flag-check" -- a tempting fix: refuse :WAIT T once the loop has stopped, by
//                   checking a flag, and nothing else.
//   "guarded"    -- the proposed fix: the loop state lives under the tasks lock;
//                   ON-MAIN :WAIT T checks it and registers in one critical section, and
//                   when [NSApp run] returns the main thread, under the same lock, marks
//                   the loop Stopped, removes every registered task that has a waiter,
//                   records "cancelled" for it and signals its semaphore. :WAIT NIL work
//                   keeps today's meaning (it stays queued for the next loop).
//   TIMEOUT (guarded only): a waiter may also give up on its own.
//
// Simplified away: the result values and conditions passed back; the autorelease
// pool and float traps; ON-LAUNCH as a separate argument (it is a main-thread :WAIT NIL
// call); AppKit events other than the one STOP-APPLICATION posts; what -stop: does
// when no loop is running (the model only lets the stop job run inside the loop).
module mainThreadDispatch {
  const DESIGN: str
  const TIMEOUT: bool

  type Loop = NotStarted | Running | Stopping | Stopped
  type Kind = Plain | StopJob
  type Res = Pending | Done | Cancelled
  type Phase = Ready | Registered | Waiting

  type Entry = { live: bool, kind: Kind, waiter: int }
  type WorkerSt = { phase: Phase, id: int, wait: bool }

  pure val WORKERS = Set(1, 2)
  pure val NOBODY = 0
  pure val CALLS = 2
  pure val RUNS = 2
  pure val MAIN_CALLS = 1
  pure val IDS = 0.to(2 * CALLS + MAIN_CALLS - 1)

  var loop: Loop
  var inLoop: bool              // the main thread is inside [NSApp run]
  var runs: int
  var table: int -> Entry       // *TASKS*: live = present in the hash table
  var q: List[int]              // GCD main queue
  var nextId: int               // *NEXT-TASK-ID*
  var ran: int -> int           // ghost: times each task's function ran
  var res: int -> Res           // ghost: what the waiter of each task will see
  var worker: int -> WorkerSt
  var calls: int -> int
  var mainCalls: int

  val refusing: bool = DESIGN != "now" and (loop == Stopping or loop == Stopped)

  action init = all {
    loop' = NotStarted,
    inLoop' = false,
    runs' = 0,
    table' = IDS.mapBy(_ => { live: false, kind: Plain, waiter: NOBODY }),
    q' = List(),
    nextId' = 0,
    ran' = IDS.mapBy(_ => 0),
    res' = IDS.mapBy(_ => Pending),
    worker' = WORKERS.mapBy(_ => { phase: Ready, id: 0, wait: false }),
    calls' = WORKERS.mapBy(_ => 0),
    mainCalls' = 0,
  }

  // A worker enters ON-MAIN (or STOP-APPLICATION) and registers its function.
  action call(w: int, kind: Kind, wait: bool): bool = {
    val refuse = wait and refusing
    all {
      worker.get(w).phase == Ready,
      calls.get(w) < CALLS,
      kind == StopJob implies wait,
      if (refuse) all {
        // guarded / flag-check: signal "the loop has stopped" at once
        calls' = calls.put(w, calls.get(w) + 1),
        worker' = worker,
        table' = table,
        nextId' = nextId,
      } else all {
        table' = table.put(nextId, { live: true, kind: kind, waiter: if (wait) w else NOBODY }),
        nextId' = nextId + 1,
        worker' = worker.put(w, { phase: Registered, id: nextId, wait: wait }),
        calls' = calls,
      },
      loop' = loop, inLoop' = inLoop, runs' = runs, q' = q,
      ran' = ran, res' = res, mainCalls' = mainCalls,
    }
  }

  // DISPATCH-TO-MAIN: dispatch_async_f with the id; then wait, or return.
  action dispatch(w: int): bool = {
    val s = worker.get(w)
    all {
      s.phase == Registered,
      q' = q.append(s.id),
      worker' = worker.put(w, if (s.wait) { ...s, phase: Waiting } else { ...s, phase: Ready }),
      calls' = if (s.wait) calls else calls.put(w, calls.get(w) + 1),
      loop' = loop, inLoop' = inLoop, runs' = runs, table' = table, nextId' = nextId,
      ran' = ran, res' = res, mainCalls' = mainCalls,
    }
  }

  // WAIT-ON-SEMAPHORE returns once the semaphore was signalled.
  action wake(w: int): bool = {
    val s = worker.get(w)
    all {
      s.phase == Waiting,
      res.get(s.id) != Pending,
      worker' = worker.put(w, { ...s, phase: Ready }),
      calls' = calls.put(w, calls.get(w) + 1),
      loop' = loop, inLoop' = inLoop, runs' = runs, table' = table, q' = q, nextId' = nextId,
      ran' = ran, res' = res, mainCalls' = mainCalls,
    }
  }

  // guarded + TIMEOUT: the waiter gives up; under the lock it detaches from its task,
  // which may still run later (its result is dropped).
  action giveUp(w: int): bool = {
    val s = worker.get(w)
    all {
      DESIGN == "guarded", TIMEOUT,
      s.phase == Waiting,
      res.get(s.id) == Pending,
      worker' = worker.put(w, { ...s, phase: Ready }),
      calls' = calls.put(w, calls.get(w) + 1),
      table' = table.put(s.id, { ...table.get(s.id), waiter: NOBODY }),
      loop' = loop, inLoop' = inLoop, runs' = runs, q' = q, nextId' = nextId,
      ran' = ran, res' = res, mainCalls' = mainCalls,
    }
  }

  // The main thread, outside the loop, calls ON-MAIN itself.
  action mainCall(wait: bool): bool = all {
    not(inLoop),
    mainCalls < MAIN_CALLS,
    mainCalls' = mainCalls + 1,
    nextId' = nextId + 1,
    if (wait) all {
      // (main-thread-p): runs in place, never touches the queue
      ran' = ran.put(nextId, 1),
      res' = res.put(nextId, Done),
      table' = table,
      q' = q,
    } else all {
      table' = table.put(nextId, { live: true, kind: Plain, waiter: NOBODY }),
      q' = q.append(nextId),
      ran' = ran,
      res' = res,
    },
    loop' = loop, inLoop' = inLoop, runs' = runs, worker' = worker, calls' = calls,
  }

  // RUN-APPLICATION: [NSApp run] starts draining the main queue.
  action runApp: bool = all {
    not(inLoop),
    loop == NotStarted or loop == Stopped,
    runs < RUNS,
    loop' = Running,
    inLoop' = true,
    runs' = runs + 1,
    table' = table, q' = q, nextId' = nextId, ran' = ran, res' = res,
    worker' = worker, calls' = calls, mainCalls' = mainCalls,
  }

  // The run loop drains one entry of the main queue: RUN-TASK.
  action runJob: bool = {
    val id = q.head()
    val e = table.get(id)
    all {
      inLoop,
      q.length() > 0,
      q' = q.tail(),
      if (e.live) all {
        table' = table.put(id, { ...e, live: false }),
        ran' = ran.put(id, ran.get(id) + 1),
        res' = res.put(id, Done),
        loop' = if (e.kind == StopJob and loop == Running) Stopping else loop,
      } else all {
        // TAKE-TASK found nothing: a no-op
        table' = table, ran' = ran, res' = res, loop' = loop,
      },
      inLoop' = inLoop, runs' = runs, nextId' = nextId,
      worker' = worker, calls' = calls, mainCalls' = mainCalls,
    }
  }

  // The event posted by STOP-APPLICATION is processed: [NSApp run] returns.
  action exitLoop: bool = all {
    inLoop,
    loop == Stopping,
    loop' = Stopped,
    inLoop' = false,
    if (DESIGN == "guarded") all {
      table' = IDS.mapBy(i => {
        val e = table.get(i)
        if (e.live and e.waiter != NOBODY) { ...e, live: false } else e
      }),
      res' = IDS.mapBy(i => {
        val e = table.get(i)
        if (e.live and e.waiter != NOBODY) Cancelled else res.get(i)
      }),
    } else all {
      table' = table, res' = res,
    },
    runs' = runs, q' = q, nextId' = nextId, ran' = ran,
    worker' = worker, calls' = calls, mainCalls' = mainCalls,
  }

  action step = {
    nondet w = WORKERS.oneOf()
    nondet kind = Set(Plain, StopJob).oneOf()
    nondet wait = Set(true, false).oneOf()
    any {
      call(w, kind, wait),
      dispatch(w),
      wake(w),
      giveUp(w),
      mainCall(wait),
      runApp,
      runJob,
      exitLoop,
    }
  }

  // ---- properties ----

  // No task's function runs twice.
  val atMostOnce: bool = IDS.forall(i => ran.get(i) <= 1)

  // No task vanishes: an id handed out is still in the table, or its function ran, or
  // its waiter was told it was cancelled.
  val noLostTask: bool =
    IDS.forall(i => i < nextId implies (table.get(i).live or ran.get(i) == 1 or res.get(i) == Cancelled))

  // No :WAIT T caller is blocked on a task that no loop will run: the loop has
  // returned and nothing has signalled the caller's semaphore.
  val noWaiterAfterStop: bool = WORKERS.forall(w => {
    val s = worker.get(w)
    not(s.phase == Waiting and res.get(s.id) == Pending and loop == Stopped)
  })

  // Not an invariant to hold, a fact to see: a :WAIT T caller can be blocked before
  // the first RUN-APPLICATION. In every design it is served once the loop starts.
  val noWaiterBeforeStart: bool = WORKERS.forall(w => {
    val s = worker.get(w)
    not(s.phase == Waiting and res.get(s.id) == Pending and loop == NotStarted)
  })

  val tableSound: bool = atMostOnce and noLostTask
  val safe: bool = tableSound and noWaiterAfterStop

  // ---- tests (quint test; they pass in every design) ----

  // A worker waits before the loop runs; the first RUN-APPLICATION serves it.
  run waitBeforeRunTest =
    init
      .then(call(1, Plain, true))
      .then(dispatch(1))
      .expect(not(noWaiterBeforeStart))
      .then(runApp)
      .then(runJob)
      .then(wake(1))
      .expect(ran.get(0) == 1 and worker.get(1).phase == Ready)

  // The race: worker 1 stops the application while worker 2 is between registering
  // and being served. now / flag-check: worker 2 is left blocked after the loop
  // returned. guarded: it is woken with "cancelled".
  run stopRaceTest =
    init
      .then(runApp)
      .then(call(1, StopJob, true))
      .then(dispatch(1))
      .then(call(2, Plain, true))
      .then(runJob)          // the stop job: -stop:, then the posted event
      .then(exitLoop)        // [NSApp run] returns before worker 2's task ran
      .then(dispatch(2))
      .expect(
        if (DESIGN == "guarded") noWaiterAfterStop and res.get(1) == Cancelled
        else not(noWaiterAfterStop))

  // After the loop has stopped, STOP-APPLICATION (or any :WAIT T) from a worker.
  // now: blocked for ever unless RUN-APPLICATION is called again.
  // flag-check / guarded: refused at once.
  run callAfterStopTest =
    init
      .then(runApp)
      .then(call(1, StopJob, true))
      .then(dispatch(1))
      .then(runJob)
      .then(exitLoop)
      .then(wake(1))
      .then(call(2, Plain, true))
      .expect(
        if (DESIGN == "now") worker.get(2).phase == Registered
        else worker.get(2).phase == Ready and nextId == 1)

  // :WAIT NIL work queued while the loop is down runs once in the next loop, and an
  // id cancelled in the queue is a no-op there.
  run queuedNoWaitTest =
    init
      .then(mainCall(false))
      .then(runApp)
      .then(runJob)
      .expect(ran.get(0) == 1 and atMostOnce)
}

module now { import mainThreadDispatch(DESIGN = "now", TIMEOUT = false).* from "./main-thread-dispatch" }
module flagCheck { import mainThreadDispatch(DESIGN = "flag-check", TIMEOUT = false).* from "./main-thread-dispatch" }
module guarded { import mainThreadDispatch(DESIGN = "guarded", TIMEOUT = true).* from "./main-thread-dispatch" }
