// url-scheme-task.qnt -- WKURLSchemeHandler start/stop against a Lisp responder
// (src/webview.lisp: START-URL-SCHEME-TASK, STOP-URL-SCHEME-TASK, RESPOND).
//
// The contract WebKit enforces on a WKURLSchemeTask:
//   * after webView:stopURLSchemeTask:, sending the task anything raises an
//     NSException -- which CFFI cannot catch, so the process dies;
//   * the messages come in the order didReceiveResponse: -> didReceiveData:* ->
//     didFinish | didFailWithError: (didFailWithError: may also come first);
//   * the task ends once: nothing after didFinish / didFailWithError:.
//
// What is modelled
//   * WebKit, on the main thread, starts tasks (up to TASKS of them) and may stop any
//     task it has not seen end. It frees a task object some time after the task was
//     stopped or ended, and a later task may get the same address: ADDRS addresses.
//   * A sent message reaches whatever task object lives at the address it is sent
//     to. Each message carries, as a ghost, the task it was meant for, so a message
//     that lands on a different (newer) task is caught.
//   * Synchronous responder ("sync", the code as it is): RESPOND runs inside the start
//     callback and sends response, data, finish. With NESTED_LOOP the handler may spin
//     a nested run loop (a modal panel, say), during which WebKit can deliver stop.
//   * Asynchronous responder (the next implementation): one responder thread per task
//     produces response, at most MAX_DATA data, then finish or fail -- or fails at once
//     -- and hands each message to the main thread with ON-MAIN :WAIT NIL (GCD's main
//     queue: FIFO). The main thread sends it when it runs the job.
//
// Designs (const DESIGN)
//   "sync"            -- the code as it is.
//   "async-naive"     -- the job sends to the task pointer it captured, unchecked.
//   "async-addr-flag" -- a tempting fix: a main-thread table keyed by the task's
//                        address; stop marks it stopped; a job sends only if its
//                        address is marked open.
//   "async-guarded"   -- the proposed fix: start gives each task a fresh integer id
//                        (never reused) and records { task, open } under it on the main
//                        thread; stop marks that id stopped; the responder holds only
//                        the id; a job looks the id up on the main thread and sends
//                        only while it is open, and a terminal message closes it.
//
// Simplified away: the bytes, status and headers; WebKit freeing a task object while
// a message to it is being sent (all sends and frees are main-thread steps); a
// responder that sends from several threads at once (one responder thread per task
// keeps its own order, and the main queue is FIFO).
module urlSchemeTask {
  const DESIGN: str
  const NESTED_LOOP: bool

  type WkSt = Active | Responded | WStopped | Ended | Freed
  type Msg = Response | Data | Finish | Fail
  type RStage = Fresh | Body(int) | RDone | NoResponder
  type LSt = LNone | LOpen | LStopped | LEnded
  type Fault = SentAfterStop | OutOfOrder | SentAfterEnd | SentToFreed | CrossTalk
  type Main = Free | InHandler(int)

  type WkTask = { addr: int, st: WkSt }
  type Job = { from: int, key: int, msg: Msg }
  type LEntry = { addr: int, st: LSt }

  pure val TASKS = 3
  pure val ADDRS = Set(0, 1)
  pure val MAX_DATA = 1
  pure val INSTS = 0.to(TASKS - 1)
  pure val KEYS = 0.to(TASKS - 1)      // ids or addresses, whichever is larger
  pure val ASYNC = DESIGN != "sync"

  var wk: int -> WkTask       // WebKit's task objects, by creation order
  var started: int
  var resp: int -> RStage     // each task's responder thread
  var q: List[Job]            // GCD main queue
  var lisp: int -> LEntry     // the Lisp main-thread table (addr-flag: by address; guarded: by id)
  var main: Main
  var faults: Set[Fault]      // the first fault kills the process

  pure def terminal(m: Msg): bool = m == Finish or m == Fail

  // The task object at address a, if any.
  def liveAt(a: int): Set[int] = INSTS.filter(i => i < started and wk.get(i).addr == a and wk.get(i).st != Freed)

  // What WebKit does with message m arriving at address a, meant for task `from`.
  pure def receive(w: int -> WkTask, live: Set[int], from: int, m: Msg): (int -> WkTask, Set[Fault]) =
    if (live.size() == 0) (w, Set(SentToFreed))
    else if (not(live.contains(from))) (w, Set(CrossTalk))
    else {
      val t = w.get(from)
      if (t.st == WStopped) (w, Set(SentAfterStop))
      else if (t.st == Ended) (w, Set(SentAfterEnd))
      else if (t.st == Active)
        (if (m == Response) (w.put(from, { ...t, st: Responded }), Set())
         else if (m == Fail) (w.put(from, { ...t, st: Ended }), Set())
         else (w, Set(OutOfOrder)))
      else // Responded
        (if (m == Response) (w, Set(OutOfOrder))
         else if (m == Data) (w, Set())
         else (w.put(from, { ...t, st: Ended }), Set()))
    }

  def liveAtIn(w: int -> WkTask, a: int): Set[int] =
    INSTS.filter(i => i < started and w.get(i).addr == a and w.get(i).st != Freed)

  // Send a list of messages for task `from` to address a, stopping at the first fault.
  def sendAll(a: int, from: int, ms: List[Msg]): (int -> WkTask, Set[Fault]) =
    ms.foldl((wk, Set()), (acc, m) =>
      if (acc._2 != Set()) acc
      else receive(acc._1, liveAtIn(acc._1, a), from, m))

  action init = all {
    wk' = INSTS.mapBy(_ => { addr: 0, st: Freed }),
    started' = 0,
    resp' = INSTS.mapBy(_ => NoResponder),
    q' = List(),
    lisp' = KEYS.mapBy(_ => { addr: 0, st: LNone }),
    main' = Free,
    faults' = Set(),
  }

  // webView:startURLSchemeTask: for a new task object at a free address.
  action start(a: int): bool = {
    val i = started
    all {
      faults == Set(),
      main == Free,
      started < TASKS,
      liveAt(a) == Set(),
      wk' = wk.put(i, { addr: a, st: Active }),
      started' = started + 1,
      resp' = if (ASYNC) resp.put(i, Fresh) else resp,
      lisp' = if (DESIGN == "async-addr-flag") lisp.put(a, { addr: a, st: LOpen })
              else if (DESIGN == "async-guarded") lisp.put(i, { addr: a, st: LOpen })
              else lisp,
      main' = if (ASYNC) Free else InHandler(i),
      q' = q, faults' = faults,
    }
  }

  // sync: ON-REQUEST returns and RESPOND sends response, data, finish.
  pure def handled(m: Main): int = match m { | InHandler(i) => i | Free => -1 }

  action handlerReturns: bool = {
    val i = handled(main)
    val r = sendAll(wk.get(i).addr, i, List(Response, Data, Finish))
    all {
      faults == Set(),
      i >= 0,
      wk' = r._1,
      faults' = r._2,
      main' = Free,
      started' = started, resp' = resp, q' = q, lisp' = lisp,
    }
  }

  // webView:stopURLSchemeTask: -- on the main thread, or inside the handler's nested
  // run loop.
  action stop(i: int): bool = {
    val t = wk.get(i)
    all {
      faults == Set(),
      main == Free or NESTED_LOOP,
      i < started,
      t.st == Active or t.st == Responded,
      wk' = wk.put(i, { ...t, st: WStopped }),
      lisp' =
        if (DESIGN == "async-addr-flag") lisp.put(t.addr, { ...lisp.get(t.addr), st: LStopped })
        else if (DESIGN == "async-guarded") lisp.put(i, { ...lisp.get(i), st: LStopped })
        else lisp,
      started' = started, resp' = resp, q' = q, main' = main, faults' = faults,
    }
  }

  // WebKit drops a stopped or ended task object; its address may be reused.
  action free(i: int): bool = {
    val t = wk.get(i)
    all {
      faults == Set(),
      main == Free,
      i < started,
      t.st == WStopped or t.st == Ended,
      wk' = wk.put(i, { ...t, st: Freed }),
      started' = started, resp' = resp, q' = q, lisp' = lisp, main' = main, faults' = faults,
    }
  }

  // The responder thread of task i produces its next message: ON-MAIN :WAIT NIL.
  action respond(i: int, m: Msg): bool = {
    val st = resp.get(i)
    val ok = match st {
      | Fresh => m == Response or m == Fail
      | Body(n) => (m == Data and n < MAX_DATA) or m == Finish or m == Fail
      | RDone => false
      | NoResponder => false
    }
    val nextSt = match st {
      | Body(n) => if (m == Data) Body(n + 1) else RDone
      | _ => if (m == Response) Body(0) else RDone
    }
    val key = if (DESIGN == "async-guarded") i else wk.get(i).addr
    all {
      faults == Set(),
      ok,
      resp' = resp.put(i, nextSt),
      q' = q.append({ from: i, key: key, msg: m }),
      wk' = wk, started' = started, lisp' = lisp, main' = main, faults' = faults,
    }
  }

  // The main thread runs the job at the head of the queue.
  action runJob: bool = {
    val j = q.head()
    val e = lisp.get(j.key)
    val checked = DESIGN == "async-addr-flag" or DESIGN == "async-guarded"
    val send = not(checked) or e.st == LOpen
    val addr = if (DESIGN == "async-guarded") e.addr else j.key
    val r = if (send) sendAll(addr, j.from, List(j.msg)) else (wk, Set())
    all {
      faults == Set(),
      main == Free,
      q.length() > 0,
      q' = q.tail(),
      wk' = r._1,
      faults' = r._2,
      lisp' = if (checked and send and terminal(j.msg)) lisp.put(j.key, { ...e, st: LEnded }) else lisp,
      started' = started, resp' = resp, main' = main,
    }
  }

  action step = {
    nondet a = ADDRS.oneOf()
    nondet i = INSTS.oneOf()
    nondet m = Set(Response, Data, Finish, Fail).oneOf()
    any { start(a), handlerReturns, stop(i), free(i), respond(i, m), runJob }
  }

  // ---- properties ----
  val noSendAfterStop: bool = not(faults.contains(SentAfterStop))
  val inOrder: bool = not(faults.contains(OutOfOrder))
  val endsOnce: bool = not(faults.contains(SentAfterEnd))
  val noSendToFreed: bool = not(faults.contains(SentToFreed))
  val noCrossTalk: bool = not(faults.contains(CrossTalk))
  val safe: bool = faults == Set()

  // ---- tests (quint test; they pass in every design) ----

  // A task answered normally ends, with no fault.
  run answerTest =
    init
      .then(start(0))
      .then(if (ASYNC) respond(0, Response).then(runJob).then(respond(0, Data)).then(runJob)
                         .then(respond(0, Finish)).then(runJob)
            else handlerReturns)
      .expect(wk.get(0).st == Ended and safe)

  // Stop arrives while a response is still queued for the main thread (async), or
  // while ON-REQUEST is running (sync). async-naive, and sync with a nested run loop:
  // the late send raises (SentAfterStop). sync without one: stop cannot come then.
  // The checked designs: the send is dropped.
  run stopWhileQueuedTest =
    init
      .then(start(0))
      .then(if (ASYNC) respond(0, Response).then(stop(0)).then(runJob)
            else if (NESTED_LOOP) stop(0).then(handlerReturns)
            else all { main != Free, handlerReturns })   // stop(0) is not enabled here
      .expect(if (DESIGN == "async-naive" or (DESIGN == "sync" and NESTED_LOOP)) faults == Set(SentAfterStop)
              else safe)

  // The stopped task's object is freed and its address goes to a new task before the
  // old responder's message runs. async-addr-flag: the message lands on the new task
  // (CrossTalk). async-guarded: dropped.
  run addressReuseTest =
    init
      .then(start(0))
      .then(if (ASYNC) respond(0, Response).then(stop(0)).then(free(0)).then(start(0)).then(runJob)
            else handlerReturns.then(free(0)).then(start(0)).then(handlerReturns))
      .expect(if (DESIGN == "async-naive" or DESIGN == "async-addr-flag") faults == Set(CrossTalk)
              else safe)
}

module sync { import urlSchemeTask(DESIGN = "sync", NESTED_LOOP = false).* from "./url-scheme-task" }
module syncNested { import urlSchemeTask(DESIGN = "sync", NESTED_LOOP = true).* from "./url-scheme-task" }
module asyncNaive { import urlSchemeTask(DESIGN = "async-naive", NESTED_LOOP = false).* from "./url-scheme-task" }
module asyncAddrFlag { import urlSchemeTask(DESIGN = "async-addr-flag", NESTED_LOOP = false).* from "./url-scheme-task" }
module asyncGuarded { import urlSchemeTask(DESIGN = "async-guarded", NESTED_LOOP = false).* from "./url-scheme-task" }
