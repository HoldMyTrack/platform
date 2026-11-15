package pngenc

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"sync"
	"testing"
)

// Encodes running at once, each sharing the pool, all decode to the image they were given.
func TestEncodeRoundTrip(t *testing.T) {
	var wg sync.WaitGroup
	for i := range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			img := image.NewGray(image.Rect(0, 0, 64, 32+i))
			img.SetGray(i, i, color.Gray{Y: uint8(10 * i)})
			b, err := Encode(img)
			if err != nil {
				t.Errorf("encode %d: %v", i, err)
				return
			}
			got, err := png.Decode(bytes.NewReader(b))
			if err != nil {
				t.Errorf("decode %d: %v", i, err)
				return
			}
			if got.Bounds() != img.Bounds() || got.(*image.Gray).GrayAt(i, i) != img.GrayAt(i, i) {
				t.Errorf("image %d changed in the round trip", i)
			}
		}()
	}
	wg.Wait()
}
