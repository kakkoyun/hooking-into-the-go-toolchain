// Package hooks holds the function that step 5 links into package os.
package hooks

import (
	"fmt"
	"os"
)

// OnReadFile is called from os.ReadFile through a //go:linkname reference
// that cmd/toyhook injects into the standard library.
func OnReadFile(name string) {
	fmt.Fprintf(os.Stderr, "hooks.OnReadFile(%q)\n", name)
}
