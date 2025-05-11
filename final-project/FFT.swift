//
//  FFT.swift
//  final-project
//
//  Created by Anna Murphy on 4/17/25.
//

import Accelerate

class RealFFTProcessor {
    private var fftSetup: FFTSetupD?
    private let length: Int
    private let log2n: vDSP_Length

    init(signalLength: Int) {
        self.length = signalLength
        self.log2n = vDSP_Length(log2(Double(signalLength)))

        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup.")
        }
        self.fftSetup = setup
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetupD(setup)
        }
    }

    func computeMagnitude(signal: [Double]) -> [Double] {
        print("Expected length: \(length), actual signal count: \(signal.count)")

        precondition(signal.count == length, "Signal length must match initialized FFT length.")

        var inputCopy = signal
        var magnitudes = [Double](repeating: 0.0, count: length / 2)

        inputCopy.withUnsafeMutableBufferPointer { inputPtr in
            var real = [Double](repeating: 0, count: length / 2)
            var imag = [Double](repeating: 0, count: length / 2)

            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPDoubleSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                    // Convert interleaved real input to split complex
                    inputPtr.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: length / 2) {
                        vDSP_ctozD($0, 2, &splitComplex, 1, vDSP_Length(length / 2))
                    }

                    // Perform FFT
                    guard let setup = fftSetup else { return }
                    vDSP_fft_zripD(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Scale result
                    var scale: Double = 1.0 / Double(length)
                    vDSP_vsmulD(realPtr.baseAddress!, 1, &scale, realPtr.baseAddress!, 1, vDSP_Length(length / 2))
                    vDSP_vsmulD(imagPtr.baseAddress!, 1, &scale, imagPtr.baseAddress!, 1, vDSP_Length(length / 2))

                    // Compute magnitude
                    vDSP_zvabsD(&splitComplex, 1, &magnitudes, 1, vDSP_Length(length / 2))
                }
            }
        }

        return magnitudes
    }

    func computeFFTMagnitudes(rows: [[Double]]) -> [[Double]] {
        return rows.map { computeMagnitude(signal: $0) }
    }
}

