// Package greet is shared by ./app and ./other. The build-cache poisoning
// demo rewrites it while building ./app and then builds ./other without any
// -toolexec.
package greet

import (
	"fmt"
	"os"
	"time"
)

// Hello returns a greeting for name.
//
//demo:log
func Hello(name string) string {
	return fmt.Sprintf("hello, %s", name)
}

// Logf writes a timestamped line to stderr.
func Logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s %s\n", time.Now().Format(time.TimeOnly), fmt.Sprintf(format, args...))
}
