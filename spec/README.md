# Quint models of cl-iris's concurrency protocols

Three models, one per protocol. Each file has a base module with constants that pick a
design or an assumption about the environment, a one-line module per instance at the
bottom, invariants, and `run` tests for `quint test`.

| File | Protocol | Code |
|---|---|---|
| `main-thread-dispatch.qnt` | `ON-MAIN`, the task table, the application loop | `src/window.lisp` |
| `url-scheme-task.qnt` | `WKURLSchemeHandler` start/stop against a responder | `src/webview.lisp` |
| `completion-block-lifetime.qnt` | the hand-built block `EVAL-JS` passes to WebKit | `src/webview.lisp` |

Checked with Quint 0.32.0. "TLC: holds" means TLC explored the whole reachable state space
of the instance, within the bounds stated for that model, and found no violation. A
violation was found by both the simulator and TLC; the trace shown is TLC's, which is
breadth-first, so it is short.

## Which code the models describe

The "as it is" instances (`now`, `sync`, and the `now*` block instances) describe
the code at commit 99780d3, when everything lived in `src/window.lisp` and
`src/webview.lisp`; the file references in the models point there. The source
has since been split into `src/objc/`, `src/window/` and `src/webview/`, and:

- the main-thread dispatch follows the `guarded` design: `CALL-AND-WAIT` checks
  that the loop is running and registers its waiter in one critical section
  under `*DISPATCH-LOCK*`, and `RUN-APPLICATION` clears the running flag under
  the same lock and wakes every waiter when `[NSApp run]` returns
  (`src/window/dispatch.lisp`, `src/window/application.lisp`). It is stricter
  than the model in one place: a `:wait t` call before the loop has started
  signals `APPLICATION-NOT-RUNNING` instead of waiting;
- the completion block is a copy/dispose block (`src/objc/blocks.lisp`).

`scripts/check-spec` runs every `quint test` below; CI runs it on each push.

## Summary

| Model / instance | Design or assumption | Result |
|---|---|---|
| main-thread-dispatch `now` | the code as it is | **violation**: a `:wait t` caller stays blocked after the loop has returned |
| main-thread-dispatch `flagCheck` | refuse `:wait t` once a "stopped" flag is set | **violation**: same, through a race |
| main-thread-dispatch `guarded` | proposed fix | TLC: holds (1,141,432 states) |
| url-scheme-task `sync` | the code as it is | TLC: holds (67 states) |
| url-scheme-task `syncNested` | the code as it is, if `on-request` spins a nested run loop | **violation**: send after stop |
| url-scheme-task `asyncNaive` | async responder, unchecked sends | **violation**: send after stop |
| url-scheme-task `asyncAddrFlag` | async, "stopped" table keyed by task address | **violation**: a stale message lands on a newer task |
| url-scheme-task `asyncGuarded` | proposed design | TLC: holds (8,246,065 states) |
| completion-block-lifetime `now` | the code as it is, WebKit releases the block in the turn it calls it, no nested run loop | TLC: holds (7 states) |
| completion-block-lifetime `nowNested` | the code as it is, the callback spins a nested run loop | **violation**: use after free |
| completion-block-lifetime `nowLateRelease` | the code as it is, WebKit releases the block in a later turn | **violation**: use after free |
| completion-block-lifetime `nowDrop` | the code as it is, WebKit releases the block without calling it | **violation**: block and task entry leak; an `EVAL-JS :wait t` caller hangs |
| completion-block-lifetime `copyDispose` | proposed design, under all three assumptions at once | TLC: holds (10 states) |

## main-thread-dispatch.qnt

**Scope.** Two worker threads, two calls each (`ON-MAIN` with `:wait t` or `:wait nil`, or
`STOP-APPLICATION`); one `ON-MAIN` call by the main thread while it is outside the loop;
`RUN-APPLICATION` at most twice. A worker's call is three steps, as in the code: register
under the tasks lock, `dispatch_async_f`, wait on the semaphore. The GCD main queue is FIFO
and is drained only while the main thread is inside `[NSApp run]`. After the stop job runs,
the loop is *Stopping*: it may drain more jobs before `[NSApp run]` returns.

**Invariants.**

- `atMostOnce` -- no task's function runs twice.
- `noLostTask` -- every id handed out is still in the table, or ran, or (guarded) its waiter
  was told it was cancelled.
- `noWaiterAfterStop` -- no `:wait t` caller is blocked, unsignalled, once `[NSApp run]` has
  returned.
- `noWaiterBeforeStart` is not expected to hold: it shows that a `:wait t` caller may block
  before the first `RUN-APPLICATION`. `waitBeforeRunTest` shows it is served once the loop
  starts, in every design.

**Results.**

- `now`: `atMostOnce` and `noLostTask` hold (TLC, 207,356 states). `noWaiterAfterStop` is
  violated. Shortest trace: the main thread runs `RUN-APPLICATION`; worker 1 calls
  `STOP-APPLICATION`; its job runs and `[NSApp run]` returns; worker 2 now calls any `ON-MAIN :wait t` (`MAKE-WINDOW`, `EVAL-JS`, even `STOP-APPLICATION`). Its id
  goes into the main queue, which nobody drains, and it blocks until `RUN-APPLICATION` is
  called again -- for ever if it never is.
- `flagCheck` (refuse `:wait t` once a flag says the loop has stopped): `noWaiterAfterStop` is
  still violated, by a race the flag cannot see. Shortest trace: the loop runs; worker 1
  calls `STOP-APPLICATION`; worker 2 calls `ON-MAIN :wait t` and registers (the flag says
  running); the stop job runs and `[NSApp run]` returns before worker 2's job; worker 2
  dispatches and waits. Its job is behind the end of the loop. (`stopRaceTest`.)
- `guarded`: all three hold (TLC, 1,141,432 states, depth 23), with waiter timeouts enabled.

**Proposed design (`guarded`).**

1. Keep the loop state (`not-started | running | stopping | stopped`) next to `*tasks*`,
   under `*tasks-lock*`. `RUN-APPLICATION` sets `running` before `[NSApp run]`; the stop job
   sets `stopping`.
2. `ON-MAIN :wait t` off the main thread checks the state and registers its function **in
   the same critical section**, recording that it has a waiter. In `stopping` or `stopped`
   it signals an error at once instead. In `not-started` it registers and waits, as today:
   the work runs when the loop starts.
3. When `[NSApp run]` returns, the main thread, under the lock, sets `stopped`, removes every
   registered task that has a waiter, marks it cancelled and signals its semaphore. The
   waiter then signals an error. Their ids may still sit in the GCD queue; `TAKE-TASK` finds
   nothing for them later, so they are no-ops.
4. `:wait nil` work keeps its meaning: it stays queued and runs in the next loop.
5. Optional: a timeout on the wait. A waiter that gives up detaches itself from its task
   under the lock; the task may still run later and its result is dropped. The model checks
   that this keeps `atMostOnce` and `noLostTask`.

**Self-wait on the main thread.** `ON-MAIN :wait t` on the main thread runs the function in
place (`main-thread-p`, `src/window.lisp`), and the model encodes that, so the model cannot
deadlock there by construction. A deadlock this model does not cover: a function running on
the main thread that blocks on something a worker will do only after its own `ON-MAIN :wait t`
returns.

**Simplified away.** Result values and conditions passed back; autorelease pools and float
traps; `ON-LAUNCH` (it is a main-thread `:wait nil` call); AppKit events other than the one
`STOP-APPLICATION` posts; what `-stop:` does when no loop is running.

## url-scheme-task.qnt

**Scope.** WebKit starts up to three tasks on the main thread, at two addresses, so a later
task can get the address of a freed one. It may stop any task it has not seen end, and frees
a task object some time after it was stopped or ended. A message reaches whatever task object
lives at the address it was sent to. Each message carries, as ghost state, the task it was
meant for. Async responders send a response, at most one data, then finish or fail, or fail
at once. They hand each message to the main thread with `ON-MAIN :wait nil`. A fault ends the
run: the first one kills the process.

**Invariants.**

- `noSendAfterStop` -- nothing is sent to a stopped task. This is the NSException CFFI cannot
  catch.
- `inOrder` -- response, then data, then finish or fail; fail may come first.
- `endsOnce` -- nothing after finish or fail.
- `noSendToFreed` -- nothing is sent to a freed task object.
- `noCrossTalk` -- no message lands on a task it was not meant for.

**Results.**

- `sync` (the code as it is: `RESPOND` runs inside the start callback): all hold (TLC, 67
  states). Stop cannot arrive while the handler runs, because both are main-thread
  callbacks.
- `syncNested`: the same code, if `on-request` spins a nested run loop (a modal panel, say)
  in which WebKit delivers the stop. Then: start; stop, inside the handler's nested loop; the
  handler returns and `RESPOND` sends `didReceiveResponse:` to the stopped task. This is a
  send after stop. Today's code is safe only as long as `on-request` does not run the run
  loop.
- `asyncNaive`: start; stop; the responder queues `didReceiveResponse:`; the main thread sends
  it to the stopped task. This is a send after stop. (`stopWhileQueuedTest`.)
- `asyncAddrFlag` (a main-thread table keyed by task address, marked stopped by stop): start
  task A at address 0; stop A; WebKit frees A; start task B, which gets address 0, so the table
  entry for 0 is open again; A's responder queues `didReceiveResponse:`; the main thread finds
  0 open and sends it, to B. B gets a response it did not ask for, or a finish that ends it
  early. (`addressReuseTest`.)
- `asyncGuarded`: all hold (TLC, 8,246,065 states, depth 22).

**Proposed design (`asyncGuarded`).**

1. In `webView:startURLSchemeTask:` (main thread), give the task a fresh integer id, never
   reused, and record `id -> (task, open)` in a main-thread table. Hand the responder only the
   id, never the task pointer.
2. In `webView:stopURLSchemeTask:` (main thread), find the open entry whose task is this
   pointer and mark it stopped. Today's no-op becomes this.
3. Every send -- response, data, finish, fail -- goes through one function that runs on the
   main thread (`ON-MAIN :wait nil` from other threads, directly on the main thread). It looks
   the id up and sends only while the entry is open. A finish or fail closes the entry. Later
   sends to a missing, stopped or closed id are dropped.
4. Order and a single end are the responder's job: one thread per task, and the main queue
   is FIFO. The send function may also refuse data or finish before a response, if you want
   the check in the library.
5. The synchronous path should use the same send function. Under a nested run loop the sync
   path is a special case of the async one: stop can come between start and any send, and
   each send is checked on the main thread. The model checks only the async form.

Entries are keyed by id rather than by address because WebKit reuses addresses once a task
object is freed. Retaining the task from start until its entry closes would also keep the
address from being reused. The id is the simpler guarantee.

**Simplified away.** Bytes, status and headers. WebKit freeing a task object while a send to
it is in progress (sends and frees are both main-thread steps). A responder that sends from
several threads at once.

## completion-block-lifetime.qnt

**Scope.** One `EVAL-JS`, on the main thread. WebKit calls the completion on the main thread.
It may copy the block once more before calling it, and it releases its references afterwards.
Every touch of the block's memory is checked against the memory being live: `Block_copy`,
the invoke, reading the id, `Block_release` / `-release`, and the dispose helper. Three
environment assumptions are constants:

- `LATE_RELEASE` -- WebKit may release a reference in a later main-thread turn, not
  only right after the call returns.
- `NESTED_LOOP` -- the Lisp callback may spin a nested run loop, inside which the main queue
  is drained.
- `MAY_DROP` -- WebKit may release the block without calling it.

**Invariants.**

- `noUseAfterFree`
- `noDoubleFree`
- `calledAtMostOnce`
- `noLeakNoHang` -- once WebKit holds nothing and the main queue is empty, the function has
  been called exactly once, its id is out of the task table, and no block memory is still
  allocated.

**Results for the code as it is** (global block; `JS-COMPLETION` queues `foreign-free` with
`ON-MAIN :wait nil`, then calls the function):

- `now` (none of the three): holds (TLC, 7 states). The deferred free is safe only because
  WebKit's last touch of the block happens before the main queue runs again.
- `nowNested`: `EVAL-JS`; WebKit calls the block; `JS-COMPLETION` queues the free and calls
  the function; the function runs a modal panel, whose nested loop drains the queue and frees
  the block; the function returns and WebKit releases the block, reading freed memory.
  (`nestedLoopTest`.)
- `nowLateRelease`: `EVAL-JS`; WebKit calls the block; the callback returns; the queued free
  runs; WebKit releases its reference later, reading freed memory. (`lateReleaseTest`.)
- `nowDrop`: `EVAL-JS`; WebKit releases the block without calling it. The block and its task
  table entry are never freed, and an `EVAL-JS :wait t` caller blocks for ever.

Whether WebKit ever releases late or drops a completion handler is a WebKit internal, not
visible from here. `NESTED_LOOP` depends only on what the user's callback does.

**Proposed design (`copyDispose`).** Holds with all three assumptions on (TLC, 10 states).

1. Build the block as a stack-style block (`_NSConcreteStackBlock`, flag
   `BLOCK_HAS_COPY_DISPOSE`). Its descriptor holds copy and dispose helpers and the size.
2. WebKit's `Block_copy` makes a heap copy that the runtime owns, with the id copied into it.
   Lisp frees its own foreign block as soon as `-evaluateJavaScript:completionHandler:`
   returns. Further copies only raise the runtime's count.
3. The invoke function reads the id from the block it is given (the copy), takes the function
   out of the task table, and calls it. It frees nothing.
4. The dispose helper runs when the last reference is released. It takes the id out of the
   table. If the function is still there (never called), it queues a call with a "dropped"
   error, so a waiting caller wakes. The runtime then frees the copy. The copy helper has
   nothing to do: the id is a plain integer.

**Simplified away.** Result and error values. Several `EVAL-JS` calls at once (the task
table keeps their ids apart). WebKit calling the block from inside
`-evaluateJavaScript:completionHandler:`. WebKit using the original block pointer without
copying it, which the blocks ABI forbids; the design relies on that ABI.

## Commands

Tests (each test passes in every instance of its file; `--max-samples 1` because they are
deterministic):

```sh
for m in now flagCheck guarded; do
  quint test main-thread-dispatch.qnt --main $m --max-samples 1; done
for m in sync syncNested asyncNaive asyncAddrFlag asyncGuarded; do
  quint test url-scheme-task.qnt --main $m --max-samples 1; done
for m in now nowNested nowLateRelease nowDrop copyDispose; do
  quint test completion-block-lifetime.qnt --main $m --max-samples 1; done
```

Simulator (Rust backend, 8 threads, 20,000 traces). Each run either stopped at the first
violation, or simulated 20,000 traces with no violation:

```sh
quint run main-thread-dispatch.qnt --main guarded \
  --invariants atMostOnce noLostTask noWaiterAfterStop --max-samples 20000 --max-steps 30
quint run url-scheme-task.qnt --main asyncGuarded \
  --invariants noSendAfterStop inOrder endsOnce noSendToFreed noCrossTalk \
  --max-samples 20000 --max-steps 30
quint run completion-block-lifetime.qnt --main copyDispose \
  --invariants noUseAfterFree noDoubleFree calledAtMostOnce noLeakNoHang \
  --max-samples 20000 --max-steps 20
```

TLC (whole state space; `tlc.json` is `{"maxHeap":"-Xmx2G","workers":4}`; Java 21). This
was run for every instance in the summary table:

```sh
quint verify main-thread-dispatch.qnt --main guarded --backend tlc --invariant safe --tlc-config tlc.json
quint verify main-thread-dispatch.qnt --main now --backend tlc --invariant tableSound --tlc-config tlc.json
quint verify url-scheme-task.qnt --main asyncGuarded --backend tlc --invariant safe --tlc-config tlc.json
quint verify completion-block-lifetime.qnt --main copyDispose --backend tlc --invariant safe --tlc-config tlc.json
```

Running times on the machine used: `asyncGuarded` about 10 minutes, `guarded` about 35
seconds, the rest a few seconds. TLC does not name the invariant it breaks; the simulator
does (`quint run --invariants ...`). Apalache was not used.
