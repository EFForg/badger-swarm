#!/usr/bin/env bash

err() {
  echo "$*" >&2
}

parse_args() {
  local OPTIND
  local usage="Usage: $0 -n NUM_CRAWLERS -s NUM_SITES [-r]"

  while getopts 'n:s:r' flag; do
    case "$flag" in
      n) num_crawlers="$OPTARG" ;;
      s) num_sites="$OPTARG" ;;
      r) resume_scan=true ;;
      *) err "$usage"; exit 1 ;;
    esac
  done

  # TODO restore num_crawlers and num_sites automatically when -r is present
  if [ "$resume_scan" = true ]; then
    if [ ! -f output/.run_in_progress ]; then
      err "No in-progress run found ..."
      exit 1
    fi
  fi

  if [ -z "$num_sites" ] || [ -z "$num_crawlers" ]; then
    err "$usage"
    exit 1
  fi

  if [ "$num_crawlers" -lt 1 ] || [ "$num_crawlers" -gt 100 ]; then
    err "NUM_CRAWLERS must be > 0 and <= 100"
    exit 1
  fi
  if [ "$num_sites" -lt 1 ] || [ "$num_sites" -gt 1000000 ]; then
    err "NUM_SITES must be > 0 and <= 1,000,000"
    exit 1
  fi

  readonly num_crawlers num_sites
}

parse_config() {
  local name value

  if [ ! -f settings.ini ]; then
    err "Missing settings.ini"
    exit 1
  fi

  while IFS='= ' read -r name value; do
    # ignore comments, section names and blank lines
    [ "${name:0:1}" = "#" ] || [ "${name:0:1}" = "[" ] || [ -z "$name" ] && continue

    if [ -z "$value" ]; then
      err "Missing settings.ini value for $name"
      exit 1
    fi

    case "$name" in
      browser) readonly browser="$value" ;;
      do_image) readonly do_image="$value" ;;
      do_region) readonly do_region="$value" ;;
      do_size) readonly do_size="$value" ;;
      do_ssh_key) readonly do_ssh_key="$value" ;;
      droplet_name_prefix) readonly droplet_name_prefix="$value" ;;
      tlds_to_exclude) readonly tlds_to_exclude="$value" ;;
      *) err "Unknown settings.ini setting: $name"; exit 1 ;;
    esac
  done < settings.ini

  # do_ssh_key must be provided as it's required and there is no default
  if [ -z "$do_ssh_key" ]; then
    err "Missing settings.ini setting: do_ssh_key"
    exit 1
  fi
}

grep_filter() {
  local tlds_to_exclude="$1"
  local tld

  shift
  for tld in ${tlds_to_exclude//','/' '}; do
    set -- -e "\.${tld}[[:cntrl:]]*$" "$@"
  done

  grep -v "$@" 2>/dev/null
}

init_sitelists() {
  local top1m_zip=output/top-1m.csv.zip
  local lines_per_list

  # get Tranco list if no zip or old zip
  # TODO is there a version of the list bigger than 1M?
  if [ ! -f "$top1m_zip" ] || [ ! "$(find "$top1m_zip" -newermt "1 day ago")" ]; then
    echo "Downloading Tranco list ..."
    curl -sSL "https://tranco-list.eu/top-1m.csv.zip" > output/top-1m.csv.zip
  fi

  unzip -oq output/top-1m.csv.zip -d output/

  # convert Tranco CSV to list of domains
  # cut to desired length and with some TLDs filtered out
  grep_filter "$tlds_to_exclude" output/top-1m.csv | head -n "$num_sites" | cut -d "," -f 2 > output/sitelist.txt

  # create chunked site lists
  # note: we will use +1 droplet when there is a division remainder
  # TODO could be an extra droplet just to visit a single site ...
  lines_per_list=$((num_sites / num_crawlers))
  # TODO should -da be determined by $num_crawlers?
  split -da 4 --lines="$lines_per_list" output/sitelist.txt "$results_folder"/sitelist.split.

  # clean up intermediate files
  rm output/sitelist.txt output/top-1m.csv
}

create_droplet() {
  local droplet="$1"
  local region="$2"
  local image="$3"
  local size="$4"
  local ssh_key="$5"

  echo "Creating Droplet $droplet ($region $image $size)"
  doctl compute droplet create "$droplet" --region "$region" --image "$image" --size "$size" --ssh-keys "$ssh_key" > /dev/null
}

wait_for_active_status() {
  local droplet="$1"

  sleep 10
  until [ "$(doctl compute droplet get "$droplet" --template "{{.Status}}")" = "active" ] ; do
    echo "Waiting for $droplet to become active ..."
    sleep 10
  done
}

get_droplet_ip() {
  local droplet="$1"
  local ip_file="$results_folder"/"$droplet".ip
  if [ ! -f "$ip_file" ]; then
    doctl compute droplet get "$droplet" --template "{{.PublicIPv4}}" > "$ip_file"
  fi
  cat "$ip_file"
}

ssh_fn() {
  local retry=true
  if [ "$1" = noretry ]; then
    retry=false
    shift
  fi

  local ret

  set -- -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes "$@"
  while ssh "$@"; ret=$?; [ $ret -eq 255 ]; do
    [ $retry = false ] && break
    err "Waiting to retry SSH: $*"
    sleep 10
  done

  return $ret
}

rsync_fn() {
  declare -i num=1 max_tries=5
  local ret
  set -- -q -e 'ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes' "$@"
  while rsync "$@"; ret=$?; [ $ret -ne 0 ] && [ "$num" -lt "$max_tries" ]; do
    num=$((num + 1))
    err "Waiting to retry rsync: $*"
    sleep 10
  done
  return $ret
}

wait_for_cloudinit() {
  local droplet="$1"
  local droplet_ip="$2"

  # wait for cloud-init to kick off
  # TODO actually detect when that happens
  sleep 10

  while ssh_fn root@"$droplet_ip" 'pgrep cloud-init >/dev/null'; do
    echo "Waiting for cloud-init to complete on $droplet ($droplet_ip) ..."
    sleep 10
  done
}

install_dependencies() {
  local droplet="$1"
  local droplet_ip="$2"
  local aptget_with_opts='DEBIAN_FRONTEND=noninteractive apt-get -qq -o DPkg::Lock::Timeout=60 -o Dpkg::Use-Pty=0'

  echo "Installing dependencies on $droplet ($droplet_ip) ..."
  ssh_fn root@"$droplet_ip" "$aptget_with_opts update >/dev/null 2>&1"
  ssh_fn root@"$droplet_ip" "$aptget_with_opts install docker.io >/dev/null 2>&1"
}

init_scan() {
  local droplet="$1"
  local domains_chunk="$2"
  local exclude="$3"

  local droplet_ip chunk_size

  wait_for_active_status "$droplet"

  droplet_ip=$(get_droplet_ip "$droplet")

  wait_for_cloudinit "$droplet" "$droplet_ip"
  install_dependencies "$droplet" "$droplet_ip"

  # create non-root user
  ssh_fn root@"$droplet_ip" 'useradd -m crawluser && usermod -aG docker crawluser && cp -r /root/.ssh /home/crawluser/ && chown -R crawluser:crawluser /home/crawluser/.ssh'

  # check out Badger Sett
  ssh_fn crawluser@"$droplet_ip" 'git clone -q --depth 1 https://github.com/EFForg/badger-sett.git'

  # remove previous scan results to avoid any potential confusion
  ssh_fn crawluser@"$droplet_ip" 'rm badger-sett/results.json badger-sett/log.txt'

  # copy domain list
  rsync_fn "$domains_chunk" crawluser@"$droplet_ip":badger-sett/domain-lists/domains.txt

  echo "Starting scan on $droplet ($droplet_ip) ..."
  chunk_size=$(wc -l < ./"$domains_chunk")
  if [ -n "$exclude" ]; then
    exclude="--exclude=$exclude"
  fi
  # TODO support configuring --load-extension
  ssh_fn crawluser@"$droplet_ip" "BROWSER=$browser GIT_PUSH=0 RUN_BY_CRON=1 nohup ./badger-sett/runscan.sh --n-sites $chunk_size --domain-list ./domain-lists/domains.txt $exclude </dev/null >runscan.out 2>&1 &"
}

wait_for_completion() {
  local droplet_ip="$1"
  local scan_result

  while ssh_fn crawluser@"$droplet_ip" '[ -d ./badger-sett/.scan_in_progress ]' 2>/dev/null; do
    sleep 60
  done

  scan_result=$(ssh_fn crawluser@"$droplet_ip" "tail -n1 runscan.out" 2>/dev/null)

  # successful scan
  [ "${scan_result:0:16}" = "Scan successful." ] && return 0

  # failed scan
  return 1
}

manage_scan() {
  local droplet="$1"
  local domains_chunk="$2"

  local chunk=${domains_chunk##*.}
  local copy_err=false
  local droplet_ip
  droplet_ip=$(get_droplet_ip "$droplet")

  if wait_for_completion "$droplet_ip"; then
    echo "Completed scan on $droplet ($droplet_ip)"
    # extract results
    rsync_fn crawluser@"$droplet_ip":badger-sett/results.json "$results_folder"/results."$chunk".json || copy_err=$?
  else
    # TODO retry scan
    echo "Failed scan on $droplet ($droplet_ip)"
    # extract Docker output log
    rsync_fn crawluser@"$droplet_ip":runscan.out "$results_folder"/erroredscan."$chunk".out || copy_err=$?
  fi

  # extract Badger Sett log
  if ! rsync_fn crawluser@"$droplet_ip":badger-sett/log.txt "$results_folder"/log."$chunk".txt; then
    copy_err=$?
    echo "rsync failed with exit value: $copy_err" > "$results_folder"/log."$chunk".txt
  fi

  if [ "$copy_err" = false ]; then
    echo "Deleting $droplet"
    doctl compute droplet delete -f "$droplet"
  else
    err "Failed to extract one or more files from $droplet"
  fi
  rm -f "$results_folder"/"$droplet".ip "$results_folder"/"$droplet".status
}

print_progress() {
  local curval="$1"
  local total="$2"
  local pct=$((curval * 100 / total))
  local num_filled=$((pct * 3 / 10)) # between 0 and 30 chars
  local bar_fill bar_empty
  printf -v bar_fill "%${num_filled}s"
  printf -v bar_empty "%$((30 - num_filled))s" # num_empty
  printf "[${bar_fill// /#}${bar_empty}] %*s  $pct%%\n" $((${#total} * 2 + 2)) "$1/$2"
}

update_droplet_status() {
  local droplet="$1"
  local domains_chunk="$2"
  local droplet_ip num_visited chunk_size

  droplet_ip=$(get_droplet_ip "$droplet")

  num_visited=$(ssh_fn noretry crawluser@"$droplet_ip" 'if [ -f ./badger-sett/docker-out/log.txt ]; then grep -E "Visiting [0-9]+:" ./badger-sett/docker-out/log.txt | tail -n1 | sed "s/.*Visiting \([0-9]\+\):.*/\1/"; fi' 2>/dev/null)

  if [ $? -eq 255 ]; then
    echo "SSH error"
  elif [ -n "$num_visited" ]; then
    # TODO detect and retry stalled scans
    # TODO for example can try `pkill chrome` when browser = chrome
    chunk_size=$(wc -l < ./"$domains_chunk")
    print_progress "$num_visited" "$chunk_size"
  else
    # empty num_visited can happen in the beginning but also at the end,
    # after docker-out/log.txt was moved but before .scan_in_progress removal
    # TODO when we resume and a droplet is already finished, we still seem to go here for 30 secs ...
    echo "waiting ..."
  fi
}

show_progress() {
  local all_done domains_chunk chunk droplet
  local first_time=true

  while true; do
    all_done=true

    # update status files asynchronously
    for domains_chunk in "$results_folder"/sitelist.split.*; do
      [ -f "$domains_chunk" ] || continue

      chunk=${domains_chunk##*.}

      # skip finished or errored
      [ -f "$results_folder"/log."$chunk".txt ] && continue

      droplet="${droplet_name_prefix}${chunk}"

      update_droplet_status "$droplet" "$domains_chunk" > "$results_folder"/"$droplet".status &
    done

    wait

    # move cursor back up
    if [ "$first_time" = false ]; then
      for domains_chunk in "$results_folder"/sitelist.split.*; do
        [ -f "$domains_chunk" ] || continue
        # ANSI escape sequences for cursor movement
        # https://tldp.org/HOWTO/Bash-Prompt-HOWTO/x361.html
        echo -ne '\033M' # scroll up one line
      done
      # TODO
      #echo -ne '\033M' # one more for the last update line
    fi
    first_time=false

    # print statuses
    for domains_chunk in "$results_folder"/sitelist.split.*; do
      [ -f "$domains_chunk" ] || continue
      chunk=${domains_chunk##*.}
      droplet="${droplet_name_prefix}${chunk}"

      echo -ne '\r\033[K' # first erase previous output

      if [ -f "$results_folder"/erroredscan."$chunk".out ]; then
        echo "$droplet failed"
        continue
      elif [ -f "$results_folder"/results."$chunk".json ]; then
        echo "$droplet finished"
        continue
      elif [ -f "$results_folder"/log."$chunk".txt ]; then
        echo "$droplet ??? (see $results_folder/log.${chunk}.txt)"
        continue
      fi

      all_done=false

      echo "$droplet $(cat "$results_folder"/"$droplet".status)"
    done

    # TODO ETA Xh:Ym
    #echo "Last update: $(date +'%Y-%m-%dT%H:%M:%S%z')"
    #echo -ne '\r\033[K' # first erase previous output
    #echo "$total/$num_sites"

    [ $all_done = true ] && break

    sleep 30

  done
}

merge_results() {
  for results_chunk in "$results_folder"/results.*.json; do
    [ -f "$results_chunk" ] || continue
    set -- --load-data="$results_chunk" "$@"
  done

  # TODO badger_sett_dir and --pb-dir should be in settings.ini
  echo "../badger-sett/crawler.py --n-sites 0 --browser chrome --pb-dir ../privacybadger/ $*"

  if ! ../badger-sett/crawler.py --n-sites 0 --browser chrome --pb-dir ../privacybadger/ "$@"; then
    return 1
  fi

  mv results.json "$results_folder"/ && rm log.txt
}

main() {
  # cli args
  local num_crawlers num_sites resume_scan=false

  # settings.ini settings with default values
  local browser=chrome
  local do_region=nyc2
  local do_image=ubuntu-20-04-x64
  local do_size=s-1vcpu-1gb
  local do_ssh_key=
  local droplet_name_prefix=badger-sett-scanner-
  local tlds_to_exclude=

  # loop vars and misc.
  local domains_chunk droplet
  local results_folder

  parse_args "$@"
  parse_config

  if [ "$resume_scan" = true ]; then
    results_folder=$(cat output/.run_in_progress)
    echo "Resuming scan in $results_folder"
  else
    results_folder="output/$(numfmt --to=si "$num_sites")-${num_crawlers}-${browser}-${do_size}-$(date +"%s")"
    echo "Creating $results_folder"
    mkdir -p "$results_folder"

    init_sitelists

    # create droplets and initiate scans
    for domains_chunk in "$results_folder"/sitelist.split.*; do
      [ -f "$domains_chunk" ] || continue
      droplet="${droplet_name_prefix}${domains_chunk##*.}"
      create_droplet "$droplet" "$do_region" "$do_image" "$do_size" "$do_ssh_key"
      init_scan "$droplet" "$domains_chunk" "$tlds_to_exclude" &
    done

    wait
    echo "$results_folder" > output/.run_in_progress
    echo "This run is now resumable (using the -r flag)"
  fi

  # poll for status and clean up when finished
  for domains_chunk in "$results_folder"/sitelist.split.*; do
    [ -f "$domains_chunk" ] || continue

    # skip finished or errored
    [ -f "$results_folder"/log."${domains_chunk##*.}".txt ] && continue

    droplet="${droplet_name_prefix}${domains_chunk##*.}"
    manage_scan "$droplet" "$domains_chunk" >/dev/null &
  done

  # periodically print progress updates
  show_progress &

  wait
  echo "All scans finished"
  rm output/.run_in_progress

  sleep 10
  if doctl compute droplet list --format Name | grep -q "$droplet_name_prefix"; then
    err "WARNING: Not all Droplets deleted?"
    err "Check with smth. like 'doctl compute droplet list --format Name,Status'"
  fi

  echo "Merging results ..."
  merge_results || echo "Failed merging results ... fix --pb-dir or enable the Python virtual environment and try again manually?"

  echo "All done"
}

main "$@"
