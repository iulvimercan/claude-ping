# ⏰ claude-ping

[![deploy](../../actions/workflows/deploy.yml/badge.svg)](../../actions/workflows/deploy.yml)

A tiny AWS Lambda that sends a one-word prompt to Claude Code on a schedule. A new 5-hour usage window then starts on time, even when your PC is off. It costs **$0**: everything runs inside AWS and GitHub always-free tiers.

---

## 🎯 Why

Claude Pro/Max plans meter usage in **5-hour windows**. A window doesn't start at a fixed time. It starts with your **first message** after the previous window has expired, so idle time is wasted:

> Your window ends at 11:00, but you only send your next message at 13:30. The new window starts at 13:30, and those 2.5 hours never count toward anything. 😩

claude-ping runs `claude -p "hi"` at scheduled times, so each window starts right after the previous one ends. Your resets then land where you want them. ✅

### ⚠️ What it does NOT do

- 📅 It does **not** raise your **weekly limit**. That resets at a fixed weekly time for your account.
- 🏦 It does **not** "bank" unused usage. It only controls **when** windows start.
- 🧪 It is **not** an official Anthropic feature. It relies on `claude setup-token` for headless auth. Check Anthropic's usage terms before relying on it.

---

## 🏗️ Architecture

```
GitHub (public repo)
  ├─ pull request → ci.yml: lint + build + Lambda size checks (no AWS access)
  └─ push to main → deploy.yml (environment: production)
        │ OIDC, no AWS keys stored in GitHub
        ▼
  CloudFormation stack "claude-ping"
        ├─ Lambda claude-ping (Node 24, zip)  +  2 layers with the Claude Code CLI
        ├─ 4× EventBridge Scheduler (Europe/Istanbul)
        ├─ CloudWatch Logs (14-day retention)
        └─ Errors alarm → SNS email

At ping time:  Lambda → SSM Parameter Store (OAuth token, SecureString)
               → claude -p "hi" --model sonnet → new 5-hour window ✅
```

| Component | Role |
|---|---|
| 🔑 `claude setup-token` | Long-lived OAuth token for your Pro/Max subscription (valid ~1 year) |
| 🔐 SSM Parameter Store | Holds the token. GitHub never sees it |
| 📦 CLI layers | Claude Code's ~240 MB Linux binary, zstd-compressed to ~84 MB and split into 2 layers |
| ⚡ Lambda | Reassembles the CLI into `/tmp` on cold start (~3 s), then runs one prompt |
| ⏰ EventBridge Scheduler | Timezone-aware cron, one schedule per ping |
| 🚨 CloudWatch alarm + SNS | Emails you when a ping fails (usually: the token expired) |
| 🤖 GitHub Actions | Builds, publishes and deploys on every merge to `main` |

<details>
<summary>Why is the CLI split across layers?</summary>

- **Container image:** needs ECR. Private ECR storage is free only for 12 months, then about $0.10/GB-month.
- **Plain zip:** the Claude Code binary is ~240 MB and gzips to ~108 MB. Direct zip uploads are capped at 50 MB, and anything bigger has to go through S3.
- **Layers:** compressed with zstd (`-19 --long=27`), the binary is ~84 MB. Split into two parts of under 50 MB, each part fits a direct layer upload, so no paid storage is needed.
- The layers are republished **only** when the Claude Code version in `package-lock.json` changes. A normal code deploy uploads a ~2 KB zip.
</details>

---

## 📁 Project structure

```
claude-ping/
├── .github/
│   ├── workflows/ci.yml           # PR checks: lint, build, size limits
│   ├── workflows/deploy.yml       # main → layers + stack + code + smoke test
│   └── dependabot.yml             # weekly Claude Code + action updates
├── infra/
│   ├── bootstrap.yaml             # one-time: GitHub OIDC + all IAM roles
│   └── app.yaml                   # Lambda, schedules, alarm (⏰ schedule lives here)
├── scripts/
│   ├── build.sh                   # function zip + CLI layer zips
│   └── publish-cli-layers.sh      # publishes layers only when Claude Code changed
├── src/index.mjs                  # Lambda handler
└── package.json / package-lock.json  # pins the Claude Code version
```

---

## 🍴 Use it yourself

Each copy runs in **its own** AWS account with **its own** Claude token. Your copy can't touch anyone else's deployment, and theirs can't touch yours.

1. Click **Use this template** (or **Fork**) at the top of this page. A template copy is cleaner: it's independent, and Dependabot works normally there.
2. Clone your copy and follow [One-time setup](#setup) below. Skip step 2, since your repo already exists.
3. Set your timezone and ping times under `Mappings → Ping → Settings` in [infra/app.yaml](infra/app.yaml).
4. Push that change, or run **Actions → deploy → Run workflow**.

Until you set the `AWS_REGION` variable, the deploy job is **skipped** rather than failing, so a fresh copy stays green.

---

<a id="setup"></a>

## 🛠️ One-time setup

Prerequisites: a Claude **Pro or Max** subscription, Claude Code on your PC, the AWS CLI v2 logged in with admin rights, and the GitHub CLI (`gh`).

The commands use `eu-north-1`. Use any region, but use the same one everywhere.

### 1. 🔑 Store the Claude token in SSM

```bash
claude setup-token
```

Copy the token it prints. The next command waits for you to paste it and press Enter. Nothing is shown, and the token stays out of your shell history:

```bash
read -rs CLAUDE_TOKEN
```

```bash
aws ssm put-parameter --region eu-north-1 --name /claude-ping/oauth-token --type SecureString --value "$CLAUDE_TOKEN" && unset CLAUDE_TOKEN
```

The token grants full access to your subscription. Treat it like a password and never commit it. 🔐

### 2. 🐙 Create the GitHub repo

```bash
git init -b main && git add . && git commit -m "Initial commit"
```

```bash
gh repo create claude-ping --public --source . --push
```

Pushing now is safe: until step 4 sets `AWS_REGION`, only the checks run and the deploy job is skipped.

### 3. 🏗️ Deploy the bootstrap stack (IAM + GitHub OIDC)

The deploy role trusts exactly one repo, identified by its OIDC subject prefix. New repos use IDs (`repo:you@123/claude-ping@456`), older ones use names (`repo:you/claude-ping`), so read yours from GitHub:

```bash
gh api repos/<your-github-username>/claude-ping/actions/oidc/customization/sub --jq .sub_claim_prefix
```

Check whether your account already trusts GitHub Actions. If this prints a provider, add `CreateOidcProvider=false` to the deploy command:

```bash
aws iam list-open-id-connect-providers
```

```bash
aws cloudformation deploy --region eu-north-1 --stack-name claude-ping-bootstrap --template-file infra/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides GitHubSubjectPrefix=<prefix-from-above>
```

```bash
aws cloudformation describe-stacks --region eu-north-1 --stack-name claude-ping-bootstrap --query "Stacks[0].Outputs" --output table
```

### 4. 🔗 Connect GitHub to AWS

Use the values from step 3's outputs:

```bash
gh secret set AWS_DEPLOY_ROLE_ARN --body "<GitHubDeployRoleArn>"
```

```bash
gh secret set CFN_EXEC_ROLE_ARN --body "<CfnExecRoleArn>"
```

```bash
gh secret set ALERT_EMAIL --body "<you@example.com>"
```

```bash
gh variable set AWS_REGION --body eu-north-1
```

Then, in **Settings** on GitHub:
- **Environments → production:** limit deployment branches to `main`. A required reviewer is optional.
- **Branches:** protect `main` and require the `ci` check.
- **Actions → General → Fork pull request workflows:** require approval for **all outside collaborators**.
- **Code security:** turn on secret scanning and push protection.

Finally, start the first deploy from **Actions → deploy → Run workflow**.

### 5. ✅ Verify

1. **Actions → deploy** should finish green. Its smoke test is a dry run that starts the CLI and reads the token without messaging Claude.
2. Confirm the SNS subscription email AWS sent you.
3. **Actions → deploy → Run workflow** with **realPing** checked. Then run `/usage` in Claude Code and confirm a session started.
4. 💸 In **AWS Billing → Budgets**, create the **Zero spend budget** template. It emails you if anything ever costs money.

---

## 🔄 Day-to-day

| I want to… | Do this |
|---|---|
| ⏰ Change the ping times | Edit `Mappings → Ping → Settings` in [infra/app.yaml](infra/app.yaml) and merge to `main` |
| ⏸️ Pause pings | Set `State: DISABLED` there and merge |
| 🤖 Use another model | Change `Model` there, then check `/usage` after the next ping to confirm it still starts a window |
| ✏️ Change the handler | Edit [src/index.mjs](src/index.mjs), open a PR and merge |
| ⬆️ Update Claude Code | Merge Dependabot's weekly PR. CI rebuilds and re-checks the layers |
| 🔑 Rotate the token | `claude setup-token`, then the step 1 commands with `--overwrite` added to `put-parameter`. No redeploy needed |
| ⏪ Roll back | `git revert` the bad commit and push |
| 🚀 Redeploy manually | **Actions → deploy → Run workflow** |

### 🧠 Timing tip

Don't schedule pings **exactly** 5 hours apart. A ping at exactly +5h can land just before the old window ends and start nothing. Leave a few minutes of buffer:

```
05:00 → 10:05 → 15:10 → 20:15 ✅
```

Extra pings during an active window are harmless.

---

## 🐛 Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| 📧 Alarm email | Check `/aws/lambda/claude-ping` in CloudWatch Logs. Auth errors mean the token expired, so rotate it |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `GitHubSubjectPrefix` doesn't match the repo's `sub_claim_prefix` (re-run the step 3 `gh api` command), or the job isn't running in the `production` environment |
| `ParameterNotFound` | Step 1 used a different region or name than the stack |
| Stack fails on `LogGroup` "already exists" | A `/aws/lambda/claude-ping` log group already exists in the account. Delete it and re-run |
| `layer-N.zip exceeds the 50 MB` in CI | Claude Code grew. Lower `PART_SIZE` in `build.sh` and bump `RECIPE` |
| Ping ran but no new window | The ping landed inside the old window. Add more buffer to the schedule |

---

## 💰 Cost: $0

| Service | Usage (~88 pings/month) | Always-free allowance |
|---|---|---|
| Lambda | ~88 requests, ~1,300 GB-s | 1M requests + 400,000 GB-s |
| Lambda code + layers storage | ~170 MB | 75 GB |
| EventBridge Scheduler | ~88 invocations | 14M/month |
| SSM Parameter Store | 1 standard SecureString | free (standard tier) |
| KMS (`aws/ssm` managed key) | ~90 requests | 20,000/month |
| CloudWatch Logs / alarms | a few KB / 1 alarm | 5 GB / 10 alarms |
| SNS email | 0–5 | 1,000/month |
| GitHub Actions | public repo | free |

---

## 🔐 Security

- The Claude token lives only in SSM, encrypted. It never touches GitHub, the repo or the Lambda configuration.
- GitHub assumes an AWS role over OIDC, so no long-lived AWS keys exist. Only jobs in this repo's `production` environment can assume it, and forks can't.
- The deploy role can only change the `claude-ping` stack, function and layers. CloudFormation runs as a separate role scoped to those resources, and no role can create IAM resources.
- Pull requests from forks only run `ci.yml`, which has no secrets and no AWS access. Nothing uses `pull_request_target`.
- Workflow logs are public. The deploy job masks the AWS account ID, and secrets show as `***`.
- The deploy job builds the CLI layers itself instead of reusing the `ci` job's cache, so nothing that runs during CI can alter the binary that receives the token.
- Third-party actions are pinned to commit SHAs, and Dependabot keeps them current.
- ⚠️ Read every pull request before merging, especially changes to `.github/`, `scripts/` and `infra/`. Once on `main`, code runs with the deploy role.

---

## 📌 Disclaimer

This project uses community-documented techniques, not an official Anthropic feature. The behavior of usage windows, `setup-token` and headless auth can change. Check current Anthropic docs and terms. 🧪
