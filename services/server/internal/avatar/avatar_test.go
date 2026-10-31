package avatar

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

// halves is a w × h image, red on its left half and blue on its right.
func halves(w, h int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		for x := range w {
			c := color.RGBA{R: 255, A: 255}
			if x >= w/2 {
				c = color.RGBA{B: 255, A: 255}
			}
			img.Set(x, y, c)
		}
	}
	return img
}

// withExif is a JPEG of img carrying an EXIF block: Orientation o, and a stand-in for the GPS
// position a phone writes.
func withExif(t *testing.T, img image.Image, o uint16) []byte {
	t.Helper()
	var plain bytes.Buffer
	if err := jpeg.Encode(&plain, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatal(err)
	}
	tiff := []byte("MM\x00\x2a\x00\x00\x00\x08")  // big-endian, IFD0 at 8
	tiff = binary.BigEndian.AppendUint16(tiff, 1) // one entry
	tiff = binary.BigEndian.AppendUint16(tiff, 0x0112)
	tiff = binary.BigEndian.AppendUint16(tiff, 3) // SHORT
	tiff = binary.BigEndian.AppendUint32(tiff, 1)
	tiff = binary.BigEndian.AppendUint16(tiff, o)
	tiff = append(tiff, 0, 0, 0, 0, 0, 0) // value padding, no next IFD
	tiff = append(tiff, "GPSLatitude 52.5200 N"...)
	payload := append([]byte("Exif\x00\x00"), tiff...)
	app1 := []byte{0xFF, 0xE1}
	app1 = binary.BigEndian.AppendUint16(app1, uint16(len(payload)+2))
	app1 = append(app1, payload...)
	b := plain.Bytes()
	return append(append(append([]byte{}, b[:2]...), app1...), b[2:]...)
}

func near(c color.Color, r, b uint32) bool {
	cr, _, cb, _ := c.RGBA()
	return (cr>>8 > 200) == (r > 0) && (cb>>8 > 200) == (b > 0)
}

func TestNormalizeTurnsUprightAndDropsMetadata(t *testing.T) {
	in := withExif(t, halves(64, 32), 6) // stored on its side: shown turned 90° clockwise
	if jpegOrientation(in) != 6 {
		t.Fatalf("test image orientation %d, want 6", jpegOrientation(in))
	}
	out, contentType, err := Normalize(in)
	if err != nil {
		t.Fatal(err)
	}
	if contentType != "image/jpeg" || bytes.Contains(out, []byte("Exif")) || bytes.Contains(out, []byte("GPS")) {
		t.Fatalf("%s, %d bytes: want a JPEG with no EXIF left", contentType, len(out))
	}
	img, err := jpeg.Decode(bytes.NewReader(out))
	if err != nil {
		t.Fatal(err)
	}
	// Turned clockwise, the left (red) half is on top.
	if b := img.Bounds(); b.Dx() != 32 || b.Dy() != 64 {
		t.Fatalf("size %v, want 32 × 64", b.Size())
	}
	if !near(img.At(16, 8), 1, 0) || !near(img.At(16, 56), 0, 1) {
		t.Errorf("top %v, bottom %v: want red over blue", img.At(16, 8), img.At(16, 56))
	}
}

func TestNormalizeScalesDownAndKeepsPNG(t *testing.T) {
	var in bytes.Buffer
	if err := png.Encode(&in, halves(1024, 300)); err != nil {
		t.Fatal(err)
	}
	out, contentType, err := Normalize(in.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(bytes.NewReader(out))
	if err != nil || contentType != "image/png" {
		t.Fatalf("%s: %v", contentType, err)
	}
	if b := img.Bounds(); b.Dx() != MaxSide || b.Dy() != 150 {
		t.Errorf("size %v, want %d × 150", b.Size(), MaxSide)
	}
}

func TestNormalizeRefusesWhatIsntAnImage(t *testing.T) {
	if _, _, err := Normalize([]byte("GIF89a not really")); err != ErrNotImage {
		t.Errorf("err %v, want ErrNotImage", err)
	}
}

func TestOrientMapsEachCorner(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 3, 2))
	src.Set(0, 0, color.RGBA{R: 255, A: 255}) // the top-left corner, marked
	for o, want := range map[int]image.Point{
		1: {0, 0}, 2: {2, 0}, 3: {2, 1}, 4: {0, 1}, 5: {0, 0}, 6: {1, 0}, 7: {1, 2}, 8: {0, 2},
	} {
		dst := orient(src, o)
		if r, _, _, _ := dst.At(want.X, want.Y).RGBA(); r == 0 {
			t.Errorf("orientation %d: marked corner not at %v", o, want)
		}
	}
}
