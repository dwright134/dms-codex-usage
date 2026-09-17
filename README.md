# Codex Usage for Dank Material Shell

A DankBar widget for live Codex limits, quota pacing, local token activity, and estimated API-equivalent value.

## Features

- Live Codex quota data through the official `codex app-server` interface
- Weekly percentage used, remaining quota, reset countdown, and pacing
- Synthetic five-hour budget when Codex does not provide a five-hour limit
- Pace markers showing the even-burn position on each usage ring
- Token totals for today, the last seven days, and the current calendar month
- Seven-day and 30-day activity charts
- Per-model token and cost estimates
- Cached-input, cache-write, input, output, and reasoning-token aware accounting
- Estimated standard API cost for each period
- Configurable subscription cost comparison
- Optional quota alerts
- Cached account response and local activity index for fast refreshes

## Requirements

- [Dank Material Shell](https://github.com/AvengeMedia/DankMaterialShell) with plugin support
- [Codex CLI](https://developers.openai.com/codex/cli/) signed in with `codex login`
- Python 3.9 or newer

## Install

Clone the repository into the DMS plugin directory. The destination directory must be named `codexusage` because that is the plugin ID.

```sh
git clone https://github.com/dwright134/dms-codex-usage.git \
  ~/.config/DankMaterialShell/plugins/codexusage
```

Open DMS Settings, enable **Codex Usage**, and add it to DankBar. Restart DMS if the plugin does not appear immediately.

## Update

Pull the latest version and restart DMS:

```sh
git -C ~/.config/DankMaterialShell/plugins/codexusage pull --ff-only
dms restart
```

[`VERSION`](VERSION) and the `version` field in [`plugin.json`](plugin.json) are updated together for each release. Registry installations can use the normal DMS plugin update command after this repository is added to a DMS registry.

## How the five-hour budget works

Some Codex plans expose only a weekly limit. The widget divides an evenly distributed weekly budget into five-hour blocks:

```text
five-hour share of weekly quota = 5 / 168 = 2.976%
```

The first session starts with the day's first recorded Codex token activity, rounded to the nearest five minutes. Each new five-hour session starts when the previous one ends. The widget saves weekly quota snapshots and compares the current percentage with the percentage at the start of the current session. Consuming 1.5 percentage points of weekly quota uses about 50% of the suggested five-hour budget.

This is a pacing tool. It does not represent an OpenAI-enforced five-hour limit. A session may show partial history while the widget collects its baseline.

## API-equivalent value

Codex session logs record the model and cumulative input, cached input, cache-write, output, reasoning, and total token counts. The helper converts positive counter changes into daily and per-model totals.

Cost estimates use standard API text-token rates bundled in [`get-codex-usage.py`](get-codex-usage.py). Cached input is charged at its discounted rate. Cache writes use their separate rate. Reasoning tokens are already part of output tokens and are not counted twice. Requests above a model's 272K long-context threshold receive the documented input and output multipliers.

The result is labeled **API equivalent** because it is an estimate of what the recorded text inference would cost through the API. It is not an OpenAI invoice. Tool-call fees, missing logs, copied sessions, future pricing changes, and unknown models can make the estimate incomplete.

Currently bundled rates cover:

- GPT-6 Astra
- GPT-5.6 Sol, Terra, and Luna
- GPT-5.5
- GPT-5.4

Unknown models retain their token totals and are excluded from the dollar estimate instead of receiving a guessed price.

## Data and authentication

The helper starts `codex app-server` and requests:

- `account/rateLimits/read`
- `account/usage/read`

The Codex CLI manages authentication and token refresh. The plugin does not read or print `~/.codex/auth.json`.

Local activity comes from `$CODEX_HOME/sessions/**/*.jsonl`, defaulting to `~/.codex/sessions`. The helper reads token metadata and never caches conversation text. Derived activity and quota snapshots are stored under `~/.cache/dms-codex-usage` or `$XDG_CACHE_HOME/dms-codex-usage`.

## Development

Run the collector directly:

```sh
python3 get-codex-usage.py
```

Run the tests:

```sh
python3 -m unittest discover -s tests -v
```

## Credits and license

MIT licensed. The widget began as a Codex adaptation of Nicolas Bellamy's [Claude Code Usage plugin](https://github.com/titeya/dms-claudecode), with work from Feiko Wielsma and mir4zul's Codex port. Copyright notices are preserved in [`LICENSE`](LICENSE).

This community plugin is not affiliated with OpenAI or the DMS maintainers.
