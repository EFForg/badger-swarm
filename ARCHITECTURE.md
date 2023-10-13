# Architecture

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

[*] --> ManageScans

state fork2 <<fork>>
ManageScans --> fork2
fork2 --> CheckBadgerScan1
fork2 --> CheckBadgerScan2
fork2 --> CheckBadgerScanN

state PollInProgressScansForStatus {
    chk1: CheckForFailure
    cr1: CreateDroplet
    dep1: InstallDependencies
    go1: StartScan
    pro1: ExtractProgress
    ter1: CheckForTermination
    fin1: ExtractResults
    fai1: ExtractErrorLog
    del1: DeleteDroplet
    sta1: CheckForStall
    res1: RestartScan
    ddd2: ...
    ddd3: ...

    state CheckBadgerScan1 {
        [*] --> chk1

        state scan1_failed <<choice>>
        chk1 --> scan1_failed
        scan1_failed --> cr1 : Scan previously failed
        scan1_failed --> pro1 : No error log found

        cr1 --> dep1
        dep1 --> UploadSiteList1
        UploadSiteList1 --> go1
        go1 --> [*]

        pro1 --> ter1

        state scan1_term <<choice>>
        ter1 --> scan1_term
        scan1_term --> fin1 : Scan finished
        scan1_term --> fai1: Scan failed
        scan1_term --> sta1 : Scan is still running

        fin1 --> del1
        fai1 --> del1

        del1 --> [*]

        state scan1_stall <<choice>>
        sta1 --> scan1_stall
        scan1_stall --> res1: Progress file is stale
        scan1_stall --> [*] : Progress was updated recently

        res1 --> [*]
    }
    --
    state CheckBadgerScan2 {
        [*] --> ddd2
        ddd2 --> [*]
    }
    --
    state CheckBadgerScanN {
        [*] --> ddd3
        ddd3 --> [*]
    }
}

state join2 <<join>>
CheckBadgerScan1 --> join2
CheckBadgerScan2 --> join2
CheckBadgerScanN --> join2

state all_finished <<choice>>
join2 --> all_finished
all_finished --> PrintProgress : One or more scan results missing
all_finished --> MergeResults : All scans completed successfully

PrintProgress --> ManageScans

MergeResults --> [*]
```

On completion scan results are merged by Privacy Badger as if each result was manually imported on the Manage Data tab on Privacy Badger's options page.
