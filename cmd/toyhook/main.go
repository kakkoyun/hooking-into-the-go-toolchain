// Command toyhook is a -toolexec wrapper that rewrites source code on its way
// to the compiler. One binary, several behaviours, selected by environment:
//
//	TOYHOOK_MODE       rewrite | slog | linkname
//	TOYHOOK_TARGET     import path of the package to rewrite (default depends on mode)
//	TOYHOOK_IMPORTCFG  "patch": add missing packagefile lines to compile and link importcfg
//	TOYHOOK_MARK       "1": append a toyhook marker to the "-V=full" answer
//	TOYHOOK_VERBOSE    "1": describe what was changed on stderr
//	TOYHOOK_STATE      directory for the cached "go list -export" answer
//
// With no TOYHOOK_MODE it passes every tool call through unchanged.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

const (
	modulePath = "github.com/kakkoyun/hooking-into-the-go-toolchain"

	modeRewrite  = "rewrite"
	modeSlog     = "slog"
	modeLinkname = "linkname"
)

type config struct {
	mode     string
	target   string
	patchCfg bool
	mark     bool
	verbose  bool
	state    string
}

func loadConfig() config {
	c := config{
		mode:     os.Getenv("TOYHOOK_MODE"),
		target:   os.Getenv("TOYHOOK_TARGET"),
		patchCfg: os.Getenv("TOYHOOK_IMPORTCFG") == "patch",
		mark:     os.Getenv("TOYHOOK_MARK") == "1",
		verbose:  os.Getenv("TOYHOOK_VERBOSE") == "1",
		state:    os.Getenv("TOYHOOK_STATE"),
	}
	if c.target == "" {
		if c.mode == modeLinkname {
			c.target = "os"
		} else {
			c.target = modulePath + "/app"
		}
	}
	if c.state == "" {
		c.state = filepath.Join(os.TempDir(), "toyhook")
	}
	return c
}

// rulesHash identifies the rewrite rules. It goes into the "-V=full" marker so
// that changing the rules changes every build cache key.
func (c config) rulesHash() string {
	return shortHash(c.mode, c.target, fmt.Sprint(c.patchCfg))
}

func (c config) logf(format string, args ...any) {
	if c.verbose {
		fmt.Fprintf(os.Stderr, "toyhook: "+format+"\n", args...)
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: toyhook <tool> [args...]")
		os.Exit(2)
	}
	cfg := loadConfig()
	tool, args := os.Args[1], os.Args[2:]

	if len(args) == 1 && args[0] == "-V=full" {
		os.Exit(answerVersionProbe(cfg, tool))
	}
	if cfg.mode == "" {
		os.Exit(run(tool, args))
	}

	importPath := os.Getenv("TOOLEXEC_IMPORTPATH")
	var err error
	switch filepath.Base(tool) {
	case "compile":
		if importPath == cfg.target {
			args, err = rewriteCompile(cfg, tool, args)
		}
	case "link":
		if importPath == cfg.target && cfg.patchCfg {
			args, err = patchImportcfg(cfg, tool, args, "link")
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "toyhook: %v\n", err)
		os.Exit(1)
	}
	os.Exit(run(tool, args))
}

// run executes the real tool with the wrapper's stdio and returns its exit code.
func run(tool string, args []string) int {
	cmd := exec.Command(tool, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err := cmd.Run()
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
	fmt.Fprintf(os.Stderr, "toyhook: %v\n", err)
	return 1
}

// flagValue returns the argument that follows name, or "".
func flagValue(args []string, name string) string {
	if i := slices.Index(args, name); i >= 0 && i+1 < len(args) {
		return args[i+1]
	}
	return ""
}

// withFlagValue returns a copy of args with the value after name replaced.
func withFlagValue(args []string, name, value string) []string {
	out := slices.Clone(args)
	if i := slices.Index(out, name); i >= 0 && i+1 < len(out) {
		out[i+1] = value
	}
	return out
}

// rewriteCompile edits the arguments of one compile invocation: it swaps
// rewritten copies of the package's Go files into the arguments, optionally
// patches the importcfg, and (linkname mode) adds a generated file.
func rewriteCompile(cfg config, tool string, args []string) ([]string, error) {
	out := flagValue(args, "-o")
	if out == "" {
		return nil, errors.New("compile call without -o")
	}
	workDir := filepath.Dir(out)
	cfg.logf("compile %s before: %s", cfg.target, strings.Join(args, " "))

	newArgs := slices.Clone(args)
	changed := false
	for i, arg := range newArgs {
		if !strings.HasSuffix(arg, ".go") {
			continue
		}
		rewritten, n, err := rewriteFile(cfg, arg)
		if err != nil {
			return nil, err
		}
		if n == 0 {
			continue
		}
		dst := filepath.Join(workDir, filepath.Base(arg))
		if err := os.WriteFile(dst, rewritten, 0o644); err != nil {
			return nil, err
		}
		cfg.logf("rewrote %d function(s) in %s -> %s", n, arg, dst)
		newArgs[i] = dst
		changed = true
	}

	if cfg.mode == modeLinkname {
		if !changed {
			return nil, errors.New("os.ReadFile not found in the compile arguments")
		}
		dst := filepath.Join(workDir, linknameFileName)
		if err := os.WriteFile(dst, []byte(linknameFile), 0o644); err != nil {
			return nil, err
		}
		cfg.logf("generated %s", dst)
		newArgs = append(newArgs, dst)
		// -complete makes the compiler reject bodyless functions unless they
		// carry //go:linkname (golang/go#23311, cmd/compile/internal/noder/
		// writer.go in Go 1.27.1), and ours does. cmd/go omits -complete for
		// os anyway (cmd/go/internal/work/gc.go). This strip is a defensive
		// no-op; record whether it was needed.
		if slices.Contains(newArgs, "-complete") {
			newArgs = slices.DeleteFunc(newArgs, func(a string) bool { return a == "-complete" })
			cfg.logf("stripped -complete")
		} else {
			cfg.logf("-complete not present, nothing to strip")
		}
	}

	if cfg.patchCfg {
		var err error
		newArgs, err = patchImportcfg(cfg, tool, newArgs, "compile")
		if err != nil {
			return nil, err
		}
	}
	cfg.logf("compile %s after: %s", cfg.target, strings.Join(newArgs, " "))
	return newArgs, nil
}
