import matplotlib.pyplot as plt
from IPython.display import HTML, Audio
from base64 import b64decode
import numpy as np
import statistics

import json
import time

import struct
import io
import ffmpeg
import sounddevice as sd

from scipy.io import wavfile
from scipy.io.wavfile import read as wav_read
from scipy import signal, stats
from scipy.signal import chirp, detrend, detrend, butter, filtfilt, find_peaks, savgol_filter

from flask import Flask, request, jsonify
import numpy as np
import json

def background_subtract(all_multiplied_ffts):
    after_subtraction = []
    for i in range(30, len(all_multiplied_ffts)):
        after_subtraction.append(all_multiplied_ffts[i] - all_multiplied_ffts[i-30])
    return np.array(after_subtraction)

def moving_average(x, w):
    return np.convolve(x, np.ones(w)/w, mode='same')

def get_largest_n_mean(array, n):
    return np.mean(np.argpartition(array, -n)[-n:])

def butter_lowpass(cutoff, fs, order=5):
    nyq = 0.5 * fs
    normalCutoff = cutoff / nyq
    b, a = signal.butter(order, normalCutoff, btype='low')
    return b, a

def butter_lowpass_filter(data, cutoff, fs, order=5):
    b, a = butter_lowpass(cutoff, fs, order=order)
    y = signal.lfilter(b, a, data)
    return y

def butter_bandpass(lowcut, highcut, fs, order=5):
    nyq = 0.5 * fs
    low = lowcut / nyq
    high = highcut / nyq
    b, a = signal.butter(order, [low, high], btype='band')
    return b, a

def butter_bandpass_filter(data, lowcut, highcut, fs, order=5):
    b, a = butter_bandpass(lowcut, highcut, fs, order=order)
    y = signal.lfilter(b, a, data)
    return y

def highpass(data, cutoff, fs, order=4):
    nyq = 0.5 * fs
    norm_cutoff = cutoff / nyq
    b, a = butter(order, norm_cutoff, btype='high')
    return filtfilt(b, a, data)

# HR range (0.67–3.33 Hz = 40–200 BPM)
def bandpass(data, lowcut, highcut, fs, order=10):
    nyq = 0.5 * fs
    low = lowcut / nyq
    high = highcut / nyq
    b, a = butter(order, [low, high], btype='band')
    return filtfilt(b, a, data)

sample_rate = 48000
freq_low = 1000        # start of chirp (Hz)
freq_high = 23000       # end of chirp (Hz)
chirp_length = 0.1      # duration of each chirp in seconds
total_duration = 60     # total recording time in seconds


def preprocess(tx, rx):
    tx_sig = tx
    rx_sig = rx[:,0]

    num_chirps_recorded = int(rx_sig.shape[0] // (chirp_length * sample_rate))

    if num_chirps_recorded == 0:
        raise ValueError("No chirps recorded. num_chirps_recorded is zero.")

    # trim audio to a whole number of chirps recorded
    rx_sig = rx_sig[:int(num_chirps_recorded * chirp_length * sample_rate)]

    rx_data = np.array(np.split(rx_sig, num_chirps_recorded))
    tx_data = np.tile(tx_sig[0:int(chirp_length*sample_rate)], (num_chirps_recorded, 1))

    time_to_drop = 1
    segments_to_drop = int(time_to_drop/chirp_length)
    rx_data = rx_data[segments_to_drop:]
    tx_data = tx_data[segments_to_drop:]

    return tx_data, rx_data

def filter_hr(tx_data, rx_data):
    # --- FMCW ---
    window_length = rx_data.shape[1]
    chirp_length = 0.1 
    dechirped = rx_data * np.conj(tx_data)
    fft_size = window_length*4
    fft_data = np.fft.fft(dechirped, n=fft_size, axis=1)

    subtracted = background_subtract(np.fft.fftshift(fft_data, axes=(1,))) # remove signal from stationary objects
    all_peak_locations = np.apply_along_axis(np.argmax, 1, np.fft.fftshift(fft_data, axes=(1,))) # for every chirp, find max fft
    median_peak_location = int(np.median(all_peak_locations)) # find median bin

    # define window around median peak
    peak_window_size     = 100
    window_range_start   = median_peak_location - peak_window_size/2
    window_range         = np.arange(window_range_start,
                            window_range_start + peak_window_size,
                            dtype=np.int32)

    freqs               = np.multiply(np.fft.rfftfreq(window_length), sample_rate) # calculate freq bins
    subtracted_filtered = subtracted[:, window_range] # extract windowed region
    argmaxes = np.apply_along_axis(np.argmax, 1, subtracted_filtered) # find peak location for each chirp
    MEDIAN_FILTER_LENGTH  = 7
    med_filtered = signal.medfilt(argmaxes, MEDIAN_FILTER_LENGTH) # smooth peak locations

    # bin_to_track = np.argmax(np.mean(np.abs(fft_data), axis=0))
    bin_to_track = int(np.median(med_filtered))
    phases = np.angle(fft_data[:, bin_to_track])

    unwrapped_phases = np.unwrap(phases)
    detrended_phase = detrend(unwrapped_phases)

    times = np.arange(unwrapped_phases.shape[0]) * chirp_length

    fs = 1 / chirp_length
    hr_filtered = bandpass(detrended_phase, 45 / 60, 200 / 60, fs)

    return hr_filtered

def get_bpm(hr_filtered):
    hr_fft = np.fft.rfft(hr_filtered)
    hr_freqs = np.fft.rfftfreq(len(hr_filtered), d=chirp_length)
    hr_bpm_freqs = hr_freqs * 60
    mask = (hr_bpm_freqs >= 40) & (hr_bpm_freqs <= 200)
    hr_bpm_freqs = hr_bpm_freqs[mask]
    hr_fft_mag = np.abs(hr_fft)[mask]

    if len(hr_fft_mag) > 5:
        min_bpm = 40  # min expected heart rate
        min_idx = np.argmin(np.abs(hr_bpm_freqs - min_bpm))
        peak_idx = np.argmax(hr_fft_mag[min_idx:]) + min_idx
    else:
        peak_idx = np.argmax(hr_fft_mag)

    bpm_from_fft = hr_bpm_freqs[peak_idx]
    return bpm_from_fft

app = Flask(__name__)

@app.route('/estimate_bpm', methods=['POST'])
def estimate_bpm():
    tx = np.array(request.json['tx'])
    rx = np.array(request.json['rx'])

    print("SHAPES BEFORE", tx.shape, rx.shape)

    if rx.shape[0] < tx.shape[0]:
        extra = tx.shape[0] - rx.shape[0]
        tx = tx[:-extra]

    rx = rx.reshape(-1, 1)
    print("SHAPES AFTER", tx.shape, rx.shape)

    tx_data, rx_data = preprocess(tx, rx)
    hr_filtered = filter_hr(tx_data, rx_data)
    bpm = get_bpm(hr_filtered)

    print("Estimated BPM:", bpm)
    return jsonify({'bpm': bpm})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001)