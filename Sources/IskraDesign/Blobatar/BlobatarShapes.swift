//  Ported from blobatar (https://blobatar.dev), MIT licence,
//  Copyright (c) 2026 Alain. See Licenses/blobatar.txt.

import Foundation

/// The body, as numbers, before anything is traced.
struct BlobatarBody {
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
    /// Squareness, for the silhouettes drawn as a superellipse.
    var n: Double
    var rot: Double
    /// Per-vertex radius multipliers, for the ones drawn as a spline.
    var radii: [Double]
    /// Set only by the silhouettes that draw a polygon.
    var sides: Int = 0
    var round: Double = 0
}

/// A region the eyes have to fit inside.
struct BlobatarEllipse {
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
}

/// What a silhouette adds around its core body. The petals are plain circles, unioned with the
/// body by nothing more than overlapping the same fill — no boolean geometry, no clip paths.
struct BlobatarDecoration {
    struct Petal {
        var cx: Double
        var cy: Double
        var r: Double
    }

    var petals: [Petal] = []
    /// Extra outlines drawn in the body's own fill — the droplet's point, and nothing else.
    var extra: [BlobatarOutline] = []
}

/// One silhouette: everything needed to draw it, and nothing about how often it comes up.
///
/// How often is a property of the band table below, not of the shape — which is what lets the
/// weighting be re-read from blobatar's own fixture without touching any of this.
struct BlobatarSilhouette: Sendable {
    let name: String
    /// How much of the frame the core body takes.
    let core: Double
    /// Patches the body before the face is measured.
    var body: (@Sendable (BlobatarTraits, inout BlobatarBody) -> Void)?
    /// The region the eyes must fit inside. Omitted, it is the body itself — which is what every
    /// silhouette convex around its own centre wants, and half the roster is.
    var face: (@Sendable (BlobatarBody) -> BlobatarEllipse)?
    var decorate: (@Sendable (BlobatarTraits, BlobatarBody, inout BlobatarDecoration) -> Void)?
    /// The core outline. Omitted, a superellipse.
    var path: (@Sendable (BlobatarBody) -> BlobatarOutline)?
}

extension BlobatarSilhouette {
    // Five path calls serve all ten shapes; the shapes that are parameterizations of another
    // name the same function rather than restating it.
    private static let spline: @Sendable (BlobatarBody) -> BlobatarOutline = { b in
        BlobatarGeometry.blob(cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, radii: b.radii, rot: b.rot)
    }

    private static let poly: @Sendable (BlobatarBody) -> BlobatarOutline = { b in
        BlobatarGeometry.polygon(
            cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, sides: b.sides, round: b.round, rot: b.rot
        )
    }

    private static func shrunk(_ k: Double) -> @Sendable (BlobatarBody) -> BlobatarEllipse {
        { b in BlobatarEllipse(cx: b.cx, cy: b.cy, rx: b.rx * k, ry: b.ry * k) }
    }

    private static let splineFace: @Sendable (BlobatarBody) -> BlobatarEllipse = { b in
        shrunk((b.radii.min() ?? 1) * 0.95)(b)
    }

    static let round = BlobatarSilhouette(name: "round", core: 1)

    static let organic = BlobatarSilhouette(
        name: "organic", core: 0.98, face: splineFace, path: spline
    )

    /// `round`, squared off and tilted. Same path, different numbers.
    static let boxy = BlobatarSilhouette(
        name: "boxy", core: 0.86,
        body: { t, b in
            b.n = t.num("body.n", 3.4, 6)
            b.rot = t.num("body.rot", -20, 20)
        }
    )

    static let capsule = BlobatarSilhouette(
        name: "capsule", core: 1.02,
        body: { t, b in b.ry *= t.num("capsule.squat", 0.55, 0.68) },
        face: shrunk(0.94),
        decorate: { _, b, out in
            for side in [-1.0, 1.0] {
                out.petals.append(.init(cx: b.cx + side * (b.rx - b.ry), cy: b.cy, r: b.ry))
            }
        },
        path: { b in BlobatarGeometry.box(cx: b.cx, cy: b.cy, rx: b.rx - b.ry, ry: b.ry) }
    )

    static let nub = BlobatarSilhouette(
        name: "nub", core: 0.88,
        decorate: { t, b, out in
            for i in 0..<t.int("nub.n", 1, 2) {
                let a = t.num("nub.a\(i)", 0, 2 * Double.pi)
                out.petals.append(.init(
                    cx: b.cx + cos(a) * b.rx * 0.88,
                    cy: b.cy + sin(a) * b.rx * 0.88,
                    r: b.rx * t.num("nub.r\(i)", 0.24, 0.4)
                ))
            }
        }
    )

    /// `organic`, with lobes on the upper half.
    static let cloud = BlobatarSilhouette(
        name: "cloud", core: 0.78,
        face: splineFace,
        decorate: { t, b, out in
            let count = t.int("cloud.n", 4, 6)
            for i in 0..<count {
                let a = Double.pi + Double.pi * (Double(i) + 0.5) / Double(count)
                out.petals.append(.init(
                    cx: b.cx + cos(a) * b.rx * 0.8,
                    cy: b.cy + sin(a) * b.rx * 0.5,
                    r: b.rx * t.num("cloud.r\(i)", 0.44, 0.62)
                ))
            }
        },
        path: spline
    )

    static let droplet = BlobatarSilhouette(
        name: "droplet", core: 0.78,
        // Shifted down by what the taper adds above, so head and point together sit centred in
        // the frame rather than the head alone. `n` is pinned to a true ellipse, which is the
        // curve the taper is tangent to.
        body: { _, b in
            b.cy += 0.22 * b.ry
            b.n = 2
        },
        face: { b in
            BlobatarEllipse(cx: b.cx, cy: b.cy + b.ry * 0.05, rx: b.rx * 0.88, ry: b.ry * 0.88)
        },
        decorate: { t, b, out in
            out.extra.append(BlobatarGeometry.taper(
                cx: b.cx, cy: b.cy, rx: b.rx, ry: b.ry, tip: t.num("droplet.tip", 1.4, 1.65)
            ))
        }
    )

    static let hexagon = BlobatarSilhouette(
        name: "hexagon", core: 1.05,
        body: { t, b in
            b.sides = 6
            b.rot = t.num("body.rot", -12, 12)
            b.round = t.num("poly.round", 0.24, 0.5)
        },
        face: shrunk(0.84),
        path: poly
    )

    static let sun = BlobatarSilhouette(
        name: "sun", core: 0.7,
        decorate: { t, b, out in
            let count = t.int("sun.n", 6, 9)
            let dist = b.rx * t.num("sun.dist", 1.0, 1.08)
            let r = b.rx * t.num("sun.r", 0.2, 0.26)
            let off = t.num("sun.rot", 0, 2 * Double.pi)
            for i in 0..<count {
                let a = off + 2 * Double.pi * Double(i) / Double(count)
                out.petals.append(.init(cx: b.cx + cos(a) * dist, cy: b.cy + sin(a) * dist, r: r))
            }
        }
    )

    /// `hexagon` with three sides, and a tighter tilt so it rests on its base.
    static let triangle = BlobatarSilhouette(
        name: "triangle", core: 1.15,
        body: { t, b in
            b.sides = 3
            b.rot = t.num("body.rot", -5, 5)
            b.round = t.num("poly.round", 0.24, 0.5)
        },
        face: { b in
            BlobatarEllipse(cx: b.cx, cy: b.cy + b.ry * 0.1, rx: b.rx * 0.54, ry: b.ry * 0.36)
        },
        path: poly
    )

    /// The ten-silhouette vocabulary, each with the upper edge of its band.
    ///
    /// Weighted rather than uniform, and the weights are the point: round and organic are the
    /// everyday creatures, while a triangle stays a find — 2% of people, so meeting one means
    /// something. These edges, the layout ranges in `BlobatarLayout`, and the tone set in
    /// `BlobatarPalette` are one frozen mapping from seed to look: move any of them and every
    /// existing face changes identity.
    static let bands: [(BlobatarSilhouette, Double)] = [
        (round, 0.22), (organic, 0.48), (boxy, 0.6), (capsule, 0.7), (nub, 0.79),
        (cloud, 0.86), (droplet, 0.915), (hexagon, 0.95), (sun, 0.98), (triangle, 1),
    ]
}
