package statscard

import (
	"bytes"
	"flag"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

var update = flag.Bool("update", false, "rewrite testdata/golden from the current renderer")

// goldenSizes are the export's distinct image sizes: each preset's (apps/web/src/map/
// exportPresets.ts) and Custom's long sides in a 16:9 window.
var goldenSizes = []struct {
	name string
	w, h int
}{
	{"square-1080x1080", 1080, 1080},
	{"portrait-1080x1350", 1080, 1350},
	{"facebook-portrait-1080x1359", 1080, 1359},
	{"landscape-1080x566", 1080, 566},
	{"story-1080x1920", 1080, 1920},
	{"x-landscape-1280x720", 1280, 720},
	{"custom-1920x1080", 1920, 1080},
	{"custom-2560x1440", 2560, 1440},
	{"custom-3840x2160", 3840, 2160},
}

// sevenChecked is docs' example: seven checked, the last two under "+ 2 more".
func sevenChecked() []Activity {
	walk := Activity{Type: "walk", DistanceMeters: f(1770), MovingSeconds: s(1620), ElevationGainM: f(0)}
	ride := Activity{Type: "ride", DistanceMeters: f(39429), MovingSeconds: s(7500), ElevationGainM: f(341)}
	return []Activity{hike(), ride, walk, hike(), ride, walk, hike()}
}

func TestRenderGolden(t *testing.T) {
	card := Values(sevenChecked(), i18n.Get("en"), true)
	for _, size := range goldenSizes {
		for _, theme := range []Theme{Light, Dark} {
			name := fmt.Sprintf("%s-%s.png", size.name, theme)
			t.Run(name, func(t *testing.T) {
				got, err := Render(card, size.w, size.h, theme)
				if err != nil {
					t.Fatal(err)
				}
				path := filepath.Join("testdata", "golden", name)
				if *update {
					if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(path, got, 0o644); err != nil {
						t.Fatal(err)
					}
					return
				}
				want, err := os.ReadFile(path)
				if err != nil {
					t.Fatalf("%v (run with -update to write it)", err)
				}
				if msg := imageDiff(t, got, want); msg != "" {
					t.Errorf("%s differs from its golden: %s (run with -update after checking the new image)", name, msg)
				}
			})
		}
	}
}

// imageDiff compares two PNGs, allowing for the rounding differences fused multiply-adds make
// between CPUs: a channel within 8, and at most 0.2% of pixels past that.
func imageDiff(t *testing.T, a, b []byte) string {
	t.Helper()
	ia, err := png.Decode(bytes.NewReader(a))
	if err != nil {
		t.Fatal(err)
	}
	ib, err := png.Decode(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	if ia.Bounds() != ib.Bounds() {
		return fmt.Sprintf("size %v, golden %v", ia.Bounds().Size(), ib.Bounds().Size())
	}
	bounds := ia.Bounds()
	off := 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			if !near(ia, ib, x, y) {
				off++
			}
		}
	}
	if limit := bounds.Dx() * bounds.Dy() / 500; off > limit {
		return fmt.Sprintf("%d pixels off, at most %d allowed", off, limit)
	}
	return ""
}

func near(a, b image.Image, x, y int) bool {
	r1, g1, b1, a1 := a.At(x, y).RGBA()
	r2, g2, b2, a2 := b.At(x, y).RGBA()
	for _, d := range [][2]uint32{{r1, r2}, {g1, g2}, {b1, b2}, {a1, a2}} {
		diff := int(d[0]>>8) - int(d[1]>>8)
		if diff > 8 || diff < -8 {
			return false
		}
	}
	return true
}

func TestRenderSize(t *testing.T) {
	card := Values(sevenChecked(), i18n.Get("en"), true)
	got, err := Render(card, 1920, 1080, Light)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := png.DecodeConfig(bytes.NewReader(got))
	if err != nil {
		t.Fatal(err)
	}
	fs, _ := newFaces(FontPx(1920, 1080))
	l := Arrange(card, 1920, 1080, fs.measure)
	if cfg.Width != l.Width || cfg.Height != l.Height {
		t.Errorf("PNG %d×%d, layout %d×%d", cfg.Width, cfg.Height, l.Width, l.Height)
	}
	if _, err := Render(card, 1920, 1080, "sepia"); err == nil {
		t.Error("an unknown theme rendered")
	}
}
