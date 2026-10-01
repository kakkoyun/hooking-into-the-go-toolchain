package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// shortHash returns 8 hex digits identifying parts.
func shortHash(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(sum[:4])
}

// answerVersionProbe answers the "tool -V=full" probe cmd/go uses to compute
// the tool ID that is hashed into every build cache key. Without TOYHOOK_MARK
// the real answer passes through unchanged.
func answerVersionProbe(cfg config, tool string) int {
	cmd := exec.Command(tool, "-V=full")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		fmt.Fprintf(os.Stderr, "toyhook: %v\n", err)
		return 1
	}
	if !cfg.mark {
		if _, err := os.Stdout.Write(out); err != nil {
			fmt.Fprintf(os.Stderr, "toyhook: %v\n", err)
			return 1
		}
		return 0
	}
	fmt.Println(markVersion(string(out), cfg.rulesHash()))
	return 0
}

// markVersion appends a toyhook marker to a "-V=full" line so that the tool
// ID, and with it every cache key, differs from a plain build's.
//
// cmd/go uses the whole line for release toolchains. For "devel" toolchains it
// only uses the content ID in the trailing buildID=... field, so the marker
// has to go inside that field (and must not contain a slash).
func markVersion(line, hash string) string {
	line = strings.TrimSpace(line)
	f := strings.Fields(line)
	if len(f) >= 3 && strings.Contains(f[2], "devel") {
		return line + "+toyhook@v1+" + hash
	}
	return line + " toyhook@v1/" + hash
}
