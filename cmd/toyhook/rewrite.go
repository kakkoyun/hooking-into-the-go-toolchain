package main

import (
	"cmp"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

const (
	directive = "//demo:log"

	linknameFileName = "toyhook_linkname.go"
	linknameFile     = `package os

import _ "unsafe"

//go:linkname toyhookOnReadFile ` + modulePath + `/hooks.OnReadFile
func toyhookOnReadFile(name string)
`
)

// edit inserts text at a byte offset of the original source.
type edit struct {
	offset int
	text   string
}

// rewriteFile returns the source of path with the mode's statement inserted
// at the top of every matching function, and the number of functions changed.
// n == 0 means the file needs no change.
func rewriteFile(cfg config, path string) (rewritten []byte, n int, err error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, 0, err
	}
	return rewriteSource(cfg.mode, abs, src)
}

func rewriteSource(mode, abs string, src []byte) (rewritten []byte, n int, err error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, abs, src, parser.ParseComments)
	if err != nil {
		return nil, 0, err
	}

	var edits []edit
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		stmt, ok := statementFor(mode, file, fn)
		if !ok {
			continue
		}
		lbrace := fset.Position(fn.Body.Lbrace)
		// The //line directive gives the rest of the file its original line
		// numbers and file name, so positions in errors, panics and profiles
		// still point at the file the author wrote.
		edits = append(edits, edit{
			offset: lbrace.Offset + 1,
			text:   fmt.Sprintf("\n\t%s\n//line %s:%d", stmt, abs, lbrace.Line+1),
		})
	}
	if len(edits) == 0 {
		return src, 0, nil
	}

	funcs := len(edits)
	if mode == modeSlog && !importsPath(file, "log/slog") {
		pkg := fset.Position(file.Name.End())
		edits = append(edits, edit{
			offset: pkg.Offset,
			text:   fmt.Sprintf("\nimport %q\n//line %s:%d", "log/slog", abs, pkg.Line+1),
		})
	}

	// Apply from the end so earlier offsets stay valid.
	slices.SortFunc(edits, func(a, b edit) int { return cmp.Compare(b.offset, a.offset) })
	out := slices.Clone(src)
	for _, e := range edits {
		out = slices.Insert(out, e.offset, []byte(e.text)...)
	}
	return out, funcs, nil
}

// statementFor returns the statement to insert at the top of fn, if fn is a
// target of the mode.
func statementFor(mode string, file *ast.File, fn *ast.FuncDecl) (string, bool) {
	switch mode {
	case modeRewrite, modeSlog:
		if !hasDirective(fn) {
			return "", false
		}
		name := strconv.Quote(fn.Name.Name)
		if mode == modeSlog {
			return fmt.Sprintf("slog.Info(\"enter\", \"func\", %s)", name), true
		}
		return fmt.Sprintf("fmt.Fprintf(os.Stderr, \"→ %%s at %%s\\n\", %s, time.Now().Format(time.TimeOnly))", name), true
	case modeLinkname:
		if file.Name.Name != "os" || fn.Recv != nil || fn.Name.Name != "ReadFile" {
			return "", false
		}
		return fmt.Sprintf("toyhookOnReadFile(%s)", fn.Type.Params.List[0].Names[0].Name), true
	}
	return "", false
}

func hasDirective(fn *ast.FuncDecl) bool {
	if fn.Doc == nil {
		return false
	}
	for _, c := range fn.Doc.List {
		if strings.TrimSpace(c.Text) == directive {
			return true
		}
	}
	return false
}

func importsPath(file *ast.File, path string) bool {
	for _, imp := range file.Imports {
		if p, err := strconv.Unquote(imp.Path.Value); err == nil && p == path {
			return true
		}
	}
	return false
}
