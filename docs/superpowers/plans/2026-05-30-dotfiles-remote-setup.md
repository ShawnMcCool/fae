# Dotfiles Remote Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** A foolproof, step-by-step in-app flow to configure this machine's dotfiles git remote — either **create a private GitHub repo via `gh`** (gated on `gh` being installed + authed) or **paste a URL** — with validation, reconcile-before-push so the DB is the single source of truth, and honest human-readable status (no raw git errors). Closes the gap where the import set no remote and there was no UI to fix it.

**Context:** Builds on the shipped `Fae.Dotfiles` tool (`lib/fae/dotfiles/`, board at `lib/fae_web/live/dotfiles_live/`). The `dotfiles_config` row already has `remote_url`, `remote_name` (default `"origin"`), `branch` (default `"main"`). The backup pipeline (`backup_pipeline.ex`) already pushes via `Git.push(remote_name, branch)`. The bare repo is `~/.local/share/fae/dotfiles/repo.git`, work-tree `$HOME`.

**Key facts (verified):** `gh` 2.93 authed; the `hostname` shell command is ABSENT on this Arch box — use `:inet.gethostname/0`. SSH URL retrieval: `gh repo view <owner>/<name> --json sshUrl -q .sshUrl`.

**Conventions:** same as the main dotfiles plan (`docs/superpowers/plans/2026-05-30-fae-dotfiles.md`) — `Fae.Clock`, Topics broadcast on writes, `Fae.DataCase`/`FaeWeb.ConnCase`, decision 019 (logic in pure modules), `mix precommit` green, injectable command fns for shell-outs so tests don't hit the network/gh. All git/gh shell-outs take an injectable `cmd` (default `&System.cmd/3`) and (for git) `:git_dir`/`:work_tree` opts.

---

## Task 1: Git — `ls_remote/2` (validate) + `ensure_remote/3` (reconcile)

**Files:** `lib/fae/dotfiles/git.ex` (extend), `test/fae/dotfiles/git_test.exs` (extend).

- [ ] **Step 1: Tests** — add to git_test.exs:
  - `ls_remote/2` against a real local `--bare` remote → `:ok`.
  - `ls_remote/2` against a bogus path/URL → `{:error, reason}` where reason is one of `:not_found | :auth_failed | :unreachable`.
  - `ensure_remote/3`: with no remote set, sets it; called again with the same URL is a no-op; called with a different URL updates it (assert `git remote get-url origin` reflects the change).

- [ ] **Step 2: Implement** in git.ex:
```elixir
@doc "Validate a remote URL is reachable + authorized. Classifies failures."
def ls_remote(url, opts \\ []) do
  case System.cmd("git", ["ls-remote", url], env: [{"GIT_TERMINAL_PROMPT", "0"}], stderr_to_stdout: true) do
    {_, 0} -> :ok
    {out, _} -> {:error, classify_remote_error(out)}
  end
end

defp classify_remote_error(out) do
  cond do
    out =~ "Permission denied" or out =~ "Could not read from remote" or out =~ "authentication" -> :auth_failed
    out =~ "not found" or out =~ "does not appear to be a git repository" or out =~ "repository" and out =~ "not" -> :not_found
    out =~ "Could not resolve host" or out =~ "unable to access" or out =~ "timed out" -> :unreachable
    true -> :unreachable
  end
end

@doc "Make the named remote's URL match `url` (add if missing, set-url if drifted)."
def ensure_remote(name, url, opts \\ []) do
  case run(["remote", "get-url", name], opts) do
    {current, 0} ->
      if String.trim(current) == url, do: :ok, else: (case run(["remote", "set-url", name, url], opts) do {_,0} -> :ok; {o,_} -> {:error, o} end)
    _ ->
      case run(["remote", "add", name, url], opts) do {_,0} -> :ok; {o,_} -> {:error, o} end
  end
end
```
(Refine `classify_remote_error` until the tests' three cases pass.)

- [ ] **Step 3:** `mix test test/fae/dotfiles/git_test.exs`; `mix compile --warnings-as-errors`; `mix format`. Commit `Dotfiles: git ls_remote validation + ensure_remote reconcile`.

---

## Task 2: `Fae.Dotfiles.GitHub` helper

**Files:** `lib/fae/dotfiles/github.ex` (new), `test/fae/dotfiles/github_test.exs` (new).

- [ ] **Step 1: Tests** (inject a fake `cmd`):
  - `available?/1` → true when `gh` resolves and `gh auth status` exits 0; false otherwise.
  - `default_repo_name/1` → `"dotfiles-" <> sanitized_hostname` (inject hostname; sanitize to `[a-z0-9-]`).
  - `create_private_repo/2` happy path → runs `gh repo create <name> --private`, then resolves the SSH URL, returns `{:ok, ssh_url}`.
  - `create_private_repo/2` when the repo already exists (gh nonzero, stderr mentions "already exists") → `{:error, :already_exists}`.

- [ ] **Step 2: Implement**:
```elixir
defmodule Fae.Dotfiles.GitHub do
  @moduledoc "Thin wrapper over the `gh` CLI for creating the dotfiles remote."
  @type cmd_fun :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})
  @default_cmd &System.cmd/3

  @spec available?(cmd_fun()) :: boolean()
  def available?(cmd \\ @default_cmd) do
    System.find_executable("gh") != nil and match?({_, 0}, cmd.("gh", ["auth", "status"], [stderr_to_stdout: true]))
  end

  @spec default_repo_name(String.t() | nil) :: String.t()
  def default_repo_name(host \\ hostname()) do
    slug = host |> String.downcase() |> String.replace(~r/[^a-z0-9-]+/, "-") |> String.trim("-")
    "dotfiles-" <> slug
  end

  @spec create_private_repo(String.t(), cmd_fun()) :: {:ok, String.t()} | {:error, atom() | String.t()}
  def create_private_repo(name, cmd \\ @default_cmd) do
    case cmd.("gh", ["repo", "create", name, "--private"], [stderr_to_stdout: true]) do
      {_, 0} -> ssh_url(name, cmd)
      {out, _} -> if out =~ "already exists", do: {:error, :already_exists}, else: {:error, String.trim(out)}
    end
  end

  defp ssh_url(name, cmd) do
    case cmd.("gh", ["repo", "view", name, "--json", "sshUrl", "-q", ".sshUrl"], []) do
      {url, 0} -> {:ok, String.trim(url)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, h} -> List.to_string(h)
      _ -> "machine"
    end
  end
end
```

- [ ] **Step 3:** test, compile, format. Commit `Dotfiles: GitHub helper (gh availability, create private repo)`.

---

## Task 3: `Configs.set_remote/1` + pipeline reconcile/skip + friendly push errors

**Files:** `lib/fae/dotfiles/configs.ex` (extend), `lib/fae/dotfiles/backup_pipeline.ex` (edit), tests.

- [ ] **Step 1: Tests**
  - `Configs.set_remote(url)` with a reachable local bare remote → updates `remote_url`, calls `Git.ensure_remote`, broadcasts `{:dotfiles_changed}`, returns `{:ok, config}`.
  - `Configs.set_remote(bad_url)` → `{:error, reason}` (from `Git.ls_remote`), does NOT change `remote_url`.
  - Pipeline: when `remote_url` is `nil`, a backup cycle commits but does **not** attempt push and does **not** set `last_push_ok: false` (no spurious error) — `last_push_ok` stays neutral/true.
  - Pipeline: when `remote_url` set, it reconciles (`ensure_remote`) before pushing.

- [ ] **Step 2: Implement**
  - `Configs.set_remote(url, opts \\ [])`: `Git.ls_remote(url)` → on `:ok`, `Git.ensure_remote(get().remote_name, url)`, then `update(%{remote_url: url, last_push_ok: true, last_push_error: nil})` (which broadcasts via the existing path or add a broadcast); on `{:error, reason}` return `{:error, reason}` unchanged.
  - `backup_pipeline.ex` `commit_and_push/…`: if `config.remote_url` is `nil` → skip push entirely, finalize success with `pushed: false` but leave push-ok state neutral (don't write `last_push_ok: false`/error). If set → `Git.ensure_remote(remote_name, remote_url)` before `Git.push`; on push error store the **classified** reason (reuse `Git.classify_remote_error` or map push stderr) not the raw fatal string.

- [ ] **Step 3:** tests, compile, format, full `mix test`. Commit `Dotfiles: Configs.set_remote + reconcile/skip-push + friendly errors`.

---

## Task 4: `DotfilesView` — honest remote status

**Files:** `lib/fae_web/live/dotfiles_view.ex` (extend), `test/fae_web/live/dotfiles_view_test.exs` (extend).

- [ ] **Step 1: Tests** — `build/1` health now includes `remote: %{configured?: boolean, url: string|nil, status: :none | :ok | :failed, message: human_string}`. Cases: no remote → `:none` + "Backups are staying local — no remote set"; remote set + last_push_ok → `:ok` + url; remote set + last push failed → `:failed` + a friendly message derived from `last_push_error` (which is now a classified atom/short string, not raw git).

- [ ] **Step 2: Implement** the `remote` shaping in `build/1` (pure). Map classified reasons → sentences: `:auth_failed` → "GitHub rejected the key — check your SSH access"; `:not_found` → "Repo not found — re-check the URL"; `:unreachable` → "Couldn't reach GitHub — will retry".

- [ ] **Step 3:** test, compile, format. Commit `Dotfiles: honest remote status in view`.

---

## Task 5: Step-by-step `RemoteSetupComponent` + board banner + wiring

**Files:** `lib/fae_web/live/dotfiles_live/remote_setup_component.ex` (new), `lib/fae_web/live/dotfiles_live/index.ex` (edit), `test/fae_web/live/dotfiles_live/remote_setup_component_test.exs` (new). Mockup intent: clear, numbered steps.

- [ ] **Step 1: Tests** — component renders; when `GitHub.available?` it shows the "Create a private repo" option with the default name; choosing create calls `GitHub.create_private_repo` then `Configs.set_remote` and shows success; the paste path validates via `Configs.set_remote` and shows a friendly error for a bad URL; on success sends `{:remote_done}` to the parent. (Inject fakes so tests don't hit gh/network.)

- [ ] **Step 2: Implement** the LiveComponent as an explicit step flow:
  - **Step 1 — Choose:** two cards: *"Create a private GitHub repo for me"* (only rendered if `GitHub.available?/0`; subtitle shows the default name `dotfiles-<hostname>`) and *"I already have a repo — paste its URL."* If gh isn't available, show only the paste path with a one-line note ("install GitHub CLI to create one automatically").
  - **Step 2a — Create:** show/confirm the name (editable), a **Create repo** button; on click → `create_private_repo` → `set_remote` → step 3. Show inline spinner/result and a friendly error on `:already_exists` ("that name's taken — pick another or paste its URL").
  - **Step 2b — Paste:** a URL input + **Check & save**; on submit → `Configs.set_remote` → validates (`ls_remote`) → step 3 or inline friendly error.
  - **Step 3 — Done:** "✓ Remote set: `<url>` — reachable. Backups will push from now on." + Close.
  - Each step has a clear heading ("Step 1 of 2 …") and a back affordance. Plain language throughout.
  - In `index.ex`: add a `:modal` value `:remote_setup`; render a **banner** above the health strip when `@view.health.remote.configured? == false`: *"Backups are staying local — no remote set"* + a **Set up remote** button → opens the component. When configured, the health strip shows the remote + status (from Task 4) with an **Edit** affordance that also opens the component. Handle `{:remote_done}` → clear modal + reload. Also surface "Set up remote" inside the import flow if not configured.

- [ ] **Step 3:** component test + `mix test test/fae_web/live/`, full `mix test`, compile, format. Commit `Dotfiles: step-by-step remote setup flow + board banner`.

---

## Task 6: Deploy + verify

- [ ] `mix precommit` green.
- [ ] `bin/build` then `bin/install`.
- [ ] Verify on `http://127.0.0.1:4321/dotfiles`: with no remote, the banner shows; run the **Create private repo** path → confirm `dotfiles-shawn-desktop` is created on GitHub, the remote is wired, status flips to reachable, and a **Back up now** actually pushes (check the repo on GitHub).

## Out of scope
GitHub OAuth/device-flow (we lean on the already-authed `gh`); multi-remote; non-GitHub provider niceties (paste-URL still works for any provider).
