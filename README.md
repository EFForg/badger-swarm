# Badger Swarm

Runs distributed [Badger Sett](https://github.com/EFForg/badger-sett) scans on Digital Ocean. Yes, a group of badgers is called a _cete_, but "swarm" just sounds better.


## Architecture

Badger Swarm converts a Badger Sett scan of X sites into N Badger Sett scans of X/N sites. This makes medium scans complete as quickly as small scans, and large scans complete in a reasonable amount of time.

Once a run is confirmed, scans get initialized in parallel. Each scan instance receives their portion of the site list.

```mermaid
stateDiagram-v2

[*] --> ConfirmRun

state fork1 <<fork>>
ConfirmRun --> fork1
fork1 --> BadgerInit1
fork1 --> BadgerInit2
fork1 --> BadgerInitN

state InitScans {
    cr1: CreateDroplet
    cr2: CreateDroplet
    cr3: CreateDroplet
    dep1: InstallDependencies
    dep2: InstallDependencies
    dep3: InstallDependencies
    sta1: StartScan
    sta2: StartScan
    sta3: StartScan

    state BadgerInit1 {
        [*] --> cr1
        cr1 --> dep1
        dep1 --> UploadSiteList1
        UploadSiteList1 --> sta1
        sta1 --> [*]
    }
    --
    state BadgerInit2 {
        [*] --> cr2
        cr2 --> dep2
        dep2 --> UploadSiteList2
        UploadSiteList2 --> sta2
        sta2 --> [*]
    }
    --
    state BadgerInitN {
        [*] --> cr3
        cr3 --> dep3
        dep3 --> UploadSiteListN
        UploadSiteListN --> sta3
        sta3 --> [*]
    }
}

state join1 <<join>>
BadgerInit1 --> join1
BadgerInit2 --> join1
BadgerInitN --> join1

join1 --> [*]
```

The run is now resumable. Scans are checked for progress and status (errored/stalled/complete) in parallel.

- If a scan fails, its instance is deleted and the scan gets reinitialized.
- When a scan fails to progress long enough, it is considered stalled. Stalled scans get restarted, which mostly means they get to keep going after skipping the site they got stuck on.
- When a scan finishes, the results are extracted and the instance is deleted.

This continues until all scans finish.

```mermaid
stateDiagram-v2

[*] --> PollForStatus

state fork2 <<fork>>
PollForStatus --> fork2
fork2 --> CheckBadgerScan1
fork2 --> CheckBadgerScan2
fork2 --> CheckBadgerScanN

state ManageInProgressScans {
    err1: CheckForFailure
    err2: CheckForFailure
    err3: CheckForFailure
    pro1: ExtractProgress
    pro2: ExtractProgress
    pro3: ExtractProgress
    sta1: CheckForStall
    sta2: CheckForStall
    sta3: CheckForStall

    state CheckBadgerScan1 {
        [*] --> err1
        err1 --> pro1
        pro1 --> sta1
        sta1 --> [*]
    }
    --
    state CheckBadgerScan2 {
        [*] --> err2
        err2 --> pro2
        pro2 --> sta2
        sta2 --> [*]
    }
    --
    state CheckBadgerScanN {
        [*] --> err3
        err3 --> pro3
        pro3 --> sta3
        sta3 --> [*]
    }
}

state join2 <<join>>
CheckBadgerScan1 --> join2
CheckBadgerScan2 --> join2
CheckBadgerScanN --> join2

state check1 <<choice>>
join2 --> check1
check1 --> PrintProgress : One or more scans still running
check1 --> MergeResults : All scans finished

PrintProgress --> PollForStatus

MergeResults --> [*]
```

On completion scan results are merged by Privacy Badger as if each result was manually imported on the Manage Data tab on Privacy Badger's options page.


## Setup

1. Check out this repository
2. [Install `doctl`](https://github.com/digitalocean/doctl#installing-doctl)
3. [Authenticate `doctl`](https://github.com/digitalocean/doctl#authenticating-with-digitalocean) with DigitalOcean
4. Copy `settings.ini.sample` to `settings.ini`
5. Review the settings. At minimum, specify your Digital Ocean SSH key (see `doctl compute ssh-key`). For Droplet sizes and hourly prices, see `doctl compute size list`.
6. To automatically merge results on completion, check out Badger Sett and [Privacy Badger](https://github.com/EFForg/privacybadger) (at the same directory level as this repository) and then [set up and activate a virtual environment](https://snarky.ca/a-quick-and-dirty-guide-on-how-to-install-packages-for-python/) for Badger Sett.
7. Run `./main.sh` to initiate a new run.

Once you are told the run is resumable, you can stop the script with <kbd>Ctrl</kbd>-<kbd>C</kbd> and then later resume the in-progress run with `./main.sh -r`.
