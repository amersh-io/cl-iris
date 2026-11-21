# Examples

Each file is a complete program. From the repository root, after
`scripts/bootstrap`:

```sh
export PATH="$PWD/.local/bin:$PATH"
qlot exec sbcl --load examples/hello.lisp
```

| File | Shows |
|---|---|
| [hello.lisp](hello.lisp) | a window with a page in it |
| [ipc.lisp](ipc.lisp) | `iris.invoke` (a Promise of Lisp's answer), `iris.post`, and `eval-js` from a timer |
| [custom-protocol.lisp](custom-protocol.lisp) | a site served by Lisp under `app://`: pages, a POST endpoint, an answer sent later from another thread |
| [menu.lisp](menu.lisp) | the default menu bar plus a menu of Lisp actions, shortcuts and a check mark |
| [multi-window.lisp](multi-window.lisp) | two webviews side by side in one window, window events, a close request that asks first |

Each example defines `main`, which takes `run-application`'s options, and
calls it at the end of the file; closing the last window quits. To load one
into a REPL without running it, push `:cl-iris-example-test` onto
`*features*` first. The test suite runs every example this way and checks
that its pages load.
