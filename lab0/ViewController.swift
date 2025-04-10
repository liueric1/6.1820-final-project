//  lab0
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
        recording.generateTone(frequency: 440, duration: 1.0)
        recording.start()
    }
    
    @IBAction func stopRecording(_ sender: Any) {
        recording.stop()
    }
    
}

