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
        //        let filter = ButterworthFilter(cutoff: lowpassCutoff, fs: sampleRate)
        //        for i in 0..<rowCount {
        //            allMultiplied[i] = filter.filter(data: allMultiplied[i])
        //        }
        
        // compute FFT
        let chirpSampleCount = rxData[0].count
        let fftProcessor = RealFFTProcessor(signalLength: chirpSampleCount)
        let validSignals = allMultiplied.filter { $0.count == 4800 }
        let allMultipliedFFTs = fftProcessor.computeFFTMagnitudes(rows: validSignals)
        
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
    
    func HR_analysis(rxData: [[Double]], txData: [[Double]], sampleRate: Double, freqHigh: Double, freqLow: Double, chirpLength: Double, lowpassCutoff: Double = 5000) -> Int {
        let shifted = shift(fft: multiplyFFTs(rxData: rxData, txData: txData, sampleRate: sampleRate, lowpassCutoff: lowpassCutoff))
        let subtracted = backgroundSubtraction(allMultipliedFfts: shifted)
        let allPeakLocations = applyArgmax(matrix: shifted)
        let medianPeakLocation = Int(median(array: allPeakLocations))
        let peakWindowSize = 100
        let windowLength = rxData.first!.count

        let windowRangeStart = max(0, medianPeakLocation - peakWindowSize / 2)
        let windowRangeEnd = min(windowRangeStart + peakWindowSize, windowLength)
        let windowRange = [Int](windowRangeStart..<windowRangeEnd)
        let subtractedFiltered = getColumns(matrix: subtracted, columnIndices: windowRange)
        
        let argmaxes = applyArgmax(matrix: subtractedFiltered)
        let MOVING_AVERAGE_LENGTH = 5
        let MEDIAN_FILTER_LENGTH  = 7
        let medFiltered = medianFilter(array: argmaxes, size: MEDIAN_FILTER_LENGTH)
        let bin_to_track = Int(median(array: medFiltered))
        
        let phases = calculatePhasesWithRealFFT(fftData: shifted, binToTrack: bin_to_track)
        let unwrappedPhases = unwrapPhases(phases)
        let detrendedPhase = [detrend(unwrappedPhases)]
                
        let fs = 1 / chirpLength
        
        let chirpSampleCount = detrendedPhase[0].count
        let fftProcessor = RealFFTProcessor(signalLength: chirpSampleCount)
        let hrFFT = fftProcessor.computeFFTMagnitudes(rows: detrendedPhase)
        
        // Compute frequencies (same for each row)
        let hrFreqs = fftFrequencies(length: hrFFT[0].count, sampleRate: fs)
        let hrBpmFreqs = hrFreqs.map { $0 * 60 }
        
        // Create a mask for BPM range [40, 200]
        let maskIndices = hrBpmFreqs.enumerated()
            .filter { $0.element >= 40 && $0.element <= 200 }
            .map { $0.offset }
        
        let maskedHrFFT: [[Double]] = hrFFT.map { row in
            maskIndices.map { idx in Foundation.fabs(row[idx]) }
        }
        
        let averagedHrFFTMag: [Double] = (0..<maskIndices.count).map { i in
            maskedHrFFT.map { $0[i] }.reduce(0, +) / Double(maskedHrFFT.count)
        }
        
        let maskedHrBpmFreqs = maskIndices.map { hrBpmFreqs[$0] }
        
        var peakIdx = 0
        if averagedHrFFTMag.count > 5 {
            let minBpm = 40
            let minIdx = maskedHrBpmFreqs.enumerated()
                .min(by: { abs($0.element - Double(minBpm)) < abs($1.element - Double(minBpm)) })?.offset ?? 0
            peakIdx = averagedHrFFTMag[minIdx...].enumerated()
                .max(by: { $0.element < $1.element })?.offset ?? 0 + minIdx
        } else {
            peakIdx = averagedHrFFTMag.enumerated()
                .max(by: { $0.element < $1.element })?.offset ?? 0
        }
        
        return Int(maskedHrBpmFreqs[peakIdx])
    }
}
