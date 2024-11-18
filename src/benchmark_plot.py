"""
This script automates the process of running bandwidth tests using iperf3 in a Linux network 
namespace environment. It performs two tests: one in a namespace simulating a MACsec (encrypted)
connection and another simulating a plain (unencrypted) connection. The script then plots the 
bandwidth results for comparison.

**How it works:**
1. Starts an iperf3 server in a specified network namespace.
2. Runs an iperf3 client to connect to the server from another namespace for a specified duration.
3. Parses the JSON output from iperf3 to extract timestamps and bandwidth data.
4. Plots the results with timestamps on the x-axis and bandwidth (logarithmic scale) on the y-axis.

**Where to configure:**
- In the `main` function, update the following fields as per your setup:
    - `server_macsec`: The IP address of the MACsec server namespace.
    - `server_plain`: The IP address of the plain server namespace.
    - `namespace_macsec`: The namespace name running the iperf3 client for the MACsec test.
    - `namespace_plain`: The namespace name running the iperf3 client for the plain test.
    
**Dependencies:**
- Linux with `iperf3` installed and configured in the namespaces.
- Python libraries: `subprocess`, `time`, `json`, `matplotlib`, `numpy`, `tqdm`.

**Usage:**
Run the script, enter the duration when prompted, and ensure the namespaces and servers are 
properly configured and running. You can use the pdf, located in the doc folder of the repo,
as reference for setting up the same LAN or WAN environment without MACsec. 

Note: If you plan to run the repository's scripts for setting up MACsec, then specify different
names for the new namespaces or bridges and skip the steps regarding the MACsec configuration 
(wpa_supplicant in case of LAN environment). 
You are free to use your own implementation of MACsec/unencrypted as long as you follow the
requirements described above.
"""

import subprocess
import time
import json
import matplotlib.pyplot as plt
import numpy as np  
from matplotlib.ticker import FuncFormatter
from tqdm import tqdm

def run_iperf(server_ip, duration=10, namespace='ns1'):
    cmd = ['ip', 'netns', 'exec', namespace, 'iperf3', '-c', server_ip, '-t', str(duration), '-i', '1', '--json']
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return process

def start_iperf_s(namespace='ns2'):
    cmd = ['ip', 'netns', 'exec', namespace, 'iperf3', '-s']
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return process

def parse_iperf_output(process):
    output_lines = []
    for line in process.stdout:
        output_lines.append(line.decode('utf-8').strip())
    
    # Join all lines together to form the full output
    output = '\n'.join(output_lines)

    try:
        data = json.loads(output)
        timestamps = []
        bandwidths = []

        # Extract bandwidth data from the sum field of the intervals
        for idx, interval in enumerate(data.get("intervals", [])):
            sum_data = interval.get("sum", {})
            if "bits_per_second" in sum_data:
                # Bandwidth in Gbit/s
                bandwidth = sum_data["bits_per_second"] / 1e9
                bandwidths.append(bandwidth)
                timestamps.append(idx + 1)        
        return timestamps, bandwidths
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}")
        return [], []

def plot_bandwidth(timestamps1, bandwidths1, timestamps2, bandwidths2):
    # Calculate the min, max, and average for each dataset
    min_bandwidth1 = min(bandwidths1)
    max_bandwidth1 = max(bandwidths1)
    avg_bandwidth1 = np.mean(bandwidths1)

    min_bandwidth2 = min(bandwidths2)
    max_bandwidth2 = max(bandwidths2)
    avg_bandwidth2 = np.mean(bandwidths2)

    # Define the min and max values based on both datasets
    min_bandwidth = min(min_bandwidth1, min_bandwidth2)
    max_bandwidth = max(max_bandwidth1, max_bandwidth2)

    # Ensure that the minimum bandwidth value for log scale is greater than 0
    min_bandwidth = max(min_bandwidth * 0.8, 0.01)
    max_bandwidth = max_bandwidth * 1.2

    plt.figure(figsize=(10, 6))

    # Plot the bandwidth data
    plt.plot(timestamps1, bandwidths1, label=f'MACsec\nAvg: {avg_bandwidth1:.2f} Gbit/s', color='red')
    plt.plot(timestamps2, bandwidths2, label=f'Plain\nAvg: {avg_bandwidth2:.2f} Gbit/s', color='blue')

    plt.xlabel('Time (seconds)')
    plt.ylabel('Bandwidth (Gbit/s)')
    plt.title('Link Bandwidth Over Time (Logarithmic Scale)')
    plt.yscale('log')
    
    # Adjusting y-limits to zoom in more closely on the data
    plt.ylim(min_bandwidth, max_bandwidth)

    plt.grid(True, which="both", linestyle='--', linewidth=0.5)

    # Generate y-ticks with more granularity around the measured bandwidths
    y_ticks = np.logspace(np.log10(min_bandwidth), np.log10(max_bandwidth), num=7)
    plt.yticks(y_ticks)

    # Use a custom formatter to display bandwidths in Gbit/s with more precision
    def format_ticks(x, pos):
        return f'{x:.2f} Gbit/s'

    plt.gca().yaxis.set_major_formatter(FuncFormatter(format_ticks))


    plt.axhline(y=max_bandwidth1, color='red', linestyle=':', label=f'Max Bandwidth (MACsec) {max_bandwidth1:.2f} Gbit/s', alpha=0.5)
    plt.axhline(y=min_bandwidth1, color='red', linestyle='--', label=f'Min Bandwidth (MACsec) {min_bandwidth1:.2f} Gbit/s', alpha=0.5)

    plt.axhline(y=max_bandwidth2, color='blue', linestyle=':', label=f'Max Bandwidth (Plain) {max_bandwidth2:.2f} Gbit/s', alpha=0.5)
    plt.axhline(y=min_bandwidth2, color='blue', linestyle='--', label=f'Min Bandwidth (Plain) {min_bandwidth2:.2f} Gbit/s', alpha=0.5)

    plt.legend(loc='center right', ncol=1, fontsize=8, frameon=False)

    plt.show()

def main():
    # Insert here the IP ADDRESS of the servers
    server_macsec = ""
    server_plain = ""
    duration = int(input("Enter the duration of the iperf test in seconds: "))
    
    # Insert here the NAME of the namespaces performing the iperf connection to the server
    namespace_macsec = "" 
    namespace_plain = ""

    # Insert here the NAME of the namespaces acting as iperf server waiting for incoming connections
    server_macsec = ""
    server_plain = ""

    print(f"Starting iperf server in namespace {server_macsec}...")
    server_proc1 = start_iperf_s(server1)
    time.sleep(1)  

    print(f"Running first iperf test in namespace {namespace_macsec} for {duration} seconds...")
    process1 = run_iperf(server_macsec, duration, namespace_macsec)

    for _ in tqdm(range(duration), desc="MACsec Progress"):
        time.sleep(1)
    
    timestamps1, bandwidths1 = parse_iperf_output(process1)
    server_proc1.terminate()

    print(f"Starting iperf server in namespace {server_plain}...")
    server_proc2 = start_iperf_s(server2)
    time.sleep(1)

    print(f"Running second iperf test in namespace {namespace_plain} for {duration} seconds...")
    process2 = run_iperf(server_macsec, duration, namespace_plain)

    for _ in tqdm(range(duration), desc="Plain Progress"):
        time.sleep(1)
    
    timestamps2, bandwidths2 = parse_iperf_output(process2)
    server_proc2.terminate()

    if timestamps1 and bandwidths1 and timestamps2 and bandwidths2:
        plot_bandwidth(timestamps1, bandwidths1, timestamps2, bandwidths2)
    else:
        print("No data received. Check if the iperf server is running properly.")

if __name__ == "__main__":
    main()

