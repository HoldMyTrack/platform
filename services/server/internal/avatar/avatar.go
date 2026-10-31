// Package avatar turns an uploaded profile picture into the one stored: upright, at most MaxSide
// pixels on its long side, and re-encoded, which leaves every metadata block of the upload
// behind. A phone photo's EXIF holds where it was taken, and an avatar is shown in the app's
// header, so a home position would otherwise sit in storage and every backup.
package avatar

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp" // image.Decode for an uploaded WebP
)

// MaxSide bounds the stored image's long side: sharp at the sizes the header and the You tab draw
// it, on a dense screen.
const MaxSide = 512

// maxPixels refuses an image whose decoded size would be out of all proportion to its bytes: a
// few-KB PNG can claim 50,000 × 50,000 pixels.
const maxPixels = 40_000_000

// ErrNotImage is an upload no decoder here can read, or one too large to decode.
var ErrNotImage = errors.New("avatar: not a readable image")

// Normalize decodes data (PNG, JPEG or WebP) and returns the image to store and its content
// type: a JPEG stays a JPEG, anything else becomes a PNG (Go has no WebP encoder, and PNG keeps
// transparency).
func Normalize(data []byte) ([]byte, string, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width*cfg.Height > maxPixels {
		return nil, "", ErrNotImage
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, "", ErrNotImage
	}
	img := orient(scaled(src), jpegOrientation(data))

	var out bytes.Buffer
	if format == "jpeg" {
		if err := jpeg.Encode(&out, img, &jpeg.Options{Quality: 88}); err != nil {
			return nil, "", fmt.Errorf("avatar: encode: %w", err)
		}
		return out.Bytes(), "image/jpeg", nil
	}
	if err := png.Encode(&out, img); err != nil {
		return nil, "", fmt.Errorf("avatar: encode: %w", err)
	}
	return out.Bytes(), "image/png", nil
}

// scaled is src as an RGBA image, shrunk so its long side is at most MaxSide.
func scaled(src image.Image) *image.RGBA {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if long := max(w, h); long > MaxSide {
		w, h = max(1, w*MaxSide/long), max(1, h*MaxSide/long)
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, b, draw.Src, nil)
	return dst
}

// orient turns src upright by its EXIF orientation (1–8, TIFF 6.0): what a viewer does on
// display, and what re-encoding would otherwise lose along with the tag.
func orient(src *image.RGBA, o int) *image.RGBA {
	if o < 2 || o > 8 {
		return src
	}
	w, h := src.Bounds().Dx(), src.Bounds().Dy()
	dw, dh := w, h
	if o >= 5 {
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := range h {
		for x := range w {
			var dx, dy int
			switch o {
			case 2:
				dx, dy = w-1-x, y
			case 3:
				dx, dy = w-1-x, h-1-y
			case 4:
				dx, dy = x, h-1-y
			case 5:
				dx, dy = y, x
			case 6:
				dx, dy = h-1-y, x
			case 7:
				dx, dy = h-1-y, w-1-x
			case 8:
				dx, dy = y, w-1-x
			}
			copy(dst.Pix[dst.PixOffset(dx, dy):dst.PixOffset(dx, dy)+4], src.Pix[src.PixOffset(x, y):src.PixOffset(x, y)+4])
		}
	}
	return dst
}
