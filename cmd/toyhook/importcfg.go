package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

const (
	injectedPackage = "log/slog"

	listExportTemplate = `{{if .Export}}packagefile {{.ImportPath}}={{.Export}}{{end}}`
)

// patchImportcfg points the -importcfg argument at a copy of the file with
// packagefile lines appended for log/slog and its dependencies. kind is
// "compile" or "link" and only labels the verbose output.
func patchImportcfg(cfg config, tool string, args []string, kind string) ([]string, error) {
	path := flagValue(args, "-importcfg")
	if path == "" {
		return nil, fmt.Errorf("%s call without -importcfg", kind)
	}
	base, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	extra, err := exportLines(cfg, tool)
	if err != nil {
		return nil, err
	}
	merged, added := mergePackageFiles(string(base), extra)
	cfg.logf("%s importcfg %s: %d lines, adding %d:", kind, path, strings.Count(string(base), "\n"), len(added))
	for _, l := range added {
		cfg.logf("  + %s", l)
	}
	patched := path + ".toyhook"
	if err := os.WriteFile(patched, []byte(merged), 0o644); err != nil {
		return nil, err
	}
	return withFlagValue(args, "-importcfg", patched), nil
}

// mergePackageFiles appends the lines of extra whose package base does not
// mention yet. It returns the merged text and the lines it added.
func mergePackageFiles(base string, extra []string) (merged string, added []string) {
	have := map[string]bool{}
	for line := range strings.SplitSeq(base, "\n") {
		if pkg, ok := packageOf(line); ok {
			have[pkg] = true
		}
	}
	var b strings.Builder
	b.WriteString(base)
	if base != "" && !strings.HasSuffix(base, "\n") {
		b.WriteByte('\n')
	}
	for _, line := range extra {
		if pkg, ok := packageOf(line); ok && !have[pkg] {
			b.WriteString(line + "\n")
			added = append(added, line)
		}
	}
	return b.String(), added
}

// packageOf extracts the import path from a "packagefile path=file" line.
func packageOf(line string) (string, bool) {
	rest, ok := strings.CutPrefix(line, "packagefile ")
	if !ok {
		return "", false
	}
	pkg, _, ok := strings.Cut(rest, "=")
	return pkg, ok
}

// exportLines returns "packagefile" lines for log/slog and its dependencies,
// taken from the export data go list builds. The answer is cached in the
// state directory, because compile and link both ask for it.
func exportLines(cfg config, tool string) ([]string, error) {
	// tool is $GOROOT/pkg/tool/<os_arch>/<name>; use the matching go command.
	goroot := filepath.Join(filepath.Dir(tool), "..", "..", "..")
	goBin := filepath.Join(goroot, "bin", "go")

	cached := filepath.Join(cfg.state, "export-"+shortHash(goBin, os.Getenv("GOCACHE"), injectedPackage)+".txt")
	if data, err := os.ReadFile(cached); err == nil {
		return readLines(string(data)), nil
	}

	// A plain go list, without -toolexec and without GOFLAGS: the wrapper
	// must not call itself. For the same reason the outer build's flags (-tags,
	// -race, -gcflags, -a) do not reach it, so this patching assumes the outer
	// build uses default flags; otherwise the export data could not match.
	cmd := exec.Command(goBin, "list", "-deps", "-export", "-f", listExportTemplate, injectedPackage)
	cmd.Env = append(os.Environ(), "GOFLAGS=")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("go list -export %s: %w", injectedPackage, err)
	}

	if err := os.MkdirAll(cfg.state, 0o755); err != nil {
		return nil, err
	}
	tmp, err := os.CreateTemp(cfg.state, "export-*.tmp")
	if err != nil {
		return nil, err
	}
	_, werr := tmp.Write(out)
	cerr := tmp.Close()
	if err := errors.Join(werr, cerr); err != nil {
		os.Remove(tmp.Name())
		return nil, err
	}
	if err := os.Rename(tmp.Name(), cached); err != nil {
		return nil, err
	}
	return readLines(string(out)), nil
}

func readLines(s string) []string {
	var lines []string
	sc := bufio.NewScanner(strings.NewReader(s))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		if l := strings.TrimSpace(sc.Text()); l != "" {
			lines = append(lines, l)
		}
	}
	return slices.Clip(lines)
}
