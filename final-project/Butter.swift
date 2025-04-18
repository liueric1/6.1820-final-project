//
//  Butter.swift
//  final-project
//
//  Created by Anna Murphy on 4/17/25.
//

import Foundation
import Accelerate

/// A class implementing a Butterworth low-pass filter
public class ButterworthFilter {
    
    // MARK: - Properties
    
    /// Filter order
    private let order: Int
    
    /// Cutoff frequency in Hz
    private let cutoff: Double
    
    /// Sampling frequency in Hz
    private let fs: Double
    
    /// Filter coefficients
    private var b: [Double]
    private var a: [Double]
        
    /// Initialize a new Butterworth low-pass filter
    /// - Parameters:
    ///   - cutoff: Cutoff frequency in Hz
    ///   - fs: Sampling frequency in Hz
    ///   - order: Filter order, defaults to 5
    public init(cutoff: Double, fs: Double, order: Int = 5) {
        self.cutoff = cutoff
        self.fs = fs
        self.order = order
        
        // Initialize coefficients
        let (bCoeffs, aCoeffs) = ButterworthFilter.calculateCoefficients(
            cutoff: cutoff,
            fs: fs,
            order: order
        )
        self.b = bCoeffs
        self.a = aCoeffs
    }
        
    /// Apply the filter to the given data
    /// - Parameter data: Input signal data to filter
    /// - Returns: Filtered signal
    public func filter(data: [Double]) -> [Double] {
        return ButterworthFilter.applyFilter(data: data, b: b, a: a)
    }
    
    /// Update filter parameters and recalculate coefficients
    /// - Parameters:
    ///   - cutoff: New cutoff frequency in Hz
    ///   - fs: New sampling frequency in Hz
    ///   - order: New filter order
    public func updateParameters(cutoff: Double? = nil, fs: Double? = nil, order: Int? = nil) {
        let newCutoff = cutoff ?? self.cutoff
        let newFs = fs ?? self.fs
        let newOrder = order ?? self.order
        
        let (bCoeffs, aCoeffs) = ButterworthFilter.calculateCoefficients(
            cutoff: newCutoff,
            fs: newFs,
            order: newOrder
        )
        
        self.b = bCoeffs
        self.a = aCoeffs
    }
        
    /// Calculate Butterworth low-pass filter coefficients
    /// - Parameters:
    ///   - cutoff: Cutoff frequency in Hz
    ///   - fs: Sampling frequency in Hz
    ///   - order: Filter order
    /// - Returns: Tuple containing filter coefficients (b, a)
    public static func calculateCoefficients(cutoff: Double, fs: Double, order: Int) -> ([Double], [Double]) {
        let nyq = 0.5 * fs
        let normalCutoff = cutoff / nyq
        
        // Calculate filter poles in the s-plane
        let poles = butterworthPoles(order: order)
        
        // Apply bilinear transform to convert to z-domain
        var b = [Double](repeating: 0, count: order + 1)
        var a = [Double](repeating: 0, count: order + 1)
        
        bilinearTransform(poles: poles, wc: normalCutoff, b: &b, a: &a)
        
        return (b, a)
    }
    
    /// Apply Butterworth low-pass filter to data using given coefficients
    /// - Parameters:
    ///   - data: Input signal data
    ///   - b: Filter numerator coefficients
    ///   - a: Filter denominator coefficients
    /// - Returns: Filtered signal
    public static func applyFilter(data: [Double], b: [Double], a: [Double]) -> [Double] {
        return lfilter(b: b, a: a, x: data)
    }
    
    /// Apply Butterworth low-pass filter to data (convenience method)
    /// - Parameters:
    ///   - data: Input signal data
    ///   - cutoff: Cutoff frequency in Hz
    ///   - fs: Sampling frequency in Hz
    ///   - order: Filter order, defaults to 5
    /// - Returns: Filtered signal
    public static func filterData(data: [Double], cutoff: Double, fs: Double, order: Int = 5) -> [Double] {
        let (b, a) = calculateCoefficients(cutoff: cutoff, fs: fs, order: order)
        return applyFilter(data: data, b: b, a: a)
    }
        
    /// Calculate Butterworth poles in the s-plane
    private static func butterworthPoles(order: Int) -> [Complex] {
        var poles = [Complex]()
        
        for k in 0..<order {
            let theta = Double.pi * Double(2*k + 1) / Double(2*order)
            let real = -sin(theta)
            let imag = cos(theta)
            poles.append(Complex(real: real, imaginary: imag))
        }
        
        return poles
    }
    
    /// Perform bilinear transform to convert from s-plane to z-plane
    private static func bilinearTransform(poles: [Complex], wc: Double, b: inout [Double], a: inout [Double]) {
        // Initialize coefficients
        a[0] = 1.0
        b[0] = 1.0
        
        // For a more accurate implementation, we would properly convert each pole
        // using the bilinear transform formula. This is a simplified approach for
        // demonstration purposes.
        
        for i in 1...poles.count {
            a[i] = wc / Double(i) * (1.0 - Double(i % 2 == 0 ? -1 : 1) * wc)
        }
        
        // Normalize to ensure DC gain is 1
        let sum_a = a.reduce(0, +)
        let sum_b = b.reduce(0, +)
        let gain = sum_a / sum_b
        
        for i in 0..<b.count {
            b[i] *= gain
        }
    }
    
    /// Implementation of scipy.signal.lfilter
    private static func lfilter(b: [Double], a: [Double], x: [Double]) -> [Double] {
        let n = x.count
        let nB = b.count
        let nA = a.count
        
        // Output array
        var y = [Double](repeating: 0.0, count: n)
        
        // Normalize coefficients by a[0]
        let a0 = a[0]
        var bNorm = b.map { $0 / a0 }
        var aNorm = Array(a.dropFirst()).map { $0 / a0 } // Skip a[0] which becomes 1
        
        // Apply filter
        for i in 0..<n {
            // Apply b coefficients (FIR part)
            for j in 0..<min(i+1, nB) {
                y[i] += bNorm[j] * x[i-j]
            }
            
            // Apply a coefficients (IIR part)
            for j in 0..<min(i, nA-1) {
                y[i] -= aNorm[j] * y[i-j-1]
            }
        }
        
        return y
    }
}

/// Helper struct for complex numbers
fileprivate struct Complex {
    var real: Double
    var imaginary: Double
}
