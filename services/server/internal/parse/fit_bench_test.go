package parse

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

// countingReader counts the Read calls that reach the source, as each would reach object
// storage's stream in ingest.
type countingReader struct {
	r     io.Reader
	calls int
}

func (c *countingReader) Read(p []byte) (int, error) {
	c.calls++
	return c.r.Read(p)
}

// benchFIT is a FIT of n records with a position, altitude, timestamp and four fields nothing
// reads, as a device writes beside them.
func benchFIT(n int) []byte {
	var body bytes.Buffer
	body.WriteByte(0x40)
	body.Write([]byte{0x00, 0x00})
	binary.Write(&body, binary.LittleEndian, uint16(20))
	body.WriteByte(8)
	body.Write([]byte{0x00, 4, 0x85, 0x01, 4, 0x85, 0x02, 2, 0x84, 0xFD, 4, 0x86, 3, 1, 0x02, 4, 1, 0x02, 5, 4, 0x86, 6, 2, 0x84})
	for i := range n {
		body.WriteByte(0x00)
		binary.Write(&body, binary.LittleEndian, int32(600000000+i))
		binary.Write(&body, binary.LittleEndian, int32(120000000+i))
		binary.Write(&body, binary.LittleEndian, uint16(3000))
		binary.Write(&body, binary.LittleEndian, uint32(1000000000+i))
		body.Write([]byte{140, 85})
		binary.Write(&body, binary.LittleEndian, uint32(i*3))
		binary.Write(&body, binary.LittleEndian, uint16(2800))
	}
	hdr := make([]byte, 12)
	hdr[0] = 12
	binary.LittleEndian.PutUint32(hdr[4:8], uint32(body.Len()))
	copy(hdr[8:], ".FIT")
	return append(hdr, body.Bytes()...)
}

func BenchmarkParseFIT(b *testing.B) {
	data := benchFIT(36000)
	b.ReportAllocs()
	var calls int
	for b.Loop() {
		src := &countingReader{r: bytes.NewReader(data)}
		if _, err := ParseFIT(src); err != nil {
			b.Fatal(err)
		}
		calls = src.calls
	}
	b.ReportMetric(float64(calls), "reads/op")
}
