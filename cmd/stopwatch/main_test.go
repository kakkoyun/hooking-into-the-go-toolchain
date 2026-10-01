package main

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestMain lets the test binary act as the stopwatch wrapper.
func TestMain(m *testing.M) {
	if os.Getenv("STOPWATCH_TEST_RUN_MAIN") == "1" {
		os.Args = append([]string{"stopwatch"}, os.Args[1:]...)
		main()
		return
	}
	os.Exit(m.Run())
}

func wrapper(t *testing.T, env []string, args ...string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), "STOPWATCH_TEST_RUN_MAIN=1")
	cmd.Env = append(cmd.Env, env...)
	return cmd
}

func TestWrapperPassesThroughOutputAndExitCode(t *testing.T) {
	logFile := filepath.Join(t.TempDir(), "log.tsv")
	cmd := wrapper(t, []string{"STOPWATCH_LOG=" + logFile, "TOOLEXEC_IMPORTPATH=example.com/p"},
		"/bin/sh", "-c", "echo out; echo err >&2; exit 3")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	err := cmd.Run()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.ExitCode() != 3 {
		t.Fatalf("err = %v, want exit status 3", err)
	}
	if stdout.String() != "out\n" || stderr.String() != "err\n" {
		t.Errorf("stdout %q, stderr %q", stdout.String(), stderr.String())
	}

	data, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatal(err)
	}
	fields := strings.Split(strings.TrimSuffix(string(data), "\n"), "\t")
	if len(fields) != 4 || fields[0] != "sh" || fields[1] != "example.com/p" || fields[3] != "files=0" {
		t.Errorf("log line = %q", data)
	}
}

func TestWrapperStdoutVariantPrintsRecordToStdout(t *testing.T) {
	cmd := wrapper(t, []string{"STOPWATCH_STDOUT=1"}, "/bin/sh", "-c", "echo answer")
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(lines) != 2 || lines[0] != "answer" || !strings.HasPrefix(lines[1], "sh\t-\t") {
		t.Errorf("stdout = %q", out)
	}
}

func TestWrapperForwardsSignals(t *testing.T) {
	cmd := wrapper(t, nil, "/bin/sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond) // let the wrapper install its handler and start sleep
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) || exitErr.ExitCode() != 128+int(syscall.SIGTERM) {
			t.Errorf("err = %v, want exit status 143", err)
		}
	case <-time.After(10 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("wrapper did not stop after SIGTERM")
	}
}
