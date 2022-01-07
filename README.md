# badger-sett-orchestration

Runs distributed [Badger Sett](https://github.com/EFForg/badger-sett) scans on Digital Ocean.

## Setup

1. Check out this repository
2. [Install `doctl`](https://github.com/digitalocean/doctl#installing-doctl)
3. Copy `settings.ini.sample` to `settings.ini`
4. Review the settings. At minimum, specify your Digital Ocean SSH key (see `doctl compute ssh-key`). For Droplet sizes and hourly prices, see `doctl compute size list`.
5. To automatically merge results at completion, check out Badger Sett and [Privacy Badger](https://github.com/EFForg/privacybadger) (at the same directory level as this repository) and then [set up and activate a virtual environment](https://snarky.ca/a-quick-and-dirty-guide-on-how-to-install-packages-for-python/) for Badger Sett.
6. Run distributed scans! For example, to distribute a 100 site scan over two Droplets, run `./main.sh -n2 -s100`.
