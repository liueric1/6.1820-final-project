//
//  Recording.swift
//  final-proj
//
//  Created by Eric Liu on 4/9/25.
//

import UIKit
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
        
        // Trim audio to a whole number of chirps
        let trimmedLength = Int(Double(numChirpsRecorded) * chirpLength * sampleRate)
        let rxSig = Array(rx.prefix(min(trimmedLength, rx.count)))
        
        // Split received signal into individual chirps
        let chirpSampleCount = Int(chirpLength * sampleRate)
        var rxData: [[Float]] = []
        
        for i in 0..<numChirpsRecorded {
            let startIdx = i * chirpSampleCount
            let endIdx = min(startIdx + chirpSampleCount, rxSig.count)
            if endIdx - startIdx == chirpSampleCount {
                rxData.append(Array(rxSig[startIdx..<endIdx]))
            }
        }
        
        // Create matching transmitted data
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
    
        let sample_tx = rxData[0]
        let sample_rx = txData[0]
        print("sample_tx: \(sample_tx)")
        print("sample_rx: \(sample_rx)")
    
        return (tx: txData, rx: rxData)
    }
    
    
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

