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
go -C "$here/python-ban-guard-go" test ./...
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

# Hashes inside quotes or escaped as data cannot erase a later command.
hash_case=0
for shell_line in 'echo "a # b"; python3 tools/check.py' \
  "echo 'a # b'; python3 tools/check.py" \
  'echo a\ #\ b; python3 tools/check.py' \
  'echo "a \" # b"; python3 tools/check.py'; do
  hash_case=$((hash_case + 1))
  r="$(mkrepo "quoted-hash-${hash_case}")"; addf "$r" tools/hash.sh "$shell_line"
  run "$r"
  report "a quoted or escaped hash preserves the later invocation (${hash_case})" \
    "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo quoted-hash-comment)"; addf "$r" tools/hash.sh \
  'echo "a # b" # python3 tools/check.py' "echo 'a # b' # python3 tools/check.py"
run "$r"
report "control: a real comment after a quoted hash still hides comment text" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# Unquoted escapes in command names retain the same executable identity.
escape_case=0
for invocation in 'pyt\hon3 tools/check.py' 'pi\p3 install example' \
  '/usr/bi\n/pyt\hon3 tools/check.py' \
  '/usr/bi\n/env /usr/bi\n/pyt\hon3 tools/check.py'; do
  escape_case=$((escape_case + 1))
  r="$(mkrepo "escaped-command-${escape_case}")"; addf "$r" tools/escaped.sh "$invocation"
  run "$r"
  report "unquoted escapes do not hide an interpreter or executable path (${escape_case})" \
    "$([[ $rc -eq 1 && "$out" == *'tools/escaped.sh:1: Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo escaped-command-controls)"; addf "$r" tools/escaped.sh \
  'pyt\honics --version' 'pyt\\hon3 tools/check.py' 'pyt\\\hon3 tools/check.py' \
  '"pyt\hon3" tools/check.py' "'pyt\\hon3' tools/check.py" \
  '"/usr/bin/pyt\hon3" tools/check.py' '/usr/bin/pyt\\hon3 tools/check.py' \
  'echo pyt\hon3' 'echo "pyt\hon3"' 'py\ thon3 tools/check.py' \
  'r\un: python3 tools/check.py'
run "$r"
report "control: non-Python commands, quoted literal backslashes and escaped backslashes pass" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# Backslash-newline pairs outside single quotes join before token matching.
r="$(mkrepo continued-bare)"; addf "$r" tools/continued.sh '#!/usr/bin/env bash' 'py\' 'thon3 tools/check.py'
run "$r"
report "an unquoted continuation cannot split the interpreter name" \
  "$([[ $rc -eq 1 && "$out" == *'tools/continued.sh:2: Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continued-wrapper)"; addf "$r" tools/continued.sh '#!/usr/bin/env bash' '/usr/bin/env py\' 'th\' 'on3 tools/check.py'
run "$r"
report "wrapped names join repeated continuations and retain the first physical line" \
  "$([[ $rc -eq 1 && "$out" == *'tools/continued.sh:2: Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continued-double-quoted-wrapper)"; addf "$r" tools/continued.sh '#!/usr/bin/env bash' 'bash -c "py\' 'thon3 tools/check.py"'
run "$r"
report "a double-quoted shell command joins continuations at its first physical line" \
  "$([[ $rc -eq 1 && "$out" == *'tools/continued.sh:2: Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continued-double-quoted-argument)"; addf "$r" tools/continued.sh '#!/usr/bin/env bash' 'echo "py\' 'thon3 tools/check.py"'
run "$r"
report "control: the same double-quoted continuation remains a safe echo argument" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continued-line-numbers)"; addf "$r" tools/continued.sh 'echo sa\' 'fe' 'python3 tools/check.py'
run "$r"
report "a command after a joined logical line retains its own physical line" \
  "$([[ $rc -eq 1 && "$out" == *'tools/continued.sh:3: Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continuation-controls)"; addf "$r" tools/continued.sh \
  'py\\' 'thon3 tools/check.py' \
  '# py\' 'thon3 tools/check.py' \
  'echo safe # py\' 'thon3 tools/check.py' \
  'echo "py\' 'thon3"' \
  "echo 'py\\" "thon3'" \
  "'py\\" "thon3'" \
  'echo py\' 'thon3'
run "$r"
report "control: escaped slashes, comments, quoted continuations and arguments stay safe" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continued-comment)"; addf "$r" tools/continued.sh '# a comment ending in a backslash\' 'python3 tools/check.py'
run "$r"
report "a backslash in a comment cannot consume the next command" \
  "$([[ $rc -eq 1 && "$out" == *'tools/continued.sh:2: Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continued-even-slashes)"; addf "$r" tools/continued.sh 'echo safe\\' 'python3 tools/check.py'
run "$r"
report "an even number of trailing backslashes cannot consume the next command" \
  "$([[ $rc -eq 1 && "$out" == *'tools/continued.sh:2: Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo continued-eof)"; addf "$r" tools/continued.sh 'echo safe\'
run "$r"
report "control: a trailing continuation at EOF terminates scanning" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# Executable text can contain non-UTF-8 bytes; command syntax is still ASCII.
r="$(mkrepo invalid-utf8-command)"; addf "$r" tools/bytes.sh "$(printf 'echo "\377"; python3 tools/check.py')"
LC_ALL=C.UTF-8 run "$r"
report "an invalid UTF-8 byte cannot crash scanning or hide a later command" \
  "$([[ $rc -eq 1 && "$out" == *'Python invocation `python3 tools/check.py`'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo invalid-utf8-control)"; addf "$r" tools/bytes.sh "$(printf 'echo "\377"; echo safe')"
LC_ALL=C.UTF-8 run "$r"
report "control: executable text with an invalid UTF-8 byte can pass" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

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

# Dockerfile RUN introduces a shell command or an exec-form JSON operand.
docker_case=0
for instruction in 'RUN python3 tools/check.py' \
  'run /usr/bin/python3 tools/check.py' \
  'RUN --mount=type=cache,target=/cache pip install example' \
  'RUN ["python3", "tools/check.py"]' \
  'RUN ["/usr/bin/env", "/bin/sh", "-c", "python3 tools/check.py"]'; do
  docker_case=$((docker_case + 1))
  r="$(mkrepo "docker-run-${docker_case}")"; addf "$r" Dockerfile 'FROM scratch' "$instruction"
  run "$r"
  report "a Dockerfile RUN operand exposes its Python invocation (${docker_case})" \
    "$([[ $rc -eq 1 && "$out" == *'Dockerfile:2: Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo docker-run-controls)"; addf "$r" Dockerfile \
  'FROM scratch' 'RUN echo python3' 'RUN ["echo", "python3"]' \
  'ARG TOOL=python3' 'LABEL example="RUN python3 tools/check.py"'
run "$r"
report "control: Dockerfile arguments and metadata do not become commands" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
# CMD and ENTRYPOINT declare the image's own command, so a container whose Python entrypoint is
# written there — most often in exec form — is exactly as much an invocation as a RUN.
docker_entry_case=0
for instruction in 'CMD ["python3", "-m", "http.server"]' \
  'ENTRYPOINT ["python3", "app.py"]' \
  'CMD python3 -m http.server' \
  'entrypoint ["/usr/bin/python3", "app.py"]'; do
  docker_entry_case=$((docker_entry_case + 1))
  r="$(mkrepo "docker-entry-${docker_entry_case}")"; addf "$r" Dockerfile 'FROM scratch' "$instruction"
  run "$r"
  report "a Dockerfile CMD/ENTRYPOINT operand exposes its Python invocation (${docker_entry_case})" \
    "$([[ $rc -eq 1 && "$out" == *'Dockerfile:2: Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo docker-entry-controls)"; addf "$r" Dockerfile \
  'FROM scratch' 'CMD ["echo", "python3"]' 'ENTRYPOINT ["/bin/bash"]' \
  'LABEL example="CMD python3 app.py"'
run "$r"
report "control: a CMD/ENTRYPOINT naming python only as an argument passes" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo docker-entry-scope)"; addf "$r" tools/text.sh 'CMD python3 app.py'
run "$r"
report "control: CMD is not a command wrapper outside Dockerfiles" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo docker-prefix-scope)"; addf "$r" tools/text.sh 'RUN python3 tools/check.py'
run "$r"
report "control: RUN is not a command wrapper outside Dockerfiles" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

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

shebang_case=0
for shebang in '#!/usr/bin/env -Spython3 -u' '#!/usr/bin/env --split-string=python3 -u'; do
  shebang_case=$((shebang_case + 1))
  r="$(mkrepo "attached-env-python-${shebang_case}")"; addf "$r" tools/check "$shebang" '# entry point fixture only'
  run "$r"
  report "an attached env split-string operand exposes the Python shebang (${shebang_case})" \
    "$([[ $rc -eq 1 && "$out" == *'Python source file (its shebang names python)'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo attached-env-shell-control)"; addf "$r" tools/short '#!/usr/bin/env -Sbash -e' 'echo safe'
addf "$r" tools/long '#!/usr/bin/env --split-string=bash -e' 'echo safe'
run "$r"
report "control: attached env split-string shell operands pass" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

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
# The compatibility route must still report non-workflow command operands.
r="$(mkrepo legacy-command)"; addf "$r" deploy/pod.yaml \
  "annotation: 'python-ban-guard: allow-file — data'" 'command:' '  - python3'
run "$r"
report "unsupported YAML retains detection and marker data cannot exempt it" \
  "$([[ $rc -eq 1 && "$out" == *'Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"

legacy_nice_case=0
for invocation in 'nice python3 --version' 'nice -n 10 pip3 --version' 'nice --adjustment 10 python3 --version'; do
  legacy_nice_case=$((legacy_nice_case + 1))
  r="$(mkrepo "legacy-nice-${legacy_nice_case}")"; addf "$r" deploy/pod.yaml "command: $invocation"
  run "$r"
  report "compatibility command operands inspect $invocation" \
    "$([[ $rc -eq 1 && "$out" == *'Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo legacy-nice-control)"; addf "$r" deploy/pod.yaml \
  'command: nice echo python3' 'run: nice -n 10 echo python3' 'run: nice --help python3'
run "$r"
report "control: compatibility nice arguments remain data" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# A Dockerfile heredoc selects the compatibility route for the whole file.
# Attached env split-string operands must remain visible on that route too.
legacy_env_case=0
for invocation in 'RUN ["env", "-Spython3 --version"]' \
  'RUN ["env", "--split-string=pip3 install example"]' \
  'RUN ["env", "-vSpython3 --version"]'; do
  legacy_env_case=$((legacy_env_case + 1))
  r="$(mkrepo "legacy-env-${legacy_env_case}")"; addf "$r" Dockerfile \
    'FROM scratch' 'RUN <<SCRIPT' 'echo safe' 'SCRIPT' "$invocation"
  run "$r"
  report "compatibility Dockerfile inspects attached env split-string (${legacy_env_case})" \
    "$([[ $rc -eq 1 && "$out" == *'Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo legacy-env-control)"; addf "$r" Dockerfile \
  'FROM scratch' 'RUN <<SCRIPT' 'echo safe' 'SCRIPT' \
  'RUN ["env", "-Secho python3"]' 'RUN ["env", "-uSpython3", "echo", "safe"]'
run "$r"
report "control: compatibility env split arguments stay data" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

legacy_env_boundary=0
for invocation in 'RUN ["env", "-u", "-Spython3", "echo", "safe"]' \
  'RUN ["env", "-vu", "-Spython3", "echo", "safe"]' \
  'RUN ["env", "--", "-Spython3"]' \
  'RUN ["env", "NAME=value", "-Spython3"]'; do
  legacy_env_boundary=$((legacy_env_boundary + 1))
  r="$(mkrepo "legacy-env-boundary-${legacy_env_boundary}")"; addf "$r" Dockerfile \
    'FROM scratch' 'RUN <<SCRIPT' 'echo safe' 'SCRIPT' "$invocation"
  run "$r"
  report "control: compatibility env option boundary (${legacy_env_boundary})" \
    "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
done

# 9. Ablation: neutralise the invocation pattern in a COPY of the guard and show the
#    #2769 fixture no longer fires — so the earlier flag depended on that pattern — while
#    the source-file check, which the ablation does not touch, still fires.
ablated_dir="$tmp/ablation"
mkdir -p "$ablated_dir"
cp -R "$here/python-ban-guard-go" "$ablated_dir/"
ablated="$ablated_dir/python-ban-guard.sh"
sed 's/(python\[23\]?(\[\.\]\[0-9\]+)?|pip3?|pytest)/(pythonZZ[23]?([.][0-9]+)?|pipZZ3?|pytestZZ)/' "$guard" >"$ablated"
sed 's/(python\[23\]?(\[\.\]\[0-9\]+)?|pip3?|pytest)/(pythonZZ[23]?([.][0-9]+)?|pipZZ3?|pytestZZ)/' "$here/python-ban-guard-go/main.go" >"$ablated_dir/python-ban-guard-go/main.go"
if grep -q 'pythonZZ' "$ablated"; then
  report "ablation edit landed" yes
else
  report "ablation edit landed" no "the sed did not change the guard's invocation pattern"
fi
GUARD="$ablated" run "$tmp/test-sh"
report "ablation: with the invocation pattern neutralised, the #2769 fixture passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
GUARD="$ablated" run "$tmp/py-file"
report "ablation control: the untouched source-file check still flags a .py file" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"
GUARD="$ablated" run "$tmp/legacy-command"
report "ablation: the compatibility invocation pattern is neutralised too" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

# Review regressions: these strings are scanner inputs, never executable fixtures.
review_case=0
for invocation in "case \"\$mode\" in yes) python3 --version ;; esac" \
  "eval 'python3 --version'" \
  "bash -lc 'python3 --version'" \
  "bash -ec 'python3 --version'" \
  "bash -xc 'python3 --version'" \
  "py''thon3 --version" '"py"thon3 --version' "\$'python3' --version" \
  '>output python3 --version' '2>output python3 --version' '> output python3 --version'; do
  review_case=$((review_case + 1))
  r="$(mkrepo "review-command-${review_case}")"; addf "$r" tools/check.sh "$invocation"
  run "$r"
  report "shell syntax preserves command position (${review_case})" \
    "$([[ $rc -eq 1 && "$out" == *'Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo review-command-controls)"; addf "$r" tools/check.sh \
  'case "$mode" in yes) echo python3 ;; esac' "eval 'echo python3'" \
  "bash -lc 'echo python3'" "echo py''thon3" '2>output echo python3' \
  "bash -- -lc 'python3 --version'" "grep -E '(npm ci|pytest)' input"
run "$r"
report "control: shell words used as data stay data" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo review-marker-data)"; addf "$r" tools/check.sh \
  "printf '%s\\n' 'python-ban-guard: allow-file — user data'; python3 --version"
run "$r"
report "marker text in an argument cannot exempt a command" "$([[ $rc -eq 1 && "$out" == *'Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo review-marker-data-control)"; addf "$r" tools/check.sh \
  "printf '%s\\n' 'python-ban-guard: allow-file'"
run "$r"
report "control: bare marker text as data is not a declaration" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo review-heredoc-data)"; addf "$r" tools/check.sh \
  "cat <<'DATA'" 'python3 --version' 'DATA' \
  'cat <<DATA' 'python3 --version' 'DATA'
run "$r"
report "control: literal heredoc content is data" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo review-heredoc-marker)"; addf "$r" tools/check.sh \
  "cat <<'DATA'" '# python-ban-guard: allow-file — data' 'DATA' 'python3 --version'
run "$r"
report "a heredoc marker cannot exempt the command after it" \
  "$([[ $rc -eq 1 && "$out" == *'check.sh:4: Python invocation'* ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo review-heredoc-substitution)"; addf "$r" tools/check.sh \
  'cat <<DATA' '$(python3 --version)' 'DATA'
run "$r"
report "an unquoted heredoc still executes command substitutions" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo review-heredoc-shell)"; addf "$r" tools/check.sh \
  "bash <<'SCRIPT'" 'python3 --version' 'SCRIPT'
run "$r"
report "a shell reading a heredoc executes its body" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"

review_shebang=0
for shebang in "#!/usr/bin/env -S 'python3' -u" '#!/usr/bin/env -S "python3" -u' \
  "#!/usr/bin/env -S'python3' -u" "#!/usr/bin/env --split-string='python3' -u"; do
  review_shebang=$((review_shebang + 1))
  r="$(mkrepo "review-shebang-${review_shebang}")"; addf "$r" tools/check "$shebang"
  run "$r"
  report "quoted env split-string exposes the source interpreter (${review_shebang})" \
    "$([[ $rc -eq 1 && "$out" == *'shebang names python'* ]] && echo yes || echo no)" "rc=$rc: $out"
done
r="$(mkrepo review-prose-shebang)"; addf "$r" tools/check.md '#!/usr/bin/env python3'
chmod +x "$r/tools/check.md"; git -C "$r" add -- tools/check.md
run "$r"
report "a prose suffix cannot hide an executable Python shebang" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo review-prose-shell)"; addf "$r" tools/check.md '#!/usr/bin/env bash' 'python3 --version'
chmod +x "$r/tools/check.md"; git -C "$r" add -- tools/check.md
run "$r"
report "a prose suffix cannot hide an executable shell invocation" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"

r="$(mkrepo review-package-script)"; addf "$r" docs/package.json '{"scripts":{"check":"python3 --version"}}'
run "$r"
report "package scripts expose their executable command" "$([[ $rc -eq 1 ]] && echo yes || echo no)" "rc=$rc: $out"
r="$(mkrepo review-package-control)"; addf "$r" docs/package.json \
  '{"description":"python3 --version","scripts":{"check":"echo python3"}}'
run "$r"
report "control: package metadata and script arguments are data" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc: $out"

if [[ $fail -eq 0 ]]; then
  echo "python-ban-guard self-test: all cases passed"
else
  echo "python-ban-guard self-test: FAILED" >&2
  exit 1
fi
