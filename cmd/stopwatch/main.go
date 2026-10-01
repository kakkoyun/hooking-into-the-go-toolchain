// Command stopwatch is a -toolexec wrapper that times every tool invocation.
//
//	go build -toolexec=$PWD/.bin/stopwatch ./app
//
// It appends one line per invocation to the file named by $STOPWATCH_LOG:
//
//	<tool-basename> TAB <TOOLEXEC_IMPORTPATH or -> TAB <ms> TAB <args summary>
//
// The wrapped tool's stdout, stderr and stdin pass through untouched, signals
// are forwarded, and the exit status is the tool's.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: stopwatch <tool> [args...]")
		os.Exit(2)
	}
	tool, args := os.Args[1], os.Args[2:]

	cmd := exec.Command(tool, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr

	if os.Getenv("STOPWATCH_STDOUT") == "first" {
		// The second deliberate bug: announce the tool on stdout before it runs.
		fmt.Printf("stopwatch: starting %s\n", filepath.Base(tool))
	}
	// Install the handler before the tool starts, so no signal can hit the
	// wrapper with the default disposition while the tool is running.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	start := time.Now()
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "stopwatch: %v\n", err)
		os.Exit(1)
	}
	go func() {
		for sig := range sigs {
			_ = cmd.Process.Signal(sig)
		}
	}()

	err := cmd.Wait()
	elapsed := time.Since(start)
	logLine(tool, args, elapsed)
	os.Exit(exitCode(err))
}

// logLine appends one record to $STOPWATCH_LOG. With STOPWATCH_STDOUT=1 it
// prints the record to stdout instead. That is a deliberate bug: cmd/go reads
// the tool's stdout when it asks for "-V=full", so the extra line follows the
// tool's own answer. STOPWATCH_STDOUT=first is the other deliberate bug (see
// main).
func logLine(tool string, args []string, elapsed time.Duration) {
	importPath := os.Getenv("TOOLEXEC_IMPORTPATH")
	if importPath == "" {
		importPath = "-"
	}
	line := fmt.Sprintf("%s\t%s\t%d\t%s\n", filepath.Base(tool), importPath, elapsed.Milliseconds(), summarize(args))

	if os.Getenv("STOPWATCH_STDOUT") == "1" {
		fmt.Print(line)
		return
	}
	path := os.Getenv("STOPWATCH_LOG")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stopwatch: %v\n", err)
		return
	}
	defer f.Close()
	// One Write call per record keeps lines whole when tools run in parallel.
	if _, err := f.WriteString(line); err != nil {
		fmt.Fprintf(os.Stderr, "stopwatch: %v\n", err)
	}
}

// summarize keeps the log readable: the -V=full probe verbatim, otherwise
// the number of source files given to the tool.
func summarize(args []string) string {
	if slices.Contains(args, "-V=full") {
		return "-V=full"
	}
	n := 0
	for _, a := range args {
		if strings.HasSuffix(a, ".go") || strings.HasSuffix(a, ".s") {
			n++
		}
	}
	return fmt.Sprintf("files=%d", n)
}

// exitCode maps the result of cmd.Wait to the wrapper's exit status. A tool
// killed by a signal yields the shell convention 128+signal.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return exitErr.ExitCode()
	}
	fmt.Fprintf(os.Stderr, "stopwatch: %v\n", err)
	return 1
}
