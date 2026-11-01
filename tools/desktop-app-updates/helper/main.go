// app-lifecycle uses public AppKit process lifecycle APIs. It has no UI,
// Accessibility, chat, network, private IPC, or force-termination code.
package main

/*
#cgo darwin LDFLAGS: -framework AppKit
#include <stdlib.h>
#include "lifecycle.h"
*/
import "C"

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"
	"unsafe"
)

func init() { runtime.LockOSThread() }

func pids(bundle, path string) ([]int, error) {
	name := C.CString(bundle)
	defer C.free(unsafe.Pointer(name))
	appPath := C.CString(path)
	defer C.free(unsafe.Pointer(appPath))
	var values [128]C.int
	n := int(C.desktop_app_pids(name, appPath, &values[0], C.int(len(values))))
	if n < 0 {
		return nil, fmt.Errorf("cannot enumerate application processes")
	}
	result := make([]int, n)
	for i := range result {
		result[i] = int(values[i])
	}
	return result, nil
}

func output(bundle, result string, processes []int) {
	_ = json.NewEncoder(os.Stdout).Encode(struct {
		BundleID string `json:"bundleId"`
		Result   string `json:"result"`
		Running  bool   `json:"running"`
		PIDs     []int  `json:"pids"`
	}{bundle, result, len(processes) > 0, processes})
}

func run(args []string) int {
	if len(args) == 0 || (args[0] != "status" && args[0] != "quit") {
		fmt.Fprintln(os.Stderr, "usage: app-lifecycle status|quit --bundle-id ID [--timeout 45]")
		return 2
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	bundle := flags.String("bundle-id", "", "application bundle ID")
	path := flags.String("app-path", "", "exact application bundle path")
	timeout := flags.Int("timeout", 45, "graceful termination deadline in seconds")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 0 || *timeout < 1 || *timeout > 60 {
		return 2
	}
	expected := ""
	switch *bundle {
	case "com.openai.codex":
		expected = "/Applications/ChatGPT.app"
	case "com.anthropic.claudefordesktop":
		expected = "/Applications/Claude.app"
	case "tech.devantler.desktop-app-updates.canary":
		expected = *path
	default:
		fmt.Fprintln(os.Stderr, "application is outside the lifecycle allow-list")
		return 2
	}
	if *path == "" {
		*path = expected
	}
	if !filepath.IsAbs(*path) || filepath.Clean(*path) != expected || *path != expected {
		fmt.Fprintln(os.Stderr, "application path does not match the lifecycle allow-list")
		return 2
	}
	if args[0] == "quit" {
		info, err := os.Stat(*path)
		if err != nil || !info.IsDir() {
			fmt.Fprintln(os.Stderr, "application bundle path is unavailable")
			return 2
		}
	}
	processes, err := pids(*bundle, *path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if args[0] == "status" || len(processes) == 0 {
		output(*bundle, "observed", processes)
		return 0
	}
	name := C.CString(*bundle)
	appPath := C.CString(*path)
	accepted := C.desktop_app_request_quit(name, appPath)
	C.free(unsafe.Pointer(appPath))
	C.free(unsafe.Pointer(name))
	if accepted != 0 {
		output(*bundle, "quit_refused", processes)
		return 1
	}
	deadline := time.Now().Add(time.Duration(*timeout) * time.Second)
	for time.Now().Before(deadline) {
		C.desktop_app_pump()
		processes, err = pids(*bundle, *path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 2
		}
		if len(processes) == 0 {
			output(*bundle, "closed", processes)
			return 0
		}
	}
	output(*bundle, "quit_timed_out", processes)
	return 1
}

func main() { os.Exit(run(os.Args[1:])) }
