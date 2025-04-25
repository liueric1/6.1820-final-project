//
//  Utilities.swift
//  final-project
//
//  Created by Anna Murphy on 4/23/25.
//

import UIKit
import Foundation
import AVFoundation
import Accelerate

extension Recording {
    
    func shift(fft: [[Double]]) -> [[Double]] {
        print(fft[0][0], fft[1][0])
        print(fft[0][1], fft[1][1])
        print(fft[0][2], fft[1][2])
        let columnCount = fft.first!.count
        let offset = columnCount / 2

        return fft.map { row in
            Array(row[(columnCount - offset)...] + row[..<(columnCount - offset)])
        }
    }
    
    func applyArgmax(matrix: [[Double]]) -> [Int] {
        return matrix.map { row in
            row.indices.max(by: { row[$0] < row[$1] })!
        }
    }
    
    func median(array: [Int]) -> Double {
        let sorted = array.sorted()
        if sorted.count % 2 == 0 {
            return Double((sorted[(sorted.count / 2)] + sorted[(sorted.count / 2) - 1])) / 2
        }
        else {
            return Double(sorted[(sorted.count - 1) / 2])
        }
    }
    
    func getColumns(matrix: [[Double]], columnIndices: [Int]) -> [[Double]] {
        return matrix.map { row in
            return columnIndices.map { idx in
                return row[idx]
            }
        }
    }
    
    func getDistanceFromPeak(idx: Int, windowRangeStart: Int, medianPeakLocation: Int) -> Int {
        return idx + windowRangeStart - medianPeakLocation
    }
    
    func indxToDistance(idx: Int, windowLength: Int, sampleRate: Double, freqHigh: Double, freqLow: Double, chirpLength: Double, columnCount: Int) -> Double {
        let speedSound: Double = 343
        
        let delta_f = Double(idx) *  (sampleRate / Double(columnCount))
        let top: Double = delta_f * speedSound
        let bottom: Double = (2 * ((freqHigh - freqLow) / chirpLength))
        return top / bottom
    }
    
    func medianFilter(array: [Int], size: Int) -> [Int] {
        let pad = size / 2
        let padded = Array(repeating: array.first, count: pad)
            + array
            + Array(repeating: array.last, count: pad)

        let rolled = pad..<(padded.count - pad)
        return rolled.map { i in
            let window = padded[(i - pad)...(i + pad)]
            let sortedWindow = window.compactMap{ $0 }.sorted()
            return sortedWindow[pad]
        }
    }
    
    func movingAverage(array: [Double], size: Int) -> [Double] {
        var result: [Double] = []
        var windowSum = array.prefix(size).reduce(0, +)
        result.append(windowSum / Double(size))

        for i in size..<array.count {
            windowSum += array[i] - array[i - size]
            result.append(windowSum / Double(size))
        }
        return result
    }
}
