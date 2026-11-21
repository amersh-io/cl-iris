// completion-block-lifetime.qnt -- the completion block EVAL-JS hands to
// -evaluateJavaScript:completionHandler: (src/webview.lisp: MAKE-COMPLETION-BLOCK,
// JS-COMPLETION, EVAL-JS).
//
// Memory cells: Tmpl, the block Lisp builds in foreign memory, and Copy, a heap copy
// made by the blocks runtime (only in the copy/dispose design). Every touch of a cell
// -- Block_copy, invoking it, reading the id out of it, Block_release / -release,
// the dispose helper -- is checked against the cell being live.
//
// What is modelled (all on the main thread; WebKit calls the completion there)
//   * EVAL-JS calls -evaluateJavaScript:completionHandler:, and WebKit Block_copy's
//     the block and keeps the reference. It may copy it once more (WebKit keeps
//     blocks in more than one holder).
//   * Later WebKit invokes the block once, and releases its references.
//     LATE_RELEASE = false: every reference is released right after the call returns,
//     in the same main-thread turn. LATE_RELEASE = true: a reference may be released
//     in any later main-thread turn (a holder destroyed afterwards).
//   * NESTED_LOOP: the Lisp callback may spin a nested run loop (a modal panel, a
//     nested event loop), and the main queue is drained inside it.
//   * MAY_DROP: WebKit may release the block without ever invoking it.
//   * The main queue (GCD) is FIFO; ON-MAIN :WAIT NIL appends to it.
//
// Designs (const DESIGN)
//   "global-free-later" -- the code as it is: the block is marked global, so the
//       runtime neither copies nor frees it (Block_copy returns Tmpl itself);
//       JS-COMPLETION takes the function out of the task table, queues
//       (foreign-free block) with ON-MAIN :WAIT NIL, then calls the function.
//   "copy-dispose" -- the proposed fix: Tmpl is laid out as a stack block with
//       BLOCK_HAS_COPY_DISPOSE. Block_copy makes Copy (refcount 1, the id moves
//       with it); further copies bump the count. Lisp frees Tmpl as soon as
//       -evaluateJavaScript:completionHandler: returns. The invoke function takes the
//       function out of the task table and calls it; nobody in Lisp frees Copy.
//       When the count reaches 0 the runtime calls the dispose helper -- which takes
//       the id out of the table and, if the function was never called, queues a call
//       with a "dropped" error -- and then frees Copy.
//
// Simplified away: the result and error values; several EVAL-JS calls at once (the
// task table keeps their ids apart; one call shows a block's whole life); WebKit
// invoking the block from inside -evaluateJavaScript:completionHandler: itself.
module completionBlockLifetime {
  const DESIGN: str
  const LATE_RELEASE: bool
  const NESTED_LOOP: bool
  const MAY_DROP: bool

  type Cell = Tmpl | Copy
  type Mem = Unalloc | Live | Freed
  type Job = FreeTmpl | CallDropped
  type Main = Idle | InCallback
  type Fault = UseAfterFree | DoubleFree | CalledTwice

  pure val COPY_DISPOSE = DESIGN == "copy-dispose"
  pure val MAX_REFS = 2

  var mem: Cell -> Mem
  var evaluated: bool       // -evaluateJavaScript:completionHandler: was called
  var refs: int             // references WebKit holds
  var rc: int               // the runtime's count on Copy (copy-dispose only)
  var invoked: bool         // WebKit invoked the block
  var registered: bool      // the function is in the task table
  var calls: int            // times the Lisp function was called
  var main: Main
  var q: List[Job]
  var faults: Set[Fault]

  // The cell WebKit's references point at.
  pure val held: Cell = if (COPY_DISPOSE) Copy else Tmpl

  def touch(c: Cell): Set[Fault] = if (mem.get(c) == Live) Set() else Set(UseAfterFree)

  action init = all {
    mem' = Map(Tmpl -> Unalloc, Copy -> Unalloc),
    evaluated' = false,
    refs' = 0,
    rc' = 0,
    invoked' = false,
    registered' = false,
    calls' = 0,
    main' = Idle,
    q' = List(),
    faults' = Set(),
  }

  // EVAL-JS :WAIT NIL, on the main thread: build the block, register the function,
  // call -evaluateJavaScript:completionHandler:, which Block_copy's it.
  action evalJs: bool = all {
    faults == Set(),
    main == Idle,
    not(evaluated),
    evaluated' = true,
    registered' = true,
    refs' = 1,
    rc' = if (COPY_DISPOSE) 1 else 0,
    // copy-dispose: Copy made from Tmpl, then Lisp frees Tmpl after the call returns
    mem' = if (COPY_DISPOSE) Map(Tmpl -> Freed, Copy -> Live) else Map(Tmpl -> Live, Copy -> Unalloc),
    invoked' = invoked, calls' = calls, main' = main, q' = q, faults' = faults,
  }

  // WebKit copies the block once more.
  action wkCopy: bool = all {
    faults == Set(),
    main == Idle,
    refs > 0, refs < MAX_REFS, not(invoked),
    refs' = refs + 1,
    rc' = if (COPY_DISPOSE) rc + 1 else rc,
    faults' = touch(held),
    mem' = mem, evaluated' = evaluated, invoked' = invoked, registered' = registered,
    calls' = calls, main' = main, q' = q,
  }

  // WebKit invokes the block: JS-COMPLETION (or the copy-dispose invoke function).
  action wkInvoke: bool = all {
    faults == Set(),
    main == Idle,
    refs > 0, not(invoked),
    invoked' = true,
    faults' = touch(held),             // the call reads the invoke pointer and the id
    registered' = false,               // TAKE-TASK
    calls' = if (registered) calls + 1 else calls,
    q' = if (COPY_DISPOSE) q else q.append(FreeTmpl),
    main' = InCallback,
    mem' = mem, evaluated' = evaluated, refs' = refs, rc' = rc,
  }

  // One reference released: Block_release / -release reads the block.
  pure def release1(m: Cell -> Mem, r: int, c: int, reg: bool, qq: List[Job]):
      { mem: Cell -> Mem, rc: int, reg: bool, q: List[Job] } =
    if (not(COPY_DISPOSE)) { mem: m, rc: c, reg: reg, q: qq }   // global block: no-op
    else if (c > 1) { mem: m, rc: c - 1, reg: reg, q: qq }
    else // last reference: dispose helper, then the runtime frees Copy
      { mem: m.put(Copy, Freed), rc: 0, reg: false, q: if (reg) qq.append(CallDropped) else qq }

  // The callback returns to WebKit. Without LATE_RELEASE, WebKit releases every
  // reference now.
  action callbackReturns: bool = {
    val n = if (LATE_RELEASE) 0 else refs
    val r1 = if (n >= 1) release1(mem, refs, rc, registered, q) else { mem: mem, rc: rc, reg: registered, q: q }
    val r2 = if (n >= 2) release1(r1.mem, refs - 1, r1.rc, r1.reg, r1.q) else r1
    // each release touches the block before it is (maybe) freed
    val f = if (n >= 1) touch(held) else Set()
    all {
      faults == Set(),
      main == InCallback,
      main' = Idle,
      refs' = refs - n,
      mem' = r2.mem, rc' = r2.rc, registered' = r2.reg, q' = r2.q,
      faults' = f,
      evaluated' = evaluated, invoked' = invoked, calls' = calls,
    }
  }

  // WebKit releases one reference in a later turn: after the call (LATE_RELEASE), or
  // without ever calling (MAY_DROP).
  action wkRelease: bool = {
    val r = release1(mem, refs, rc, registered, q)
    all {
      faults == Set(),
      main == Idle,
      refs > 0,
      (LATE_RELEASE and invoked) or (MAY_DROP and not(invoked)),
      refs' = refs - 1,
      faults' = touch(held),
      mem' = r.mem, rc' = r.rc, registered' = r.reg, q' = r.q,
      evaluated' = evaluated, invoked' = invoked,
      calls' = calls, main' = main,
    }
  }

  // The main queue runs its head job: at top level, or inside the callback's nested
  // run loop.
  action runJob: bool = {
    val j = q.head()
    all {
      faults == Set(),
      q.length() > 0,
      main == Idle or (main == InCallback and NESTED_LOOP),
      q' = q.tail(),
      if (j == FreeTmpl) all {
        mem' = mem.put(Tmpl, Freed),
        faults' = if (mem.get(Tmpl) == Live) Set() else Set(DoubleFree),
        calls' = calls,
      } else all {
        // CallDropped: the function gets a "dropped" error
        mem' = mem,
        faults' = if (calls > 0) Set(CalledTwice) else Set(),
        calls' = calls + 1,
      },
      evaluated' = evaluated, refs' = refs, rc' = rc, invoked' = invoked,
      registered' = registered, main' = main,
    }
  }

  action step = any { evalJs, wkCopy, wkInvoke, callbackReturns, wkRelease, runJob }

  // ---- properties ----
  val noUseAfterFree: bool = not(faults.contains(UseAfterFree))
  val noDoubleFree: bool = not(faults.contains(DoubleFree))
  val calledAtMostOnce: bool = not(faults.contains(CalledTwice)) and calls <= 1

  // Once WebKit holds nothing and the main thread is idle with an empty queue, the
  // function has been called exactly once, its id is out of the table, and no block
  // memory is still allocated (nothing leaks, an EVAL-JS :WAIT T caller is woken).
  val quiescent: bool = evaluated and refs == 0 and main == Idle and q.length() == 0
  val noLeakNoHang: bool =
    quiescent implies (calls == 1 and not(registered) and mem.get(Tmpl) != Live and mem.get(Copy) != Live)

  val safe: bool = faults == Set() and calls <= 1 and noLeakNoHang

  // ---- tests (quint test; they pass in every instance below) ----

  // The ordinary life: copy, invoke, return, release, then the queued work drains.
  run calledRun = init.then(evalJs).then(wkInvoke).then(callbackReturns)
  run releasedRun = if (LATE_RELEASE) calledRun.then(wkRelease) else calledRun
  run ordinaryTest =
    (if (COPY_DISPOSE) releasedRun else releasedRun.then(runJob))
      .expect(safe and quiescent)

  // WebKit releases the block in a later turn, after the queued free ran.
  // global-free-later: the release reads freed memory.
  run lateReleaseTest =
    (if (LATE_RELEASE and not(COPY_DISPOSE)) calledRun.then(runJob).then(wkRelease) else calledRun)
      .expect(if (LATE_RELEASE and not(COPY_DISPOSE)) not(noUseAfterFree) else noUseAfterFree)

  // The callback spins a nested run loop, which drains the queued free before WebKit
  // releases the block. global-free-later: the release reads freed memory.
  run invokedRun = init.then(evalJs).then(wkInvoke)
  run nestedLoopTest =
    (if (NESTED_LOOP and not(COPY_DISPOSE)) invokedRun.then(runJob) else invokedRun)
      .then(callbackReturns)
      .expect(if (NESTED_LOOP and not(COPY_DISPOSE) and not(LATE_RELEASE)) not(noUseAfterFree)
              else noUseAfterFree)
}

// The code as it is, under the assumptions it relies on: holds.
module now { import completionBlockLifetime(DESIGN = "global-free-later", LATE_RELEASE = false, NESTED_LOOP = false, MAY_DROP = false).* from "./completion-block-lifetime" }
// The code as it is, if the callback spins a nested run loop.
module nowNested { import completionBlockLifetime(DESIGN = "global-free-later", LATE_RELEASE = false, NESTED_LOOP = true, MAY_DROP = false).* from "./completion-block-lifetime" }
// The code as it is, if WebKit releases the block in a later turn.
module nowLateRelease { import completionBlockLifetime(DESIGN = "global-free-later", LATE_RELEASE = true, NESTED_LOOP = false, MAY_DROP = false).* from "./completion-block-lifetime" }
// The code as it is, if WebKit drops the block without calling it.
module nowDrop { import completionBlockLifetime(DESIGN = "global-free-later", LATE_RELEASE = false, NESTED_LOOP = false, MAY_DROP = true).* from "./completion-block-lifetime" }
// The proposed design, under all three.
module copyDispose { import completionBlockLifetime(DESIGN = "copy-dispose", LATE_RELEASE = true, NESTED_LOOP = true, MAY_DROP = true).* from "./completion-block-lifetime" }
