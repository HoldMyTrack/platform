package parse

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Each parser keeps a file of exactly MaxPoints points and refuses one more, as it reaches it,
// when asked to; a stored original read without a cap keeps them all.
func TestParsersRefusePastMaxPoints(t *testing.T) {
	gpx := func(n int) []byte {
		var b strings.Builder
		b.WriteString(`<gpx><trk><trkseg>`)
		for i := range n {
			fmt.Fprintf(&b, `<trkpt lat="50" lon="10"><time>2026-05-01T10:00:%02dZ</time></trkpt>`, i%60)
		}
		b.WriteString(`</trkseg></trk></gpx>`)
		return []byte(b.String())
	}
	tcx := func(n int) []byte {
		var b strings.Builder
		b.WriteString(`<TrainingCenterDatabase><Activities><Activity Sport="Running"><Lap><Track>`)
		for range n {
			b.WriteString(`<Trackpoint><Time>2026-05-01T10:00:00Z</Time><Position><LatitudeDegrees>50</LatitudeDegrees><LongitudeDegrees>10</LongitudeDegrees></Position></Trackpoint>`)
		}
		b.WriteString(`</Track></Lap></Activity></Activities></TrainingCenterDatabase>`)
		return []byte(b.String())
	}
	fit := func(n int) []byte {
		var body bytes.Buffer
		body.WriteByte(0x40)
		body.Write([]byte{0x00, 0x00})
		binary.Write(&body, binary.LittleEndian, uint16(20)) // record
		body.WriteByte(3)
		body.Write([]byte{0x00, 4, 0x85, 0x01, 4, 0x85, 0xFD, 4, 0x86})
		for i := range n {
			body.WriteByte(0x00)
			binary.Write(&body, binary.LittleEndian, int32(596523235)) // 50°
			binary.Write(&body, binary.LittleEndian, int32(119304647)) // 10°
			binary.Write(&body, binary.LittleEndian, uint32(1_000_000_000+i))
		}
		var hdr bytes.Buffer
		hdr.WriteByte(12)
		hdr.WriteByte(0x10)
		binary.Write(&hdr, binary.LittleEndian, uint16(100))
		binary.Write(&hdr, binary.LittleEndian, uint32(body.Len()))
		hdr.WriteString(".FIT")
		return append(hdr.Bytes(), body.Bytes()...)
	}
	for name, build := range map[string]func(int) []byte{"ride.gpx": gpx, "ride.tcx": tcx, "ride.fit": fit} {
		act, err := ByExtensionUpTo(name, bytes.NewReader(build(MaxPoints)), MaxPoints)
		if err != nil || len(act.Points) != MaxPoints {
			t.Errorf("%s at the cap: %d points, %v; want all %d", name, len(act.Points), err, MaxPoints)
		}
		if _, err := ByExtensionUpTo(name, bytes.NewReader(build(MaxPoints+1)), MaxPoints); !errors.Is(err, ErrTooManyPoints) {
			t.Errorf("%s one past the cap: %v, want ErrTooManyPoints", name, err)
		}
		if act, err := ByExtensionUpTo(name, bytes.NewReader(build(MaxPoints+1)), 0); err != nil || len(act.Points) != MaxPoints+1 {
			t.Errorf("%s past the cap, read with none: %d points, %v; want all", name, len(act.Points), err)
		}
	}
}
