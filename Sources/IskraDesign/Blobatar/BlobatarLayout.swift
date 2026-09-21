//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation

/// One eye, as a superellipse.
struct BlobatarEye {
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
    var n: Double
    var rot: Double
}

/// A whole creature, as numbers. Nothing here is traced yet and nothing here has a colour.
struct BlobatarLayout {
    var shape: String
    var body: BlobatarBody
    var face: BlobatarEllipse
    var petals: [BlobatarDecoration.Petal]
    var extra: [BlobatarOutline]
    var eyes: [BlobatarEye]
    /// The core outline, already traced with whichever primitive this silhouette uses.
    var outline: BlobatarOutline

    /// Reads a seed's traits into a creature.
    static func make(_ t: BlobatarTraits) -> BlobatarLayout {
        let shape = silhouette(for: t("shape"))
        let r = t.num("body.r", 31, 38) * shape.core

        var body = BlobatarBody(
            cx: 50 + t.jitter("body.x", 1.5),
            cy: 50 + t.jitter("body.y", 1.5),
            rx: r,
            ry: r * t.num("body.ratio", 0.92, 1.08),
            n: t.num("body.n", 1.9, 2.5),
            rot: 0,
            radii: (0..<t.int("body.pts", 6, 8)).map { 1 + t.jitter("body.r\($0)", 0.16) }
        )
        shape.body?(t, &body)

        let face = shape.face?(body)
            ?? BlobatarEllipse(cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry)

        var decoration = BlobatarDecoration()
        shape.decorate?(t, body, &decoration)

        let outline = shape.path?(body) ?? BlobatarGeometry.superellipse(
            cx: body.cx, cy: body.cy, rx: body.rx, ry: body.ry, n: body.n, rot: body.rot
        )

        return BlobatarLayout(
            shape: shape.name,
            body: body,
            face: face,
            petals: decoration.petals,
            extra: decoration.extra,
            eyes: eyes(t, body: body, face: face),
            outline: outline
        )
    }

    /// The first band the value falls under.
    private static func silhouette(for value: Double) -> BlobatarSilhouette {
        BlobatarSilhouette.bands.first { value < $0.1 }?.0 ?? BlobatarSilhouette.bands.last!.0
    }

    /// Fits the pair of eyes against the silhouette's face region, on both axes.
    ///
    /// The arithmetic in the middle is containment, and it is the reason a blobatar never comes
    /// out with an eye hanging off the side of its head: the cluster's reach is measured against
    /// the face it has to sit in, and everything — the gap, the gaze offset, the lean — is scaled
    /// down together by one factor when it would not fit. Both eyes read the same `eye.n`, so
    /// they always share their squareness; everything else about the right eye is the left one
    /// scaled, which is what keeps a face asymmetric without making it wrong.
    private static func eyes(
        _ t: BlobatarTraits, body b: BlobatarBody, face: BlobatarEllipse
    ) -> [BlobatarEye] {
        let rx = b.rx
        let baseRx = t.num("eye.rx", 0.075, 0.105) * rx
        let ratio = t.num("eye.ratio", 1.9, 3.2)
        let scale = t.num("eye.scale", 0.78, 1.24)
        let stretch = t.num("eye.stretch", 0.85, 1.18)
        let clearance = t.num("eye.gap", 0.1, 0.24) * rx
        let wide = baseRx * Swift.max(1, scale)
        let tall = baseRx * ratio * Swift.max(1, scale * stretch)
        let baseGap = wide + rx * 0.03 + clearance

        let gx = t.jitter("gaze.x", 0.09) * face.rx
        let gy = t.num("gaze.y", -0.2, 0.08) * face.ry
        let dy = t.jitter("eye.dy", 0.04) * face.ry
        let reach = hypot(wide, tall)
        let need = hypot(
            (abs(gx) + baseGap + reach) / face.rx,
            (abs(gy) + abs(dy) + reach) / face.ry
        )
        let fit = need > 0.9 ? 0.9 / need : 1

        let er = baseRx * fit
        let eyeRy = er * ratio
        let gap = baseGap * fit
        let room = Swift.max(0, Swift.min(1, clearance / tall))
        let bound = Swift.min(12, asin(room) * 180 / Double.pi)
        let lean = t.num("eye.lean", -1, 1) * bound
        let lean2 = Swift.max(-12, Swift.min(12, lean + t.jitter("eye.lean2", 3.5)))

        let cx = face.cx + gx * fit
        let cy = face.cy + gy * fit
        return [
            BlobatarEye(
                cx: cx - gap, cy: cy, rx: er, ry: eyeRy, n: t.num("eye.n", 3.5, 6), rot: lean
            ),
            BlobatarEye(
                cx: cx + gap, cy: cy + dy * fit,
                rx: er * scale, ry: eyeRy * scale * stretch,
                n: t.num("eye.n", 3.5, 6), rot: lean2
            ),
        ]
    }
}
