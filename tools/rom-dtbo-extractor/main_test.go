package main

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestRejectMalformedProtobuf(t *testing.T) {
	for _, raw := range [][]byte{{0}, {8, 0x80}, {10, 3, 1}, {15, 0}, {9, 1}, {13, 1}} {
		if _, err := decode(raw); err == nil {
			t.Fatalf("accepted malformed bytes %x", raw)
		}
	}
	fields, err := decode([]byte{8, 1, 8, 2})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := one(fields, 1); err == nil {
		t.Fatal("accepted duplicate scalar")
	}
	if _, _, err := optional(fields, 1); err == nil {
		t.Fatal("accepted duplicate optional field")
	}
	if _, err := blob([]field{{id: 1, wire: 0, n: 5}}, 1); err == nil {
		t.Fatal("accepted integer as blob")
	}
}

func TestOverflowSafeRanges(t *testing.T) {
	if inRange(math.MaxUint64, 2, math.MaxUint64) {
		t.Fatal("range overflow accepted")
	}
	if inRange(100, math.MaxUint64, 200) {
		t.Fatal("size overflow accepted")
	}
	if !inRange(100, 100, 200) {
		t.Fatal("valid end-boundary range rejected")
	}
}

func TestRefusesInvalidRomWithoutOutput(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "not-a-rom.zip")
	if err := os.WriteFile(source, []byte("invalid"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := extract(source, "PJX110_16.0.3.500", dir); err == nil {
		t.Fatal("accepted invalid ROM")
	}
	if _, err := os.Stat(filepath.Join(dir, "dtbo_16_0_3_500_stock.img")); !os.IsNotExist(err) {
		t.Fatal("invalid ROM produced image")
	}
}
