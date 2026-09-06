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
# fixture stages what it wants seen. The only repository file read is the guard itself, plus the
# real tree once, as the positive control the issue demands ("passes on the current tree").
#
# python-ban-guard: allow-file — this file quotes every Python shape the guard rejects as fixture text.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
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
# 1. Positive control. The repository-wide sweep is gated behind the release flag, so this
#    reads the REAL tree only in the on state. In the off state a fixed clean fixture stands in:
#    the self-test itself is not gated, so an unconditional repository sweep here would block
#    exactly the changes the off state exists to let through, and the two flag states would not
#    be distinguishable at all (Codex P1 on #3222).
if [[ "${ENFORCE_PYTHON_BAN_GUARD:-}" == "true" ]]; then
  run "$repo_root"
  report "positive control (flag on): the repository's current tree passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
else
  r="$(mkrepo clean-fixture)"; addf "$r" tools/ok.sh '#!/usr/bin/env bash' 'jq -n 1'
  run "$r"
  report "positive control (flag off): a clean fixture passes, and the repository sweep stays behind ENFORCE_PYTHON_BAN_GUARD" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
fi

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
# ---------------------------------------------------------------------------
# 7c. Codex round on #3222: shapes that read clean under the first cut of the heuristic.
r="$(mkrepo quoted-hash)"; addf "$r" tools/h.sh '#!/usr/bin/env bash' 'echo "a # b"; python3 -c "print(1)"'
run "$r"
report "a quoted # does not open a comment: the invocation after it flags" "$([[ $rc -eq 1 && "$out" == *'h.sh:2: Python invocation `python3 -c`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo quoted-hash-control)"; addf "$r" tools/h.sh '#!/usr/bin/env bash' 'echo "a" # python3 -c "print(1)"'
run "$r"
report "control: an unquoted # still opens a comment" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo dockerfile)"; addf "$r" tools/Dockerfile 'FROM debian:stable' 'RUN python3 -c "print(1)"' 'CMD ["python3", "-m", "http.server"]'
run "$r"
report "flags a Dockerfile RUN and an exec-form CMD" \
  "$([[ $rc -eq 1 && "$out" == *'Dockerfile:2: Python invocation `python3 -c`'* && "$out" == *'Dockerfile:3: Python invocation `python3`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo dockerfile-control)"; addf "$r" tools/Dockerfile 'FROM debian:stable' 'RUN echo python3' 'ENTRYPOINT ["/bin/bash"]'
run "$r"
report "control: a Dockerfile whose RUN mentions python as an argument passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo path-qualified)"; addf "$r" tools/p.sh '#!/usr/bin/env bash' '/usr/bin/python3 -c "print(1)"' './venv/bin/pip install x'
run "$r"
report "a path-qualified interpreter flags by its basename" \
  "$([[ $rc -eq 1 && "$out" == *'p.sh:2: Python invocation `/usr/bin/python3 -c`'* && "$out" == *'p.sh:3: Python invocation `./venv/bin/pip install`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo path-qualified-control)"; addf "$r" tools/p.sh '#!/usr/bin/env bash' '/usr/bin/pythonic-tool -c x' '/usr/bin/env bash -c "echo python3"'
run "$r"
report "control: a path whose basename is not an interpreter passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo shebang-env-s-attached)"; addf "$r" tools/check '#!/usr/bin/env -Spython3 -u' 'print(1)'
run "$r"
report "flags an attached env -Spython3 shebang" "$([[ $rc -eq 1 && "$out" == *"shebang names python"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo shebang-split-string)"; addf "$r" tools/check '#!/usr/bin/env --split-string=python3 -u' 'print(1)'
run "$r"
report "flags an env --split-string=python3 shebang" "$([[ $rc -eq 1 && "$out" == *"shebang names python"* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo shebang-env-s-control)"; addf "$r" tools/check '#!/usr/bin/env -Sbash -u' 'echo 1'
run "$r"
report "control: an attached env -Sbash shebang passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo blender-shared-line)"; addf "$r" tools/b.sh '#!/usr/bin/env bash' 'echo blender --python; python3 -c "print(1)"' 'blender --background --python bake.py -- "$@"; python3 post.py'
run "$r"
report "the blender carve-out exempts only its own command segment" \
  "$([[ $rc -eq 1 && "$out" == *'b.sh:2: Python invocation `python3 -c`'* && "$out" == *'b.sh:3: Python invocation `python3 post.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo blender-shared-line-control)"; addf "$r" tools/b.sh '#!/usr/bin/env bash' 'blender --background --python bake.py -- "$@"; echo done'
run "$r"
report "control: a blender segment followed by a non-Python command passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# ---------------------------------------------------------------------------
# 8. Usage and non-repository input fail closed with exit 2.
run "$tmp/not-a-repo-$$"
report "a directory that is not a git repository exits 2" "$([[ $rc -eq 2 ]] && echo yes || echo no)" "rc=$rc: $out"

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
