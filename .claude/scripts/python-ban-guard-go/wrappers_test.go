package main

import "testing"

// python-ban-guard: allow-file — inert commands verify wrapper argument boundaries.
// TestCommandWrapperBoundaries checks executable selection without running fixtures.
func TestCommandWrapperBoundaries(t *testing.T) {
	tests := []struct {
		name, source string
		wantHit      bool
	}{
		{"timeout duration", "timeout 5 python3 --version", true},
		{"timeout short options", "timeout -vk1s -s TERM 5 pip3 --version", true},
		{"timeout long options", "timeout --signal=TERM --kill-after 1s -- 0 python3", true},
		{"timeout abbreviations", "timeout --kill 1s 5 python3", true},
		{"stdbuf attached", "stdbuf -oL python3", true},
		{"stdbuf long options", "stdbuf --output L --error=0 pip3", true},
		{"stdbuf abbreviation", "stdbuf --out L python3", true},
		{"setsid clustered", "setsid -fw python3", true},
		{"setsid long options", "setsid --ctty --wait -- python3", true},
		{"ionice clustered", "ionice -tc2 -n7 python3", true},
		{"ionice long options", "ionice --class best-effort --classdata=7 python3", true},
		{"doas clustered", "doas -nu root python3", true},
		{"doas attached", "doas -a bsd -uroot -- pip3", true},
		{"nested wrappers", "/usr/bin/timeout 5 /usr/bin/setsid -fw bash -c 'python3 --version'", true},
		{"unknown duration", "timeout \"$duration\" python3", true},
		{"timeout help", "timeout --help 5 python3", false},
		{"timeout operand", "timeout -k python3 1 echo safe", false},
		{"timeout literal command separator", "timeout 5 -- python3", false},
		{"stdbuf operand", "stdbuf -o python3", false},
		{"stdbuf no settings", "stdbuf python3", false},
		{"setsid help", "setsid -h python3", false},
		{"ionice pid mode", "ionice -p 123 python3", false},
		{"ionice pgid mode", "ionice --pgid=123 python3", false},
		{"ionice uid mode", "ionice -u 1000 python3", false},
		{"doas config check", "doas -C /etc/doas.conf python3", false},
		{"doas clear authorization", "doas -L python3", false},
		{"doas operand", "doas -u python3 echo safe", false},
		{"doas shell mode", "doas -s python3", false},
		{"unknown command", "timeout 5 \"$command\" python3", false},
		{"unknown option", "setsid --unknown python3", false},
		{"ambiguous option", "ionice --c 2 python3", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := scanner{path: "check.sh", seen: make(map[string]bool)}
			if err := s.source(test.source, 1, 0, false); err != nil {
				t.Fatal(err)
			}
			if got := len(s.hits) > 0; got != test.wantHit {
				t.Errorf("findings=%v; want hit=%v", s.hits, test.wantHit)
			}
		})
	}
	for _, command := range []string{"timeout 5", "stdbuf -oL", "setsid -fw", "ionice -tc2 -n7", "doas -u root"} {
		s := scanner{path: "check.sh", seen: make(map[string]bool)}
		if err := s.source(command+" echo python3", 1, 0, false); err != nil {
			t.Fatal(err)
		}
		if len(s.hits) > 0 {
			t.Errorf("%q data argument reported: %v", command, s.hits)
		}
	}
}
