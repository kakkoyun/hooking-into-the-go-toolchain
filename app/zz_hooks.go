//go:build toyhook

package main

// Linking hooks is what satisfies the //go:linkname reference that step 5
// injects into package os.
import _ "github.com/kakkoyun/hooking-into-the-go-toolchain/hooks"
