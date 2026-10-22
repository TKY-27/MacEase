import Foundation

/// Björn Ottosson's Oklab, from 8-bit sRGB.
struct Oklab: Equatable {
    var l: Float
    var a: Float
    var b: Float

    static let linearTable: [Float] = (0..<256).map { value in
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    init(l: Float, a: Float, b: Float) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.init(
            linearRed: Self.linearTable[Int(red)], green: Self.linearTable[Int(green)],
            blue: Self.linearTable[Int(blue)])
    }

    init(linearRed r: Float, green g: Float, blue b: Float) {
        let lms = (
            cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b),
            cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b),
            cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        )
        l = 0.2104542553 * lms.0 + 0.7936177850 * lms.1 - 0.0040720468 * lms.2
        a = 1.9779984951 * lms.0 - 2.4285922050 * lms.1 + 0.4505937099 * lms.2
        self.b = 0.0259040371 * lms.0 + 0.7827717662 * lms.1 - 0.8086757660 * lms.2
    }

    var srgb: (UInt8, UInt8, UInt8) {
        let l1 = l + 0.3963377774 * a + 0.2158037573 * b
        let m1 = l - 0.1055613458 * a - 0.0638541728 * b
        let s1 = l - 0.0894841775 * a - 1.2914855480 * b
        let (l3, m3, s3) = (l1 * l1 * l1, m1 * m1 * m1, s1 * s1 * s1)
        let red = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let green = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let blue = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        return (Self.encode(red), Self.encode(green), Self.encode(blue))
    }

    private static func encode(_ linear: Float) -> UInt8 {
        let clamped = min(max(linear, 0), 1)
        let gamma = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return UInt8((gamma * 255).rounded())
    }
}
