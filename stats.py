#!/usr/bin/env python3

# pylint: disable=too-many-locals

import fnmatch
import os
import pathlib
import re
import sys

from datetime import datetime

def get_log_stats(path):
    """Parses Badger Sett log files to extract scan statistics."""

    num_restarts = 0
    num_links = 0
    num_links_failed = 0
    num_site_timeouts = 0
    num_ext_timeouts = 0

    with path.open() as f:
        for line in f:
            if "Clicking on " in line:
                num_links += 1
            elif "Failed to visit link" in line:
                num_links_failed += 1
            elif "Timed out loading skin/" in line or "Timed out loading extension page" in line:
                num_ext_timeouts += 1
            elif "Timed out loading " in line:
                num_site_timeouts += 1
            elif "Restarting browser" in line:
                num_restarts += 1
            elif "Starting new crawl" in line:
                #print(line, end='')
                start_time = datetime.strptime(line[:23], '%Y-%m-%d %H:%M:%S,%f')
            elif "Finished scan" in line:
                #print(line, end='')
                end_time = datetime.strptime(line[:23], '%Y-%m-%d %H:%M:%S,%f')
                site_matches = re.search(r'Visited (\d+) sites and errored on (\d+)', line)
                num_visited = int(site_matches.group(1))
                num_errored = int(site_matches.group(2))
                num_sites = num_visited + num_errored
                error_rate = num_errored / num_sites * 100

    total_time = end_time - start_time

    return {
        "error_rate": error_rate,
        "num_links_failed": num_links_failed,
        "num_links": num_links,
        "num_restarts": num_restarts,
        "num_sites": num_sites,
        "num_timeouts_ext": num_ext_timeouts,
        "num_timeouts_site": num_site_timeouts,
        "num_visited": num_visited,
        "speed": num_sites / total_time.total_seconds() * 60 * 60,
        "time_end": end_time,
        "time_start": start_time,
        "time_total": total_time,
    }

def out(*args):
    print(f"{args[0]:<25}", *args[1:])

def print_scan_stats(path):
    log_stats = []
    for log_path in sorted(path.glob('log.????.txt'), key=os.path.getmtime):
        log_stats.append(get_log_stats(log_path))

    run_start = datetime.fromtimestamp(os.path.getctime(sorted(path.glob('*'), key=os.path.getctime)[0]))
    run_end = datetime.fromtimestamp(os.path.getmtime(sorted(path.glob('log.????.txt'), key=os.path.getmtime)[-1]))
    sites_success = sum(i['num_visited'] for i in log_stats)
    sites_total = sum(i['num_sites'] for i in log_stats)
    links_total = sum(i['num_links'] for i in log_stats)
    link_click_rate = round(links_total / sites_success * 100, 1)
    link_failure_rate = round(sum(i['num_links_failed'] for i in log_stats) * 100 / links_total, 1)
    error_avg = round(sum(i['error_rate'] for i in log_stats) / len(log_stats), 1)
    error_max = round(max(i['error_rate'] for i in log_stats), 1)
    restarts_total = sum(i['num_restarts'] for i in log_stats)
    timeout_rate = round(sum(i['num_timeouts_site'] for i in log_stats) * 100 / sites_total, 1)
    timeouts_ext_total = sum(i['num_timeouts_ext'] for i in log_stats)
    scan_time_avg = round(sum(i['time_total'].total_seconds() for i in log_stats) / len(log_stats) / 60 / 60, 1)
    scan_time_max = round(max(i['time_total'].total_seconds() for i in log_stats) / 60 / 60, 1)
    run_time_total = round((run_end - run_start).total_seconds() / 60 / 60, 1)
    speed_avg = round(sum(i['speed'] for i in log_stats) / len(log_stats), 1)
    speed_min = round(min(i['speed'] for i in log_stats), 1)

    out("Run path:", path)
    out("Date started:", run_start)
    out("Sites:", f"{sites_success} ({sites_total} total)")
    out("Links clicked:", f"{links_total} ({link_click_rate}% of sites) ({link_failure_rate}% failed)")
    out("Overall error rate:", f"{error_avg}% average ({error_max}% max) ({restarts_total} restarts)")
    out("Timeout rate:", f"{timeout_rate}% of sites ({timeouts_ext_total} extension page timeouts)")
    out("Scan time:", f"{scan_time_avg} hours on average ({scan_time_max} max)")
    out("Run time:", f"{run_time_total} hours")
    out("Speed:", f"{speed_avg} sites/hour on average (slowest: {speed_min} sites/hour)\n")


if __name__ == '__main__':
    # to limit output, add match pattern strings as positional arguments
    # these are matched (with wildcards) against scan results directory names
    # for example: ./stats.py chrome 20K
    scan_paths = [x for x in pathlib.Path('output').iterdir() if x.is_dir() and
                  all(fnmatch.fnmatch(x, f"*{s}*") for s in sys.argv[1:])]
    for path in sorted(scan_paths, key=os.path.getmtime):
        print_scan_stats(path)
