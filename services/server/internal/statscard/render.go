package statscard

import (
	"bytes"
	_ "embed"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"sync"

	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
	"golang.org/x/image/vector"
)

// Inter, the apps' UI font, as static Regular and SemiBold instances of the variable font the
// apps ship (apps/android/.../res/font/inter.ttf), cut with fontTools' varLib.instancer: x/image
// draws only a variable font's default instance. OFL.txt is its license.
var (
	//go:embed fonts/inter-regular.ttf
	interRegular []byte
	//go:embed fonts/inter-semibold.ttf
	interSemiBold []byte
)

var fonts = sync.OnceValues(func() ([2]*opentype.Font, error) {
	var out [2]*opentype.Font
	for i, data := range [][]byte{interRegular, interSemiBold} {
		f, err := opentype.Parse(data)
		if err != nil {
			return out, fmt.Errorf("statscard: parse font: %w", err)
		}
		out[i] = f
	}
	return out, nil
})

// Theme is the image's: Dark under a dark flavor or Satellite, as the watermark's colors are.
type Theme string

const (
	Light Theme = "light"
	Dark  Theme = "dark"
)

// palette is tokens.css's surface, ink and secondary ink for a theme.
type palette struct{ surface, ink, secondary color.NRGBA }

var palettes = map[Theme]palette{
	Light: {color.NRGBA{0xff, 0xff, 0xff, 0xff}, color.NRGBA{0x20, 0x2b, 0x25, 0xff}, color.NRGBA{0x6c, 0x7a, 0x70, 0xff}},
	Dark:  {color.NRGBA{0x1c, 0x25, 0x20, 0xff}, color.NRGBA{0xec, 0xe6, 0xd8, 0xff}, color.NRGBA{0xa8, 0xb2, 0xa9, 0xff}},
}

// The panel's opacity, so the map shows through while the text reads over Satellite; and the
// totals rule's, over the panel.
const (
	panelAlpha = 0.8
	ruleAlpha  = 0.18
)

// faces is the card's two weights at one size; Measure for Arrange.
type faces [2]font.Face

func newFaces(fontPx float64) (faces, error) {
	fs, err := fonts()
	if err != nil {
		return faces{}, err
	}
	var out faces
	for i, f := range fs {
		face, err := opentype.NewFace(f, &opentype.FaceOptions{Size: fontPx, DPI: 72, Hinting: font.HintingNone})
		if err != nil {
			return faces{}, fmt.Errorf("statscard: face: %w", err)
		}
		out[i] = face
	}
	return out, nil
}

func (f faces) of(s Style) font.Face {
	if s == Bold {
		return f[1]
	}
	return f[0]
}

func (f faces) measure(text string, s Style, _ float64) float64 {
	return fixedToFloat(font.MeasureString(f.of(s), text))
}

// Render is card laid out for an image width × height and drawn in theme, as a PNG of the panel
// alone: the client places it in the image's corner.
func Render(card Card, width, height int, theme Theme) ([]byte, error) {
	p, ok := palettes[theme]
	if !ok {
		return nil, fmt.Errorf("statscard: unknown theme %q", theme)
	}
	fs, err := newFaces(FontPx(width, height))
	if err != nil {
		return nil, err
	}
	l := Arrange(card, width, height, fs.measure)
	img := image.NewRGBA(image.Rect(0, 0, l.Width, l.Height))

	panel := vector.NewRasterizer(l.Width, l.Height)
	roundedRect(panel, 0, 0, float32(l.Width), float32(l.Height), float32(l.Radius))
	panel.Draw(img, img.Bounds(), image.NewUniform(withAlpha(p.surface, panelAlpha)), image.Point{})

	if l.RuleY > 0 {
		x0, x1 := l.FontPx*padX, float64(l.Width)-l.FontPx*padX
		thick := max(1, l.FontPx/16)
		rule := vector.NewRasterizer(l.Width, l.Height)
		rect(rule, float32(x0), float32(l.RuleY-thick/2), float32(x1), float32(l.RuleY+thick/2))
		rule.Draw(img, img.Bounds(), image.NewUniform(withAlpha(p.ink, ruleAlpha)), image.Point{})
	}

	for _, r := range l.Runs {
		ink := p.ink
		if r.Style == Secondary {
			ink = p.secondary
		}
		d := font.Drawer{Dst: img, Src: image.NewUniform(ink), Face: fs.of(r.Style), Dot: fixed.Point26_6{X: floatToFixed(r.X), Y: floatToFixed(r.Y)}}
		d.DrawString(r.Text)
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, fmt.Errorf("statscard: encode: %w", err)
	}
	return buf.Bytes(), nil
}

func withAlpha(c color.NRGBA, a float64) color.NRGBA {
	c.A = uint8(a*255 + 0.5)
	return c
}

func fixedToFloat(v fixed.Int26_6) float64 { return float64(v) / 64 }
func floatToFixed(v float64) fixed.Int26_6 { return fixed.Int26_6(v*64 + 0.5) }

func rect(z *vector.Rasterizer, x0, y0, x1, y1 float32) {
	z.MoveTo(x0, y0)
	z.LineTo(x1, y0)
	z.LineTo(x1, y1)
	z.LineTo(x0, y1)
	z.ClosePath()
}

// roundedRect adds a rectangle with corners of radius r, each a cubic Bézier's quarter circle.
func roundedRect(z *vector.Rasterizer, x0, y0, x1, y1, r float32) {
	const k = 0.5523 // the control-point distance that best fits a quarter circle
	c := r * (1 - k)
	z.MoveTo(x0+r, y0)
	z.LineTo(x1-r, y0)
	z.CubeTo(x1-c, y0, x1, y0+c, x1, y0+r)
	z.LineTo(x1, y1-r)
	z.CubeTo(x1, y1-c, x1-c, y1, x1-r, y1)
	z.LineTo(x0+r, y1)
	z.CubeTo(x0+c, y1, x0, y1-c, x0, y1-r)
	z.LineTo(x0, y0+r)
	z.CubeTo(x0, y0+c, x0+c, y0, x0+r, y0)
	z.ClosePath()
}
