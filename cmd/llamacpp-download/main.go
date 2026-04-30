// llamacpp-download saves the lemonade gfx1150 llama-server zip to a directory.
// Intended for airgap prepare: download on online machine, ship on T9 drive.
//
// Usage:
//
//	llamacpp-download --dest DIR     # download zip to DIR
//	llamacpp-download --check DIR    # exit 0 if zip already in DIR, 1 if not
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"airgap-llm/installer"
)

func log(msg string) { fmt.Println(msg) }

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "Användning: llamacpp-download [--dest|--check] DIR")
		os.Exit(1)
	}

	flag, dir := os.Args[1], os.Args[2]

	switch flag {
	case "--check":
		matches, _ := filepath.Glob(filepath.Join(dir, "llama-*-ubuntu-rocm-gfx1150*.zip"))
		if len(matches) > 0 {
			fmt.Println("finns:", matches[0])
			os.Exit(0)
		}
		fmt.Fprintln(os.Stderr, "saknas")
		os.Exit(1)

	case "--dest":
		if _, err := installer.DownloadZip(dir, log); err != nil {
			fmt.Fprintln(os.Stderr, "Fel:", err)
			os.Exit(1)
		}

	default:
		fmt.Fprintln(os.Stderr, "Okänd flagga:", flag)
		os.Exit(1)
	}
}
