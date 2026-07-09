# samosbor

Keep systemd services fresh from git.

`samosbor gen` stamps a per-project set of systemd units that pull a git
repo on a timer, rebuild it out of tree, and restart the service **only
when the built artifact actually changed**. systemd does the supervision,
journaling, crash-loop backoff and file watching; samosbor only generates
the units and owns the pull/build cycle. One bash file, no dependencies
beyond git + systemd (+ rsync for the escape hatch).

Born from "services live in tmux because writing units is a chore": both
chores — writing the units and remembering `enable-linger` — are done by
the generator.

## Quick start

```sh
# a Go service with daemon flags, config watched, binary also on PATH
samosbor gen --name mybot --repo https://github.com/me/mybot \
  --preset go --config ~/.config/mybot/conf.toml \
  --install-to ~/.local/bin -- --listen :8080 --state ~/mybot/state.db

# a legacy in-tree Makefile project
samosbor gen --name legacyd --repo /srv/git/legacyd \
  --build-cmd 'make -j' --bin out/legacyd

samosbor list            # the fleet, detailed
samosbor pull mybot      # what the timer runs; safe by hand too
samosbor uninstall mybot # units gone, state kept (regen resurrects)
```

Run `samosbor help` for the full flag reference.

## What gets stamped

For `--user` (the default for non-root; unit name == project name, no
prefix — after `gen` it is just *your* service):

| unit | role |
|---|---|
| `<name>.service` | the service: `Restart=always`, `WantedBy=default.target` |
| `<name>-pull.service` + `.timer` | `samosbor pull <name>` every `--pull-interval` (default 5m, `RandomizedDelaySec` against herds) |
| `<name>-config.path` + `-config.service` | watched configs / env-file → `try-restart`, no rebuild |

Plus `daemon-reload`, `enable --now` of the set, and a linger check —
with `loginctl enable-linger` the service runs boot-to-shutdown without a
single login (the only manual step, samosbor prints the command).

Root gets **no default flavor**: pass `--user` or `--system` explicitly.
`--system` puts units in `/etc/systemd/system`, state in
`/var/lib/samosbor`, and the linger dance disappears entirely.

## How pull works

1. **Pristine mirror.** `fetch --prune`; if `HEAD == @{u}` and an artifact
   is installed — done. Otherwise `reset --hard @{u}` + `clean -ffdx` +
   the explicit submodule dance (`sync --recursive`, `update --init
   --recursive --force`, `foreach clean`). Upstream force-push, amend,
   rebase — absorbed silently. The clone is samosbor's: never edit it.
   It tracks the remote's default branch unless the project was generated
   with `--branch <name>`; the branch is enforced on every pull, so a
   re-gen with a different `--branch` switches the clone on the project's
   next pull (a branch deleted upstream fails the pull loudly — the old
   artifact keeps running).
2. **Out-of-tree build.** Build *outputs* land under the project's state
   dir (`-o`, `--target-dir`, `--builddir`, the venv); toolchain *caches*
   stay the machine's own (go build cache, cargo registry, pip cache) —
   shared and warm, trimmed by their owners. The escape hatch
   (`--build-cmd`) runs in an rsync mirror of the tree (`--checksum`
   keeps mtimes, so `make` stays incremental) — the clone stays pristine
   even for in-tree build systems.
   A broken commit never touches the running service: build fails → the
   old artifact keeps running, noise goes to the journal.
3. **Gentle replace.** The fresh artifact is byte-compared against the
   installed one; identical → no restart (a README-only commit never
   bounces the service). Different → previous kept as `last-good`,
   atomic rename, `try-restart` — a service you stopped by hand stays
   stopped. Go preset builds `-trimpath -buildvcs=false` so identical
   sources give identical bytes; opt out with `--vcs-stamp` if you want
   the revision stamped into the binary (every commit then restarts).

## Who starts what

`gen` **converges to enabled + running**: stamp units, initial
pull/build, `daemon-reload`, `enable --now` the set. On a re-gen only
units whose text actually changed get a `try-restart` (identical text —
untouched), and an active service is never double-bounced; but the
final `enable --now` *does* resurrect a hand-stopped service — gen's
contract is "make it run". The opt-out is `--no-start`: everything is
stamped, cloned and built, yet **no unit state is touched** — nothing
enabled, started or restarted. A fresh `gen --no-start` project is
fully inert (no timer pulls either); a re-gen with it changes nothing
that was running *or* stopped. Per-invocation, deliberately not a
manifest slot: bring the project live with a plain re-gen or
`systemctl`.

`pull` (what the timer runs) never raises a stopped service:
`try-restart` only restarts *active* units. A service you stopped by
hand stays down while pulls keep the artifact fresh — the eventual
manual start runs the newest build.

`regen` restamps unit files from the manifest plus `daemon-reload`,
and touches nothing else: no enable, no start, no restart. A running
process keeps its old text until something restarts it; stopped stays
stopped, disabled stays disabled.

The service's `WorkingDirectory` defaults to the source clone for
python and the project state dir otherwise — a least-surprise container
for the daemon's relative writes, not semantics. `--cwd <dir>`
overrides; a relative path (including `.`) is captured against *your*
cwd at `gen` time, so `--cwd . -- -c config.toml` runs the daemon
where you stand.

## State

One root per project — `uninstall --purge` is one `rm -rf`:

```
~/.local/state/samosbor/<name>/   (--system: /var/lib/samosbor/<name>/)
  src/        pristine clone (owned by samosbor, never edit)
  build/      out-of-tree build outputs (out/, target, dist, venv, tree/)
  current/    artifact ExecStart points at (unless --install-to)
  last-good/  previous artifact, manual rollback
  manifest    resolved gen arguments — regen reads this, nothing is
              re-derived from the command line
  last-pull   timestamp + rev + result of the last pull
```

`--install-to ~/.local/bin` puts the working binary there instead of
`current/` — for binaries with a user-facing surface besides the daemon
one. The swap is still atomic, `last-good` still kept in state.

CLI arguments for the daemon: everything after `--` is the daemon's
argv, appended to the generated `ExecStart` — so you never need to know
where the artifact lands. The words come from your live shell, so tilde
expansion and file completion just work; spaces and quotes survive via
unit quoting, `%` stays a literal byte. `--run-args '--listen :8080'`
is the one-string spelling (there `%h` stays available), `--run-cmd`
overrides the whole line; the three are mutually exclusive. systemd
never runs a shell, so a quoted `~` headed for the unit is refused at
`gen` time instead of failing at runtime — use an absolute path or
`%h`; the same guard covers the path flags
(`--config`/`--env-file`/`--install-to`/`--cwd`). Those also accept
*relative* paths, resolved against your cwd at `gen` time and baked
into the manifest — systemd directives need absolute paths, and
"relative to wherever the timer woke up" is never what you meant.

More generally, `gen` fails fast on the unusual instead of escaping
heroically: project names are whitelisted (letters/digits plus `._-`,
no `@` — that is systemd template syntax — no `%` or spaces),
ExecStart-bound strings must be one line, unit-bound paths must be
whitespace-free, `--pull-interval` must parse as a time span, `--bin`
stays inside the tree.

A re-gen whose flags actually changed a unit's text try-restarts that
unit (identical text — no restart, a hand-stopped service stays
stopped), so new args/environment take effect without a manual
`systemctl restart`.

Units run with systemd's own minimal environment, not your shell's —
`--env PATH` captures *your* value at `gen` time and hardcodes it into
the unit (bare `--env NAME` for any variable, `--env NAME=VALUE` for a
literal, repeatable). Captured values live in the manifest: `regen`
keeps them, re-run `gen` to refresh. Values land byte-literal: samosbor
escapes systemd's specifier layer (`%`) and unit quoting for you, and
`$` is never expanded inside `Environment=` to begin with.

`--env` targets the *daemon*; the **pull/build unit** — the oneshot the
timer runs to fetch and rebuild — has its own env knob, `--pull-env`
(same capture and literal forms, repeatable). The split is deliberate:
build-time and run-time environments are different populations, and
samosbor keeps the two units apart the way it keeps the build out of the
run — a daemon secret does not belong in the build unit, and the
toolchain PATH does not belong on the daemon. `--pull-env` is where
fetch/build variables go: `GIT_SSH_COMMAND` for a private clone,
`GOPROXY`, and above all `--pull-env PATH` so the timer build finds
*your* toolchain. That last one is the common trap — units run with
systemd's minimal PATH, which routinely omits `/usr/local/go/bin`,
`~/.cargo/bin`, or a `uv`/`pyenv` python, or (worse) carries an ancient
system `go` that shadows the one you build with. So `gen` warns at stamp
time when the preset's toolchain (`go`/`cargo`/`cabal`/the interpreter)
resolves to a *different* binary on the unit's effective PATH than on
yours — read from `systemctl show-environment`, so `environment.d` and
`DefaultEnvironment` overrides are honored, not guessed. Config files the
toolchain already reads (`~/.ssh/config`, `~/.netrc`, `~/.config/go/env`)
keep working too: the pull runs with `$HOME` set — `--pull-env` is for
what those cannot express per-project.

A local path given as `--repo` is only the *origin*: samosbor still
clones it into state and works on its own copy — the pristine policy
(`reset --hard` + `clean -ffdx`) would be a disaster on a working copy.
A relative path (`.` included) resolves against your cwd at `gen` time
and is baked absolute into the manifest — a later re-clone runs from
timer context, where "relative to what?" has no answer.

## Presets

- **go** — polished: `go build -trimpath -buildvcs=false -o <state>`;
  full gentle replace. Default package: `./cmd/<name>` when that dir
  exists, else the repo root — `--package` overrides.
- **rust / haskell** — skeletons: `cargo build --release --target-dir` /
  `cabal build --builddir` + `list-bin`; reproducibility (and hence
  gentle replace) is best-effort.
- **python** — no binary artifact: venv in state (`requirements.txt` or
  `pyproject.toml`); restart decision uses the source *tree hash* instead
  of artifact bytes. `--entrypoint` is the ExecStart; a bare command
  resolves in the project venv (`--entrypoint 'uvicorn app:app'` — where
  the venv lives is samosbor's business), an absolute path is taken
  verbatim. The unit also gets `VIRTUAL_ENV` and a venv-first `PATH`, so
  the service runs as if the venv were activated; an explicit
  `--env PATH=…` still overrides. `--python <exe>` picks the interpreter
  the venv is built with (default `python3`); changing it rebuilds the
  venv. A bare entrypoint missing from the venv draws a build-time
  warning (typo, or a dependency missing from requirements) instead of a
  silent 203/EXEC at service start.
- **everything else** (C/C++, zoo build systems) — no preset by design:
  `--build-cmd '...' --bin <path-from-root>`.

## Testing

```sh
tests/run.sh
```

No systemd, no network. `gen --render-to <dir>` renders the full unit
set + manifest into a directory (zero systemd, zero network) — the
golden tests diff those renders; it doubles as an eyeball-review mode
before a real `gen`. The smoke test drives the full gen/pull cycle
against a local origin through the `SAMOSBOR_NO_SYSTEMCTL=1` seam:
initial build, gentle replace, force-push absorption, `last-good`,
uninstall/regen resurrection, `--purge`.
