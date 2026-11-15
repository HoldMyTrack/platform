package parse

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"time"
)

// ParseFIT is a minimal, honest subset of the FIT binary format: enough to read `record`
// (global message 20) and `session` (global message 18, for activity_type — see
// fit_sport.go) fields out of files produced by mainstream encoders (little-endian
// architecture, no compressed-timestamp headers). It correctly walks every other message
// type it doesn't understand (reading each field's declared byte width so the stream stays
// aligned) rather than only handling those two and desyncing on anything else. It does not
// implement developer-field *values* (only skips their declared bytes) and does not verify
// CRCs. This is the parser most likely to need the most depth of the three formats — it
// covers the common case, not the full FIT SDK surface.
func ParseFIT(r io.Reader) (Activity, error) { return parseFIT(r, 0) }

// parseFIT is ParseFIT refusing a file past maxPoints positioned points, 0 for no cap.
func parseFIT(r io.Reader, maxPoints int) (Activity, error) {
	br := bufio.NewReader(r)

	hdr := make([]byte, 12)
	if _, err := io.ReadFull(br, hdr); err != nil {
		return Activity{}, fmt.Errorf("parse fit: header: %w", err)
	}
	headerSize := int(hdr[0])
	if string(hdr[8:12]) != ".FIT" {
		return Activity{}, fmt.Errorf("parse fit: missing .FIT signature")
	}
	dataSize := binary.LittleEndian.Uint32(hdr[4:8])
	if headerSize > 12 {
		extra := make([]byte, headerSize-12)
		if _, err := io.ReadFull(br, extra); err != nil {
			return Activity{}, fmt.Errorf("parse fit: header CRC bytes: %w", err)
		}
	}

	defs := map[byte]*fitDef{}
	act := Activity{ActivityType: "unknown"}
	var read uint32

	const fitEpoch = 631065600 // seconds between Unix epoch and 1989-12-31T00:00:00Z

	for read < dataSize {
		recHdr, err := br.ReadByte()
		if err != nil {
			return Activity{}, fmt.Errorf("parse fit: record header: %w", err)
		}
		read++

		if recHdr&0x80 != 0 {
			return Activity{}, fmt.Errorf("parse fit: compressed timestamp headers are not supported")
		}
		localType := recHdr & 0x0F
		isDefinition := recHdr&0x40 != 0

		if isDefinition {
			hasDevFields := recHdr&0x20 != 0
			def, n, err := readDefinition(br, hasDevFields)
			if err != nil {
				return Activity{}, fmt.Errorf("parse fit: definition: %w", err)
			}
			read += n
			defs[localType] = def
			continue
		}

		def, ok := defs[localType]
		if !ok {
			return Activity{}, fmt.Errorf("parse fit: data message for undefined local type %d", localType)
		}

		if def.data == nil {
			def.data = make([]byte, def.size)
		}
		if _, err := io.ReadFull(br, def.data); err != nil {
			return Activity{}, fmt.Errorf("parse fit: field data: %w", err)
		}
		read += uint32(len(def.data))

		switch def.globalMesgNum {
		case 18: // session — carries the activity's own sport/sub_sport (fields 5, 6).
			// A multi-sport file can have more than one session message; last one read
			// wins, a deliberate simplification rather than an oversight — there's no
			// single obviously-correct "the whole file's type" when there's more than
			// one, and this parser covers the common single-sport case (see doc comment).
			var sport, subSport byte = 0xFF, 0xFF
			if raw := def.value(5); len(raw) > 0 {
				sport = raw[0]
			}
			if raw := def.value(6); len(raw) > 0 {
				subSport = raw[0]
			}
			act.ActivityType = sportName(sport, subSport)

		case 20: // record — the point stream
			// A field's width comes from the file's own definition, so each read checks it
			// first: a field narrower than its type is treated as absent rather than read past
			// its end. So is FIT's "invalid" value for each type, which encoders write for a
			// record with no position yet (before GPS lock, through a dropout) — read as a
			// coordinate it would put the point at about (180, 180).
			p := Point{}
			haveLat, haveLon := false, false
			var enhanced *float32
			for _, f := range def.fields {
				raw := def.data[f.off : f.off+int(f.size)]
				switch f.num {
				case 0: // position_lat, sint32 semicircles
					if v, ok := fitSint32(def.order, raw); ok {
						p.Lat = float64(v) * (180.0 / math.Pow(2, 31))
						haveLat = true
					}
				case 1: // position_long
					if v, ok := fitSint32(def.order, raw); ok {
						p.Lon = float64(v) * (180.0 / math.Pow(2, 31))
						haveLon = true
					}
				case 2: // altitude, uint16, scale 5, offset 500
					if len(raw) >= 2 {
						if v := def.order.Uint16(raw); v != 0xFFFF {
							e := float32(v)/5 - 500
							p.Elevation = &e
						}
					}
				case 78: // enhanced_altitude, uint32, the same scale and offset: what many newer
					// devices write instead of altitude, which they leave out or invalid
					if len(raw) >= 4 {
						if v := def.order.Uint32(raw); v != 0xFFFFFFFF {
							e := float32(v)/5 - 500
							enhanced = &e
						}
					}
				case 253: // timestamp, uint32 seconds since FIT epoch
					if len(raw) >= 4 {
						if v := def.order.Uint32(raw); v != 0xFFFFFFFF {
							p.Time = time.Unix(int64(v)+fitEpoch, 0).UTC()
						}
					}
				}
			}
			if enhanced != nil {
				p.Elevation = enhanced
			}
			if haveLat && haveLon {
				if maxPoints > 0 && len(act.Points) == maxPoints {
					return Activity{}, ErrTooManyPoints
				}
				act.Points = append(act.Points, p)
			}

		default:
			// Every other message type is just skipped — its bytes were already read
			// above to keep the stream aligned, but nothing here needs its fields.
		}
	}

	if len(act.Points) == 0 {
		return Activity{}, fmt.Errorf("parse fit: %w", ErrNoPoints)
	}
	return act, nil
}

// fitSint32 reads a sint32 field, reporting false for one too short to hold it and for FIT's
// invalid value, 0x7FFFFFFF.
func fitSint32(order binary.ByteOrder, raw []byte) (int32, bool) {
	if len(raw) < 4 {
		return 0, false
	}
	v := int32(order.Uint32(raw))
	return v, v != math.MaxInt32
}

type fitField struct {
	num  byte
	size byte
	off  int // where the field starts in a data message's bytes
}

// fitDef is a definition message, and the buffer each data message of its local type is read
// into, its fields at their offsets. A message's bytes are used before the next one is read.
// The buffer is made for the first data message, so a file of definitions alone, each up to
// about 130 KB of fields, allocates nothing for them.
type fitDef struct {
	globalMesgNum uint16
	order         binary.ByteOrder
	fields        []fitField
	size          int // bytes in a data message
	data          []byte
}

// value is field num's bytes in the data message last read, the last field of that number when
// a definition repeats one; nil when the definition has none.
func (d *fitDef) value(num byte) []byte {
	var raw []byte
	for _, f := range d.fields {
		if f.num == num {
			raw = d.data[f.off : f.off+int(f.size)]
		}
	}
	return raw
}

// readDefinition reads a definition message: reserved, architecture, global_mesg_num,
// num_fields, fields..., and — when the record header's bit 5 (devFields) said so — a
// trailing developer-field count and that many (num, size, dev_data_index) triples. Those
// bytes are read and skipped, not interpreted: values from developer fields on `record`
// aren't extracted, but the byte stream stays correctly aligned for every message that
// follows, which is the part that actually matters for not silently corrupting the rest of
// the parse. Returns bytes consumed after the header byte.
func readDefinition(br *bufio.Reader, devFields bool) (*fitDef, uint32, error) {
	// reserved(1) + architecture(1) + global_mesg_num(2) = 4 bytes, not 5.
	buf := make([]byte, 4)
	if _, err := io.ReadFull(br, buf); err != nil {
		return nil, 0, err
	}
	var n uint32 = 4
	arch := buf[1]
	order := binary.ByteOrder(binary.LittleEndian)
	if arch == 1 {
		order = binary.BigEndian
	}
	globalMesgNum := order.Uint16(buf[2:4])

	numFieldsB, err := br.ReadByte()
	if err != nil {
		return nil, n, err
	}
	n++
	def := &fitDef{globalMesgNum: globalMesgNum, order: order}
	size := 0
	var fb [3]byte
	for i := byte(0); i < numFieldsB; i++ {
		if _, err := io.ReadFull(br, fb[:]); err != nil {
			return nil, n, err
		}
		n += 3
		def.fields = append(def.fields, fitField{num: fb[0], size: fb[1], off: size})
		size += int(fb[1])
	}

	if devFields {
		numDevB, err := br.ReadByte()
		if err != nil {
			return nil, n, err
		}
		n++
		for i := byte(0); i < numDevB; i++ {
			// field_num, size, developer_data_index — skipped, not stored
			if _, err := io.ReadFull(br, fb[:]); err != nil {
				return nil, n, err
			}
			n += 3
			// The data-message bytes these fields occupy still need to be skipped when a
			// matching data message arrives, so they're recorded like any other field —
			// just never read by number in the `record` switch above.
			def.fields = append(def.fields, fitField{num: 0xFF, size: fb[1], off: size})
			size += int(fb[1])
		}
	}
	def.size = size
	return def, n, nil
}
