#!/usr/bin/env python3
"""iTerm2 helper for swarm. Run with `python -I swarm-iterm.py <cmd>`.

plan-order is pure. The other commands import iterm2 lazily and exit 3 with
`swarm-iterm: <reason>` on stderr when the API is unavailable.
"""
import argparse
import sys


def tid(s):
    return s.strip().lstrip("@")


def ids(csv):
    return [tid(x) for x in csv.split(",") if x.strip()]


def plan_order(tabs, new, project):
    """Move `new` right after the last tab in `project`; unchanged if none."""
    rest = [t for t in tabs if t != new]
    last = -1
    for i, t in enumerate(rest):
        if t in project:
            last = i
    if last < 0 or new not in tabs:
        return list(tabs)
    return rest[: last + 1] + [new] + rest[last + 1 :]


def fail(reason):
    print("swarm-iterm: %s" % reason, file=sys.stderr)
    sys.exit(3)


def run_api(coro_fn):
    try:
        import iterm2
    except Exception as e:  # ImportError or anything odd at import time
        fail("cannot import iterm2: %s" % e)
    try:
        iterm2.run_until_complete(lambda conn: coro_fn(iterm2, conn), retry=False)
    except SystemExit:
        raise
    except BaseException as e:
        fail("iTerm API error: %s" % e)


async def _place_tab(iterm2, conn, new, project):
    app = await iterm2.async_get_app(conn)
    for window in app.terminal_windows:
        tabs = list(window.tabs)
        order = [t.tmux_window_id for t in tabs]
        if new not in [str(o) for o in order]:
            continue
        # Non-tmux tabs (None ids) get unique placeholder keys so they keep their slots.
        names = [str(o) if o is not None else "#%d" % i for i, o in enumerate(order)]
        by_name = dict(zip(names, tabs))
        planned = plan_order(names, new, set(project))
        if planned != names:
            await window.async_set_tabs([by_name[n] for n in planned])
        return


async def _hotkey(iterm2, conn):
    app = await iterm2.async_get_app(conn)
    for window in app.terminal_windows:
        if await window.async_get_variable("isHotkeyWindow"):
            out = ["@%s" % t.tmux_window_id for t in window.tabs if t.tmux_window_id]
            if out:
                print(" ".join(out))
            return


async def _new_window(iterm2, conn, session):
    window = await iterm2.Window.async_create(conn)
    if window is None:
        raise RuntimeError("could not create window")
    await window.current_tab.current_session.async_send_text(
        "tmux -CC attach -t %s\n" % session
    )


def main(argv):
    p = argparse.ArgumentParser(prog="swarm-iterm")
    sub = p.add_subparsers(dest="cmd", required=True)
    po = sub.add_parser("plan-order")
    po.add_argument("--tabs", required=True)
    po.add_argument("--new", required=True)
    po.add_argument("--project", required=True)
    pt = sub.add_parser("place-tab")
    pt.add_argument("--new", required=True)
    pt.add_argument("--project", required=True)
    sub.add_parser("hotkey-windows")
    nw = sub.add_parser("new-window")
    nw.add_argument("--session", required=True)
    a = p.parse_args(argv)

    if a.cmd == "plan-order":
        print(",".join(plan_order(ids(a.tabs), tid(a.new), set(ids(a.project)))))
    elif a.cmd == "place-tab":
        project = ids(a.project)
        if not project:
            return
        run_api(lambda i2, c: _place_tab(i2, c, tid(a.new), project))
    elif a.cmd == "hotkey-windows":
        run_api(_hotkey)
    elif a.cmd == "new-window":
        run_api(lambda i2, c: _new_window(i2, c, a.session))


if __name__ == "__main__":
    main(sys.argv[1:])
