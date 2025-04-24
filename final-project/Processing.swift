//
//  Processing.swift
//  final-project
//
//  Created by Anna Murphy on 4/23/25.
//

import UIKit
import Foundation
import AVFoundation
import Accelerate

extension Recording {
    
    func processCollectedData() -> (tx: [[Float]], rx: [[Float]])? {
        return reshapeChirps()
    }
    
    func reshapeChirps() ->  (tx: [[Float]], rx: [[Float]])? {
        guard !rxSignal.isEmpty && !txSignal.isEmpty else {
            print("No data recorded to process")
            return nil
        }
        
        print("Processing radar data...")
        
        let rx = rxSignal
        let tx = txSignal
        
        let chirpLength = chirpDuration
        
        let numChirpsRecorded = Int(rx.count / (Int(chirpLength * sampleRate)))
        print("Number of chirps recorded: \(numChirpsRecorded)")
        
        // trim audio to a whole number of chirps
        let trimmedLength = Int(Double(numChirpsRecorded) * chirpLength * sampleRate)
        let rxSig = Array(rx.prefix(min(trimmedLength, rx.count)))
        
        // split received signal into individual chirps
        let chirpSampleCount = Int(chirpLength * sampleRate)
        var rxData: [[Float]] = []
        
        for i in 0..<numChirpsRecorded {
            let startIdx = i * chirpSampleCount
            let endIdx = min(startIdx + chirpSampleCount, rxSig.count)
            if endIdx - startIdx == chirpSampleCount {
                rxData.append(Array(rxSig[startIdx..<endIdx]))
            }
        }
        
        // create matching transmitted data
        let txChirp = Array(tx.prefix(min(chirpSampleCount, tx.count)))
        var txData: [[Float]] = []
        
        for _ in 0..<rxData.count {
            txData.append(txChirp)
        }
        
        let timeToDrop = 1.0
        let segmentsToDrop = Int(timeToDrop / chirpLength)
        
        if segmentsToDrop < rxData.count {
            rxData = Array(rxData[segmentsToDrop...])
            txData = Array(txData[segmentsToDrop...])
        }
        
        guard !rxData.isEmpty else {
            print("Not enough data after dropping segments")
            return nil
        }
        return (tx: txData, rx: rxData)
    }
    
    func multiplyFFTs(rxData: [[Double]], txData: [[Double]], sampleRate: Double, lowpassCutoff: Double = 5000) -> [[Double]] {
        guard rxData.count == txData.count && rxData.first?.count == txData.first?.count else {
            fatalError("Input arrays must have the same dimensions")
        }
        
        let rowCount = rxData.count
        let colCount = rxData[0].count
        
        // multiply
        var allMultiplied = [[Double]](repeating: [Double](repeating: 0.0, count: colCount), count: rowCount)
        for i in 0..<rowCount {
            vDSP_vmulD(rxData[i], 1, txData[i], 1, &allMultiplied[i], 1, vDSP_Length(colCount))
        }
        
        // filter
        let filter = ButterworthFilter(cutoff: lowpassCutoff, fs: sampleRate)
        for i in 0..<rowCount {
            allMultiplied[i] = filter.filter(data: allMultiplied[i])
        }
        
        // compute FFT
        let chirpSampleCount = rxData[0].count
        let fftProcessor = RealFFTProcessor(signalLength: chirpSampleCount)
        let allMultipliedFFTs = fftProcessor.computeFFTMagnitudes(rows: allMultiplied)

        return allMultipliedFFTs
    }
    
    func backgroundSubtraction(allMultipliedFfts: [[Double]]) -> [[Double]] {
            var subtracted: [[Double]] = []
            for i in 1..<allMultipliedFfts.count {
                let row = allMultipliedFfts[i]
                let prev = allMultipliedFfts[i-1]
                var diff: [Double] = []
                for j in 0..<row.count {
                    diff.append(row[j] - prev[j])
                }
                subtracted.append(diff)
            }
            return subtracted
        }
    
    func peakFinding(rxData: [[Double]], txData: [[Double]], sampleRate: Double, freqHigh: Double, freqLow: Double, chirpLength: Double, lowpassCutoff: Double = 5000) -> [Double] {
        var shifted = shift(fft: multiplyFFTs(rxData: rxData, txData: txData, sampleRate: sampleRate, lowpassCutoff: lowpassCutoff))
        var subtracted = backgroundSubtraction(allMultipliedFfts: shifted)
        var allPeakLocations = applyArgmax(matrix: shifted)
        var medianPeakLocation = Int(median(array: allPeakLocations))
        let peakWindowSize: Int = 100
        let windowRangeStart = medianPeakLocation - peakWindowSize/2
        let windowRange = [Int](windowRangeStart..<(windowRangeStart + peakWindowSize))
        let windowLength = rxData.first!.count
        let subtractedFiltered = getColumns(matrix: subtracted, columnIndices: windowRange)
        let argmaxes = applyArgmax(matrix: subtractedFiltered)
        let MOVING_AVERAGE_LENGTH = 5
        let MEDIAN_FILTER_LENGTH  = 7
        let medFiltered = medianFilter(array: argmaxes, size: MEDIAN_FILTER_LENGTH)
        let argmaxDistancesMed = medFiltered.map { getDistanceFromPeak(idx: $0, windowRangeStart: windowRangeStart, medianPeakLocation: medianPeakLocation) }
        let argmaxDistances = argmaxDistancesMed.map { indxToDistance(idx: $0, windowLength: windowLength, sampleRate: sampleRate, freqHigh: freqHigh, freqLow: freqLow, chirpLength: chirpLength) }
        let finalDistances = movingAverage(array: argmaxDistances, size: MOVING_AVERAGE_LENGTH)
        return finalDistances
    }

}
