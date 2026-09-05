#!/usr/bin/env bash
#
# Self-test for python-ban-guard.sh.
#
# Every "must flag" case has a control twin that differs in exactly the character that matters,
# so a control that passes for the wrong reason cannot hide a broken pattern; and the invocation
# check is ABLATED once (its pattern neutralised in a copy of the guard) to prove the flagged
# fixture depended on that pattern rather than on some other path through the script.
#
# Fixtures are throwaway git repositories under mktemp: the guard scans TRACKED files, so each
# fixture stages what it wants seen. The repository-wide sweep is a separate CI step behind
# ENFORCE_PYTHON_BAN_GUARD; running it here would silently enforce the rule even with that flag off.
#
# python-ban-guard: allow-file — this file quotes every Python shape the guard rejects as fixture text.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/python-ban-guard.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "yes" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name${detail:+ — $detail}"
    fail=1
  fi
}

# A fixture repository; prints its path.
mkrepo() {
  local dir="$tmp/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email fixture@example.invalid
  git -C "$dir" config user.name fixture
  printf '%s' "$dir"
}

# Write $3.. as lines into $1/$2 and stage it.
addf() {
  local dir="$1" rel="$2"
  shift 2
  mkdir -p "$dir/$(dirname "$rel")"
  printf '%s\n' "$@" >"$dir/$rel"
  git -C "$dir" add -- "$rel"
}

# Run the guard over one repository; sets $out and $rc.
run() {
  rc=0
  out="$(bash "${GUARD:-$guard}" "$1" 2>&1)" || rc=$?
}

# ---------------------------------------------------------------------------
# 0. Release-flag expiry (feature-flag-first: the CI gate ships latent behind
#    ENFORCE_PYTHON_BAN_GUARD, and a release flag must not become permanent debt).
today="$(date -u +%Y-%m-%d)"
if [[ "$today" < "2026-11-01" ]]; then
  report "release flag ENFORCE_PYTHON_BAN_GUARD is within its window (expires 2026-10-31)" yes
else
  report "release flag ENFORCE_PYTHON_BAN_GUARD is within its window (expires 2026-10-31)" no \
    "the flag is overdue: activate the sweep and remove the gate, then delete this check"
fi

# ---------------------------------------------------------------------------
# 1. Positive control: a tracked bash script is clean.
r="$(mkrepo clean-bash)"; addf "$r" tools/check.sh '#!/usr/bin/env bash' 'echo safe'
run "$r"
report "positive control: a tracked bash script passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 2. A tracked Python source file, by extension and by shebang.
r="$(mkrepo py-file)"; addf "$r" tools/gen.py 'print("hi")'
run "$r"
report "flags a tracked .py file" "$([[ $rc -eq 1 && "$out" == *"tools/gen.py: Python source file"* ]] && echo yes || echo no)" "rc=$rc: $out"
report "the .py finding names the rule and the alternative" \
  "$([[ "$out" == *"never Python"* && "$out" == *"write it in bash"* ]] && echo yes || echo no)" "$out"

r="$(mkrepo py-untracked)"; mkdir -p "$r/tools"; printf 'print(1)\n' >"$r/tools/gen.py"
run "$r"
report "control: an UNTRACKED .py file is outside the contract and passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo shebang)"; addf "$r" tools/check '#!/usr/bin/env python3' 'print(1)'
run "$r"
report "flags an extensionless file whose shebang names python" \
  "$([[ $rc -eq 1 && "$out" == *"tools/check: Python source file (its shebang names python)"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo shebang-control)"; addf "$r" tools/check '#!/usr/bin/env bash' 'echo 1'
run "$r"
report "control: a bash shebang passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 3. The exact shape that got through (#2769): python3 -c inside a contract test.
r="$(mkrepo test-sh)"; addf "$r" .claude/scripts/x.test.sh '#!/usr/bin/env bash' "out=\"\$(python3 -c 'print(1)')\""
run "$r"
report "flags python3 -c inside .claude/scripts/*.test.sh" \
  "$([[ $rc -eq 1 && "$out" == *'.claude/scripts/x.test.sh:2: Python invocation `python3 -c`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo test-sh-control)"; addf "$r" .claude/scripts/x.test.sh '#!/usr/bin/env bash' 'out="$(jq -n 1)"'
run "$r"
report "control: the same line built with jq passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 4. The embedded-interpreter carve-out (#2324), keyed on the invocation.
r="$(mkrepo blender)"; addf "$r" tools/bake.sh '#!/usr/bin/env bash' 'blender --background --python tools/bake.py -- "$@"'
run "$r"
report "carve-out: blender --background --python passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo blender-followed-by-python)"; addf "$r" tools/bake.sh 'blender --background --python tools/bake.py; python3 tools/check.py'
run "$r"
report "a blender invocation does not exempt a later Python command" \
  "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo blender-mentioned-after-python)"; addf "$r" tools/bake.sh 'python3 tools/check.py; echo blender --python'
run "$r"
report "mentioning blender as data does not exempt an earlier Python command" \
  "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo blender-control)"; addf "$r" tools/bake.sh '#!/usr/bin/env bash' 'python tools/bake.py -- "$@"'
run "$r"
report "control: the same line without blender is a plain python invocation and flags" \
  "$([[ $rc -eq 1 && "$out" == *'Python invocation `python tools/bake.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo blender-py)"; addf "$r" tools/bake.py 'import bpy'
run "$r"
report "the carve-out never exempts a tracked .py file in this repository" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 5. Prose is not an executable surface; comments are not invocations.
r="$(mkrepo prose)"; addf "$r" docs/howto.md 'Run `python3 -c "print(1)"` upstream.' 'python3 -m venv .venv'
run "$r"
report "prose (.md) mentioning python passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo prose-control)"; addf "$r" docs/howto.sh 'python3 -m venv .venv'
run "$r"
report "control: the same text in a .sh flags" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo comments)"; addf "$r" tools/a.sh '#!/usr/bin/env bash' "# python3 -c 'print(1)' was the old way" 'echo shaping # never python here'
run "$r"
report "a full-line comment and a trailing comment pass" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo comments-control)"; addf "$r" tools/a.sh '#!/usr/bin/env bash' "python3 -c 'print(1)' # was the old way"
run "$r"
report "control: code before the comment marker still flags" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 6. Other executable surfaces and spellings.
r="$(mkrepo workflow)"; addf "$r" .github/workflows/ci.yaml 'jobs:' '  t:' '    steps:' '      - run: pip install requests' '      - run: |' '          pytest -q'
run "$r"
report "flags pip and pytest in a workflow step" \
  "$([[ $rc -eq 1 && "$out" == *'ci.yaml:4: Python invocation `pip install`'* && "$out" == *'ci.yaml:6: Python invocation `pytest -q`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo quoted)"; addf "$r" tools/q.sh '#!/usr/bin/env bash' 'bash -c "python3 -m http.server 8000"'
run "$r"
report "a quoted invocation still flags" "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 -m`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo absolute-interpreter)"; addf "$r" tools/check.sh '/usr/bin/python3 tools/check.py' './venv/bin/pip install example'
run "$r"
report "interpreter executable paths do not hide Python or pip" \
  "$([[ $rc -eq 1 && "$out" == *'Python invocation `/usr/bin/python3 tools/check.py`'* && "$out" == *'Python invocation `./venv/bin/pip install`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo absolute-shell)"; addf "$r" tools/check.sh '/usr/bin/env /bin/bash -c "python3 tools/check.py"'
run "$r"
report "absolute wrapper and shell paths do not hide a nested Python invocation" \
  "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo python-shell)"; addf "$r" .github/workflows/ci.yaml 'steps:' '  - shell: python' '    run: placeholder' "  - shell: '/usr/bin/python3 {0}'" '    run: placeholder'
run "$r"
report "a workflow Python shell selector is an invocation" \
  "$([[ $rc -eq 1 && "$out" == *'ci.yaml:2: Python invocation `python`'* && "$out" == *'ci.yaml:4: Python invocation `/usr/bin/python3'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo bash-shell)"; addf "$r" .github/workflows/ci.yaml 'steps:' '  - shell: bash' '    run: echo safe'
run "$r"
report "control: a workflow bash shell selector passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo piped)"; addf "$r" tools/p.sh '#!/usr/bin/env bash' 'cat data | python3.12 - >out'
run "$r"
report "a versioned interpreter after a pipe flags" "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3.12 -`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo lookalike)"; addf "$r" tools/l.sh '#!/usr/bin/env bash' 'echo "license: Python-2.0"' 'export PYTHONPATH=/x' 'go run ./cmd/pythonic-name'
run "$r"
report "control: Python-2.0, PYTHONPATH and pythonic-name are not invocations" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 7. The allow-file marker: honoured with a reason, a finding without one.
r="$(mkrepo marker)"; addf "$r" tools/about.sh '#!/usr/bin/env bash' '# python-ban-guard: allow-file — this fixture is about the form' "python3 -c 'print(1)'"
run "$r"
report "an allow-file marker with a reason exempts the file" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo marker-bare)"; addf "$r" tools/about.sh '#!/usr/bin/env bash' '# python-ban-guard: allow-file' "python3 -c 'print(1)'"
run "$r"
report "a bare allow-file marker is itself a finding" \
  "$([[ $rc -eq 1 && "$out" == *"carries no reason"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo marker-control)"; addf "$r" tools/about.sh '#!/usr/bin/env bash' '# a comment that is not the marker' "python3 -c 'print(1)'"
run "$r"
report "control: without the marker the same file flags" "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 -c`'* ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 7b. Command position: a mention as an ARGUMENT or in a YAML name is not an invocation,
#     while an interpreter reached through an assignment prefix, a wrapper, a shell -c, or an
#     env -S shebang is.
r="$(mkrepo argument-mention)"; addf "$r" tools/m.sh '#!/usr/bin/env bash' 'echo "install python3 first"' '[[ "$lang" == python ]] && echo yes'
run "$r"
report "control: python as an argument or an operand is not an invocation" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo yaml-name)"; addf "$r" .github/workflows/ci.yaml 'jobs:' '  t:' '    steps:' '      - name: Install python deps' '        run: npm ci'
run "$r"
report "control: a YAML step name mentioning python passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo assignment-prefix)"; addf "$r" tools/a.sh '#!/usr/bin/env bash' 'PYTHONUNBUFFERED=1 python3 serve.py'
run "$r"
report "an assignment prefix does not hide the command" "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 serve.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo wrappers)"; addf "$r" tools/w.sh '#!/usr/bin/env bash' 'if python3 -c "import x"; then exit 0; fi' 'sudo pip3 install x'
run "$r"
report "if … and sudo … wrappers do not hide the command" \
  "$([[ $rc -eq 1 && "$out" == *'w.sh:2: Python invocation `python3 -c`'* && "$out" == *'w.sh:3: Python invocation `pip3 install`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo shebang-env-s)"; addf "$r" tools/check '#!/usr/bin/env -S python3 -u' 'print(1)'
run "$r"
report "flags an env -S shebang naming python" "$([[ $rc -eq 1 && "$out" == *"shebang names python"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo prose-marker)"; addf "$r" docs/guard.md 'Declare `python-ban-guard: allow-file` — no, with a reason.'
run "$r"
report "control: prose that mentions a bare marker is never a finding" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 8. Usage and non-repository input fail closed with exit 2.
run "$tmp/not-a-repo-$$"
report "a directory that is not a git repository exits 2" "$([[ $rc -eq 2 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo unreadable-index)"; addf "$r" tools/check.sh 'echo safe'
GIT_INDEX_FILE="$tmp" run "$r"
report "failed tracked-file enumeration exits 2 instead of reporting clean" \
  "$([[ $rc -eq 2 && "$out" != *'clean —'* ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 9. Ablation: neutralise the invocation pattern in a COPY of the guard and show the
#    #2769 fixture no longer fires — so the earlier flag depended on that pattern — while
#    the source-file check, which the ablation does not touch, still fires.
ablated="$tmp/guard-ablated.sh"
sed 's/(python\[23\]?(\[\.\]\[0-9\]+)?|pip3?|pytest)/(pythonZZ[23]?([.][0-9]+)?|pipZZ3?|pytestZZ)/' "$guard" >"$ablated"
if grep -q 'pythonZZ' "$ablated"; then
  report "ablation edit landed" yes
else
  report "ablation edit landed" no "the sed did not change the guard's invocation pattern"
fi
GUARD="$ablated" run "$tmp/test-sh"
report "ablation: with the invocation pattern neutralised, the #2769 fixture passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
GUARD="$ablated" run "$tmp/py-file"
report "ablation control: the untouched source-file check still flags a .py file" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"

if [[ $fail -eq 0 ]]; then
  echo "python-ban-guard self-test: all cases passed"
else
  echo "python-ban-guard self-test: FAILED" >&2
  exit 1
fi
