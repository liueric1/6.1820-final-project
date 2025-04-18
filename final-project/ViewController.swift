//
//  ViewController.swift
//  final-proj
//
//  Created by Eric Liu on 2/5/25.
//

import UIKit

class ViewController: UIViewController {
    var recording = Recording()
    @IBOutlet weak var heartRate: UILabel!
    @IBOutlet weak var breathingRate: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
    }

    @IBAction func startRecording(_ sender: Any) {
        let recordingDuration = 5.0
        
        recording.reset()
        recording.generateTone(startFrequency: 440, endFrequency: 880, chirp_duration: 0.05, total_duration: 5)
        recording.start()
        
        // TEST FFT & BUTTER FUNCTIONS
//        let fftMagnitudes = recording.testFFTFromJSON()
//        recording.saveFFTResultToDocumentsAndShare(fftMagnitudes, filename: "fft_output.json", presentingViewController: self)
        
        Timer.scheduledTimer(withTimeInterval: recordingDuration, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.recording.stop()
                print("Recording automatically stopped after \(recordingDuration) seconds")
            }
    }
}

