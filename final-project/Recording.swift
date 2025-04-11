//
//  Recording.swift
//  final-proj
//
//  Created by Eric Liu on 4/9/25.
//

import UIKit
import AVFoundation

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
    private var sweepDuration: Double = 0
    private var sweepStartTime: TimeInterval = 0
    
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
    
    func generateTone(startFrequency: Float, endFrequency: Float, duration: Double) {
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.sweepDuration = duration
        self.sweepStartTime = CACurrentMediaTime()
        
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        
        let data = buffer.floatChannelData?[0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            // Calculate the current frequency using linear interpolation
            let currentFrequency = startFrequency + (endFrequency - startFrequency) * Float(time / duration)
            // Calculate the phase using the integral of frequency over time
            let phase = 2.0 * .pi * Double(currentFrequency) * time
            data?[frame] = Float(sin(phase))
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
        print("FMCW tone generated from \(startFrequency)Hz to \(endFrequency)Hz")
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
    
    func stop() {
        stopMonitoring()
        playerNode.stop()
        audioEngine.stop()
        isRecording = false
        print("Audio engine stopped and monitoring ended")
    }
    
    private func startMonitoring() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        
        mixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            // Analyze the incoming audio buffer
            self.analyzeReflectedSound(buffer: buffer, time: time)
        }
    }
    
    private func stopMonitoring() {
        mixerNode.removeTap(onBus: 0)
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
            let sweepPosition = elapsedTime.truncatingRemainder(dividingBy: sweepDuration)
            let expectedFrequency = startFrequency + (endFrequency - startFrequency) * Float(sweepPosition / sweepDuration)
            
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

