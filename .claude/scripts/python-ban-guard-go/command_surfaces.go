package main

import "strings"

// findCommands follows only terminated find execution actions; predicate operands remain data.
func (s *scanner) findCommands(args []string, known []bool, line, depth int) error {
	for i := 0; i < len(args); i++ {
		if !known[i] {
			continue
		}
		action := args[i]
		switch action {
		case "--help", "--version", "-help", "-version":
			return nil
		case "-exec", "-execdir", "-ok", "-okdir":
			end := i + 1
			for end < len(args) {
				if known[end] && (args[end] == ";" ||
					(args[end] == "+" && end > i+1 && known[end-1] && args[end-1] == "{}" &&
						(action == "-exec" || action == "-execdir"))) {
					break
				}
				end++
			}
			if end == len(args) {
				return nil // An unterminated action cannot select a command.
			}
			if _, err := s.argv(args[i+1:end], known[i+1:end], line, depth); err != nil {
				return err
			}
			i = end
		case "-fprintf":
			i += 2
		case "-f", "-files0-from", "-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename",
			"-regex", "-iregex", "-regextype", "-lname", "-ilname", "-fstype", "-type", "-xtype",
			"-user", "-group", "-uid", "-gid", "-inum", "-links", "-perm", "-size", "-context",
			"-amin", "-atime", "-anewer", "-cmin", "-ctime", "-cnewer", "-mmin", "-mtime", "-newer",
			"-Bmin", "-Btime", "-Bnewer", "-used", "-samefile", "-maxdepth", "-mindepth",
			"-printf", "-fprint", "-fprint0", "-fls":
			i++
		default:
			if strings.HasPrefix(action, "-newer") && len(action) == len("-newerXY") {
				i++
			}
		}
	}
	return nil
}
