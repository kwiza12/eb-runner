# Enter Bash Runner

GitHub Actions runner for [Enter Bash](https://enter-bash.pages.dev) lab sessions.

This repo must be **public** to get unlimited free GitHub Actions minutes.

## How it works

1. The Enter Bash API triggers a `workflow_dispatch` on `lab-session.yml`
2. The workflow starts a Docker container, ttyd terminal, and cloudflared tunnel
3. It calls back to the API with the tunnel URL
4. It polls for challenge commands (apply files, run setup, validate)
5. It sends heartbeats and stops on timeout or explicit signal

## Security

- No secrets are stored in this repo
- Callback tokens are passed via workflow inputs and used ephemerally
- Each lab session runs in an isolated Docker container
