package statscard

import (
	"math"
	"strings"
)

// Proportions of the card, as fractions of its font size, which scales with the image's long
// side so the card reads the same at every export size.
const (
	fontFraction = 0.0135
	minFontPx    = 13
	maxFontPx    = 52
	lineHeight   = 1.4
	padX         = 0.8
	padY         = 0.6
	radius       = 0.6
	// totalsGap is the space above the totals line, where its rule sits.
	totalsGap = 0.5
	capHalf   = 0.365
	// maxWidthFraction caps the panel's width as a fraction of the image's, so it stays a corner
	// card on a narrow preset.
	maxWidthFraction = 0.62
)

// Style is how a run of text is drawn.
type Style int

const (
	Regular   Style = iota
	Secondary       // "+ N more": regular, in the secondary ink
	Bold            // the totals line
)

// Run is one line of text: its left edge and baseline in the panel's pixels.
type Run struct {
	Text  string
	X, Y  float64
	Style Style
}

// Layout is the card's panel, its own pixel size, and the text on it. RuleY is the totals
// line's rule, 0 without one.
type Layout struct {
	Width, Height int
	FontPx        float64
	Radius        float64
	RuleY         float64
	Runs          []Run
}

// Measure is a line's width in pixels, in style at fontPx.
type Measure func(text string, style Style, fontPx float64) float64

// FontPx is the card's font size for an image width × height.
func FontPx(width, height int) float64 {
	long := float64(max(width, height))
	return math.Min(maxFontPx, math.Max(minFontPx, long*fontFraction))
}

// Arrange lays card out for an image width × height: one line per run, the totals under a rule,
// the panel as wide as its longest line within maxWidthFraction of the image, and a line too
// long for that cut short with "…".
func Arrange(card Card, width, height int, measure Measure) Layout {
	font := FontPx(width, height)
	lh := font * lineHeight
	maxText := float64(width)*maxWidthFraction - 2*font*padX

	type item struct {
		text  string
		style Style
	}
	var items []item
	for _, l := range card.Lines {
		items = append(items, item{l, Regular})
	}
	if card.More != "" {
		items = append(items, item{card.More, Secondary})
	}
	if card.Totals != "" {
		items = append(items, item{card.Totals, Bold})
	}

	out := Layout{FontPx: font, Radius: font * radius}
	var widest float64
	top := font * padY
	for i, it := range items {
		if it.style == Bold && i > 0 {
			out.RuleY = top + font*totalsGap/2
			top += font * totalsGap
		}
		text := fit(it.text, it.style, font, maxText, measure)
		widest = math.Max(widest, measure(text, it.style, font))
		// The baseline that centers a capital letter (Inter's cap height is 0.73 em) in its line box.
		out.Runs = append(out.Runs, Run{Text: text, X: font * padX, Y: top + lh/2 + font*capHalf, Style: it.style})
		top += lh
	}
	out.Width = int(math.Ceil(widest + 2*font*padX))
	out.Height = int(math.Ceil(top + font*padY))
	return out
}

// fit is text cut short with "…" so it measures at most maxWidth.
func fit(text string, style Style, font, maxWidth float64, measure Measure) string {
	if measure(text, style, font) <= maxWidth {
		return text
	}
	runes := []rune(text)
	lo, hi := 0, len(runes)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if measure(strings.TrimRight(string(runes[:mid]), " ·")+"…", style, font) <= maxWidth {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return strings.TrimRight(string(runes[:lo]), " ·") + "…"
}
