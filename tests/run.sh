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
            SAMOSBOR_SELF=/usr/local/bin/samosbor)

env "${golden_env[@]}" "$samosbor" gen \
  --name demo --repo https://example.com/demo.git --preset go \
  --config /etc/demo/conf.toml --env-file /etc/demo/env \
  --run-args '--listen :8080 --verbose' \
  --render-to "$tmp/go-demo" 2>/dev/null
diff -ru "$here/golden/go-demo" "$tmp/go-demo" || fail "golden go-demo diverged"

env "${golden_env[@]}" "$samosbor" gen \
  --name legacy --repo /srv/git/legacy --build-cmd 'make -j' --bin out/legacyd \
  --install-to /home/user/.local/bin --pull-interval 10m \
  --render-to "$tmp/legacy" 2>/dev/null
diff -ru "$here/golden/legacy" "$tmp/legacy" || fail "golden legacy diverged"

env "${golden_env[@]}" "$samosbor" gen \
  --name webapp --repo https://example.com/webapp.git --preset python \
  --entrypoint '/home/user/.local/state/samosbor/webapp/build/venv/bin/python -m webapp' \
  --render-to "$tmp/webapp" 2>/dev/null
diff -ru "$here/golden/webapp" "$tmp/webapp" || fail "golden webapp diverged"

# --run-cmd already carries its own args — combining it with --run-args
# must be refused at gen time.
if env "${golden_env[@]}" "$samosbor" gen \
     --name clash --repo https://example.com/clash.git --preset go \
     --run-cmd '/usr/bin/clash --serve' --run-args '--verbose' \
     --render-to "$tmp/clash" 2>/dev/null; then
  fail "gen accepted --run-cmd together with --run-args"
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
echo "PASS"
