#!/usr/bin/env bash
# samosbor test suite: golden render tests + a pull-machinery smoke test.
# Needs no systemd and no network (SAMOSBOR_NO_SYSTEMCTL seam + local repos).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
samosbor=$here/../samosbor
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- golden
# Renders are deterministic functions of the arguments given a fixed HOME
# and SAMOSBOR_SELF; HOME may not even exist — --render-to touches nothing
# outside the render dir.
golden_env=(HOME=/home/user
            XDG_CONFIG_HOME=/home/user/.config
            XDG_STATE_HOME=/home/user/.local/state
            SAMOSBOR_SELF=/usr/local/bin/samosbor
            DEMO_TOKEN=s3cr3t)

env "${golden_env[@]}" "$samosbor" gen \
  --name demo --repo https://example.com/demo.git --preset go \
  --config /etc/demo/conf.toml --env-file /etc/demo/env \
  --env DEMO_TOKEN --env GREETING='hello world' \
  --env 'TRICKY=50% "q" $dollar \back' \
  --run-args '--listen :8080 --verbose' \
  --render-to "$tmp/go-demo" 2>/dev/null
diff -ru "$here/golden/go-demo" "$tmp/go-demo" || fail "golden go-demo diverged"

env "${golden_env[@]}" "$samosbor" gen \
  --name legacy --repo /srv/git/legacy --build-cmd 'make -j' --bin out/legacyd \
  --install-to /home/user/.local/bin --pull-interval 10m \
  --render-to "$tmp/legacy" -- --port 9090 --data '/home/user/my data' 2>/dev/null
diff -ru "$here/golden/legacy" "$tmp/legacy" || fail "golden legacy diverged"

# Bare entrypoint anchors in the project venv — the user never needs to
# know where samosbor keeps it.
env "${golden_env[@]}" "$samosbor" gen \
  --name webapp --repo https://example.com/webapp.git --preset python \
  --entrypoint 'python -m webapp' \
  --render-to "$tmp/webapp" 2>/dev/null
diff -ru "$here/golden/webapp" "$tmp/webapp" || fail "golden webapp diverged"

# Absolute entrypoint stays verbatim; an explicit --env PATH lands after
# the synthetic venv PATH, so it wins (systemd: later setting overrides).
# --python only lands in the manifest — the venv is a pull-time affair.
env "${golden_env[@]}" "$samosbor" gen \
  --name webabs --repo https://example.com/webabs.git --preset python \
  --entrypoint '/usr/bin/gunicorn webabs:app' --python python3.11 \
  --env PATH=/opt/tools/bin:/usr/bin \
  --render-to "$tmp/webabs" 2>/dev/null
diff -ru "$here/golden/webabs" "$tmp/webabs" || fail "golden webabs diverged"

# --help in flag position prints usage and exits 0 — the option-shopping
# flow: build up a gen line, append --help, read what else there is,
# arrow-up and keep going. (No golden_env: usage() reads $SELF.)
"$samosbor" gen --name probe --python zzz --help | grep -q 'gen flags:' \
  || fail "gen --help did not print usage"

# --env with a bare name captures at gen time — a variable that is not
# set in the gen environment must be refused, not baked in empty.
if env -u NOPE "${golden_env[@]}" "$samosbor" gen \
     --name nope --repo https://example.com/nope.git --preset go \
     --env NOPE --render-to "$tmp/nope" 2>/dev/null; then
  fail "gen accepted --env for an unset variable"
fi

# systemd does not expand ~ — a shell-position tilde in an Exec-bound
# value, or a (quoted) ~/path in a unit-bound path flag, must be refused
# at gen time instead of landing literal in the unit.
if env "${golden_env[@]}" "$samosbor" gen \
     --name tilde --repo https://example.com/tilde.git --preset go \
     --run-args '--config ~/x.toml' --render-to "$tmp/tilde1" 2>/dev/null; then
  fail "gen accepted a tilde in --run-args"
fi
if env "${golden_env[@]}" "$samosbor" gen \
     --name tilde --repo https://example.com/tilde.git --preset go \
     --config '~/conf.toml' --render-to "$tmp/tilde2" 2>/dev/null; then
  fail "gen accepted a tilde --config path"
fi

# --run-cmd already carries its own args — combining it with --run-args
# must be refused at gen time.
if env "${golden_env[@]}" "$samosbor" gen \
     --name clash --repo https://example.com/clash.git --preset go \
     --run-cmd '/usr/bin/clash --serve' --run-args '--verbose' \
     --render-to "$tmp/clash" 2>/dev/null; then
  fail "gen accepted --run-cmd together with --run-args"
fi
if env "${golden_env[@]}" "$samosbor" gen \
     --name clash --repo https://example.com/clash.git --preset go \
     --run-args '--verbose' --render-to "$tmp/clash2" -- --port 1 2>/dev/null; then
  fail "gen accepted --run-args together with a -- tail"
fi

echo "golden: OK"

# ---------------------------------------------------------------- smoke
# Full gen+pull cycle against a local origin, escape-hatch preset, no
# systemd: initial build, gentle replace (no restart on identical bytes),
# force-pushed upstream absorbed by the pristine mirror.
export HOME=$tmp/home XDG_STATE_HOME=$tmp/home/.local/state \
       XDG_CONFIG_HOME=$tmp/home/.config SAMOSBOR_NO_SYSTEMCTL=1
mkdir -p "$HOME"
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)

origin=$tmp/origin
mkdir -p "$origin"
"${G[@]}" -C "$origin" init -q -b main
echo '#!/bin/sh' >"$origin/hello.sh"
echo 'echo hello-v1' >>"$origin/hello.sh"
printf 'cp hello.sh smoked\nchmod +x smoked\n' >"$origin/build.sh"
"${G[@]}" -C "$origin" add -A
"${G[@]}" -C "$origin" commit -qm v1

"$samosbor" gen --name smoked --repo "$origin" \
  --build-cmd 'sh build.sh' --bin smoked 2>/dev/null

state=$XDG_STATE_HOME/samosbor/smoked
artifact=$state/current/smoked
[ -x "$artifact" ] || fail "smoke: no artifact after gen"
grep -q hello-v1 "$artifact" || fail "smoke: wrong artifact content"
grep -q 'result=updated' "$state/last-pull" || fail "smoke: gen pull not recorded"

# README-only commit => rebuild, byte-identical artifact => gentle, no restart
echo docs >"$origin/README.md"
"${G[@]}" -C "$origin" add -A && "${G[@]}" -C "$origin" commit -qm docs
"$samosbor" pull smoked 2>/dev/null
grep -q 'result=unchanged' "$state/last-pull" || fail "smoke: gentle replace missed"

# Upstream amend (history rewrite) => pristine mirror absorbs, artifact updates
sed -i s/hello-v1/hello-v2/ "$origin/hello.sh"
"${G[@]}" -C "$origin" add -A && "${G[@]}" -C "$origin" commit -q --amend -m docs-v2
"$samosbor" pull smoked 2>/dev/null
grep -q hello-v2 "$artifact" || fail "smoke: force-push not absorbed"
grep -q 'result=updated' "$state/last-pull" || fail "smoke: update not recorded"
[ -f "$state/last-good/smoked" ] || fail "smoke: last-good not kept"
grep -q hello-v1 "$state/last-good/smoked" || fail "smoke: last-good wrong version"

# No-op pull => fast path
"$samosbor" pull smoked 2>/dev/null
grep -q 'result=unchanged' "$state/last-pull" || fail "smoke: fast path missed"

# Re-gen with identical flags => unit texts unchanged => nothing restarted;
# a re-gen that DOES change the service unit try-restarts exactly it.
regen_out=$("$samosbor" gen --name smoked --repo "$origin" \
  --build-cmd 'sh build.sh' --bin smoked 2>&1)
if grep -q try-restart <<<"$regen_out"; then
  fail "smoke: same-flags re-gen restarted something"
fi
regen_out=$("$samosbor" gen --name smoked --repo "$origin" \
  --build-cmd 'sh build.sh' --bin smoked -- --verbose 2>&1)
grep -q 'smoked.service changed — try-restart' <<<"$regen_out" \
  || fail "smoke: changed service unit not try-restarted"
if grep -q 'pull.service changed\|pull.timer changed' <<<"$regen_out"; then
  fail "smoke: unchanged units restarted"
fi
grep -q 'ExecStart=.*smoked --verbose' \
  "$XDG_CONFIG_HOME/systemd/user/smoked.service" \
  || fail "smoke: -- tail did not land in ExecStart"

# uninstall keeps state, --purge wipes it (unit dir is fake but exercised)
mkdir -p "$XDG_CONFIG_HOME/systemd/user"
"$samosbor" regen smoked 2>/dev/null
[ -f "$XDG_CONFIG_HOME/systemd/user/smoked.service" ] || fail "smoke: regen stamped nothing"
"$samosbor" uninstall smoked 2>/dev/null
[ ! -e "$XDG_CONFIG_HOME/systemd/user/smoked.service" ] || fail "smoke: uninstall left units"
[ -f "$state/manifest" ] || fail "smoke: uninstall should keep state"
"$samosbor" regen smoked 2>/dev/null
[ -f "$XDG_CONFIG_HOME/systemd/user/smoked.service" ] || fail "smoke: regen resurrection failed"
"$samosbor" uninstall --purge smoked 2>/dev/null
[ ! -d "$state" ] || fail "smoke: purge left state"

echo "smoke: OK"

# ---------------------------------------------------------------- go preset
# Package default falls back to the repo root when cmd/<name> is absent.
# Needs a go toolchain; skipped (loudly) when there is none.
if command -v go >/dev/null; then
  gorigin=$tmp/gorigin
  mkdir -p "$gorigin"
  "${G[@]}" -C "$gorigin" init -q -b main
  printf 'package main\n\nfunc main() { println("rootd") }\n' >"$gorigin/main.go"
  (cd "$gorigin" && go mod init example.com/rootd >/dev/null 2>&1)
  "${G[@]}" -C "$gorigin" add -A
  "${G[@]}" -C "$gorigin" commit -qm v1
  "$samosbor" gen --name rootd --repo "$gorigin" --preset go 2>/dev/null
  [ -x "$XDG_STATE_HOME/samosbor/rootd/current/rootd" ] \
    || fail "go: root-package default built no artifact"
  echo "go-preset: OK"
else
  echo "go-preset: SKIPPED (no go toolchain)"
fi

# ---------------------------------------------------------------- python preset
# venv-anchored entrypoint: bin/python always exists in the venv (even on
# hosts with no bare `python`); a bad bare entrypoint warns at build time;
# a changed --python rebuilds the venv. No requirements file — no network.
if command -v python3 >/dev/null; then
  porigin=$tmp/porigin
  mkdir -p "$porigin"
  "${G[@]}" -C "$porigin" init -q -b main
  printf 'print("hi")\n' >"$porigin/app.py"
  "${G[@]}" -C "$porigin" add -A
  "${G[@]}" -C "$porigin" commit -qm v1

  pyout=$("$samosbor" gen --name pyapp --repo "$porigin" --preset python \
    --entrypoint 'python app.py' 2>&1)
  pyvenv=$XDG_STATE_HOME/samosbor/pyapp/build/venv
  [ -x "$pyvenv/bin/python" ] || fail "python: venv has no bin/python"
  grep -q "ExecStart=$pyvenv/bin/python app.py" \
    "$XDG_CONFIG_HOME/systemd/user/pyapp.service" \
    || fail "python: entrypoint not anchored in the venv"
  if grep -q 'is not in the venv' <<<"$pyout"; then
    fail "python: spurious entrypoint warning"
  fi

  pyout=$("$samosbor" gen --name pyapp --repo "$porigin" --preset python \
    --entrypoint 'nosuchtool --serve' --python "$(command -v python3)" 2>&1)
  grep -q 'rebuilding with' <<<"$pyout" \
    || fail "python: --python change did not rebuild the venv"
  grep -q "'nosuchtool' is not in the venv" <<<"$pyout" \
    || fail "python: missing-entrypoint warning absent"
  echo "python-preset: OK"
else
  echo "python-preset: SKIPPED (no python3)"
fi

echo "PASS"
