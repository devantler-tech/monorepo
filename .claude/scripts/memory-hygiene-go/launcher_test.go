package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The launcher must recover only the observed default-cache permission failure
// (#4479). A fake Go executable keeps failures deterministic without weakening
// or replacing the real guard's separate integration tests.
func TestLauncherCacheRecovery(t *testing.T) {
	cases := []struct {
		name, mode, cache           string
		guardExit, wantExit, builds int
	}{
		{name: "ordinary build", mode: "success", builds: 1},
		{name: "default cache denied", mode: "permission", builds: 2},
		{name: "default cache directory denied", mode: "root-permission", builds: 2},
		{name: "finding survives retry", mode: "permission", guardExit: 1, wantExit: 1, builds: 2},
		{name: "unknown survives retry", mode: "permission", guardExit: 2, wantExit: 2, builds: 2},
		{name: "private build fails", mode: "retry-fails", wantExit: 2, builds: 2},
		{name: "private allocation fails", mode: "allocation-fails", wantExit: 2, builds: 1},
		{name: "private cleanup fails", mode: "cleanup-fails", wantExit: 2, builds: 2},
		{name: "syntax failure", mode: "compile", wantExit: 2, builds: 1},
		{name: "unrelated permission failure", mode: "other-permission", wantExit: 2, builds: 1},
		{name: "same prefix is another cache", mode: "prefix-permission", wantExit: 2, builds: 1},
		{name: "unreadable default cache identity", mode: "env-fails", wantExit: 2, builds: 1},
		{name: "explicit cache respected", mode: "permission", cache: "configured", wantExit: 2, builds: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			bin, tmp := filepath.Join(root, "bin"), filepath.Join(root, "tmp with spaces")
			for _, p := range []string{bin, tmp} {
				if err := os.Mkdir(p, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			fake := `#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = env ]; then
  [ "$MOCK_MODE" != env-fails ] || exit 1
  printf '%s\n' "$MOCK_DEFAULT_CACHE"
  exit 0
fi
printf '%s\n' "${GOCACHE:-default}" >> "$MOCK_CALLS"
if [ "$MOCK_MODE" = compile ]; then echo 'compile: syntax error' >&2; exit 1; fi
if [ "$MOCK_MODE" = other-permission ]; then echo 'open /unrelated/file: operation not permitted' >&2; exit 1; fi
if [ "$MOCK_MODE" = prefix-permission ]; then echo "open $MOCK_DEFAULT_CACHE-other/file: operation not permitted" >&2; exit 1; fi
if [ "$MOCK_MODE" != success ] && { [ -z "${GOCACHE:-}" ] || [ "${GOCACHE:-}" = configured ]; }; then
  if [ "$MOCK_MODE" = root-permission ]; then echo "mkdir $MOCK_DEFAULT_CACHE: permission denied" >&2; exit 1; fi
  echo "open $MOCK_DEFAULT_CACHE/fixture-d: operation not permitted" >&2
  exit 1
fi
if [ "$MOCK_MODE" = retry-fails ]; then echo 'private build failed' >&2; exit 1; fi
if [ -n "${GOCACHE:-}" ] && [ "$GOCACHE" != configured ]; then
  [ -d "$GOCACHE" ] || { echo 'missing private cache' >&2; exit 1; }
fi
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then output=$2; break; fi
  shift
done
[ -n "$output" ]
cat > "$output" <<'GUARD'
#!/usr/bin/env bash
printf '%s\n' guard-executed
exit "$MOCK_GUARD_EXIT"
GUARD
chmod +x "$output"
`
			if err := os.WriteFile(filepath.Join(bin, "go"), []byte(fake), 0o700); err != nil {
				t.Fatal(err)
			}
			for name, script := range map[string]string{
				"rm":     "#!/usr/bin/env bash\nif [ \"$MOCK_MODE\" = cleanup-fails ] && [ \"${1:-}\" = -rf ]; then exit 1; fi\nexec /bin/rm \"$@\"\n",
				"mktemp": "#!/usr/bin/env bash\nif [ \"$MOCK_MODE\" = allocation-fails ] && [ \"${1:-}\" = -d ]; then exit 1; fi\nexec /usr/bin/mktemp \"$@\"\n",
			} {
				if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			calls := filepath.Join(root, "calls")
			cmd := exec.Command("bash", "../memory-hygiene.sh", "--layout", "codex")
			for _, e := range os.Environ() {
				if !strings.HasPrefix(e, "GOCACHE=") && !strings.HasPrefix(e, "TMPDIR=") && !strings.HasPrefix(e, "PATH=") {
					cmd.Env = append(cmd.Env, e)
				}
			}
			cmd.Env = append(cmd.Env, "PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"), "TMPDIR="+tmp,
				"MOCK_DEFAULT_CACHE="+filepath.Join(root, "default cache"), "MOCK_CALLS="+calls,
				"MOCK_MODE="+tc.mode, "MOCK_GUARD_EXIT="+strconv.Itoa(tc.guardExit))
			if tc.cache != "" {
				cmd.Env = append(cmd.Env, "GOCACHE="+tc.cache)
			}
			out, err := cmd.CombinedOutput()
			status := 0
			if err != nil {
				if e, ok := err.(*exec.ExitError); ok {
					status = e.ExitCode()
				} else {
					t.Fatal(err)
				}
			}
			if status != tc.wantExit {
				t.Errorf("exit=%d want=%d; %s", status, tc.wantExit, out)
			}
			raw, err := os.ReadFile(calls)
			if err != nil {
				t.Fatal(err)
			}
			builds := strings.Split(strings.TrimSpace(string(raw)), "\n")
			if len(builds) != tc.builds {
				t.Errorf("build calls=%d want=%d; %s", len(builds), tc.builds, out)
			}
			wantGuard := tc.mode == "success" || tc.mode == "root-permission" || tc.mode == "cleanup-fails" || (tc.mode == "permission" && tc.cache == "")
			if strings.Contains(string(out), "guard-executed") != wantGuard {
				t.Errorf("guard execution mismatch: %s", out)
			}
			for _, p := range builds {
				if p == "default" || p == "configured" {
					continue
				}
				if tc.mode == "cleanup-fails" {
					if _, err := os.Stat(p); err != nil {
						t.Errorf("cleanup fault was not exercised: %v", err)
					}
					continue
				}
				if _, err := os.Stat(p); !os.IsNotExist(err) {
					t.Errorf("private cache not cleaned: %q (%v)", p, err)
				}
			}
			entries, err := os.ReadDir(tmp)
			wantEntries := 0
			if tc.mode == "cleanup-fails" {
				wantEntries = 1
			}
			if err != nil || len(entries) != wantEntries {
				t.Errorf("temporary artifacts remain: %v (%v)", entries, err)
			}
		})
	}
}
