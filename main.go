package main

import (
	"os"

	"github.com/VMCoud/komari-agent/cmd"
)

func main() {
	cmd.Execute()
	os.Exit(0)
}
