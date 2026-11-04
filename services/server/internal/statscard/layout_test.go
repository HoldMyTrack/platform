package statscard

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// half measures every rune at half the font size.
func half(text string, _ Style, font float64) float64 {
	return float64(utf8.RuneCountInString(text)) * font / 2
}

func TestFontPx(t *testing.T) {
	for _, tc := range []struct {
		w, h int
		want float64
	}{
		{1080, 566, 14.58},
		{1080, 1920, 25.92},
		{1920, 1080, 25.92},
		{3840, 2160, 51.84},
		{500, 300, minFontPx},
		{8000, 8000, maxFontPx},
	} {
		if got := FontPx(tc.w, tc.h); got < tc.want-0.01 || got > tc.want+0.01 {
			t.Errorf("FontPx(%d, %d) = %v, want %v", tc.w, tc.h, got, tc.want)
		}
	}
}

func TestArrange(t *testing.T) {
	card := Card{Lines: []string{"Hike · 8 mi", "Walk"}, More: "+ 4 more", Totals: "6 activities"}
	l := Arrange(card, 2000, 1000, half)
	font := FontPx(2000, 1000) // 27
	if l.FontPx != font {
		t.Fatalf("FontPx = %v", l.FontPx)
	}
	styles := []Style{Regular, Regular, Secondary, Bold}
	if len(l.Runs) != len(styles) {
		t.Fatalf("runs = %d", len(l.Runs))
	}
	for i, r := range l.Runs {
		if r.Style != styles[i] || r.X != font*padX {
			t.Errorf("run %d = %+v", i, r)
		}
		if i > 0 && r.Y <= l.Runs[i-1].Y {
			t.Errorf("run %d isn't below the one before", i)
		}
	}
	// The totals sit a line plus the gap below "+ N more", the rule in that gap.
	gap := l.Runs[3].Y - l.Runs[2].Y
	if want := font*lineHeight + font*totalsGap; gap < want-0.001 || gap > want+0.001 {
		t.Errorf("totals gap = %v, want %v", gap, want)
	}
	if l.RuleY <= l.Runs[2].Y || l.RuleY >= l.Runs[3].Y-font {
		t.Errorf("RuleY = %v between %v and %v", l.RuleY, l.Runs[2].Y, l.Runs[3].Y)
	}
	// As wide as "6 activities" (12 runes) plus padding; as tall as its four lines, gap and padding.
	if want := int(12*font/2 + 2*font*padX + 0.999); l.Width != want {
		t.Errorf("Width = %d, want %d", l.Width, want)
	}
	if want := int(4*font*lineHeight + font*totalsGap + 2*font*padY + 0.999); l.Height != want {
		t.Errorf("Height = %d, want %d", l.Height, want)
	}
}

func TestArrangeOneLineHasNoRule(t *testing.T) {
	if l := Arrange(Card{Lines: []string{"Walk"}}, 1920, 1080, half); l.RuleY != 0 || len(l.Runs) != 1 {
		t.Errorf("%+v", l)
	}
}

func TestArrangeCapsWidth(t *testing.T) {
	long := strings.Repeat("Very long custom type ", 10) + "· 8 mi"
	l := Arrange(Card{Lines: []string{long}}, 1080, 1920, half)
	if float64(l.Width) > 1080*maxWidthFraction+1 {
		t.Errorf("Width = %d, past %v", l.Width, 1080*maxWidthFraction)
	}
	if got := l.Runs[0].Text; !strings.HasSuffix(got, "…") || !strings.HasPrefix(long, strings.TrimSuffix(got, "…")) {
		t.Errorf("text = %q", got)
	}
}
