// Package pngenc encodes PNGs reusing the encoder's buffers between calls, for fog tiles.
// png.Encode allocates them afresh each time, about a megabyte for a 256 px tile, and a fog
// render encodes one per changed tile. A pooled buffer keeps the last image it encoded, and
// that PNG's bytes, alive until the pool is collected, so a large image that is encoded rarely
// (an avatar, a stats card) is better encoded with png.Encode.
package pngenc

import (
	"bytes"
	"image"
	"image/png"
	"sync"
)

type bufferPool struct{ pool sync.Pool }

func (p *bufferPool) Get() *png.EncoderBuffer {
	b, _ := p.pool.Get().(*png.EncoderBuffer)
	return b
}

func (p *bufferPool) Put(b *png.EncoderBuffer) { p.pool.Put(b) }

var encoder = png.Encoder{BufferPool: &bufferPool{}}

// Encode is img as a PNG.
func Encode(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	if err := encoder.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
