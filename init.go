// Suricata hardened init — replaces entrypoint.sh + healthcheck.
// Static binary, zero shell dependency.
//
// Usage:
//
//	init --healthcheck      run Docker healthcheck (exit 0/1)
//	init --setup-dirs       create runtime directories (build-time, FROM scratch)
//	init [CMD [ARGS...]]    entrypoint: config test, then exec CMD
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
)

const (
	suricataUID = 8000
	suricataGID = 8000
	pidFile     = "/var/run/suricata/suricata.pid"
	unixSocket  = "/var/run/suricata/suricata-command.socket"
	defaultConf = "/etc/suricata/suricata.yaml"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--healthcheck":
			os.Exit(healthcheck())
		case "--setup-dirs":
			if err := setupDirs(); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] setup-dirs: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}
	if err := entrypoint(); err != nil {
		fmt.Fprintf(os.Stderr, "[init][ERROR] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Setup directories — called at build time in FROM scratch stage.
// Creates runtime dirs with correct ownership; no shell needed.
// ---------------------------------------------------------------------------

func setupDirs() error {
	dirs := []struct {
		path string
		mode os.FileMode
		uid  int
		gid  int
	}{
		// Parent dirs first
		{"/var", 0755, 0, 0},
		{"/var/run", 0755, 0, 0},
		{"/var/log", 0755, 0, 0},
		{"/var/lib", 0755, 0, 0},
		// Leaf dirs with correct ownership
		{"/var/run/suricata", 0750, suricataUID, suricataGID},
		{"/var/log/suricata", 0755, suricataUID, suricataGID},
		{"/var/lib/suricata", 0755, suricataUID, suricataGID},
		{"/var/lib/suricata/rules", 0755, suricataUID, suricataGID},
		{"/tmp", 01777, 0, 0},
	}
	for _, d := range dirs {
		fmt.Printf("[init] mkdir %s (mode=%04o uid=%d gid=%d)\n", d.path, d.mode, d.uid, d.gid)
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return fmt.Errorf("mkdir %s: %w", d.path, err)
		}
		if err := os.Chmod(d.path, d.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", d.path, err)
		}
		if err := os.Chown(d.path, d.uid, d.gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
	}
	fmt.Println("[init] setup-dirs complete")
	return nil
}

// ---------------------------------------------------------------------------
// Healthcheck: verify Suricata process is alive via PID file
// ---------------------------------------------------------------------------

func healthcheck() int {
	// Strategy 1: PID file (NFQUEUE/pcap daemon mode)
	data, err := os.ReadFile(pidFile)
	if err == nil {
		pid, err := strconv.Atoi(trimSpace(string(data)))
		if err == nil {
			proc, err := os.FindProcess(pid)
			if err == nil {
				if err := proc.Signal(syscall.Signal(0)); err == nil {
					return 0
				}
			}
		}
	}

	// Strategy 2: Unix command socket exists (unix-socket mode)
	if info, err := os.Stat(unixSocket); err == nil {
		if info.Mode()&os.ModeSocket != 0 {
			return 0
		}
	}

	fmt.Fprintf(os.Stderr, "[healthcheck] suricata not responding (no pid file, no unix socket)\n")
	return 1
}

// ---------------------------------------------------------------------------
// Entrypoint: validate config then exec suricata
// ---------------------------------------------------------------------------

func entrypoint() error {
	conf := env("SURICATA_CONF", defaultConf)

	// Verify config file exists
	if !exists(conf) {
		return fmt.Errorf("config file %s not found", conf)
	}

	// Verify rules directory is accessible
	rulesDir := "/var/lib/suricata/rules"
	if !exists(rulesDir) {
		log("WARNING: rules directory %s does not exist", rulesDir)
	}

	// Ensure log directory is writable
	if err := ensureWritable("/var/log/suricata", suricataUID, suricataGID); err != nil {
		return err
	}

	// Ensure run directory is writable (PID file + unix socket)
	if err := ensureWritable("/var/run/suricata", suricataUID, suricataGID); err != nil {
		return err
	}

	// Config validation (suricata -T)
	// Note: suricata -T returns exit 1 if any rule fails to parse (e.g. rules
	// referencing protocols with detection-enabled: no). This is non-fatal —
	// Suricata skips those rules and starts normally. Only treat as fatal if
	// SURICATA_STRICT_TEST=1 is set.
	log("Validating configuration...")
	if err := run("/usr/bin/suricata", "-T", "-c", conf); err != nil {
		if env("SURICATA_STRICT_TEST", "") == "1" {
			return fmt.Errorf("suricata config test failed: %w", err)
		}
		log("WARNING: config test returned errors (non-fatal, rule parse errors are expected)")
	} else {
		log("Configuration OK")
	}

	// Exec suricata (replaces this process)
	// If first arg is not "suricata", prepend it. This handles the case
	// where VyOS passes raw arguments (e.g. "-q 0 -q 1 --runmode workers")
	// which override the Dockerfile CMD.
	args := os.Args[1:]
	if len(args) == 0 || args[0] != "suricata" {
		args = append([]string{"suricata"}, args...)
	}
	log("Starting Suricata: %v", args)
	return execCmd(args)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func execCmd(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("no command specified")
	}
	bin, err := exec.LookPath(args[0])
	if err != nil {
		return fmt.Errorf("command not found: %s", args[0])
	}
	return syscall.Exec(bin, args, os.Environ())
}

func ensureWritable(path string, uid, gid int) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("%s exists but is not a directory", path)
	}
	// Fast path: already writable
	tmp, err := os.CreateTemp(path, ".write-test-*")
	if err == nil {
		name := tmp.Name()
		tmp.Close()
		os.Remove(name)
		return nil
	}
	// Not writable — attempt chown (best-effort)
	log("%s is not writable by uid %d, attempting chown to %d:%d", path, os.Getuid(), uid, gid)
	if chErr := chownRecursive(path, uid, gid); chErr == nil {
		tmp2, err2 := os.CreateTemp(path, ".write-test-*")
		if err2 == nil {
			name := tmp2.Name()
			tmp2.Close()
			os.Remove(name)
			log("fixed ownership of %s", path)
			return nil
		}
	}
	return fmt.Errorf(
		"%s is not writable by uid %d.\n"+
			"  Fix with: sudo chown -R %d:%d <host-path-mounted-to%s>",
		path, os.Getuid(), uid, gid, path,
	)
}

func chownRecursive(path string, uid, gid int) error {
	return filepath.Walk(path, func(name string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chown(name, uid, gid)
	})
}

func trimSpace(s string) string {
	result := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != ' ' && s[i] != '\t' && s[i] != '\n' && s[i] != '\r' {
			result = append(result, s[i])
		}
	}
	return string(result)
}

func log(format string, a ...any) {
	fmt.Printf("[init] "+format+"\n", a...)
}
