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
    
    func generateTone(frequency: Float, duration: Double) {
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        
        let data = buffer.floatChannelData?[0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            data?[frame] = Float(sin(2.0 * .pi * Double(frequency) * time))
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
        print("Tone generated")
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
        
        // Perform FFT to get frequency components
        var maxMagnitude: Float = 0
        var dominantFrequency: Float = 0
        
        // Simple frequency detection using zero crossings
        var zeroCrossings = 0
        for i in 1..<frameLength {
            if (channelData[i-1] < 0 && channelData[i] >= 0) || 
               (channelData[i-1] >= 0 && channelData[i] < 0) {
                zeroCrossings += 1
            }
        }
        
        // Calculate frequency from zero crossings
        let duration = Float(frameLength) / Float(sampleRate)
        let frequency = Float(zeroCrossings) / (2 * duration)
        
        // Calculate maximum amplitude
        var maxAmplitude: Float = 0
        for i in 0..<frameLength {
            maxAmplitude = max(maxAmplitude, abs(channelData[i]))
        }
        
        // Only report if we detect a clear signal
        if maxAmplitude > 0.01 {
            print("\nDetected frequency: \(String(format: "%.1f", frequency)) Hz")
            print("Amplitude: \(String(format: "%.3f", maxAmplitude))")
        }
    }
}

