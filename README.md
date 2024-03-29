# Badger Swarm

Runs distributed [Badger Sett](https://github.com/EFForg/badger-sett) scans on Digital Ocean. Yes, a group of badgers is called a _cete_, but "swarm" just sounds better.

![Badger Swarm demo recording](badger-swarm-screencast.gif)

Badger Swarm converts a Badger Sett scan of X sites into N Badger Sett scans of X/N sites. This makes medium scans complete as quickly as small scans, and large scans complete in a reasonable amount of time.

For more information, visit our [Introducing Badger Swarm: New Project Helps Privacy Badger Block Ever More Trackers](https://www.eff.org/deeplinks/2023/10/privacy-badger-learns-block-ever-more-trackers) blog post.


## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md).


## Setup

1. Check out this repository
2. [Install `doctl`](https://github.com/digitalocean/doctl#installing-doctl)
3. [Authenticate `doctl`](https://github.com/digitalocean/doctl#authenticating-with-digitalocean) with DigitalOcean
4. Copy `settings.ini.sample` to `settings.ini`
5. Review the settings. At minimum, specify your Digital Ocean SSH key (see `doctl compute ssh-key`). For Droplet sizes and hourly prices, see `doctl compute size list`.
6. To automatically merge results on completion, check out Badger Sett and [Privacy Badger](https://github.com/EFForg/privacybadger) (at the same directory level as this repository) and then [set up and activate a virtual environment](https://snarky.ca/a-quick-and-dirty-guide-on-how-to-install-packages-for-python/) for Badger Sett.
7. Run `./main.sh` to initiate a new run.

Once you are told the run is resumable, you can stop the script with <kbd>Ctrl</kbd>-<kbd>C</kbd> and then later resume the in-progress run with `./main.sh -r`.


## Helpful Bash scripting links
- https://google.github.io/styleguide/shellguide.html
- https://mywiki.wooledge.org/
- https://tldp.org/LDP/abs/html/index.html
- https://www.shellcheck.net/
