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
        recording.viewController = self
    }

    @IBAction func startRecording(_ sender: Any) {
        let recordingDuration = 60.0
        
        recording.reset()
        recording.generateTone(startFrequency: 1000, endFrequency: 23000, chirp_duration: 0.1, total_duration: recordingDuration)
        recording.start()

        Timer.scheduledTimer(withTimeInterval: recordingDuration, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.recording.stop()
                print("Recording automatically stopped after \(recordingDuration) seconds")
            }
    }
}

