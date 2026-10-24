// Written by apps/ios/scripts/make-design.py from the web's tokens.css; edit that file
// and run the script. The colors are the asset catalog's Palette folder.

import CoreGraphics

/// The web's spacing, radius and type scales, in points.
enum DesignTokens {
    /// fm-space-*.
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
    }
    /// fm-radius-*; pill is any value past half a control's height.
    enum Radius {
        static let xs: CGFloat = 2
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let pill: CGFloat = 999
    }
    /// fm-text-*, before Dynamic Type scales them.
    enum Text {
        static let xxxs: CGFloat = 9
        static let xxs: CGFloat = 10
        static let xs: CGFloat = 11
        static let sm: CGFloat = 12
        static let md: CGFloat = 13
        static let lg: CGFloat = 14
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
    }
    /// fm-weight-*, as variable-font weights.
    enum Weight {
        static let regular: CGFloat = 400
        static let semibold: CGFloat = 600
        static let bold: CGFloat = 700
        static let heavy: CGFloat = 800
    }
}
