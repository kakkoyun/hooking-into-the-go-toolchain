// Command other shares package greet with ./app. It is never built with
// -toolexec in the poisoning demo.
package main

import (
	"fmt"

	"github.com/kakkoyun/hooking-into-the-go-toolchain/greet"
)

func main() {
	fmt.Println(greet.Hello("other"))
}
