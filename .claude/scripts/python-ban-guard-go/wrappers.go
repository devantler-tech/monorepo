package main

import "strings"

// wrapperSpec describes option arity and modes that do not select a child command.
type wrapperSpec struct {
	flags, values, stops, long       string
	optional, optionalLong           string
	duration, needsMode, assignments bool
}

var commandWrappers = map[string]wrapperSpec{
	"timeout": {flags: "fpv", values: "ks", stops: "HV", long: "kill-after:k signal:s foreground:f preserve-status:p verbose:v help:H version:V", duration: true},
	"stdbuf":  {values: "ioe", stops: "HV", long: "input:i output:o error:e help:H version:V", needsMode: true},
	"setsid":  {flags: "cfw", stops: "hV", long: "ctty:c fork:f wait:w help:h version:V"},
	"ionice":  {flags: "t", values: "cn", stops: "pPuhV", long: "class:c classdata:n ignore:t pid:p pgid:P uid:u help:h version:V"},
	"doas":    {flags: "n", values: "au", stops: "CLs"},
	"xargs":   {flags: "0oprtx", values: "adEIJLnPRSs", optional: "eil", optionalLong: "L", stops: "HV", long: "arg-file:a delimiter:d eof:e replace:i max-lines:L max-args:n max-procs:P max-chars:s process-slot-var:a null:0 open-tty:o interactive:p no-run-if-empty:r verbose:t exit:x show-limits:0 help:H version:V"},
	"sudo":    {flags: "ABbEHkNnPSis", values: "acCDghpRrtTu", optionalLong: "E", stops: "VKvleU?", long: "auth-type:a login-class:c close-from:C chdir:D group:g host:h prompt:p chroot:R role:r type:t command-timeout:T user:u preserve-env:E preserve-groups:P set-home:H askpass:A background:b bell:B login:i shell:s reset-timestamp:k remove-timestamp:K stdin:S non-interactive:n no-update:N edit:e list:l validate:v other-user:U version:V help:?", assignments: true},
	"time":    {flags: "ahlpqv", values: "fo", stops: "HV", long: "append:a portability:p quiet:q verbose:v format:f output:o help:H version:V"},
	"exec":    {flags: "cl", values: "a"},
	"command": {flags: "p", stops: "vV"},
	"nohup":   {stops: "HV", long: "help:H version:V"},
}

// longOption accepts an exact spelling or a unique getopt_long abbreviation.
func longOption(options, name string) byte {
	var found byte
	for _, entry := range strings.Fields(options) {
		key, value, _ := strings.Cut(entry, ":")
		if key == name {
			return value[0]
		}
		if strings.HasPrefix(key, name) {
			if found != 0 {
				return 0
			}
			found = value[0]
		}
	}
	return found
}

// wrapperCommand locates the command without expanding or validating option values.
// len(args) means there is no statically selected child command.
func wrapperCommand(name string, args []string, known []bool) int {
	spec := commandWrappers[name]
	i, mode := 0, false
	for i < len(args) {
		if !known[i] {
			if spec.duration {
				break
			}
			return len(args)
		}
		arg := args[i]
		if arg == "--" {
			i++
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			break
		}
		i++
		var options string
		attached := false
		if strings.HasPrefix(arg, "--") {
			key, _, hasValue := strings.Cut(arg[2:], "=")
			option := longOption(spec.long, key)
			if option == 0 {
				return len(args)
			}
			// Optional long operands use =VALUE only, even when the short form
			// has different arity (xargs -L, sudo -E).
			if strings.ContainsRune(spec.optional+spec.optionalLong, rune(option)) {
				continue
			}
			options, attached = string(option), hasValue
			if hasValue && !strings.ContainsRune(spec.values, rune(option)) {
				return len(args)
			}
		} else {
			options = arg[1:]
		}
		for j := 0; j < len(options); j++ {
			option := rune(options[j])
			if strings.ContainsRune(spec.stops, option) {
				return len(args)
			}
			if strings.ContainsRune(spec.optional, option) {
				break // Only the remainder of this short token is its value.
			}
			if strings.ContainsRune(spec.values, option) {
				mode = true
				if !attached && j+1 == len(options) {
					if i >= len(args) {
						return len(args)
					}
					i++ // A value remains data even if it resembles another option.
				}
				break // Any remaining short-token characters belong to its value.
			}
			if !strings.ContainsRune(spec.flags, option) {
				return len(args)
			}
		}
	}
	if spec.needsMode && !mode {
		return len(args)
	}
	if spec.duration && i < len(args) {
		i++
	}
	if spec.assignments {
		for i < len(args) && known[i] && assignment.MatchString(args[i]) {
			i++
		}
	}
	return i
}
