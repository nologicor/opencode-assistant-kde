# Agent Instructions

## Pull requests

This repository is the `nologicor` fork of OpenCode Assistant.

Unless the user explicitly asks for an upstream pull request in the current
request, open pull requests against this fork:

```bash
gh pr create --repo nologicor/opencode-assistant-kde --base main
```

Never target `zonaro/opencode-assistant-kde` by default. The `upstream` remote
is for fetching changes only.

Before reporting a new pull request, verify its target and contents:

```bash
gh pr view <number> --repo nologicor/opencode-assistant-kde
gh pr diff <number> --repo nologicor/opencode-assistant-kde --name-only
```

## `gh` default repository

Check the resolved default before creating a pull request:

```bash
gh repo set-default --view
```

It must print `nologicor/opencode-assistant-kde`. If it prints the upstream
repository, fix it with:

```bash
gh repo set-default nologicor/opencode-assistant-kde
git config --unset-all remote.upstream.gh-resolved
```

## Branch hygiene

- Keep pull request branches focused on one change.
- Do not include unrelated working-tree changes in a pull request.
- When the fork's `main` is ahead of `upstream/main`, branch from `origin/main`
  so the pull request does not include unrelated commits.
