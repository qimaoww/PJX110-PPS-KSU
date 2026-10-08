package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/u-root/u-root/pkg/dt"
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  dtbo-profile-patcher probe <image.img>")
	fmt.Fprintln(os.Stderr, "  dtbo-profile-patcher build <stock.img> <template.dtbo> <pps33|pps55> <output.img>")
	fmt.Fprintln(os.Stderr, "  dtbo-profile-patcher verify <image.img>")
}

func sanitize(value string) string {
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	value = strings.ReplaceAll(value, "=", " ")
	return strings.TrimSpace(value)
}

func printKV(key string, value any) {
	fmt.Printf("%s=%s\n", key, sanitize(fmt.Sprint(value)))
}

func imageProfile(image *dtboImage) (profileState, error) {
	var state profileState
	for i := range image.Entries {
		_, current, err := inspectLayout(image.Entries[i].Tree)
		if err != nil {
			return "", fmt.Errorf("entry %d: %w", i, err)
		}
		if i == 0 {
			state = current
		} else if current != state {
			return "", fmt.Errorf("mixed entry profiles: %s and %s", state, current)
		}
	}
	return state, nil
}

func probe(path string) error {
	image, err := parseDTBO(path)
	if err != nil {
		printKV("state", "incompatible")
		printKV("message", err)
		return err
	}
	profile, err := imageProfile(image)
	if err != nil {
		printKV("state", "incompatible")
		printKV("message", err)
		return err
	}
	printKV("state", "compatible")
	printKV("profile", profile)
	printKV("sha256", image.SourceSHA256)
	printKV("entries", len(image.Entries))
	printKV("partition_size", image.PartitionSize)
	printKV("avb", 1)
	return nil
}

func loadTemplate(path string) (*dt.FDT, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("template must be a regular file")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return dt.ReadFDT(bytes.NewReader(raw))
}

func atomicWrite(path string, data []byte) (err error) {
	info, statErr := os.Stat(path)
	if statErr == nil && !info.Mode().IsRegular() {
		return fmt.Errorf("output must be a regular image file, not a device or directory")
	}
	if statErr != nil && !os.IsNotExist(statErr) {
		return statErr
	}
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer func() {
		if err != nil {
			file.Close()
			os.Remove(temp)
		}
	}()
	if err = file.Chmod(0600); err != nil {
		return err
	}
	if _, err = file.Write(data); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if err = os.Rename(temp, path); err == nil {
		return nil
	}
	// Unix rename replaces an existing file atomically. Windows does not, so
	// retain the host-side developer workflow without weakening Linux runtime
	// atomicity or deleting an output after an unrelated rename failure.
	if runtime.GOOS != "windows" {
		return err
	}
	if removeErr := os.Remove(path); removeErr != nil && !os.IsNotExist(removeErr) {
		return removeErr
	}
	return os.Rename(temp, path)
}

func sameFilePath(a, b string) bool {
	aAbs, aErr := filepath.Abs(a)
	bAbs, bErr := filepath.Abs(b)
	if aErr == nil && bErr == nil && filepath.Clean(aAbs) == filepath.Clean(bAbs) {
		return true
	}
	aInfo, aErr := os.Stat(a)
	bInfo, bErr := os.Stat(b)
	return aErr == nil && bErr == nil && os.SameFile(aInfo, bInfo)
}

func build(sourcePath, templatePath string, target profileState, outputPath string) error {
	if target != profilePPS33 && target != profilePPS55 {
		return fmt.Errorf("invalid target profile %q", target)
	}
	if sameFilePath(outputPath, sourcePath) || sameFilePath(outputPath, templatePath) {
		return fmt.Errorf("output path must not replace an input file")
	}
	image, err := parseDTBO(sourcePath)
	if err != nil {
		return err
	}
	state, err := imageProfile(image)
	if err != nil {
		return err
	}
	if state != profileStock {
		return fmt.Errorf("source image is %s, not stock", state)
	}
	template, err := loadTemplate(templatePath)
	if err != nil {
		return err
	}
	for i := range image.Entries {
		if err := applyProfile(image.Entries[i].Tree, template, target); err != nil {
			return fmt.Errorf("entry %d: %w", i, err)
		}
	}
	rebuilt, err := image.serialize()
	if err != nil {
		return err
	}
	if err := atomicWrite(outputPath, rebuilt); err != nil {
		return err
	}
	verified, err := parseDTBO(outputPath)
	if err != nil {
		return fmt.Errorf("rebuilt image verification failed: %w", err)
	}
	verifiedState, err := imageProfile(verified)
	if err != nil || verifiedState != target {
		return fmt.Errorf("rebuilt profile verification failed: state=%s error=%v", verifiedState, err)
	}
	hash := sha256.Sum256(rebuilt)
	printKV("state", "ok")
	printKV("profile", target)
	printKV("source_sha256", image.SourceSHA256)
	printKV("output_sha256", hex.EncodeToString(hash[:]))
	printKV("entries", len(image.Entries))
	printKV("partition_size", len(rebuilt))
	return nil
}

func verify(path string) error {
	image, err := parseDTBO(path)
	if err != nil {
		return err
	}
	state, err := imageProfile(image)
	if err != nil {
		return err
	}
	printKV("state", "ok")
	printKV("profile", state)
	printKV("sha256", image.SourceSHA256)
	printKV("entries", len(image.Entries))
	printKV("partition_size", image.PartitionSize)
	return nil
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "probe":
		if len(os.Args) != 3 {
			usage()
			os.Exit(2)
		}
		err = probe(os.Args[2])
	case "build":
		if len(os.Args) != 6 {
			usage()
			os.Exit(2)
		}
		err = build(os.Args[2], os.Args[3], profileState(os.Args[4]), os.Args[5])
	case "verify":
		if len(os.Args) != 3 {
			usage()
			os.Exit(2)
		}
		err = verify(os.Args[2])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
