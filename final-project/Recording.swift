//
//  Recording.swift
//  final-proj
//
//  Created by Eric Liu on 4/9/25.
//

import UIKit
import Foundation
import AVFoundation
import Accelerate

class Recording: NSObject {
    private var audioEngine: AVAudioEngine!
    private var playerNode: AVAudioPlayerNode!
    private var mixerNode: AVAudioMixerNode!
    private var isRecording = false
    private let sampleRate: Double = 44100.0
    private let channelCount: AVAudioChannelCount = 1
    private var lastPeakTime: TimeInterval = 0
    private var lastPeakAmplitude: Float = 0
    private var startFrequency: Float = 0
    private var endFrequency: Float = 0
    private var chirpDuration: Double = 0
    private var sweepStartTime: TimeInterval = 0
    
    private var txSignal: [Float] = []
    private var rxSignal: [Float] = []
    
    // params for Bandpass filter
    private var freqLow: Float = 100.0
    private var freqHigh: Float = 20000.0
    
    override init() {
        super.init()
        setupAudioSession()
        setupAudioEngine()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    private func setupAudioEngine() {
        self.audioEngine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        self.mixerNode = AVAudioMixerNode()
        
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        
        self.audioEngine.attach(playerNode)
        self.audioEngine.attach(mixerNode)
        
        self.audioEngine.connect(playerNode, to: mixerNode, format: format)
        self.audioEngine.connect(mixerNode, to: audioEngine.mainMixerNode, format: format)
    }
    
    func generateTone(startFrequency: Float, endFrequency: Float, chirp_duration: Double, total_duration: Double) {
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.chirpDuration = chirp_duration
        self.sweepStartTime = CACurrentMediaTime()
        
        let chirpFrameCount = Int(chirp_duration * sampleRate)
        let repeatCount = Int(total_duration / chirp_duration)
        let totalFrameCount = AVAudioFrameCount(chirpFrameCount * repeatCount)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrameCount)!
        buffer.frameLength = totalFrameCount
        
        let data = buffer.floatChannelData?[0]
        
        for repeatIndex in 0..<repeatCount {
            for frame in 0..<chirpFrameCount {
                let globalFrameIndex = repeatIndex * chirpFrameCount + frame
                let time = Double(frame) / sampleRate
                let currentFrequency = startFrequency + (endFrequency - startFrequency) * Float(time / chirp_duration)
                let phase = 2.0 * .pi * Double(currentFrequency) * time
                let sampleValue = Float(sin(phase))
                data?[globalFrameIndex] = sampleValue
                txSignal.append(sampleValue)
            }
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
        print("FMCW tone generated from \(startFrequency)Hz to \(endFrequency)Hz, repeated for \(total_duration)s")
    }

    
    func start() {
        do {
            try audioEngine.start()
            playerNode.play()
            startMonitoring()  // Start monitoring for reflected sound
            isRecording = true
            print("Audio engine started and monitoring begun")
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
        }
    }
    
    func processCollectedData() -> (tx: [[Float]], rx: [[Float]])? {
        return reshapeChirps()
    }
    
    func stop() {
        stopMonitoring()
        playerNode.stop()
        audioEngine.stop()
        isRecording = false
        print("Audio engine stopped and monitoring ended")
        
        if let processedData = processCollectedData() {
            print("Processing complete. Received \(processedData.rx.count) chirps")
            let newTx = processedData.tx.map{ row in
                row.map{ Double($0) }
            }
            let newRx = processedData.rx.map{ row in
                row.map{ Double($0) }
            }
            let distances = peakFinding(rxData: newRx, txData: newTx, sampleRate: self.sampleRate, freqHigh: Double(self.freqHigh), freqLow: Double(self.freqLow), chirpLength: self.chirpDuration)
            print(distances)
        } else {
            print("Failed to process data")
        }
    }
    
    func reset() {
        txSignal = []
        rxSignal = []
        isRecording = false
    }
    
    private func startMonitoring() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        
        mixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            // Analyze the incoming audio buffer
            self.analyzeReflectedSound(buffer: buffer, time: time)
            self.storeReceivedAudio(buffer: buffer)
        }
    }
    
    private func stopMonitoring() {
        mixerNode.removeTap(onBus: 0)
    }
    
    private func storeReceivedAudio(buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            
            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            rxSignal.append(contentsOf: newSamples)
        }
    
    //******************** SIGNAL PROCESSING ********************//

    private func reshapeChirps() ->  (tx: [[Float]], rx: [[Float]])? {
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
    
    // FOR TESTING
    //        let sample_tx = rxData[0]
    //        let sample_rx = txData[0]
    //        print("sample_tx: \(sample_tx)")
    //        print("sample_rx: \(sample_rx)")
        
        return (tx: txData, rx: rxData)
    }
    
    func loadJSONChirp(from filename: String) -> [Float]? {
        guard let path = Bundle.main.path(forResource: filename, ofType: "json") else {
            print("File not found: \(filename).json")
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            let array = try decoder.decode([Float].self, from: data)
            return array
        } catch {
            print("Error loading or decoding JSON: \(error)")
            return nil
        }
    }

    
    /// Process signal data by multiplying, filtering, and computing FFT
    /// - Parameters:
    ///   - rxData: Receive data array
    ///   - txData: Transmit data array
    ///   - sampleRate: Sampling frequency in Hz
    ///   - lowpassCutoff: Cutoff frequency for low-pass filter in Hz (default is 5000)
    /// - Returns: Magnitude of FFT of filtered, multiplied data
    func multiplyFFTs(rxData: [[Double]], txData: [[Double]], sampleRate: Double, lowpassCutoff: Double = 5000) -> [[Double]] {
        guard rxData.count == txData.count && rxData.first?.count == txData.first?.count else {
            fatalError("Input arrays must have the same dimensions")
        }
        
        let rowCount = rxData.count
        let colCount = rxData[0].count
        
        // multiply
        var allMultiplied = [[Double]](repeating: [Double](repeating: 0.0, count: colCount), count: rowCount)
        for i in 0..<rowCount {
//            here
            vDSP_vmulD(rxData[i], 1, txData[i], 1, &allMultiplied[i][0], 1, vDSP_Length(colCount))
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
    
    func indxToDistance(idx: Int, windowLength: Int, sampleRate: Double, freqHigh: Double, freqLow: Double, chirpLength: Double) -> Double {
        let speedSound: Double = 343
        let top: Double = ((Double(idx) *  Double(windowLength) / sampleRate) * speedSound)
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
    
//    func testFFTFromJSON() -> [[Double]]{
//        guard let tx = loadJSONChirp(from: "tx"),
//              let rx = loadJSONChirp(from: "rx") else {
//            print("Failed to load test data from JSON.")
//            return [[]]
//        }
//
//        // Ensure equal length
//        let chirpLength = min(tx.count, rx.count)
//        let txTrimmed = Array(tx.prefix(chirpLength))
//        let rxTrimmed = Array(rx.prefix(chirpLength))
//
//        // Wrap in 2D array so it matches expected input [[Double]]
//        let tx2D: [[Double]] = [txTrimmed.map(Double.init)]
//        let rx2D: [[Double]] = [rxTrimmed.map(Double.init)]
//
//        let fftMagnitudes = multiplyFFTs(rxData: rx2D, txData: tx2D, sampleRate: sampleRate)
//        print("✅ FFT Test Complete — Output Magnitudes:")
//        return fftMagnitudes
//    }
    
//    func saveFFTResultToDocumentsAndShare(_ result: [[Double]], filename: String, presentingViewController: UIViewController) {
//        let encoder = JSONEncoder()
//        encoder.outputFormatting = [.prettyPrinted]
//
//        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
//        let fileURL = documentsURL.appendingPathComponent(filename)
//
//        do {
//            let data = try encoder.encode(result)
//            try data.write(to: fileURL)
//            print("📦 Saved to: \(fileURL.path)")
//
//            // Present share sheet for AirDrop/email/etc.
//            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
//            presentingViewController.present(activityVC, animated: true, completion: nil)
//
//        } catch {
//            print("❌ Failed to save or share FFT output: \(error)")
//        }
//    }

    private func analyzeReflectedSound(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Calculate maximum amplitude
        var maxAmplitude: Float = 0
        for i in 0..<frameLength {
            maxAmplitude = max(maxAmplitude, abs(channelData[i]))
        }
        
        // Only analyze if we detect a clear signal
        if maxAmplitude > 0.01 {
            // Calculate the expected frequency at this time in the sweep
            let elapsedTime = CACurrentMediaTime() - sweepStartTime
            let sweepPosition = elapsedTime.truncatingRemainder(dividingBy: chirpDuration)
            let expectedFrequency = startFrequency + (endFrequency - startFrequency) * Float(sweepPosition / chirpDuration)
            
            // Use autocorrelation to detect frequency
            var sum: Float = 0
            let maxLag = Int(sampleRate / Double(startFrequency)) // Maximum lag based on lowest frequency
            let minLag = Int(sampleRate / Double(endFrequency))   // Minimum lag based on highest frequency
            
            // Calculate autocorrelation for a range of lags
            for lag in minLag...maxLag {
                var correlation: Float = 0
                for i in 0..<(frameLength - lag) {
                    correlation += channelData[i] * channelData[i + lag]
                }
                sum = max(sum, correlation)
            }
            
            // Find the lag that gives maximum correlation
            var maxCorrelation: Float = 0
            var bestLag = 0
            for lag in minLag...maxLag {
                var correlation: Float = 0
                for i in 0..<(frameLength - lag) {
                    correlation += channelData[i] * channelData[i + lag]
                }
                if correlation > maxCorrelation {
                    maxCorrelation = correlation
                    bestLag = lag
                }
            }
            
            // Calculate frequency from the best lag
            let detectedFrequency = Float(sampleRate) / Float(bestLag)
            
            // Only report if the detected frequency is within a reasonable range of the expected frequency
            let frequencyDiff = abs(detectedFrequency - expectedFrequency)
            if frequencyDiff < 100 { // Allow for some measurement error
                print("\nExpected frequency: \(String(format: "%.1f", expectedFrequency)) Hz")
                print("Detected frequency: \(String(format: "%.1f", detectedFrequency)) Hz")
                print("Amplitude: \(String(format: "%.3f", maxAmplitude))")
            }
        }
    }
}

