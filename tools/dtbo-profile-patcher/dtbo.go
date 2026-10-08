package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/u-root/u-root/pkg/dt"
)

const (
	dtTableMagic         = 0xd7b7ab1e
	avbBlockSize         = 4096
	avbFooterLen         = 64
	avbHeaderLen         = 256
	avbHashDescriptorTag = 2
)

type tableHeader struct {
	Magic         uint32
	TotalSize     uint32
	HeaderSize    uint32
	EntrySize     uint32
	EntryCount    uint32
	EntriesOffset uint32
	PageSize      uint32
	Version       uint32
}

type tableEntry struct {
	Raw    []byte
	Size   uint32
	Offset uint32
	Tree   *dt.FDT
}

type dtboImage struct {
	Raw           []byte
	Header        tableHeader
	Entries       []tableEntry
	DataStart     uint32
	VBMeta        []byte
	Footer        []byte
	SourceSHA256  string
	PartitionSize uint64
}

func alignUp(value, alignment uint64) uint64 {
	return (value + alignment - 1) / alignment * alignment
}

func checkedRange(offset, size, limit uint64) bool {
	return offset <= limit && size <= limit-offset
}

// validateVBMeta validates the container and the dtbo hash descriptor.  The
// descriptor digest is intentionally not compared with the rebuilt DTBO: on
// an unlocked device the module preserves the stock firmware's signed VBMeta
// while changing the overlay payload.  Structural validation still prevents a
// truncated or unrelated AVB blob from being accepted as a reusable footer.
func validateVBMeta(vbmeta []byte) error {
	if len(vbmeta) < avbHeaderLen || string(vbmeta[:4]) != "AVB0" {
		return fmt.Errorf("AVB metadata header is missing or truncated")
	}
	authSize := binary.BigEndian.Uint64(vbmeta[12:20])
	auxSize := binary.BigEndian.Uint64(vbmeta[20:28])
	// Reject overflow before adding lengths or calculating descriptor cursors.
	if !checkedRange(avbHeaderLen, authSize, uint64(len(vbmeta))) ||
		!checkedRange(uint64(avbHeaderLen)+authSize, auxSize, uint64(len(vbmeta))) {
		return fmt.Errorf("AVB authentication/auxiliary block is out of bounds")
	}
	total := uint64(avbHeaderLen) + authSize + auxSize
	if total != uint64(len(vbmeta)) {
		return fmt.Errorf("AVB metadata size mismatch: header=%d actual=%d", total, len(vbmeta))
	}
	for _, field := range []struct {
		name         string
		offset, size uint64
		limit        uint64
	}{
		{"hash", binary.BigEndian.Uint64(vbmeta[32:40]), binary.BigEndian.Uint64(vbmeta[40:48]), authSize},
		{"signature", binary.BigEndian.Uint64(vbmeta[48:56]), binary.BigEndian.Uint64(vbmeta[56:64]), authSize},
		{"public key", binary.BigEndian.Uint64(vbmeta[64:72]), binary.BigEndian.Uint64(vbmeta[72:80]), auxSize},
		{"public key metadata", binary.BigEndian.Uint64(vbmeta[80:88]), binary.BigEndian.Uint64(vbmeta[88:96]), auxSize},
		{"descriptors", binary.BigEndian.Uint64(vbmeta[96:104]), binary.BigEndian.Uint64(vbmeta[104:112]), auxSize},
	} {
		if !checkedRange(field.offset, field.size, field.limit) {
			return fmt.Errorf("AVB %s range is out of bounds", field.name)
		}
	}

	descriptorsOffset := binary.BigEndian.Uint64(vbmeta[96:104])
	descriptorsSize := binary.BigEndian.Uint64(vbmeta[104:112])
	auxStart := uint64(avbHeaderLen) + authSize
	cursor := auxStart + descriptorsOffset
	end := cursor + descriptorsSize
	foundDTBOHash := false
	for cursor < end {
		if !checkedRange(cursor, 16, uint64(len(vbmeta))) {
			return fmt.Errorf("AVB descriptor header is truncated")
		}
		tag := binary.BigEndian.Uint64(vbmeta[cursor : cursor+8])
		following := binary.BigEndian.Uint64(vbmeta[cursor+8 : cursor+16])
		if !checkedRange(cursor+16, following, end) {
			return fmt.Errorf("AVB descriptor payload is out of bounds")
		}
		if tag == avbHashDescriptorTag {
			if following < 116 {
				return fmt.Errorf("AVB hash descriptor is truncated")
			}
			base := cursor + 16
			imageSize := binary.BigEndian.Uint64(vbmeta[base : base+8])
			algorithm := string(bytes.TrimRight(vbmeta[base+8:base+40], "\x00"))
			nameLen := uint64(binary.BigEndian.Uint32(vbmeta[base+40 : base+44]))
			saltLen := uint64(binary.BigEndian.Uint32(vbmeta[base+44 : base+48]))
			digestLen := uint64(binary.BigEndian.Uint32(vbmeta[base+48 : base+52]))
			variableLen := nameLen + saltLen + digestLen
			if variableLen > following-116 {
				return fmt.Errorf("AVB hash descriptor variable data is out of bounds")
			}
			nameStart := base + 116
			name := string(vbmeta[nameStart : nameStart+nameLen])
			if name == "dtbo" {
				if imageSize == 0 || algorithm != "sha256" || digestLen != sha256.Size {
					return fmt.Errorf("unsupported dtbo AVB hash descriptor: image_size=%d algorithm=%q digest=%d", imageSize, algorithm, digestLen)
				}
				foundDTBOHash = true
			}
		}
		cursor += 16 + following
	}
	if cursor != end {
		return fmt.Errorf("AVB descriptor list has trailing bytes")
	}
	if !foundDTBOHash {
		return fmt.Errorf("AVB dtbo hash descriptor is missing")
	}
	return nil
}

func parseDTBO(path string) (*dtboImage, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("DTBO parser accepts regular image files only")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(raw) < 32+avbFooterLen {
		return nil, fmt.Errorf("image is too small: %d", len(raw))
	}

	var header tableHeader
	if err := binary.Read(bytes.NewReader(raw[:32]), binary.BigEndian, &header); err != nil {
		return nil, err
	}
	if header.Magic != dtTableMagic {
		return nil, fmt.Errorf("invalid DTBO magic: %#x", header.Magic)
	}
	if header.HeaderSize < 32 || header.EntrySize < 32 {
		return nil, fmt.Errorf("unsupported table sizes: header=%d entry=%d", header.HeaderSize, header.EntrySize)
	}
	if header.HeaderSize > header.TotalSize || header.EntriesOffset < header.HeaderSize {
		return nil, fmt.Errorf("DTBO header/table offsets are inconsistent")
	}
	if header.PageSize == 0 || header.PageSize&(header.PageSize-1) != 0 {
		return nil, fmt.Errorf("invalid DTBO page size: %d", header.PageSize)
	}
	if header.EntryCount == 0 || header.EntryCount > 64 {
		return nil, fmt.Errorf("unsafe entry count: %d", header.EntryCount)
	}
	if header.TotalSize > uint32(len(raw)-avbFooterLen) {
		return nil, fmt.Errorf("DTBO total size exceeds partition: %d", header.TotalSize)
	}
	tableEnd := uint64(header.EntriesOffset) + uint64(header.EntryCount)*uint64(header.EntrySize)
	if tableEnd > uint64(header.TotalSize) || tableEnd > uint64(len(raw)) {
		return nil, fmt.Errorf("DTBO entry table is out of bounds")
	}

	entries := make([]tableEntry, 0, header.EntryCount)
	var dataStart uint32
	var previousEnd uint32
	for i := uint32(0); i < header.EntryCount; i++ {
		tableOffset := header.EntriesOffset + i*header.EntrySize
		rawEntry := append([]byte(nil), raw[tableOffset:tableOffset+header.EntrySize]...)
		size := binary.BigEndian.Uint32(rawEntry[0:4])
		offset := binary.BigEndian.Uint32(rawEntry[4:8])
		end := uint64(offset) + uint64(size)
		if size == 0 || offset < uint32(tableEnd) || end > uint64(header.TotalSize) {
			return nil, fmt.Errorf("entry %d is out of bounds: offset=%d size=%d", i, offset, size)
		}
		if i == 0 {
			dataStart = offset
		} else if offset < previousEnd {
			return nil, fmt.Errorf("entry %d overlaps the previous entry", i)
		}
		previousEnd = offset + size
		if size < 8 || binary.BigEndian.Uint32(raw[offset:offset+4]) != 0xd00dfeed || binary.BigEndian.Uint32(raw[offset+4:offset+8]) != size {
			return nil, fmt.Errorf("entry %d FDT size/header is inconsistent", i)
		}
		tree, err := dt.ReadFDT(bytes.NewReader(raw[offset : offset+size]))
		if err != nil {
			return nil, fmt.Errorf("entry %d FDT parse failed: %w", i, err)
		}
		entries = append(entries, tableEntry{Raw: rawEntry, Size: size, Offset: offset, Tree: tree})
	}
	if previousEnd != header.TotalSize {
		return nil, fmt.Errorf("last entry end %d does not match total size %d", previousEnd, header.TotalSize)
	}

	footerOffset := len(raw) - avbFooterLen
	footer := append([]byte(nil), raw[footerOffset:]...)
	if string(footer[0:4]) != "AVBf" {
		return nil, fmt.Errorf("AVB footer is missing")
	}
	if binary.BigEndian.Uint32(footer[4:8]) != 1 {
		return nil, fmt.Errorf("unsupported AVB footer version")
	}
	originalSize := binary.BigEndian.Uint64(footer[12:20])
	vbmetaOffset := binary.BigEndian.Uint64(footer[20:28])
	vbmetaSize := binary.BigEndian.Uint64(footer[28:36])
	if originalSize != uint64(header.TotalSize) {
		return nil, fmt.Errorf("AVB original size %d does not match DTBO total size %d", originalSize, header.TotalSize)
	}
	if vbmetaOffset != alignUp(originalSize, avbBlockSize) || vbmetaSize == 0 || !checkedRange(vbmetaOffset, vbmetaSize, uint64(footerOffset)) {
		return nil, fmt.Errorf("invalid AVB metadata range: offset=%d size=%d", vbmetaOffset, vbmetaSize)
	}
	vbmeta := append([]byte(nil), raw[vbmetaOffset:vbmetaOffset+vbmetaSize]...)
	if err := validateVBMeta(vbmeta); err != nil {
		return nil, err
	}

	hash := sha256.Sum256(raw)
	return &dtboImage{
		Raw: raw, Header: header, Entries: entries, DataStart: dataStart,
		VBMeta: vbmeta, Footer: footer, SourceSHA256: hex.EncodeToString(hash[:]),
		PartitionSize: uint64(len(raw)),
	}, nil
}

func (image *dtboImage) serialize() ([]byte, error) {
	out := make([]byte, image.PartitionSize)
	copy(out[:image.DataStart], image.Raw[:image.DataStart])
	cursor := uint64(image.DataStart)
	for i := range image.Entries {
		var fdtBuffer bytes.Buffer
		if _, err := image.Entries[i].Tree.Write(&fdtBuffer); err != nil {
			return nil, fmt.Errorf("entry %d FDT write failed: %w", i, err)
		}
		blob := fdtBuffer.Bytes()
		if cursor+uint64(len(blob)) > uint64(len(out)-avbFooterLen) {
			return nil, fmt.Errorf("entry %d exceeds partition capacity", i)
		}
		copy(out[cursor:], blob)
		tableOffset := image.Header.EntriesOffset + uint32(i)*image.Header.EntrySize
		binary.BigEndian.PutUint32(out[tableOffset:tableOffset+4], uint32(len(blob)))
		binary.BigEndian.PutUint32(out[tableOffset+4:tableOffset+8], uint32(cursor))
		cursor += uint64(len(blob))
	}
	if cursor > uint64(^uint32(0)) {
		return nil, fmt.Errorf("rebuilt DTBO is too large")
	}
	binary.BigEndian.PutUint32(out[4:8], uint32(cursor))

	vbmetaOffset := alignUp(cursor, avbBlockSize)
	footerOffset := uint64(len(out) - avbFooterLen)
	if vbmetaOffset+uint64(len(image.VBMeta)) > footerOffset {
		return nil, fmt.Errorf("AVB metadata does not fit rebuilt partition")
	}
	copy(out[vbmetaOffset:], image.VBMeta)
	copy(out[footerOffset:], image.Footer)
	binary.BigEndian.PutUint64(out[footerOffset+12:footerOffset+20], cursor)
	binary.BigEndian.PutUint64(out[footerOffset+20:footerOffset+28], vbmetaOffset)
	binary.BigEndian.PutUint64(out[footerOffset+28:footerOffset+36], uint64(len(image.VBMeta)))
	return out, nil
}
