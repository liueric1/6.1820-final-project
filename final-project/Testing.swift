//
//  Testing.swift
//  final-project
//
//  Created by Anna Murphy on 4/23/25.
//

import UIKit
import Foundation
import AVFoundation
import Accelerate

extension Recording {
    
    func loadMultiChirpJSON(from filename: String) -> [[Float]]? {
        guard let path = Bundle.main.path(forResource: filename, ofType: "json") else {
            print("File not found: \(filename).json")
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            let array = try decoder.decode([[Float]].self, from: data)
            return array
        } catch {
            print("Error loading or decoding multi-chirp JSON: \(error)")
            return nil
        }
    }
    
    func testFFTsFromMultiChirpJSON(txFilename: String, rxFilename: String) -> [[Double]] {
        guard let txChirps = loadMultiChirpJSON(from: txFilename),
              let rxChirps = loadMultiChirpJSON(from: rxFilename),
              txChirps.count == rxChirps.count else {
            print("Failed to load or match chirp data count.")
            return []
        }

        let txData: [[Double]] = txChirps.map { $0.map(Double.init) }
        let rxData: [[Double]] = rxChirps.map { $0.map(Double.init) }

        let fftMagnitudes = multiplyFFTs(rxData: rxData, txData: txData, sampleRate: sampleRate)
        
        print("FFTs computed for \(fftMagnitudes.count) chirps.")
        return fftMagnitudes
    }
    
    func saveFFTResultToDocumentsAndShare(_ result: [[Double]], filename: String, presentingViewController: UIViewController) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent(filename)

        do {
            let data = try encoder.encode(result)
            try data.write(to: fileURL)
            print("Saved to: \(fileURL.path)")

            // Present share sheet for AirDrop/email/etc.
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            presentingViewController.present(activityVC, animated: true, completion: nil)

        } catch {
            print("Failed to save or share FFT output: \(error)")
        }
    }

}
