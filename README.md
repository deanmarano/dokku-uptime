# dokku-uptime

A [Dokku](https://dokku.com) plugin that automatically manages [Uptime Kuma](https://github.com/louislam/uptime-kuma) HTTP monitors for your apps.

When you deploy an app, a monitor is created. When you destroy an app, the monitor is removed.

## Requirements

- Dokku 0.30+
- Uptime Kuma instance (1.x) accessible from the Dokku server
- `jq` and `curl` installed on the host

Don't have Uptime Kuma running yet? [dokku-library](https://github.com/deanmarano/dokku-library) can set it up in one command. If you want to put Uptime Kuma behind an auth wall, check out [dokku-sso](https://github.com/deanmarano/dokku-sso).

## Installation

```bash
dokku plugin:install https://github.com/deanmarano/dokku-uptime.git uptime
```

This downloads the [kuma-cli](https://github.com/BigBoot/AutoKuma) binary automatically.

## Configuration

Connect the plugin to your Uptime Kuma instance:

```bash
dokku uptime:set --global url http://<uptime-kuma-host>:3001
dokku uptime:set --global username <your-username>
dokku uptime:set --global password <your-password>
```

Optional global settings:

```bash
dokku uptime:set --global interval 60        # Check interval in seconds (default: 60)
dokku uptime:set --global max-retries 3      # Max retries before alerting (default: 3)
```

## Usage

### Discover existing apps

Create monitors for all apps that don't have one yet:

```bash
dokku uptime:discover
```

### Check status

```bash
dokku uptime:status <app>
```

### Disable/enable monitoring for an app

```bash
dokku uptime:disable <app>   # Disables monitoring and removes the existing monitor
dokku uptime:enable <app>    # Re-enables monitoring and creates a monitor
```

### Per-app configuration

```bash
dokku uptime:set <app> <key> <value>
```

## How it works

- **On deploy** (`post-deploy` trigger): creates an HTTP monitor named `dokku/<app>` pointing at the app's first vhost domain, unless monitoring is disabled or a monitor already exists.
- **On destroy** (`pre-delete` trigger): deletes the monitor and cleans up the stored monitor ID.
- Monitors are created via [kuma-cli](https://github.com/BigBoot/AutoKuma), which authenticates to Uptime Kuma over Socket.IO using username/password.

## Updating

```bash
dokku plugin:update uptime
```

This pulls the latest plugin code and updates the kuma-cli binary if a newer version is available.

## License

MIT
