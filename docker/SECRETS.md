# Docker Secrets Setup

The Docker-based install test (`test-install.sh`) requires a GitHub Personal Access Token (PAT) to authenticate with the GitHub CLI, create test repositories, and clean them up afterward. This guide walks through creating and configuring the token.

## GitHub PAT for bitswell

### Step 1: Generate a token

Go to [github.com/settings/tokens](https://github.com/settings/tokens) and click **"Generate new token (classic)"**.

### Step 2: Select required scopes

Enable the following scopes:

- `repo` -- full control of private repositories (needed to create/push test repos)
- `workflow` -- update GitHub Action workflows
- `admin:public_key` -- manage SSH keys if install.sh configures them
- `delete_repo` -- delete repositories (needed for test cleanup)

### Step 3: Copy the token

Click **Generate token** and copy it immediately. You will not be able to see it again.

### Step 4: Create `docker/.env`

Create the file `docker/.env` with your token:

```
GITHUB_TOKEN=ghp_...
ANTHROPIC_API_KEY=sk-ant-...  # optional, for Claude Code testing
```

### Step 5: Verify

Run the following command to confirm authentication works:

```bash
docker compose -f docker/docker-compose.yml run --rm install-test gh auth status
```

You should see output confirming the token is valid and the user is logged in.

## Security Notes

- `docker/.env` is gitignored -- never commit it.
- Tokens are passed as environment variables, never as build args (build args would persist in image layers).
- Use minimal scopes -- only grant what is needed for testing.
- Rotate tokens regularly.
