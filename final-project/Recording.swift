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
    weak var viewController: UIViewController?

     var audioEngine: AVAudioEngine!
     var playerNode: AVAudioPlayerNode!
     var mixerNode: AVAudioMixerNode!
     var isRecording = false
     let sampleRate: Double = 48000
     let channelCount: AVAudioChannelCount = 1
     var lastPeakTime: TimeInterval = 0
     var lastPeakAmplitude: Float = 0
     var startFrequency: Float = 0
     var endFrequency: Float = 0
     var chirpDuration: Double = 0
     var sweepStartTime: TimeInterval = 0
    
     var txSignal: [Float] = []
     var rxSignal: [Float] = []
    
    // params for Bandpass filter
     var freqLow: Float = 100.0
     var freqHigh: Float = 20000.0
    
    override init() {
        super.init()
        setupAudioSession()
        setupAudioEngine()
    }
    
     func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
     func setupAudioEngine() {
        self.audioEngine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        self.mixerNode = AVAudioMixerNode()
        
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
         
        let inputNode = audioEngine.inputNode
             
        self.audioEngine.attach(playerNode)
        self.audioEngine.attach(mixerNode)
         
        self.audioEngine.connect(inputNode, to: mixerNode, format: format)
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
            startMonitoring()
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
                
        if let processedData = processCollectedData() {
                print("Processing complete. Received \(processedData.rx.count) chirps")
                let newTx = processedData.tx.map{ row in
                    row.map{ Double($0) }
                }
                let newRx = processedData.rx.map{ row in
                    row.map{ Double($0) }
                }
                
                let multiplied_ffts = self.multiplyFFTs(rxData: newRx, txData: newTx, sampleRate: sampleRate)
                
                // *** Save multiplied ffts for testing *** //
                if let vc = self.viewController {
                    self.saveFFTResultToDocumentsAndShare(multiplied_ffts, filename: "multiplied_ffts.json", presentingViewController: vc)
                } else {
                    print("Error: No view controller reference available")
                }
            
            } else {
                print("Failed to process data")
            }
    }
    
    func reset() {
        txSignal = []
        rxSignal = []
        isRecording = false
    }
    
     func startMonitoring() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        
        // buffer size = chirp duration * sample rate
        mixerNode.installTap(onBus: 0, bufferSize: 2400, format: format)
         { buffer, time in
            self.analyzeReflectedSound(buffer: buffer, time: time)
            self.storeReceivedAudio(buffer: buffer)
        }
    }
    
     func stopMonitoring() {
        mixerNode.removeTap(onBus: 0)
    }
    
     func storeReceivedAudio(buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
         
            rxSignal.append(contentsOf: newSamples)
        }
    
     func analyzeReflectedSound(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
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
            print("\nExpected frequency: \(String(format: "%.1f", expectedFrequency)) Hz")
            print("Detected frequency: \(String(format: "%.1f", detectedFrequency)) Hz")
            print("Amplitude: \(String(format: "%.3f", maxAmplitude))")
            
        }
    }
}

