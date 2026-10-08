package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func repoPath(parts ...string) string {
	all := append([]string{"..", ".."}, parts...)
	return filepath.Join(all...)
}

func TestParseBundledImages(t *testing.T) {
	type firmware struct {
		Family   string `json:"family"`
		StockSHA string `json:"stock_sha"`
		PPS33SHA string `json:"pps33_sha"`
		PPS55SHA string `json:"pps55_sha"`
	}
	data, err := os.ReadFile(repoPath("FIRMWARES.json"))
	if err != nil {
		t.Fatal(err)
	}
	var firmwares []firmware
	if err := json.Unmarshal(data, &firmwares); err != nil {
		t.Fatal(err)
	}
	if len(firmwares) != 19 {
		t.Fatalf("firmware count=%d, want 19", len(firmwares))
	}
	profiles := map[string]profileState{
		"stock": profileStock,
		"pps33": profilePPS33,
		"pps55": profilePPS55,
	}
	for _, firmware := range firmwares {
		family := firmware.Family
		stock, err := parseDTBO(repoPath("images", "dtbo_"+family+"_stock.img"))
		if err != nil {
			t.Fatal(err)
		}
		pins := map[string]string{"stock": firmware.StockSHA, "pps33": firmware.PPS33SHA, "pps55": firmware.PPS55SHA}
		for suffix, expected := range profiles {
			path := repoPath("images", "dtbo_"+family+"_"+suffix+".img")
			t.Run(family+"_"+suffix, func(t *testing.T) {
				image, err := parseDTBO(path)
				if err != nil {
					t.Fatal(err)
				}
				actual, err := imageProfile(image)
				if err != nil {
					t.Fatal(err)
				}
				if actual != expected {
					t.Fatalf("profile=%s, want %s", actual, expected)
				}
				if image.SourceSHA256 != pins[suffix] {
					t.Fatal("catalog/image hash mismatch")
				}
				if !bytes.Equal(stock.VBMeta, image.VBMeta) {
					t.Fatal("firmware-specific signed VBMeta was not preserved")
				}
				if image.PartitionSize != stock.PartitionSize {
					t.Fatal("partition size changed")
				}
			})
		}
	}
}

func TestBuildBothProfiles(t *testing.T) {
	stock := repoPath("images", "dtbo_1001_stock.img")
	template := repoPath("templates", "pps33-template.dtbo")
	for _, target := range []profileState{profilePPS33, profilePPS55} {
		t.Run(string(target), func(t *testing.T) {
			output := filepath.Join(t.TempDir(), string(target)+".img")
			if err := build(stock, template, target, output); err != nil {
				t.Fatal(err)
			}
			image, err := parseDTBO(output)
			if err != nil {
				t.Fatal(err)
			}
			actual, err := imageProfile(image)
			if err != nil || actual != target {
				t.Fatalf("profile=%s error=%v", actual, err)
			}
		})
	}
}

func TestBuildRefusesInputReplacement(t *testing.T) {
	stock := repoPath("images", "dtbo_1001_stock.img")
	template := repoPath("templates", "pps33-template.dtbo")
	if err := build(stock, template, profilePPS33, stock); err == nil {
		t.Fatal("build unexpectedly accepted source as output")
	}
}

func TestImageToolRefusesNonRegularFiles(t *testing.T) {
	dir := t.TempDir()
	if _, err := parseDTBO(dir); err == nil {
		t.Fatal("parser accepted directory")
	}
	if _, err := loadTemplate(dir); err == nil {
		t.Fatal("template reader accepted directory")
	}
	if err := atomicWrite(dir, []byte("bad")); err == nil {
		t.Fatal("writer accepted directory")
	}
	if info, err := os.Stat("/dev/null"); err == nil && !info.Mode().IsRegular() {
		if _, err := parseDTBO("/dev/null"); err == nil {
			t.Fatal("parser accepted device")
		}
		if _, err := loadTemplate("/dev/null"); err == nil {
			t.Fatal("template reader accepted device")
		}
		if err := atomicWrite("/dev/null", []byte("bad")); err == nil {
			t.Fatal("writer accepted device")
		}
	}
}

func TestRejectsCorruptedAVB(t *testing.T) {
	source := repoPath("images", "dtbo_1001_stock.img")
	raw, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}

	t.Run("footer", func(t *testing.T) {
		corrupt := append([]byte(nil), raw...)
		copy(corrupt[len(corrupt)-avbFooterLen:], "BAD!")
		path := filepath.Join(t.TempDir(), "bad-footer.img")
		if err := os.WriteFile(path, corrupt, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := parseDTBO(path); err == nil {
			t.Fatal("corrupted footer unexpectedly accepted")
		}
	})

	t.Run("descriptor", func(t *testing.T) {
		corrupt := append([]byte(nil), raw...)
		footer := corrupt[len(corrupt)-avbFooterLen:]
		vbmetaOffset := binaryBigEndianU64(footer[20:28])
		vbmetaSize := binaryBigEndianU64(footer[28:36])
		vbmeta := corrupt[vbmetaOffset : vbmetaOffset+vbmetaSize]
		index := bytes.Index(vbmeta, []byte("dtbo"))
		if index < 0 {
			t.Fatal("fixture has no dtbo descriptor name")
		}
		copy(vbmeta[index:index+4], "nope")
		path := filepath.Join(t.TempDir(), "bad-descriptor.img")
		if err := os.WriteFile(path, corrupt, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := parseDTBO(path); err == nil {
			t.Fatal("unrelated AVB descriptor unexpectedly accepted")
		}
	})
}

func binaryBigEndianU64(value []byte) uint64 {
	var result uint64
	for _, b := range value {
		result = result<<8 | uint64(b)
	}
	return result
}

func TestInvalidAVBNeverReachesBuildOutput(t *testing.T) {
	original, err := os.ReadFile(repoPath("images", "dtbo_1001_stock.img"))
	if err != nil {
		t.Fatal(err)
	}
	template := repoPath("templates", "pps33-template.dtbo")
	cases := map[string]func([]byte) []byte{
		"no-footer":        func(raw []byte) []byte { return raw[:len(raw)-avbFooterLen] },
		"truncated-footer": func(raw []byte) []byte { return raw[:len(raw)-1] },
		"vbmeta-magic": func(raw []byte) []byte {
			footer := raw[len(raw)-avbFooterLen:]
			offset := binary.BigEndian.Uint64(footer[20:28])
			copy(raw[offset:offset+4], "BAD!")
			return raw
		},
		"vbmeta-range": func(raw []byte) []byte {
			footer := raw[len(raw)-avbFooterLen:]
			binary.BigEndian.PutUint64(footer[28:36], ^uint64(0))
			return raw
		},
		"auth-addition-overflow": func(raw []byte) []byte {
			footer := raw[len(raw)-avbFooterLen:]
			offset := binary.BigEndian.Uint64(footer[20:28])
			size := binary.BigEndian.Uint64(footer[28:36])
			meta := raw[offset : offset+size]
			oldAuth := binary.BigEndian.Uint64(meta[12:20])
			oldDescriptors := binary.BigEndian.Uint64(meta[96:104])
			// The old parser's total and descriptor cursor could both wrap to
			// apparently correct values. This is still an invalid container.
			binary.BigEndian.PutUint64(meta[12:20], ^uint64(0))
			binary.BigEndian.PutUint64(meta[20:28], size-255)
			binary.BigEndian.PutUint64(meta[96:104], oldAuth+oldDescriptors+1)
			return raw
		},
		"descriptor-range": func(raw []byte) []byte {
			footer := raw[len(raw)-avbFooterLen:]
			offset := binary.BigEndian.Uint64(footer[20:28])
			size := binary.BigEndian.Uint64(footer[28:36])
			meta := raw[offset : offset+size]
			binary.BigEndian.PutUint64(meta[104:112], ^uint64(0))
			return raw
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			source := filepath.Join(dir, "invalid.img")
			output := filepath.Join(dir, "output.img")
			if err := os.WriteFile(source, mutate(append([]byte(nil), original...)), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := parseDTBO(source); err == nil {
				t.Fatal("invalid AVB was accepted")
			}
			if err := build(source, template, profilePPS33, output); err == nil {
				t.Fatal("invalid AVB reached a successful build")
			}
			if _, err := os.Stat(output); !os.IsNotExist(err) {
				t.Fatalf("rejected input unexpectedly created output: %v", err)
			}
		})
	}
}

func TestBuildPreservesSourceAndSignedVBMeta(t *testing.T) {
	source := repoPath("images", "dtbo_1001_stock.img")
	before, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	stock, err := parseDTBO(source)
	if err != nil {
		t.Fatal(err)
	}
	for _, profile := range []profileState{profilePPS33, profilePPS55} {
		output := filepath.Join(t.TempDir(), string(profile)+".img")
		if err := build(source, repoPath("templates", "pps33-template.dtbo"), profile, output); err != nil {
			t.Fatal(err)
		}
		image, err := parseDTBO(output)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(stock.VBMeta, image.VBMeta) {
			t.Fatal("signed stock VBMeta changed")
		}
		if stock.PartitionSize != image.PartitionSize {
			t.Fatal("partition size changed")
		}
	}
	after, err := os.ReadFile(source)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("build modified the stock source")
	}
}
