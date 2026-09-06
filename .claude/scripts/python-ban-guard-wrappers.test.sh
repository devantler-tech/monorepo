#!/usr/bin/env bash
# python-ban-guard: allow-file — these inert commands test wrapper option boundaries.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools" "$tmp/deploy"
: >"$tmp/tools/check.sh"
: >"$tmp/deploy/pod.yaml"
git -C "$tmp" init -q
git -C "$tmp" add -- tools/check.sh deploy/pod.yaml
fail=0

# Scan fixture text through each engine; no fixture command is ever executed.
check() {
  local name="$1" command="$2" expected="$3" route out rc
  for route in shell fallback; do
    : >"$tmp/tools/check.sh"
    : >"$tmp/deploy/pod.yaml"
    if [[ "$route" == shell ]]; then
      printf '%s\n' "$command" >"$tmp/tools/check.sh"
    else
      printf 'command: %s\n' "$command" >"$tmp/deploy/pod.yaml"
    fi
    rc=0
    out="$(bash "$here/python-ban-guard.sh" "$tmp" 2>&1)" || rc=$?
    if [[ "$rc" == "$expected" ]] && { [[ "$rc" == 0 ]] || [[ "$out" == *'Python invocation'* ]]; }; then
      printf 'PASS: %s (%s)\n' "$name" "$route"
    else
      printf 'FAIL: %s (%s): rc=%s expected=%s %s\n' "$name" "$route" "$rc" "$expected" "$out"
      fail=1
    fi
  done
}
check 'attached env wrapper 1' 'env -Stimeout 5 python3' 1
check 'attached env wrapper 2' 'env --split-string=timeout 5 python3' 1
check 'attached env wrapper 3' 'env -Ssetsid python3' 1
check 'attached env wrapper 4' 'env -Sstdbuf -oL python3' 1
check 'attached env wrapper help' 'env -Ssetsid --help python3' 0
check 'env delimiter keeps attached option literal' 'env -- -Stimeout 5 python3' 0
check 'timeout duration' 'timeout 5 python3 --version' 1
check 'timeout short options' 'timeout -vk1s -s TERM 5 pip3 --version' 1
check 'timeout long options' 'timeout --signal=TERM --kill-after 1s -- 0 python3' 1
check 'timeout abbreviations' 'timeout --kill 1s 5 python3' 1
check 'stdbuf attached' 'stdbuf -oL python3' 1
check 'stdbuf long options' 'stdbuf --output L --error=0 pip3' 1
check 'stdbuf abbreviation' 'stdbuf --out L python3' 1
check 'setsid clustered' 'setsid -fw python3' 1
check 'setsid long options' 'setsid --ctty --wait -- python3' 1
check 'ionice clustered' 'ionice -tc2 -n7 python3' 1
check 'ionice long options' 'ionice --class best-effort --classdata=7 python3' 1
check 'doas clustered' 'doas -nu root python3' 1
check 'doas attached' 'doas -a bsd -uroot -- pip3' 1
check 'nested wrappers' '/usr/bin/timeout 5 /usr/bin/setsid -fw bash -c '\''python3 --version'\''' 1
check 'unknown duration' 'timeout "$duration" python3' 1
check 'timeout help' 'timeout --help 5 python3' 0
check 'timeout operand' 'timeout -k python3 1 echo safe' 0
check 'timeout literal command separator' 'timeout 5 -- python3' 0
check 'stdbuf operand' 'stdbuf -o python3' 0
check 'stdbuf no settings' 'stdbuf python3' 0
check 'setsid help' 'setsid -h python3' 0
check 'ionice pid mode' 'ionice -p 123 python3' 0
check 'ionice pgid mode' 'ionice --pgid=123 python3' 0
check 'ionice uid mode' 'ionice -u 1000 python3' 0
check 'doas config check' 'doas -C /etc/doas.conf python3' 0
check 'doas clear authorization' 'doas -L python3' 0
check 'doas operand' 'doas -u python3 echo safe' 0
check 'doas shell mode' 'doas -s python3' 0
check 'unknown command' 'timeout 5 "$command" python3' 0
check 'unknown option' 'setsid --unknown python3' 0
check 'ambiguous option' 'ionice --c 2 python3' 0
for command in 'timeout 5' 'stdbuf -oL' 'setsid -fw' 'ionice -tc2 -n7' 'doas -u root'; do
  check "argument stays data: $command" "$command echo python3" 0
done
exit "$fail"
