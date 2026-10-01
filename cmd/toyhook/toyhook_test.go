package main

import (
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

const sampleSource = `package demo

import "fmt"

//demo:log
func traced(n int) int {
	fmt.Println(n)
	return n
}

func untraced() {}
`

func TestRewriteSourceInsertsStatementAndKeepsLines(t *testing.T) {
	got, n, err := rewriteSource(modeRewrite, "/src/demo.go", []byte(sampleSource))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("rewrote %d functions, want 1", n)
	}
	out := string(got)
	wantStmt := `fmt.Fprintf(os.Stderr, "→ %s at %s\n", "traced", time.Now().Format(time.TimeOnly))`
	if !strings.Contains(out, wantStmt) {
		t.Errorf("missing statement:\n%s", out)
	}
	// The body starts on line 7 of the original, right after the directive.
	if !strings.Contains(out, "//line /src/demo.go:7\n") {
		t.Errorf("missing //line directive:\n%s", out)
	}
	if strings.Contains(out, `"untraced"`) {
		t.Errorf("untraced function was touched:\n%s", out)
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "demo.go", got, 0); err != nil {
		t.Errorf("rewritten source does not parse: %v\n%s", err, out)
	}
}

func TestRewriteSourceSlogAddsImportOnce(t *testing.T) {
	got, _, err := rewriteSource(modeSlog, "/src/demo.go", []byte(sampleSource))
	if err != nil {
		t.Fatal(err)
	}
	if c := strings.Count(string(got), `import "log/slog"`); c != 1 {
		t.Errorf("log/slog imported %d times, want 1:\n%s", c, got)
	}

	withSlog := strings.Replace(sampleSource, `import "fmt"`, "import (\n\t\"fmt\"\n\t\"log/slog\"\n)", 1)
	got, _, err = rewriteSource(modeSlog, "/src/demo.go", []byte(withSlog))
	if err != nil {
		t.Fatal(err)
	}
	if c := strings.Count(string(got), `"log/slog"`); c != 1 {
		t.Errorf("existing log/slog import duplicated (%d):\n%s", c, got)
	}
}

func TestRewriteSourceLinknameTargetsOsReadFile(t *testing.T) {
	src := "package os\n\nfunc ReadFile(name string) ([]byte, error) {\n\treturn nil, nil\n}\n\nfunc other(name string) {}\n"
	got, n, err := rewriteSource(modeLinkname, "/goroot/os/file.go", []byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 || !strings.Contains(string(got), "toyhookOnReadFile(name)") {
		t.Errorf("n=%d:\n%s", n, got)
	}

	// A function with the same name in another package is left alone.
	_, n, err = rewriteSource(modeLinkname, "/x.go", []byte(strings.Replace(src, "package os", "package notos", 1)))
	if err != nil || n != 0 {
		t.Errorf("rewrote a non-os package: n=%d err=%v", n, err)
	}
}

func TestMarkVersion(t *testing.T) {
	release := "compile version go1.27.1\n"
	if got, want := markVersion(release, "abcd1234"), "compile version go1.27.1 toyhook@v1/abcd1234"; got != want {
		t.Errorf("release: got %q, want %q", got, want)
	}

	// cmd/go reads only the content ID after the last slash of buildID=...
	// for devel toolchains, so the marker must sit inside that field and must
	// not add a slash of its own.
	devel := "compile version devel go1.28-abc123 Mon Jan 1 00:00:00 2026 +0000 buildID=aaa/bbb\n"
	got := markVersion(devel, "abcd1234")
	fields := strings.Fields(got)
	last := fields[len(fields)-1]
	if !strings.HasPrefix(last, "buildID=aaa/bbb") || !strings.Contains(last, "toyhook@v1") {
		t.Errorf("devel: marker not inside the buildID field: %q", got)
	}
	if contentID := last[strings.LastIndex(last, "/")+1:]; !strings.HasPrefix(contentID, "bbb+toyhook@v1+abcd1234") {
		t.Errorf("devel: content ID %q does not carry the marker", contentID)
	}
}

func TestMergePackageFiles(t *testing.T) {
	base := "# import config\npackagefile fmt=/a/fmt.a\npackagefile os=/a/os.a"
	extra := []string{"packagefile fmt=/b/fmt.a", "packagefile log/slog=/b/slog.a"}
	merged, added := mergePackageFiles(base, extra)
	if len(added) != 1 || added[0] != "packagefile log/slog=/b/slog.a" {
		t.Errorf("added = %v, want only log/slog", added)
	}
	want := base + "\npackagefile log/slog=/b/slog.a\n"
	if merged != want {
		t.Errorf("merged:\n%s\nwant:\n%s", merged, want)
	}
}
