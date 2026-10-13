import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AppKit

// usage: engrave <input> <output.png> <lineWidth> <contrast> <angle>
let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let lineWidth = Float(args.count > 3 ? args[3] : "7") ?? 7
let contrast = Float(args.count > 4 ? args[4] : "1.35") ?? 1.35
let angle = Float(args.count > 5 ? args[5] : "0.6") ?? 0.6

let ctx = CIContext()
let original = CIImage(contentsOf: input)!

// 1. Lift the subject (dog) with Vision.
let handler = VNImageRequestHandler(ciImage: original)
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])
guard let result = request.results?.first else { fatalError("no subject found") }
let maskBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
let mask = CIImage(cvPixelBuffer: maskBuffer)

// 2. Upscale 3x for finer lines.
let scale: Float = 3
let up = CIFilter.lanczosScaleTransform()
up.inputImage = original; up.scale = scale; up.aspectRatio = 1
let big = up.outputImage!
let upMask = CIFilter.lanczosScaleTransform()
upMask.inputImage = mask; upMask.scale = scale; upMask.aspectRatio = 1
let bigMask = upMask.outputImage!.cropped(to: big.extent)

// 3. Grayscale, contrast, slight smoothing so line screen follows forms not noise.
let gammaValue = Float(args.count > 6 ? args[6] : "0.5") ?? 0.5
let shadows = CIFilter.highlightShadowAdjust()
shadows.inputImage = big; shadows.shadowAmount = 1.0; shadows.highlightAmount = 0.9; shadows.radius = 12
let mono = CIFilter.colorControls()
mono.inputImage = shadows.outputImage!; mono.saturation = 0; mono.contrast = contrast; mono.brightness = 0.0
let gamma = CIFilter.gammaAdjust()
gamma.inputImage = mono.outputImage!; gamma.power = gammaValue      // < 1 lifts midtones
let blur = CIFilter.gaussianBlur()
blur.inputImage = gamma.outputImage!; blur.radius = 1.2
let toned = blur.outputImage!.cropped(to: big.extent)

// 4. Two crossed line screens = engraving hatching (darks get cross-hatched).
func screen(_ img: CIImage, angle: Float, width: Float) -> CIImage {
    let f = CIFilter.lineScreen()
    f.inputImage = img; f.angle = angle; f.width = width; f.sharpness = 0.85
    f.center = CGPoint(x: big.extent.midX, y: big.extent.midY)
    return f.outputImage!.cropped(to: big.extent)
}
let primary = screen(toned, angle: angle, width: lineWidth)
// second pass only in the shadows: darken image response so only darks produce lines
let shadow = CIFilter.colorControls()
shadow.inputImage = toned; shadow.brightness = 0.42; shadow.contrast = 1.8
let secondary = screen(shadow.outputImage!, angle: angle + 1.1, width: lineWidth)
let mult = CIFilter.multiplyCompositing()
mult.inputImage = primary; mult.backgroundImage = secondary
let hatched = mult.outputImage!.cropped(to: big.extent)

// 5. Edge lines for contours (from the soft toned image), multiplied in.
let edges = CIFilter.edges()
edges.inputImage = toned; edges.intensity = 1.1
let inv = CIFilter.colorInvert(); inv.inputImage = edges.outputImage!
let edgeMono = CIFilter.colorControls(); edgeMono.inputImage = inv.outputImage!; edgeMono.saturation = 0; edgeMono.contrast = 1.4
let mult2 = CIFilter.multiplyCompositing()
mult2.inputImage = hatched; mult2.backgroundImage = edgeMono.outputImage!.cropped(to: big.extent)
let engraved = mult2.outputImage!.cropped(to: big.extent)

// 6. Composite onto white using the subject mask (feathered slightly).
let feather = CIFilter.gaussianBlur(); feather.inputImage = bigMask; feather.radius = 2
let white = CIImage(color: .white).cropped(to: big.extent)
let blend = CIFilter.blendWithMask()
blend.inputImage = engraved; blend.backgroundImage = white; blend.maskImage = feather.outputImage!.cropped(to: big.extent)
let final = blend.outputImage!.cropped(to: big.extent)

let cs = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
try ctx.writePNGRepresentation(of: final, to: output, format: .L8, colorSpace: cs)
print("wrote", output.path, big.extent.size)
