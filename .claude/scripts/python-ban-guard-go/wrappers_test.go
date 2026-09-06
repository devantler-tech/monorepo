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
		{"xargs long max args", "xargs --max-args 1 python3", true},
		{"xargs short max args", "xargs -n 1 python3", true},
		{"xargs input operand", "xargs --arg-file python3 echo safe", false},
		{"xargs optional short empty", "xargs -i python3", true},
		{"xargs optional short attached", "xargs -ipython3 echo safe", false},
		{"xargs optional long attached", "xargs --max-lines=1 python3", true},
		{"xargs optional long empty", "xargs --max-lines 1 python3", false},
		{"xargs display and execute", "xargs --show-limits python3", true},
		{"xargs help", "xargs --help python3", false},
		{"xargs required value", "xargs -I python3 echo safe", false},
		{"xargs process slot variable", "xargs --process-slot-var SLOT python3", true},
		{"sudo working directory", "sudo --chdir /tmp python3", true},
		{"sudo user operand", "sudo -u root python3", true},
		{"sudo host selects command", "sudo -h host python3", true},
		{"sudo host remains data", "sudo -h python3 echo safe", false},
		{"sudo clustered options", "sudo -Eu root python3", true},
		{"sudo preserve env attached", "sudo --preserve-env=python3 echo safe", false},
		{"sudo preserve env empty", "sudo --preserve-env python3", true},
		{"sudo reset and execute", "sudo -k python3", true},
		{"sudo list", "sudo -l python3", false},
		{"sudo help", "sudo --help python3", false},
		{"sudo assignment", "sudo -n NAME=value python3", true},
		{"time quiet and format", "/usr/bin/time -q -f %e python3", true},
		{"time format operand", "/usr/bin/time -f python3 echo safe", false},
		{"time output operand", "/usr/bin/time -o out python3", true},
		{"time help", "/usr/bin/time --help python3", false},
		{"exec clustered options", "exec -cla alias python3", true},
		{"exec argv name operand", "exec -a python3 echo safe", false},
		{"command path mode", "command -p python3", true},
		{"command clustered lookup", "command -pv python3", false},
		{"command lookup", "command -v python3", false},
		{"nohup help", "nohup --help python3", false},
		{"nohup delimiter", "nohup -- python3", true},
		{"time BSD reporting", "/usr/bin/time -hl python3", true},
		{"xargs BSD replacement options", "xargs -J marker -R -1 -S 1024 python3", true},
		{"xargs BSD replacement operand", "xargs -J python3 echo safe", false},
		{"xargs long replacement empty", "xargs --replace python3", true},
		{"xargs long replacement attached", "xargs --replace=python3 echo safe", false},
		{"xargs required max lines", "xargs -L 1 python3", true},
		{"sudo preserve env cluster", "sudo -En python3", true},
		{"sudo delimiter command", "sudo -- python3", true},
		{"command delimiter lookup word", "command -- -v python3", false},
		{"sudo empty prompt", "sudo -p '' python3", true},
		{"sudo empty prompt data", "sudo -p '' echo python3", false},
		{"time empty format", "/usr/bin/time -f \"\" python3", true},
		{"time empty format data", "/usr/bin/time -f \"\" echo python3", false},
		{"xargs empty eof", "xargs -E '' python3", true},
		{"xargs empty eof data", "xargs -E '' echo python3", false},
		{"sudo concatenated empty prompt", "sudo -p ''\"\" python3", true},
		{"sudo attached empty prompt", "sudo --prompt=\"\" python3", true},
		{"empty quotes concatenate command", "\"\"python3 --version", true},
		{"empty quotes concatenate data", "echo \"\"python3", false},
		{"escaped boundary is part of prompt", "sudo -p foo\\ \"\" python3", true},
		{"quoted empty pair is data", "echo \"''\" python3", false},
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
