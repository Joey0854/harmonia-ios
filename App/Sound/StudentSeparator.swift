import Foundation

/// The distilled student separation network (tools/student/student.py), as the app's Core ML model
/// runs it: `spec` is HTDemucs' normalised spectrum (4 × `Demucs.bins` × `Demucs.frames`, the same as
/// `BandNetwork`'s), the answer a complex mask per stem: 20 × bins × frames (stem in `Student.stems`
/// order, then L re, L im, R re, R im).
public protocol StudentNetwork: AnyObject {
    func run(spec: [Float]) throws -> [Float]
}

/// Pre- and post-processing around the student network: the transforms are `Demucs.spectrum` /
/// `Demucs.inverse` (Accelerate), the network only sees the z-scored spectrum and gives masks; each stem's
/// spectrum is mask × the mix's spectrum (complex), in float32, outside the network.
public enum Student {
    public static let stems = ["vocals", "drums", "bass", "piano", "other"]

    /// One segment (both channels `Demucs.segment` samples): [stem][channel][sample].
    public static func separate(left: [Float], right: [Float], network: StudentNetwork) throws -> [[[Float]]] {
        let l = Demucs.spectrum(left), r = Demucs.spectrum(right)
        let raw = [l.re, l.im, r.re, r.im]
        var spec = l.re + l.im + r.re + r.im
        let s = Demucs.stats(spec)
        let a = Float(1 / (1e-5 + s.std)), b = Float(s.mean)
        for i in 0..<spec.count { spec[i] = (spec[i] - b) * a }
        let mask = try network.run(spec: spec)
        let plane = Demucs.bins * Demucs.frames
        guard mask.count == 4 * stems.count * plane else {
            throw Demucs.NetworkShapeError(spec: mask.count, wave: 0)
        }
        var out: [[[Float]]] = []
        for stem in 0..<stems.count {
            var pair: [[Float]] = []
            for channel in 0..<2 {
                let xr = raw[channel * 2], xi = raw[channel * 2 + 1]
                let mr = (stem * 4 + channel * 2) * plane, mi = mr + plane
                var re = [Float](repeating: 0, count: plane), im = [Float](repeating: 0, count: plane)
                for k in 0..<plane {
                    let ar = mask[mr + k], ai = mask[mi + k]
                    re[k] = ar * xr[k] - ai * xi[k]
                    im[k] = ar * xi[k] + ai * xr[k]
                }
                pair.append(Demucs.inverse(re: re, im: im))
            }
            out.append(pair)
        }
        return out
    }
}
