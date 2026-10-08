// Selective, file-only DTBO extraction from full OTA ZIPs. No other partition
// data is extracted. Wire fields follow AOSP update_engine/update_metadata.proto.
package main

import (
	"archive/zip"
	"bytes"
	"compress/bzip2"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ulikunitz/xz"
)

type field struct {
	id   int
	wire byte
	n    uint64
	data []byte
}

func decode(raw []byte) ([]field, error) {
	var result []field
	for pos := 0; pos < len(raw); {
		key, n := binary.Uvarint(raw[pos:])
		if n <= 0 || key>>3 == 0 {
			return nil, fmt.Errorf("invalid protobuf key")
		}
		pos += n
		f := field{id: int(key >> 3), wire: byte(key & 7)}
		switch f.wire {
		case 0:
			f.n, n = binary.Uvarint(raw[pos:])
			if n <= 0 {
				return nil, fmt.Errorf("invalid protobuf integer")
			}
			pos += n
		case 1, 5:
			count := 8
			if f.wire == 5 {
				count = 4
			}
			if count > len(raw)-pos {
				return nil, io.ErrUnexpectedEOF
			}
			pos += count
		case 2:
			size, k := binary.Uvarint(raw[pos:])
			if k <= 0 {
				return nil, fmt.Errorf("invalid protobuf length")
			}
			pos += k
			if size > uint64(len(raw)-pos) {
				return nil, io.ErrUnexpectedEOF
			}
			f.data = raw[pos : pos+int(size)]
			pos += int(size)
		default:
			return nil, fmt.Errorf("unsupported protobuf wire %d", f.wire)
		}
		result = append(result, f)
	}
	return result, nil
}
func one(fields []field, id int) (field, error) {
	var found field
	count := 0
	for _, f := range fields {
		if f.id == id {
			found = f
			count++
		}
	}
	if count != 1 {
		return field{}, fmt.Errorf("field %d count=%d", id, count)
	}
	return found, nil
}
func optional(fields []field, id int) (field, bool, error) {
	var found field
	count := 0
	for _, f := range fields {
		if f.id == id {
			found = f
			count++
		}
	}
	if count > 1 {
		return field{}, false, fmt.Errorf("duplicate field %d", id)
	}
	return found, count == 1, nil
}
func uintField(fields []field, id int, defaultValue uint64) (uint64, error) {
	f, ok, err := optional(fields, id)
	if err != nil {
		return 0, err
	}
	if !ok {
		return defaultValue, nil
	}
	if f.wire != 0 {
		return 0, fmt.Errorf("field %d is not an integer", id)
	}
	return f.n, nil
}
func blob(fields []field, id int) ([]byte, error) {
	f, err := one(fields, id)
	if err != nil {
		return nil, err
	}
	if f.wire != 2 {
		return nil, fmt.Errorf("field %d is not bytes", id)
	}
	return f.data, nil
}
func inRange(off, size, limit uint64) bool { return off <= limit && size <= limit-off }

type extent struct{ start, end uint64 }
type report struct {
	Firmware        string   `json:"firmware"`
	ZIP             string   `json:"zip"`
	PostBuild       string   `json:"post_build"`
	PostIncremental string   `json:"post_incremental"`
	Image           string   `json:"image"`
	Size            uint64   `json:"size"`
	SHA256          string   `json:"sha256"`
	Operations      []uint64 `json:"operations"`
}

func extract(path, firmware, outDir string) (report, error) {
	r := report{Firmware: firmware, ZIP: path}
	file, err := os.Open(path)
	if err != nil {
		return r, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return r, err
	}
	if !info.Mode().IsRegular() {
		return r, fmt.Errorf("ROM input must be a regular ZIP file")
	}
	archive, err := zip.NewReader(file, info.Size())
	if err != nil {
		return r, err
	}
	var payload, metadata *zip.File
	for _, f := range archive.File {
		if f.Name == "payload.bin" {
			if payload != nil {
				return r, fmt.Errorf("duplicate payload")
			}
			payload = f
		}
		if f.Name == "META-INF/com/android/metadata" {
			metadata = f
		}
	}
	if payload == nil || metadata == nil {
		return r, fmt.Errorf("payload/metadata missing")
	}
	if payload.Method != zip.Store {
		return r, fmt.Errorf("payload is not ZIP-stored; refusing a full payload dump")
	}
	metaReader, err := metadata.Open()
	if err != nil {
		return r, err
	}
	meta, err := io.ReadAll(io.LimitReader(metaReader, 65537))
	metaReader.Close()
	if err != nil || len(meta) > 65536 {
		return r, fmt.Errorf("invalid OTA metadata")
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(meta), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			values[k] = v
		}
	}
	major := strings.Split(strings.TrimPrefix(firmware, "PJX110_"), ".")[0]
	if values["ota-type"] != "AB" || !strings.Contains(values["post-build"], "/PJX110/") || !strings.Contains(values["post-build"], "OP5D06L1:"+major+"/") {
		return r, fmt.Errorf("device/Android-major mismatch")
	}
	r.PostBuild = values["post-build"]
	r.PostIncremental = values["post-build-incremental"]
	offset, err := payload.DataOffset()
	if err != nil {
		return r, err
	}
	if payload.UncompressedSize64 > uint64(info.Size()-offset) {
		return r, fmt.Errorf("ZIP payload out of bounds")
	}
	reader := io.NewSectionReader(file, offset, int64(payload.UncompressedSize64))
	header := make([]byte, 24)
	if _, err = reader.ReadAt(header, 0); err != nil {
		return r, err
	}
	if string(header[:4]) != "CrAU" || binary.BigEndian.Uint64(header[4:12]) != 2 {
		return r, fmt.Errorf("unsupported OTA payload header")
	}
	manifestSize := binary.BigEndian.Uint64(header[12:20])
	signatureSize := uint64(binary.BigEndian.Uint32(header[20:24]))
	if manifestSize == 0 || manifestSize > 64<<20 || !inRange(24, manifestSize+signatureSize, payload.UncompressedSize64) {
		return r, fmt.Errorf("manifest range invalid")
	}
	manifest := make([]byte, manifestSize)
	if _, err = reader.ReadAt(manifest, 24); err != nil {
		return r, err
	}
	fields, err := decode(manifest)
	if err != nil {
		return r, err
	}
	blockSize, err := uintField(fields, 3, 4096)
	if err != nil || blockSize != 4096 {
		return r, fmt.Errorf("unsupported OTA block size")
	}
	var partition []field
	for _, f := range fields {
		if f.id != 13 {
			continue
		}
		if f.wire != 2 {
			return r, fmt.Errorf("invalid partition wire")
		}
		p, err := decode(f.data)
		if err != nil {
			return r, err
		}
		name, err := blob(p, 1)
		if err != nil {
			return r, err
		}
		if string(name) != "dtbo" {
			continue
		}
		if partition != nil {
			return r, fmt.Errorf("multiple DTBO partitions")
		}
		partition = p
	}
	if partition == nil {
		return r, fmt.Errorf("DTBO partition missing")
	}
	newInfo, err := blob(partition, 7)
	if err != nil {
		return r, err
	}
	partFields, err := decode(newInfo)
	if err != nil {
		return r, err
	}
	size, err := uintField(partFields, 1, 0)
	if err != nil || size == 0 || size > 128<<20 || size%blockSize != 0 {
		return r, fmt.Errorf("invalid DTBO partition size")
	}
	wantedHash, err := blob(partFields, 2)
	if err != nil || len(wantedHash) != 32 {
		return r, fmt.Errorf("missing DTBO final SHA256")
	}
	image := make([]byte, size)
	var ranges []extent
	dataBase := uint64(24) + manifestSize + signatureSize
	for _, f := range partition {
		if f.id != 8 {
			continue
		}
		if f.wire != 2 {
			return r, fmt.Errorf("invalid operation wire")
		}
		op, err := decode(f.data)
		if err != nil {
			return r, err
		}
		kind, err := uintField(op, 1, ^uint64(0))
		if err != nil {
			return r, err
		}
		r.Operations = append(r.Operations, kind)
		switch kind {
		case 0, 1, 8, 6, 7:
		default:
			return r, fmt.Errorf("DTBO operation %d requires source/delta handling; refused", kind)
		}
		var destinations []extent
		var total uint64
		for _, e := range op {
			if e.id != 6 {
				continue
			}
			if e.wire != 2 {
				return r, fmt.Errorf("invalid extent wire")
			}
			ef, err := decode(e.data)
			if err != nil {
				return r, err
			}
			start, err := uintField(ef, 1, ^uint64(0))
			if err != nil {
				return r, err
			}
			count, err := uintField(ef, 2, 0)
			if err != nil || count == 0 || start > size/blockSize || count > size/blockSize-start {
				return r, fmt.Errorf("DTBO extent out of bounds")
			}
			ex := extent{start * blockSize, (start + count) * blockSize}
			destinations = append(destinations, ex)
			ranges = append(ranges, ex)
			total += ex.end - ex.start
			if total > size {
				return r, fmt.Errorf("operation size overflow")
			}
		}
		if total == 0 {
			return r, fmt.Errorf("operation has no destination")
		}
		if kind == 6 || kind == 7 {
			continue
		}
		dataOffset, err := uintField(op, 2, 0)
		if err != nil {
			return r, err
		}
		dataLength, err := uintField(op, 3, 0)
		if err != nil || dataLength == 0 || dataLength > 128<<20 || dataOffset > payload.UncompressedSize64-dataBase || !inRange(dataBase+dataOffset, dataLength, payload.UncompressedSize64) {
			return r, fmt.Errorf("DTBO operation data range invalid")
		}
		data := make([]byte, dataLength)
		if _, err = reader.ReadAt(data, int64(dataBase+dataOffset)); err != nil {
			return r, err
		}
		dataHash, err := blob(op, 8)
		actual := sha256.Sum256(data)
		if err != nil || len(dataHash) != 32 || !bytes.Equal(dataHash, actual[:]) {
			return r, fmt.Errorf("DTBO compressed operation SHA256 mismatch")
		}
		var decoded io.Reader = bytes.NewReader(data)
		if kind == 1 {
			decoded = bzip2.NewReader(decoded)
		}
		if kind == 8 {
			decoded, err = xz.NewReader(decoded)
			if err != nil {
				return r, err
			}
		}
		unpacked, err := io.ReadAll(io.LimitReader(decoded, int64(total)+1))
		if err != nil || uint64(len(unpacked)) > total {
			return r, fmt.Errorf("DTBO decompression size invalid: %v", err)
		}
		cursor := 0
		for _, ex := range destinations {
			length := int(ex.end - ex.start)
			available := len(unpacked) - cursor
			if available > length {
				available = length
			}
			if available > 0 {
				copy(image[ex.start:ex.start+uint64(available)], unpacked[cursor:cursor+available])
				cursor += available
			}
		}
	}
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].start < ranges[j].start })
	var end uint64
	for _, ex := range ranges {
		if ex.start != end {
			return r, fmt.Errorf("DTBO operations have gaps or overlap")
		}
		end = ex.end
	}
	if end != size {
		return r, fmt.Errorf("DTBO operations do not cover the partition")
	}
	sum := sha256.Sum256(image)
	if !bytes.Equal(sum[:], wantedHash) {
		return r, fmt.Errorf("DTBO final partition SHA256 mismatch")
	}
	if len(image) < 64 || string(image[len(image)-64:len(image)-60]) != "AVBf" {
		return r, fmt.Errorf("DTBO AVB footer missing")
	}
	r.Size = size
	r.SHA256 = hex.EncodeToString(sum[:])
	r.Image = filepath.Join(outDir, "dtbo_"+strings.ReplaceAll(strings.TrimPrefix(firmware, "PJX110_"), ".", "_")+"_stock.img")
	if old, err := os.Stat(r.Image); err == nil && !old.Mode().IsRegular() {
		return r, fmt.Errorf("output is not an image file")
	}
	if err = os.WriteFile(r.Image, image, 0600); err != nil {
		return r, err
	}
	return r, nil
}

func main() {
	root := flag.String("rom-dir", "", "ROM directory")
	out := flag.String("out-dir", "", "DTBO-only output directory")
	flag.Parse()
	if *root == "" || *out == "" {
		flag.Usage()
		os.Exit(2)
	}
	if err := os.MkdirAll(*out, 0755); err != nil {
		panic(err)
	}
	dirs, err := os.ReadDir(*root)
	if err != nil {
		panic(err)
	}
	pattern := regexp.MustCompile(`^ColorOS (PJX110_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\(CN01\)`)
	var reports []report
	failed := false
	for _, dir := range dirs {
		if !dir.IsDir() {
			continue
		}
		match := pattern.FindStringSubmatch(dir.Name())
		if match == nil {
			continue
		}
		zips, err := filepath.Glob(filepath.Join(*root, dir.Name(), "*.zip"))
		if err != nil || len(zips) != 1 {
			fmt.Fprintf(os.Stderr, "%s: expected one ROM ZIP\n", dir.Name())
			failed = true
			continue
		}
		result, err := extract(zips[0], match[1], *out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL %s: %v\n", match[1], err)
			failed = true
			continue
		}
		reports = append(reports, result)
		fmt.Printf("OK %s %s ops=%v\n", match[1], result.SHA256, result.Operations)
	}
	encoded, err := json.MarshalIndent(reports, "", "  ")
	if err != nil {
		panic(err)
	}
	if err = os.WriteFile(filepath.Join(*out, "rom-dtbo.json"), append(encoded, '\n'), 0644); err != nil {
		panic(err)
	}
	if failed {
		os.Exit(1)
	}
}
