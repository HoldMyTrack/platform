package fog

import (
	"bytes"
	"image"
	"image/png"
	"testing"
)

func benchStroke() *image.Gray {
	m := image.NewGray(image.Rect(0, 0, TileSize, TileSize))
	for i := 0; i < TileSize; i++ {
		for w := -1; w <= 1; w++ { // a stroke ~3 px wide, as strokeRadiusPx draws one
			if y := i/2 + TileSize/5 + w; y >= 0 && y < TileSize {
				m.Pix[y*m.Stride+i] = 255
			}
		}
	}
	return m
}

func BenchmarkCompositeFog(b *testing.B) {
	masks := []*image.Gray{benchStroke(), benchStroke(), benchStroke()}
	for b.Loop() {
		compositeFogMask(masks)
	}
}

func BenchmarkDownsample(b *testing.B) {
	c := [4]*image.Gray{benchStroke(), benchStroke(), benchStroke(), benchStroke()}
	for b.Loop() {
		downsampleQuadrants(c)
	}
}

func BenchmarkEncodeMask(b *testing.B) {
	m := compositeFogMask([]*image.Gray{benchStroke()})
	var buf bytes.Buffer
	for b.Loop() {
		buf.Reset()
		png.Encode(&buf, m)
	}
}

func BenchmarkDecodeMask(b *testing.B) {
	var buf bytes.Buffer
	png.Encode(&buf, compositeFogMask([]*image.Gray{benchStroke()}))
	data := buf.Bytes()
	for b.Loop() {
		png.Decode(bytes.NewReader(data))
	}
}
