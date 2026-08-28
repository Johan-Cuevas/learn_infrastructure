# Infrastructure Learning Plan — AWS Container Platforms, From Scratch

**Goal:** be able to (1) deploy a container-based web application end-to-end on AWS and (2) diagnose infrastructure problems under pressure — with everything built from an empty file in your own account.

**Budget:** 1 hour/day, 5 days/week, 12 weeks core (~60 hours) + 2 optional consolidation weeks.

**Method:** 80/20 — learn only the parts of this stack that cause 80% of the deploys and 80% of the outages.

**Stack you're learning:** CloudFormation + ECS/Fargate + RDS + ElastiCache + CircleCI + Step Functions. Everything else is a distraction until week 13.

**What you finish with:** one public GitHub repo — a small multi-service app, deployed only from your own CloudFormation templates by a CircleCI pipeline — plus a `runbook.md` that is the real deliverable. This is a portfolio piece you can point an interviewer at.

---

## 0. How to use this plan

- Every week has **one project**. Theory exists only to unblock the project. If you can do the project, move on — don't finish the reading.
- Every day is `15 min theory / 40 min hands-on / 5 min notes`. The 5 minutes of notes is not optional; it becomes your runbook (Section 6), which is the actual deliverable of this whole plan.
- Every week's **Theory** line is followed by a **Read:** line with links to the exact pages to use for that day's 15 minutes — not whole guides, just the pages listed. Section 11 collects all of them in one table if a link ever goes stale (search the doc's title on `docs.aws.amazon.com` and you'll find its replacement).
- Every day is written as a **numbered chain**. Step N assumes step N−1 worked, so do them in order and never skip ahead. Each step ends with a *Check:* — the observable thing that tells you it actually worked. **If a Check fails, stop there.** Don't move to the next step; the rest of the day is built on it. Write the failing Check into `runbook.md` (that *is* the deliverable) and debug that one step.
- A day is "done" when its last Check passes. If you run out of your hour at step 3 of 6, that's fine — start tomorrow at step 4. Getting three steps genuinely working beats reading all six.
- Work in **your own AWS sandbox account**. You never need anyone else's account, credentials, or code. Everything here you build yourself.
- You are not learning "all of AWS." You are learning *this* stack: CloudFormation + ECS/Fargate + RDS + CircleCI + Step Functions. Everything else waits until week 13.

---

## 0.5 `snip` — the project you build once and carry everywhere

**The project is a Go link shortener called `snip`.** This is not a suggestion or an example — every day in this plan assumes it by name. Pick it now; don't spend a day deciding.

A link shortener is the right choice because it exercises exactly the four things this stack is about and nothing else: it needs a **database** (store links), a **cache** (hot code lookups), a **background job** (expire links, roll up click counts), and it has a trivially testable HTTP surface for health checks and load balancers.

**The contract — build to exactly this, and no more:**

| Piece | Detail |
|---|---|
| **API** (Go) | `POST /links {"url": "..."}` → `201 {"code": "aB3x9"}` · `GET /:code` → `302` redirect + increment a click counter · `GET /healthz` → `200` (no auth, no DB dependency for liveness) |
| **Job** (Python) | Runs on a cron: aggregates click counts into a rollup table, deletes links past their `expires_at`, exits `0` |
| **Data** | One table: `links(code PK, url, created_at, expires_at, click_count)`. One rollup table. That's it — no users, no auth, no analytics dashboard. |
| **Cache** | Redis, cache-aside on `GET /:code` only, with a TTL |
| **Config** | Everything from env vars: `PORT`, `DATABASE_URL` (or discrete `DB_*`), `REDIS_ADDR`. The DB credentials arrive from Secrets Manager in week 8 — write the code so it reads them at connect time, not once at boot. |
| **Port** | Listen on `0.0.0.0:${PORT}`, default `8080`. Never `127.0.0.1` — week 4 Day 5 shows you why. |

**Why Go for the API:** a static binary in a distroless image is ~15 MB, builds in seconds, and makes week 4's multi-stage build lesson land properly. **Why Python for the job:** it makes the image-weight contrast obvious, and it's what most scheduled tasks are written in anyway. If you're not fluent in Go, that's fine — the API is under 200 lines and the day-by-day steps tell you exactly what it must do. The app is a prop; budget your struggle for the infrastructure.

**(Optional) a tiny static page** that calls the API, if you want something visual behind HTTPS in week 12.

**Where `snip` shows up:** containerized in week 4 → on Fargate behind the ALB in week 5 → given RDS + ElastiCache in week 8 → instrumented in week 9 → pipelined in week 10 → deployed by state machine in week 11 → HTTPS + WAF in the week 12 capstone.

> Don't over-build the app. No auth, no admin UI, no custom short codes, no rate limiting in the app (that's WAF's job in week 12). Every hour spent on `snip` is an hour not spent on the thing you're actually here to learn. Keep the code boring on purpose.

---

## 1. Success criteria

By the end of week 12 you should be able to, without help:

| # | Capability |
|---|---|
| 1 | Trace a git commit all the way to a running container behind a load balancer, and name every hop |
| 2 | Read any CloudFormation template and explain what resource it creates and what depends on it |
| 3 | Deploy a new environment from scratch using a layered stack order (`00 → 01 → 02 → 03`) |
| 4 | Add a new environment variable / secret / port / IAM permission to a service and ship it |
| 5 | Debug: task won't start, ALB returns 502/503, health check flapping, app can't reach Postgres, secret rotation broke connections |
| 6 | Roll back a bad deploy and recover a stack stuck in `UPDATE_ROLLBACK_FAILED` |
| 7 | Read a `.circleci/config.yml` and explain/modify a `dev → stage → prod` promotion path |
| 8 | Build a Step Functions workflow that deploys a stack and rolls back on failure, and re-run a failed execution |

---

## 2. The 80/20 — what actually matters

### The 20% that produces 80% of the value

Ranked by how often it's the answer to "why is this broken?":

1. **IAM** — task role vs. execution role, trust policies, `AccessDenied` reading. Roughly a third of all "it works locally" problems.
2. **Networking** — VPC, public vs. private subnets, security groups, ALB → target group → task port chain. Another third.
3. **Container lifecycle** — image build → ECR → task definition revision → service deployment → health check. This is what "deploying" *is*.
4. **CloudFormation mechanics** — change sets, rollbacks, cross-stack exports, drift. This is how *all* infra changes happen in this stack.
5. **CloudWatch Logs Insights** — you cannot debug what you can't query.
6. **Secrets Manager + RDS** — connection limits, rotation, credential injection.
7. **CircleCI + Step Functions** — the delivery mechanism.

### The 80% you should deliberately skip (for now)

- **Kubernetes, Helm, service meshes** — not in scope. ECS/Fargate is your compute; adding K8s now just doubles the surface area.
- **Terraform, Pulumi, CDK** — you're learning CloudFormation for this plan. Learning a second IaC tool at the same time will actively confuse you when you read CFN YAML. Terraform is a great **week 13+** add-on for marketability — just not now.
- **Kafka/RabbitMQ/SQS-heavy patterns** — no broker in this stack; async here is Step Functions + EventBridge.
- **AWS certification syllabi** — ~60% of the content (Athena, Kinesis, Glue, Direct Connect, Organizations SCPs...) is irrelevant to shipping and debugging a container platform.
- **Deep application development** — you need to *build and run* small services, not become a Go/Python/frontend expert.
- **Advanced WAF rule authoring, managed AI services** — touch WAF lightly in week 12; skip the rest.

---

## 3. Prerequisites — do this before Week 1 (one weekend, ~3 hours)

1. **Create a personal AWS sandbox account** — brand new, separate from anything else you own, with its own email alias.
   *Check:* you can sign in and the account has zero existing resources.
2. **Turn on cost guardrails before creating any resource:** a $20/month AWS Budget alerting at 50/80/100%, a billing alarm in CloudWatch, and a bookmark to Billing → Cost Explorer "by service".
   *Check:* the budget lists your email under Alerts. Do this *first* — guardrails after the fact are how sandbox bills happen.
3. **Install the tooling:** AWS CLI v2, Docker Desktop, Git, **Go 1.22+**, **Python 3.11+**, `psql`, `jq`, `cfn-lint`, `redis-cli`, and the Session Manager plugin (for ECS Exec).
   *Check:* every one of `aws --version`, `docker version`, `go version`, `python3 --version`, `psql --version`, `jq --version`, `cfn-lint --version`, `redis-cli --version`, `session-manager-plugin` runs without error. Fix any that don't now, not mid-week-5.
4. **Confirm you have no default AWS profile.** Everything in this plan uses `--profile sandbox` (set up on Week 1 Day 1).
   *Check:* `aws sts get-caller-identity` with **no** `--profile` flag fails. A working default profile is how people deploy to the wrong account.
5. **Create a public GitHub repo** named `snip-platform` (or similar) for the project, and commit an empty `runbook.md` and `README.md`.
   *Check:* the repo is public and cloned locally — this is the portfolio artifact everything else lands in.

### Two things to set up a week before you need them

These have lead times that will cost you a day if you discover them on the morning you need them:

- **Before week 10 — a CircleCI account**, connected to your GitHub repo. You'll need your **organization ID** (CircleCI → Organization Settings) to build the OIDC trust policy on Week 10 Day 3. Sign up during week 9.
- **Before week 12 — a registered domain** in Route 53 (~$12/yr, non-refundable). Registration is usually minutes but can take longer, and new AWS accounts occasionally get held for verification. **Buy it during week 11**, not on Week 12 Day 1. Note it's outside your $20 budget.

### The teardown rule (one rule, not two)

Not everything needs deleting nightly. Sort by what costs money while idle:

| Delete at the end of **every session** | Safe to leave until **Friday** |
|---|---|
| ALB (~$0.023/hr), NAT Gateway (~$0.045/hr), VPC interface endpoints (~$0.01/hr each per AZ), RDS, ElastiCache, running ECS tasks | VPC, subnets, route tables, security groups, IAM roles, ECR repos, S3 buckets, log groups, secrets |

Everything in the left column is billed **per hour whether or not you use it**. Everything in the right column is free or effectively free at this scale. From week 6 onward your layered stacks map onto this cleanly: **tear down `03-compute` and `02-data` nightly, keep `00-bootstrap` and `01-network-edge` until Friday** — except the ALB and any NAT/endpoints, which live in `01` and must come down too (Week 6 Day 2 gives you a `Condition` to toggle them).

> ⚠️ Left running for a full month, the left column is roughly: ALB $16 + NAT $32 + RDS `db.t4g.micro` $12 + ElastiCache $12 ≈ **$72/month** for an idle sandbox. That is how people get surprised. Week 2 Day 5 gives you `teardown.sh` — write it early and run it.

---

## 4. Structure

### Daily (60 min)

| Block | Time | What |
|---|---|---|
| Theory | 15 min | Read the day's concept from official AWS docs. One concept, no rabbit holes. |
| Hands-on | 40 min | Build / break / fix. Always in a terminal, never just reading. |
| Notes | 5 min | Append to `runbook.md`: what you did, what broke, the exact error string, the fix. |

### Weekly

| Day | Emphasis |
|---|---|
| Mon | New concept + write the smallest version of the week's template yourself |
| Tue–Wed | Build the week's project |
| Thu | **Break it on purpose**, then fix it. This is where the learning actually happens. |
| Fri | Finish, tear down, write up in `runbook.md`, check the AWS bill |
| Sat (optional, 30 min) | Re-read your own notes from the week. Spaced repetition. |

### Rules

- If you're stuck >20 minutes, write the error verbatim in `runbook.md`, then look it up. Being stuck is fine; being stuck silently is not.
- Type commands, don't paste. Use the console to *look*, the CLI/CFN to *change*.
- Follow the **teardown rule** in Section 3: the hourly-billed things (ALB, NAT/endpoints, RDS, ElastiCache, running tasks) go at the end of every session; everything else can wait for Friday, when you delete the lot. Rebuilding on Monday is free repetition.
- Commit your templates and notes to the repo daily. Green history = evidence you did the work.

---

## 5. The 12-Week Plan

---

### PHASE 1 — ORIENTATION (Week 1)

#### Week 1 — Map the territory & harden the account

**Theory:** AWS account/region/service model; IAM users vs roles; what CloudFormation is and why layered stacks are used; the shape of a container platform (edge → compute → data).

**Read:** [Regions and Availability Zones](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html) · [AWS account root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html) · [Managing your costs with AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html) · [IAM identities: users, groups, and roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id.html) · [ARN format](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html) · [IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html) · [Using an IAM role in the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html) · [CloudFormation User Guide, "Welcome"](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html) · [AWS resource and property types reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html)

**Project:** A hand-drawn architecture diagram of the platform you're going to build, plus a hardened sandbox account.

**Day 1 — Harden the account and get a working `sandbox` CLI profile**

1. Log in as the **root** user and enable MFA on it (IAM → Security credentials → Multi-factor authentication → Assign MFA device).
   *Check:* sign out, sign back in as root — you are prompted for a code. This is the single most important security step in the whole plan. 
2. Set two budgets (Billing → Budgets): a **$20/month** cost budget alerting at 50/80/100%, and a second **$1/month** budget alerting at 100%, both emailing you.
   *Check:* both appear in the Budgets list with your email in "Alerts". You will **not** see one fire today — budgets evaluate roughly 3× a day. Day 3 checks your inbox. 
3. Create an IAM user for daily use (IAM → Users → Create user), with console access and MFA enabled, and **no permissions attached yet**.
   *Check:* the user's Security credentials tab shows an MFA device; its Permissions tab is empty. (Done account_name: sandbox-learn)
4. Create an IAM role named `Admin`: trusted entity = **AWS account → this account**, tick "Require MFA", permission = `AdministratorAccess`.
   *Check:* the role's Trust relationships tab shows `"AWS": "arn:aws:iam::<your-account-id>:root"` and a `aws:MultiFactorAuthPresent` condition. 
5. Attach an inline policy to your IAM user allowing `sts:AssumeRole` on that role's ARN, then create an access key for the user and run `aws configure --profile sandbox-user`.
   *Check:* `aws sts get-caller-identity --profile sandbox-user` returns an ARN ending in `:user/<your-user>`. 
6. Add a `sandbox` profile to `~/.aws/config` with `role_arn` (the `Admin` role), `source_profile = sandbox-user`, `mfa_serial` (your MFA device ARN), and `region`.
   *Check:* `aws sts get-caller-identity --profile sandbox` prompts for an MFA code, then returns an ARN. **From here on, every command in this plan uses `--profile sandbox`.**
7. In `runbook.md`, break down the ARN that last command returned, field by field: partition, service, account, resource type, role name, session name.
   *Check:* you can explain why it says `sts` and `assumed-role/Admin/<session>` rather than `iam` and `user/...` — you are not *being* the role, you are holding a temporary session issued by it.

**Day 2 — The four-layer mental model**

1. In `runbook.md`, write the four layers in order: **bootstrap** (S3, ECR, IAM) → **network/edge** (VPC, ALB, DNS, TLS, WAF) → **data** (RDS, Redis, secrets) → **compute** (ECS cluster, services, tasks).
   *Check:* you wrote them in that order without looking at this page.
2. Write one sentence per layer answering: *what does this layer provide that the layer after it cannot start without?*
   *Check:* each sentence names a concrete dependency (e.g. "compute can't start because the image lives in ECR, which bootstrap creates").
3. For each layer, name the single service that is its centerpiece.
   *Check:* four services, no overlaps.
4. Cover your notes and recite the four layers and why they're in that order.
   *Check:* you can say why data comes before compute, and why that ordering will later become stack names `00 → 01 → 02 → 03`.

**Day 3 — Build the resource-type vocabulary**

1. Check your inbox for the $1 budget alert set up on Day 1.
   *Check:* if it hasn't arrived and you *have* spent over $1, your alert email is wrong — fix it now, before you own real resources.
2. Open the [resource and property types reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html) and note the naming shape: `AWS::Service::Resource`.
   *Check:* you can write the type for "an ECS service" from the pattern alone, without searching.
3. For each of your four layers, list 3–6 resource types you'll eventually declare (e.g. network/edge: `AWS::EC2::VPC`, `AWS::EC2::Subnet`, `AWS::EC2::InternetGateway`, `AWS::EC2::RouteTable`, `AWS::ElasticLoadBalancingV2::LoadBalancer`).
   *Check:* ~16–20 types written down, each spelled exactly as the docs spell it.
4. Pick five of them, open each page, and write down its **required** properties only.
   *Check:* you noticed that some resources require almost nothing and others require a lot — that difference predicts which ones will fight you in week 6.
5. **Don't write any YAML today.** Vocabulary only.
   *Check:* you resisted.

**Day 4 — Draw the runtime architecture**

1. On paper, draw the request path left to right: Route 53 → ALB (HTTPS listener, ACM cert) → WAFv2 → target group → ECS/Fargate tasks (api, web) → RDS + ElastiCache.
   *Check:* every box has exactly one inbound arrow and the path has no gaps.
2. Label each arrow with its protocol and port (`:443`, `:80`, app port, `5432`, `6379`).
   *Check:* you can say which single arrow is the one exposed to the internet.
3. Shade which boxes sit in **public** subnets and which in **private**.
   *Check:* only the ALB is public. If a task or the database is public, redraw.
4. Add the Python job as a scheduled task, drawn *off* the request path, touching the same database.
   *Check:* it has no arrow from the ALB.
5. Photograph or ASCII-ify the diagram into `runbook.md` and commit.
   *Check:* it's in the repo, not just on your desk.

**Day 5 — Draw the delivery architecture**

1. Draw the delivery path: commit → CircleCI → `docker build` → ECR → CFN templates to S3 → Step Functions → CloudFormation → ECS service update.
   *Check:* every hop is a box; no "and then it deploys" hand-waving.
2. Mark where the **manual approval gate** sits between `dev` and `stage`.
   *Check:* it's before the stage deploy, not after.
3. Under each hop, write which credential it uses (your laptop's `sandbox` profile vs. CircleCI's IAM role).
   *Check:* you can name the one hop where CI needs AWS permissions for the first time.
4. Under each hop, write **where a failure there would show up** (CI log / S3 / CFN Events / ECS Events).
   *Check:* four different places named — this table becomes your first real runbook entry.
5. Commit both diagrams to the repo.
   *Check:* `git log` shows commits on five separate days this week.

**Done when:** you can whiteboard both diagrams from memory in under 5 minutes.

**Quick win / first portfolio commit:** write your repo's `README.md` with both diagrams embedded, and your first `runbook.md` entry (even just "how I set up MFA + budget alarms"). A public repo with a real README and a runbook already looks more serious than 90% of "I learned AWS" repos.

---

### PHASE 2 — THE FOUNDATIONS THAT BREAK (Weeks 2–3)

#### Week 2 — Networking

**Theory:** VPC, CIDR blocks, public vs. private subnets, route tables, Internet Gateway vs. NAT, security groups (stateful) vs. NACLs (stateless), ALB → listener → target group → target.

**Read:** [VPC CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html) · [Security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)

**Project:** Hand-write a CloudFormation template that creates a VPC with 2 public + 2 private subnets across 2 AZs, an IGW, route tables, and an ALB serving a single `nginx` Fargate task.

> **Forward dependency — read this first.** This week you need a running Fargate task as a *target* for the ALB, but task definitions, services, and clusters aren't taught until **week 5**, and the execution role isn't taught until **week 3**. That's fine: this week the task is a prop, exactly like `snip` is a prop for the infrastructure. Copy a minimal `nginx` task definition + service from the [ECS docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-ecs.html), attach the AWS-managed `AmazonECSTaskExecutionRolePolicy` to a role trusting `ecs-tasks.amazonaws.com`, and **do not try to understand it yet** — you'll write both from scratch, and know why every line is there, in weeks 3 and 5. Today's learning is the *network path*, not the container.

**Day 1 — CIDR math and subnet planning (paper only, no AWS)**

A CIDR block like `10.0.0.0/16` is a range of IP addresses; the number after the slash says how big the range is — *smaller number = bigger range* (`/16` = 65,536 addresses, `/24` = 256). Today you carve one big range into non-overlapping slices, one per subnet. Do the arithmetic by hand once so the numbers stop being magic.

1. Read the [VPC CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html) page.
   *Check:* you can say why AWS requires a VPC CIDR between `/16` and `/28`.
2. On paper, write `10.0.0.0/16` at the top as your VPC range.
   *Check:* you can state how many addresses that is (65,536) without a calculator.
3. Split it into four `/24` blocks: `10.0.0.0/24`, `10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24`.
   *Check:* no two blocks overlap, and all four fit inside `10.0.0.0/16`.
4. Label them: two **public** (for the ALB) and two **private** (for Fargate tasks) — one public + one private per Availability Zone.
   *Check:* each AZ has exactly one public and one private subnet. This is the minimum layout an ALB will accept (it requires two AZs).
5. Next to each block, write its usable address count: 256 total − 5 reserved by AWS = **251 usable**.
   *Check:* you can name what those 5 reserved addresses are used for (network address, VPC router, DNS, future use, broadcast).
6. Copy the finished table into `runbook.md`. You will type these exact values tomorrow.
   *Check:* the table has 4 rows with block, AZ, public/private, usable count.

**Day 2 — VPC, subnets, IGW, route tables**

1. Create `01-network-edge.yaml` with `AWSTemplateFormatVersion` and an empty `Resources:` block, and add an `AWS::EC2::VPC` using your `/16`, with `EnableDnsHostnames: true` and `EnableDnsSupport: true`.
   *Check:* `cfn-lint 01-network-edge.yaml` passes with no errors.
2. Deploy it: `aws cloudformation deploy --template-file 01-network-edge.yaml --stack-name net-dev --profile sandbox`.
   *Check:* the stack reaches `CREATE_COMPLETE`. **If it doesn't, stop here** — everything else this week builds on this stack.
3. Add the four `AWS::EC2::Subnet` resources using yesterday's exact blocks and AZs. Redeploy.
   *Check:* `aws ec2 describe-subnets --profile sandbox` lists four subnets with your CIDRs.
4. Add `AWS::EC2::InternetGateway` + `AWS::EC2::VPCGatewayAttachment`. Redeploy.
   *Check:* the VPC console shows an IGW in state `attached`.
5. Add a public route table with a `0.0.0.0/0` route to the IGW, and associate it with your **two public subnets only**. Redeploy.
   *Check:* the two private subnets still show the *main* route table with no internet route. If all four are public, you've mis-associated.
6. Open the stack's **Events** tab and read it top to bottom in creation order.
   *Check:* you can name one resource that waited on another and say why. That ordering *is* the dependency graph CloudFormation inferred from your `!Ref`s.

**Day 3 — ALB, listener, target group, security groups**

1. Add an ALB security group allowing inbound `:80` and `:443` from `0.0.0.0/0`. Redeploy.
   *Check:* the SG exists and has exactly two inbound rules.
2. Add a task security group whose inbound rule references the **ALB security group ID** as its source (not a CIDR), on your app port.
   *Check:* the rule's source column shows `sg-...`, not an IP range. This is the pattern that makes tasks unreachable from anywhere but the ALB.
3. Add `AWS::ElasticLoadBalancingV2::LoadBalancer` across your two **public** subnets with the ALB SG attached. Redeploy.
   *Check:* the ALB reaches state `active` and has a DNS name.
4. Add a target group with `TargetType: ip` (required for Fargate's `awsvpc` networking) and a listener on `:80` forwarding to it.
   *Check:* `curl http://<alb-dns-name>` returns **503**. That is the correct answer right now — the target group has no targets. A connection timeout instead means the ALB SG is wrong.
5. Run a single `nginx` Fargate task in a public subnet, registered to the target group, and re-curl.
   *Check:* you get the nginx welcome page. This is the first end-to-end request path you've built.
6. Write in `runbook.md`: why the ALB SG is open to the world but the task SG is not.
   *Check:* your explanation uses the phrase "SG referencing another SG".

**Day 4 — Break it on purpose (and solve private-subnet egress for good)**

This is the longest day of the week — steps 1–4 are the breaks, steps 5–7 solve the one that matters. Split it across two sessions if you need to. Do the breaks one at a time and **restore each before starting the next**, so you only ever have one fault in play.

1. Delete the ALB→task rule from the task SG. Curl the ALB.
   *Check:* 503, and the target group shows targets as `unhealthy`. Restore the rule; confirm it goes back to `healthy`.
2. Point the target group at the wrong port (e.g. 8080 when nginx listens on 80). Curl.
   *Check:* targets flip to `unhealthy` with reason "Health checks failed", and the ALB returns 502/503. Restore.
3. Move the task into a **private** subnet (`AssignPublicIp: DISABLED`) and redeploy.
   *Check:* the task never starts; the stopped-task reason contains `CannotPullContainerError`. This is the single most common Fargate failure, and it is a *networking* problem wearing an image-pull costume. **Leave it broken** — steps 5–7 fix it properly.
4. Write a `runbook.md` entry for each of the three in the Section 6 format: exact symptom string → cause → fix → how to prevent.
   *Check:* three entries, each with a verbatim error string you actually saw, not a paraphrase.
5. Understand the actual problem before fixing it: a task in a private subnet has **no route to the internet**, and ECR, CloudWatch Logs, and Secrets Manager are all *public* endpoints. There are exactly two fixes — a **NAT Gateway** (route private traffic out through the public subnet) or **VPC endpoints** (bring the AWS APIs inside your VPC). Write both in `runbook.md` with their costs: NAT ≈ $0.045/hr plus data processing; interface endpoints ≈ $0.01/hr each per AZ; the S3 **gateway** endpoint is free.
   *Check:* you can state that for a sandbox this small, the hourly costs are comparable — **what actually bills you is leaving either one running**, not which you pick.
6. Build the endpoint set (this is what production does, and it's the one most people get wrong). You need **five**, not two: an `AWS::EC2::VPCEndpoint` of type `Gateway` for **S3**, and four of type `Interface` for `ecr.api`, `ecr.dkr`, `logs`, and `secretsmanager` — each in your private subnets, with `PrivateDnsEnabled: true` and a security group allowing `:443` from the task SG.
   *Check:* five endpoints, and you can say why the S3 one is needed even though you never call S3 — **ECR stores image layers in S3**, so image pulls fail with only the two ECR endpoints. This is the exact trap.
7. Redeploy the task into the private subnet.
   *Check:* it starts, pulls its image, becomes `healthy`, and serves through the ALB — with no public IP and no NAT Gateway. Curl the ALB to confirm.
   *If it still fails:* check the endpoint security group allows 443 from the task SG, and that `PrivateDnsEnabled` is true — without it the task resolves the *public* ECR name and still has nowhere to go.
8. Add a `CreateVpcEndpoints` parameter defaulting to `true`, so `teardown.sh` can drop them nightly.
   *Check:* deploying with it `false` removes all five and the private task goes back to failing — which is now a symptom you recognize instantly.

**Day 5 — Teardown script**

1. List every stack you created this week: `aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --profile sandbox`.
   *Check:* the list matches what you think you built. Anything unexpected is a resource you'll be billed for.
2. Write `teardown.sh` that deletes stacks in **reverse** creation order, with `aws cloudformation wait stack-delete-complete` between each.
   *Check:* the script has the waits — without them the next delete starts before the previous finished and fails on in-use exports.
3. Add a `--nightly` mode that deletes only the hourly-billed things (see the teardown rule in Section 3): compute, data, the ALB, and the VPC endpoints — leaving the VPC, subnets, IAM, and ECR in place.
   *Check:* after `./teardown.sh --nightly`, `aws elbv2 describe-load-balancers` and `aws ec2 describe-vpc-endpoints` both return empty, while your VPC survives. This is the command you'll run most nights for the next 10 weeks.
4. Run the full teardown.
   *Check:* every stack reaches `DELETE_COMPLETE`.
5. Verify by hand in the console: no VPCs (other than the default), no load balancers, no VPC endpoints, no running tasks, no Elastic IPs.
   *Check:* zero of each. A leftover ALB costs ~$16/month doing nothing, and four leftover interface endpoints cost about the same.
6. Open Billing → Cost Explorer, grouped by service.
   *Check:* you know what your top cost line this week was and why.
7. Commit `teardown.sh`.
   *Check:* it's in the repo — you'll run `--nightly` most days and the full version every Friday for the next 10 weeks.

**Done when:** given a 502/503/504 from an ALB, you can name three different causes and the check for each.

#### Week 3 — IAM & Secrets

**Theory:** Principals, policies, roles, trust policies, `sts:AssumeRole`; **ECS task role vs. task execution role** (the #1 source of confusion); resource policies; Secrets Manager.

**Read:** [IAM policies and permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html) · [IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html) · [ECS task execution role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html) · [ECS task role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html)

**Project:** A Fargate task that reads a secret from Secrets Manager and an object from S3 — using least-privilege roles you wrote yourself. (Still the borrowed `nginx` task; `snip` arrives in week 4.)

> **Forward dependency:** as in week 2, keep reusing the borrowed `nginx` task definition as a carrier — you're swapping the *roles* attached to it, not writing the task definition. Week 5 is where you write that from scratch. If you want to see a secret actually arrive in a container this week, run `nginx` with a shell (`amazonlinux` with `sleep 3600` as its command works well) and use ECS Exec, or just log the env var.

**Day 1 — Policy anatomy**

1. Read the "JSON policy document structure" section of the [IAM policies](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html) page.
   *Check:* you can name the four elements — Effect, Action, Resource, Condition — and say which one is optional.
2. Hand-write policy (a): allow `s3:GetObject` on **one bucket and prefix only** (`arn:aws:s3:::my-bucket/config/*`).
   *Check:* the Resource is an object ARN with `/*`, not the bucket ARN. Those are two different things and mixing them up is the classic first IAM bug.
3. Hand-write policy (b): allow `secretsmanager:GetSecretValue` on **one secret ARN only**.
   *Check:* your ARN ends with the 6-character suffix AWS appends to secret names — a truncated ARN silently matches nothing.
4. Hand-write policy (c): allow `s3:GetObject` **only when** a condition matches (e.g. `aws:RequestTag` or `s3:prefix`).
   *Check:* the Condition block is valid JSON and names a real condition key from the docs.
5. Paste each into the IAM **Policy simulator** (console → IAM → Access management → Policy simulator) and test both a should-allow and a should-deny action.
   *Check:* all three allow exactly what you intended and deny everything else. **If a policy allows more than you meant, fix it now** — this is the muscle the whole week trains.

**Day 2 — Execution role vs. task role**

1. In `runbook.md`, write the one-line distinction: **execution role** = what ECS itself uses to pull the image and write logs, *before your code runs*. **Task role** = what *your code* uses at runtime.
   *Check:* your sentence contains the words "before your code runs".
2. Write the **execution role** from scratch: trust policy with principal `ecs-tasks.amazonaws.com`, plus the managed policy `AmazonECSTaskExecutionRolePolicy`.
   *Check:* the role's Trust relationships tab shows `ecs-tasks.amazonaws.com`. If it shows `ecs.amazonaws.com`, that's the wrong service principal and tasks will fail to launch.
3. Write the **task role** from scratch: same trust policy, but attach *your* Day-1 policies (a) and (b) instead of the managed one.
   *Check:* the task role has zero ECR and zero CloudWatch Logs permissions. It doesn't need them — that's the point.
4. Add both roles to your CloudFormation template as `AWS::IAM::Role` resources and deploy.
   *Check:* stack `CREATE_COMPLETE`, and `aws iam get-role --role-name <task-role> --profile sandbox` returns your trust policy.
5. Predict, in writing, which role each of these needs: pulling the image / writing a log line / reading a secret at boot / calling S3 from your handler.
   *Check:* you said execution, execution, execution, task. (Secrets injected via the task definition are fetched by the *execution* role — that one surprises everyone.)

**Day 3 — Secrets Manager into a container**

1. Create a secret: `aws secretsmanager create-secret --name /dev/api/demo --secret-string '{"token":"hello"}' --profile sandbox`.
   *Check:* the command returns an ARN. Copy it — including the 6-char suffix.
   > ⚠️ **The trap that will bite you next Monday:** deleting a secret doesn't delete it — it *schedules* deletion with a 7–30 day recovery window, and the name stays reserved. Rebuild your stack and you get `You can't create this secret because a secret with this name is already scheduled for deletion`. Always delete with `--force-delete-without-recovery`, and set `RecoveryWindowInDays: 0` on any `AWS::SecretsManager::Secret` in your templates. Add the force-delete to `teardown.sh` **now**, before it costs you a session.
2. Grant `secretsmanager:GetSecretValue` on that exact ARN to your **execution** role.
   *Check:* the policy's Resource matches the full ARN from step 1.
3. In the task definition, add a `secrets` block (**not** `environment`) mapping `TOKEN` to that secret ARN.
   *Check:* the rendered task definition JSON has the value under `secrets`, and no plaintext token appears anywhere in your template or repo.
4. Deploy and run the task; read the value from inside the container (log it once, or use `printenv`).
   *Check:* the container sees `TOKEN=...`. If the task fails at startup with `ResourceInitializationError`, step 2's ARN is wrong.
5. Look at the task definition in the console.
   *Check:* the secret shows as an ARN reference, not a value — confirm to yourself that anyone with console read access still can't see the secret.

**Day 4 — Break it on purpose (the three AccessDenied flavors)**

One fault at a time; restore before the next.

1. Remove `ecr:GetAuthorizationToken` from the **execution** role. Redeploy the service.
   *Check:* the task **never starts**; stopped reason is `CannotPullContainerError`. Restore.
2. Remove `secretsmanager:GetSecretValue` from the **execution** role. Redeploy.
   *Check:* the task fails at *initialization* with `ResourceInitializationError: unable to pull secrets` — a different stage than #1. Restore.
3. Remove the S3 permission from the **task** role. Redeploy and hit the endpoint that reads S3.
   *Check:* the task **starts fine and stays running**, then throws `AccessDenied` at runtime in your app logs. Restore.
4. Write the discriminator in `runbook.md`: *never started* → execution role (ECR); *started then died at init* → execution role (secrets); *running but erroring* → task role.
   *Check:* three symptoms, three distinct answers, each tied to a lifecycle stage.
5. Have someone (or your future self) show you just one of the three error strings.
   *Check:* you can name the right role in under 30 seconds without re-reading.

**Day 5 — The "Reading an AccessDenied" runbook section**

1. Take a real `AccessDenied` message you produced yesterday and split it into its parts: **principal ARN**, **action**, **resource ARN**.
   *Check:* you extracted all three from the raw message text.
2. Write the decision procedure: principal ARN tells you *which role to edit* → action tells you *what to add* → resource ARN tells you *what to scope it to*.
   *Check:* the procedure never says "attach AdministratorAccess".
3. Add the exact CLI commands you'd run first: `aws iam list-attached-role-policies`, `aws iam get-role-policy`, and the simulator.
   *Check:* you could paste these commands straight into a terminal during an incident.
4. Run `./teardown.sh` and verify zero resources remain.
   *Check:* `DELETE_COMPLETE` on every stack; no leftover roles matter (IAM roles are free, but delete them anyway to keep the account honest).
5. Commit the week's templates and runbook entries.
   *Check:* five days of green history.

**Done when:** you can look at any `AccessDenied` and say within 30 seconds whether it's the execution role or the task role.

---

### PHASE 3 — CONTAINERS & RUNTIME (Weeks 4–5)

#### Week 4 — Docker & building `snip`

**Theory:** Images vs. containers, layers and caching, multi-stage builds, `ENTRYPOINT` vs. `CMD`, healthchecks, `.dockerignore`, image size, platform/arch (`linux/amd64` matters on Apple Silicon).

**Read:** [Dockerfile best practices](https://docs.docker.com/build/building/best-practices/)

**Project:** **Build `snip`** to the contract in Section 0.5, plus its Dockerfiles — a multi-stage build for the Go API and one for the Python job — and a `docker-compose.yml` running it against local Postgres + Redis.

**Day 1 — `snip` in Go + first image**

1. Write `snip` to the contract in Section 0.5 — `POST /links`, `GET /:code`, `GET /healthz` — with links in an **in-memory map** for now (Postgres arrives on Day 4). Use only Go's standard library plus a router if you want one; no framework.
   *Check:* `go run .`, then `curl -X POST localhost:8080/links -d '{"url":"https://example.com"}'` returns a code, and `curl -i localhost:8080/<code>` returns `302` with the right `Location`. No database yet — resist.
2. Write a naive single-stage `Dockerfile` (full Go base image, `COPY . .`, `go build`).
   *Check:* `docker build -t api:v1 .` succeeds and `docker run -p 8080:8080 api:v1` serves `/healthz`.
3. Run `docker history api:v1`.
   *Check:* you can point at which layer is biggest and say what put it there.
4. Change one line of source and rebuild.
   *Check:* the output shows `CACHED` for early layers and rebuilds only from your `COPY` down. If *everything* rebuilds, your `COPY` is too early — that's the lesson.
5. Note the image size: `docker images api:v1`.
   *Check:* write the number down. Tomorrow you beat it by ~10×.

**Day 2 — Multi-stage build**

1. Split the Dockerfile into a `builder` stage (full Go image) and a final stage (`gcr.io/distroless/static` or `alpine`), copying only the compiled binary across.
   *Check:* `docker build` succeeds and the app still serves `/healthz`.
2. Add `CGO_ENABLED=0` and `GOOS=linux` to the build.
   *Check:* the binary runs in distroless. If you get "no such file or directory" running a binary that clearly exists, that's dynamic linking — this flag is the fix.
3. Add a `.dockerignore` (at minimum `.git`, build output, local env files).
   *Check:* build context size printed at the start of `docker build` drops noticeably.
4. Measure the final image.
   *Check:* **under 30 MB**, versus yesterday's number.
5. Annotate every line of the Dockerfile with a comment saying *why* it's there and *why it's in that position*.
   *Check:* your comments on the `COPY go.mod` / `COPY . .` ordering explain layer caching.
6. Split `ENTRYPOINT` (the binary) from `CMD` (default args).
   *Check:* you can explain what `docker run api:v2 --flag` does differently with each.

**Day 3 — The Python job**

1. Write the job to the Section 0.5 contract: connect to Postgres, roll up `click_count` into the rollup table, `DELETE` links past `expires_at`, print what it did, exit `0`.
   *Check:* it runs locally against nothing gracefully, or fails loudly with a clear message — no silent exits.
2. Make it exit non-zero on failure.
   *Check:* force an error; `echo $?` prints something other than 0. Scheduled tasks that swallow errors are invisible outages.
3. Write its Dockerfile (slim base, `pip install -r requirements.txt` as its own layer before copying source).
   *Check:* changing job source doesn't re-run `pip install`.
4. Build and compare sizes against the Go image.
   *Check:* write down both numbers and one sentence on why the Python one is heavier (interpreter + wheels vs. a static binary).
5. Run the job in the container end to end.
   *Check:* it exits 0 and prints what it did.

**Day 4 — docker-compose: the full local stack**

1. Write `docker-compose.yml` with a `postgres` service, a named volume, and `POSTGRES_PASSWORD`.
   *Check:* `docker compose up postgres`, then `psql -h localhost -U postgres` connects.
2. Add a `redis` service.
   *Check:* `redis-cli -h localhost ping` returns `PONG`.
3. Add healthchecks to both, and `depends_on: { condition: service_healthy }` on the API.
   *Check:* `docker compose ps` shows `healthy`, and the API doesn't start until they are. Plain `depends_on` without the condition waits for *start*, not *ready* — that difference causes flaky boots.
4. Create the `links` and rollup tables from Section 0.5, and point `snip` at Postgres and Redis via env vars (**service names as hostnames**, not `localhost` — that's the compose-networking gotcha).
   *Check:* `docker compose up` brings the whole stack up, `POST /links` persists a row you can see with `psql`, and running the Python job deletes a link you gave a past `expires_at`.
5. Restart the stack.
   *Check:* your link is still there — the named volume worked.

**Day 5 — Break it on purpose**

One at a time; fix before the next.

1. Change the API to bind `127.0.0.1:8080` instead of `0.0.0.0:8080`. Rebuild, run, curl from the host.
   *Check:* connection refused even though the container is healthy and logs look perfect. **Memorize this symptom** — it's the #1 cause of ALB 502s in week 5.
2. Remove a required env var from the compose file.
   *Check:* note whether the app crashes loudly or starts and misbehaves. Make it crash loudly, on boot, with the variable's name in the message.
3. On Apple Silicon, build without `--platform linux/amd64` and try to run it as if on Fargate.
   *Check:* `exec format error`. Then rebuild with `--platform linux/amd64` and confirm it works.
4. Write all three into `runbook.md` with verbatim error strings.
   *Check:* three entries; the bind-address one includes the phrase "logs look fine".
5. `docker compose down -v`, then `up` again.
   *Check:* the whole stack comes back from scratch with one command — that's your definition of done for the week.

**Done when:** the whole app runs locally with one `docker compose up`, and you can containerize an unfamiliar service against local Postgres + Redis in under 20 minutes.

#### Week 5 — ECR & ECS/Fargate

**Theory:** ECR repos, tags and immutability; task definitions and revisions; services vs. standalone tasks; desired count; rolling deployments; deployment circuit breaker; health check grace period; ECS Exec; scheduled tasks.

**Read:** [ECS Developer Guide, "Welcome"](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html) · [Rolling deployments & the deployment circuit breaker](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-ecs.html) · [ECS Exec](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html) · [EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html)

**Project:** `snip` running as an ECS service behind the week-2 ALB, plus its Python job as an EventBridge-scheduled task.

**Day 1 — ECR: push your first image**

1. Create the repo: `aws ecr create-repository --repository-name snip-api --image-tag-mutability IMMUTABLE --profile sandbox`.
   *Check:* the command returns a `repositoryUri`. Immutable tags mean a tag can never be re-pointed — this is what makes a deploy reproducible.
2. Authenticate Docker: `aws ecr get-login-password --profile sandbox | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com`.
   *Check:* `Login Succeeded`.
3. Tag your week-4 image with the **git commit SHA**: `docker tag api:v2 <uri>:$(git rev-parse --short HEAD)` and push.
   *Check:* the image appears in ECR with that tag.
4. Try to push the same tag again with different content.
   *Check:* it's **rejected** because the repo is immutable. That rejection is the feature.
5. Write in `runbook.md` why `:latest` is dangerous.
   *Check:* your answer mentions that you can't tell what's running, and that a rollback has no target to roll back *to*.

**Day 2 — Task definition in CloudFormation**

1. Add an `AWS::ECS::TaskDefinition` with `RequiresCompatibilities: [FARGATE]`, `NetworkMode: awsvpc`, and Cpu/Memory `256`/`512`.
   *Check:* `cfn-lint` passes. (Fargate only accepts specific cpu/memory pairs — an invalid combo fails at deploy, not at lint.)
2. Set **both** roles: `ExecutionRoleArn` (week 3's execution role) and `TaskRoleArn` (week 3's task role).
   *Check:* two different ARNs. If they're the same, you've collapsed the distinction you spent week 3 learning.
3. Add the container definition: your ECR image at the SHA tag, `PortMappings` on your app port.
   *Check:* the image URI includes the SHA, not `latest`.
4. Add `LogConfiguration` with the `awslogs` driver, pointing at a log group you also declare in the template.
   *Check:* the log group resource exists in the same stack with `RetentionInDays` set (unretained logs bill forever).
5. Add env vars via `Environment` and the secret via `Secrets`.
   *Check:* no plaintext secret in the template.
6. Deploy the stack.
   *Check:* `CREATE_COMPLETE`, and `aws ecs describe-task-definition --profile sandbox` shows revision 1.

**Day 3 — ECS service + rolling deployment**

1. Add an `AWS::ECS::Cluster` and an `AWS::ECS::Service` with `LaunchType: FARGATE`, `DesiredCount: 1`, your **private** subnets, `AssignPublicIp: DISABLED`, and the task SG from week 2.
   *Check:* the stack deploys and the service appears in the console. **Confirm your five VPC endpoints from Week 2 Day 4 are deployed first** — without them this task cannot pull its image and you'll get `CannotPullContainerError`. If you tore them down last night, redeploy `01` with `CreateVpcEndpoints=true`.
2. Attach `LoadBalancers` (target group ARN, container name, container port) and set `HealthCheckGracePeriodSeconds` to something realistic (60).
   *Check:* the target registers and turns `healthy`, and `curl https://<alb-dns>/healthz` returns 200 through the ALB.
3. Change one line of app source, rebuild, push under a **new** SHA tag, update the template's image, and deploy.
   *Check:* watch the service Events tab — you see the new task start, become healthy, then the old one drain. Zero failed requests if you curl in a loop during it.
4. Add `DeploymentConfiguration` with `DeploymentCircuitBreaker: { Enable: true, Rollback: true }`.
   *Check:* the setting shows on the service.
5. Deliberately deploy an image tag that doesn't exist.
   *Check:* the deployment fails and **automatically rolls back** to the previous task definition, with the service still serving traffic. That auto-rollback is the single most valuable ECS setting you'll turn on this week.

**Day 4 — Break it on purpose**

1. Ship an image that crashes on boot (e.g. exit 1 immediately). Deploy.
   *Check:* run `aws ecs describe-tasks --profile sandbox` on the stopped task and find `stoppedReason` and the container's `exitCode`. Write both down verbatim.
2. Ship an image that starts but fails its health check (make `/healthz` return 500).
   *Check:* the task stays **RUNNING** while the target group reports it `unhealthy` — a different failure from #1, and the distinction ECS newcomers miss.
3. During a deploy, watch the target group.
   *Check:* you can point at a target in state `draining` and say how long it stays there (`deregistration_delay`, default 300s) and why a too-long delay makes deploys feel stuck.
4. Enable `EnableExecuteCommand: true` on the service (and confirm the **task role** allows `ssmmessages:*`), redeploy, then shell into a *working* task: `aws ecs execute-command --interactive --command /bin/sh ...`.
   *Check:* you get a shell inside the container and can `printenv` your secret. If it fails with a target-not-connected error, it's the task role's SSM permissions.
5. Write the three-way discriminator in `runbook.md`: task **stopped** vs. task **unhealthy** vs. target **draining**.
   *Check:* each has a different place you look first (stopped-task reason / target group health / target group state).

**Day 5 — The scheduled job**

1. Register a second task definition for the Python job (its own log group, its own task role).
   *Check:* the job's task role has no ALB or ECR-beyond-execution permissions it doesn't need.
2. Run it once by hand: `aws ecs run-task --launch-type FARGATE ... --profile sandbox`.
   *Check:* the task runs to completion with `exitCode: 0` and its logs are in CloudWatch.
3. Create an EventBridge **Scheduler** schedule (`AWS::Scheduler::Schedule`) with a cron expression and an ECS `RunTask` target, plus the IAM role the scheduler needs to call ECS.
   *Check:* the schedule shows `ENABLED` with a next-invocation time.
4. Set the cron to a couple of minutes out and wait.
   *Check:* a task actually launches on schedule and logs. **If nothing runs, check the scheduler's IAM role first** — silent no-ops here are almost always permissions.
5. Run `./teardown.sh`, then check Cost Explorer.
   *Check:* zero stacks remain, and you can name this week's largest cost line.

**Done when:** you can deploy a new service from image → running behind the ALB with no reference material.

---

### PHASE 4 — INFRASTRUCTURE AS CODE (Weeks 6–7)

This is the heart of the plan. This stack lives in CloudFormation YAML.

#### Week 6 — CloudFormation fundamentals

**Theory:** Template anatomy (Parameters, Mappings, Conditions, Resources, Outputs); intrinsic functions (`!Ref`, `!GetAtt`, `!Sub`, `!ImportValue`, `!If`, `!FindInMap`); pseudo-parameters; `DependsOn`; cross-stack exports; `cfn-lint`.

**Read:** [CloudFormation User Guide, "Welcome"](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html) · [Intrinsic function reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference.html)

**Project:** Refactor everything you've built into a parameterized, multi-environment layered template set (`00-bootstrap` / `01-network-edge` / `02-data` / `03-compute`).

**Day 1 — Template anatomy and parameters**

1. In `runbook.md`, list the top-level template sections in order and what each is for: `Parameters`, `Mappings`, `Conditions`, `Resources`, `Outputs`.
   *Check:* you can name the only one that's mandatory (`Resources`).
2. Add a `Parameters` block to your VPC template: `EnvName` (with `AllowedValues: [dev, stage, prod]`) and `VpcCidr` (with a default).
   *Check:* `cfn-lint` passes and the deploy command now requires `--parameter-overrides EnvName=dev`.
3. Replace every hardcoded name in the template with `!Sub '${EnvName}-...'`.
   *Check:* no literal `dev` remains anywhere in the file. Grep for it.
4. Add an `Outputs` block exporting the VPC ID and both private subnet IDs.
   *Check:* `aws cloudformation describe-stacks --profile sandbox` shows the outputs after deploy.
5. Deploy with `EnvName=dev`.
   *Check:* `CREATE_COMPLETE`, and every resource name in the console is prefixed `dev-`.

**Day 2 — Intrinsic functions**

1. Replace one hardcoded ARN with `!Sub` using pseudo-parameters (`${AWS::AccountId}`, `${AWS::Region}`, `${AWS::StackName}`).
   *Check:* the deployed resource's ARN is identical to before — the refactor changed nothing observable.
2. Add a `Mappings` block keyed by environment (e.g. instance sizes or CIDRs) and read it with `!FindInMap`.
   *Check:* deploying with `EnvName=stage` picks up the stage values.
3. Add a `Conditions` block (`IsProd: !Equals [!Ref EnvName, prod]`) and attach `Condition: IsProd` to one resource.
   *Check:* deploy with `EnvName=dev` — the resource is **absent**. Deploy with `prod` — it appears. Verify both.
4. Now use the same mechanism for cost control: add a `CreateVpcEndpoints` parameter and gate all five VPC endpoints (and, if you built one, the NAT Gateway) behind a `Condition`.
   *Check:* `--parameter-overrides CreateVpcEndpoints=false` removes them in one deploy. This is the toggle the nightly teardown rule in Section 3 depends on — it turns "delete the expensive bits" into a one-line parameter change instead of a stack surgery.
5. Write down the difference between `!Ref` and `!GetAtt` for the same resource.
   *Check:* you can say what `!Ref` returns for a VPC vs. what `!GetAtt` gives you, and why the docs page for each resource type has a "Return values" section you'll live in.
6. Run `cfn-lint` on everything.
   *Check:* clean. Commit.

**Day 3 — Cross-stack references**

1. In your network stack, add `Export: { Name: !Sub '${EnvName}-VpcId' }` to the VPC output, and the same for the subnet outputs.
   *Check:* `aws cloudformation list-exports --profile sandbox` lists them.
2. In your compute stack, replace the hardcoded subnet IDs with `!ImportValue !Sub '${EnvName}-PrivateSubnetA'` (etc.). Deploy.
   *Check:* the compute stack deploys and the service still runs.
3. Now try to delete the **network** stack while compute is still up.
   *Check:* it **fails** with "Export ... cannot be deleted as it is in use by <stack>". Read that message carefully — it's the enforcement mechanism behind stack layering.
4. Try to *change* the exported value's name in the network stack.
   *Check:* also blocked. Write in `runbook.md`: exports are a one-way contract; renaming one is a two-deploy operation (add new → migrate consumers → remove old).
5. Delete compute first, then network.
   *Check:* both succeed, in that order only. That reverse order is what `teardown.sh` must encode.

**Day 4 — Split into four layered stacks**

1. Create the four files: `00-bootstrap.yaml` (S3 template bucket, ECR repo, shared IAM), `01-network-edge.yaml`, `02-data.yaml` (placeholder for now), `03-compute.yaml`.
   *Check:* four files, each lints clean, each takes `EnvName`.
2. **Deal with the ECR repo you created by hand in week 5.** You made it with `aws ecr create-repository`; `00-bootstrap.yaml` now declares the same repo. Deploying as-is fails with `Resource of type 'AWS::ECR::Repository' with identifier 'snip-api' already exists` — CloudFormation will not adopt a resource it didn't create. Pick one: (a) delete the repo and let CFN recreate it (you'll re-push your image), or (b) **import** it with `aws cloudformation create-change-set --change-set-type IMPORT --resources-to-import ...`.
   *Check:* `00-bootstrap` deploys clean and `describe-stack-resources` lists the ECR repo as stack-managed. Do (b) at least once — resource import is how you bring real, hand-made production resources under IaC, and it's a genuinely useful thing to have done.
3. Move each remaining resource into the file where it belongs.
   *Check:* nothing is duplicated across two files, and nothing was dropped — count your resources before and after.
4. Add a header comment to each file: what it owns, what it exports, what it imports.
   *Check:* the "imports" line of `03` matches the "exports" line of `01`, exactly.
5. Build a table in `runbook.md`: every Export name → the stack that produces it → the stack(s) that consume it.
   *Check:* no export is produced-but-never-consumed (delete it) and no import lacks a producer (that's a deploy failure waiting to happen).
6. Confirm the dependency direction only ever runs `00 → 01 → 02 → 03`.
   *Check:* no lower-numbered stack imports from a higher-numbered one. A cycle here means you can never tear down cleanly.

**Day 5 — Two environments from one template set**

1. Deploy all four in order with `EnvName=dev`, waiting for each to complete before the next.
   *Check:* four `CREATE_COMPLETE`s and a working app.
2. Write `deploy.sh` that encodes that order and waits.
   *Check:* the script fails fast if any stack fails, rather than plowing on.
3. Deploy the **same templates** with `EnvName=stage`.
   *Check:* a second, fully independent environment comes up with **zero template edits**. If you had to edit anything, that thing should have been a Parameter — fix it now.
4. Confirm the two environments are actually isolated.
   *Check:* stage's ALB DNS serves stage; `list-exports` shows two separate sets of prefixed exports; no name collisions.
5. Tear both down in reverse layer order (`03 → 02 → 01 → 00`), stage first.
   *Check:* clean deletes with no export-in-use errors. Update `teardown.sh` to match.

**Done when:** you can add a new resource to an existing stack, wire it via exports, and deploy it without breaking dependents.

#### Week 7 — CloudFormation operations (the debugging week)

**Theory:** Change sets; stack states; `UPDATE_ROLLBACK_FAILED` and `ContinueUpdateRollback`; `DeletionPolicy` / `UpdateReplacePolicy`; drift detection; nested stacks; replacement vs. in-place updates; stack policies.

**Read:** [Update stacks using change sets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html) · [Continue rolling back an update](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-continueupdaterollback.html) · [`DeletionPolicy` attribute](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-deletionpolicy.html) · [Drift detection](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html)

**Project:** A written recovery playbook, proven by doing each recovery yourself.

**Day 1 — Change sets**

1. Redeploy your `dev` environment so you have something to operate on.
   *Check:* all four stacks `CREATE_COMPLETE`.
2. Make a harmless template edit (add a tag), then create a change set instead of deploying: `aws cloudformation create-change-set --change-set-name t1 ... --profile sandbox`.
   *Check:* `describe-change-set` lists one change with `Action: Modify`.
3. Read the change's `ResourceChange` fields: `Action`, `Replacement`, and `Scope`.
   *Check:* `Replacement: False`. Execute the change set and confirm nothing was recreated.
4. Now make a **replacing** change (rename a resource's physical name, e.g. a security group's `GroupName`) and create another change set — **do not execute it**.
   *Check:* `Replacement: True`. This is the field that silently deletes and recreates a database. Memorize where to find it.
5. Delete that change set unexecuted.
   *Check:* the stack is untouched. Write in `runbook.md`: "before any prod update, read the change set and grep for `Replacement`."

**Day 2 — Failed update and automatic rollback**

1. Introduce a deliberately invalid property value (e.g. an out-of-range port or a bad instance type). Deploy.
   *Check:* the stack enters `UPDATE_ROLLBACK_IN_PROGRESS`, then `UPDATE_ROLLBACK_COMPLETE`, and the app still works on the old config.
2. Open the Events tab and scroll to the **bottom** of the failure block, then read upward.
   *Check:* you found the **first** `CREATE_FAILED`/`UPDATE_FAILED` event. Everything above it is consequence, not cause — same as reading a stack trace.
3. Copy that first failure's `ResourceStatusReason` verbatim into `runbook.md`.
   *Check:* it names a specific property, not a generic "resource failed".
4. Cause a second, different failure: a name collision (hardcode a resource name that already exists).
   *Check:* the reason string is clearly different from #1, and you can tell them apart at a glance.
5. Fix both and deploy clean.
   *Check:* `UPDATE_COMPLETE`.

**Day 3 — `UPDATE_ROLLBACK_FAILED` (the scary one)**

1. Pick a non-critical resource in a stack and **delete it out-of-band** in the console (that's the thing you'd normally never do — today you do it on purpose).
   *Check:* the resource is gone from AWS but still present in the template.
2. Trigger a stack update that fails.
   *Check:* rollback starts, then fails because it can't restore a resource that no longer exists → status `UPDATE_ROLLBACK_FAILED`.
3. Confirm the stack is now stuck.
   *Check:* a normal `deploy` is **rejected** outright. This is the state that causes real on-call panic — you're meeting it in safety.
4. Recover: `aws cloudformation continue-update-rollback --stack-name <name> --resources-to-skip <LogicalId> --profile sandbox`.
   *Check:* status becomes `UPDATE_ROLLBACK_COMPLETE`.
5. Reconcile: the skipped resource is now missing from reality but present in the template. Redeploy to recreate it.
   *Check:* `UPDATE_COMPLETE` and the resource exists again.
6. Write the whole recovery as a numbered runbook procedure, including the exact command.
   *Check:* a stranger could follow it under pressure without thinking.

**Day 4 — Drift**

1. Change something by hand in the console: add an inbound rule to a stack-managed security group.
   *Check:* the change is live in AWS.
2. Run drift detection: `aws cloudformation detect-stack-drift --stack-name <name> --profile sandbox`, then `describe-stack-resource-drifts`.
   *Check:* the stack reports `DRIFTED` and names that security group.
3. Read the drift detail's `PropertyDifferences`.
   *Check:* you can see expected vs. actual for the exact property.
4. Reconcile by removing the console change and re-running detection.
   *Check:* back to `IN_SYNC`. Note: redeploying the template does **not** always remove console additions — that's why drift detection exists as a separate tool.
5. Write one paragraph in `runbook.md` on why console changes are the enemy here.
   *Check:* your answer covers the failure mode where the next deploy silently reverts someone's emergency fix.

**Day 5 — `DeletionPolicy` and stateful resources**

1. Add `DeletionPolicy: Retain` to a stateful resource (an S3 bucket is a cheap stand-in for RDS this week).
   *Check:* the property is on the resource and the stack updates clean.
2. Delete the stack.
   *Check:* stack `DELETE_COMPLETE`, but the bucket **still exists**. That's the point.
3. Note the consequence: the retained resource is now unmanaged, and recreating the stack will collide on its name.
   *Check:* try it and read the collision error. This is the trap on the other side of `Retain`.
4. Read the docs on `DeletionPolicy: Snapshot` and note which resource types support it (RDS, ElastiCache, EBS, Redshift).
   *Check:* you can name what happens to the snapshot's cost after the stack is gone — **it keeps billing**.
5. Write the "how to safely change a stateful resource" runbook section: check the change set for `Replacement: True` → confirm `DeletionPolicy` → take a manual snapshot → then deploy.
   *Check:* four ordered steps, in that order.
6. Delete the retained bucket by hand and run `./teardown.sh`.
   *Check:* zero resources, zero orphaned snapshots.

**Done when:** a stack in a bad state is an annoyance, not an emergency.

---

### PHASE 5 — DATA & OBSERVABILITY (Weeks 8–9)

#### Week 8 — RDS Postgres, ElastiCache Redis, Secrets rotation

**Theory:** DB subnet groups, parameter groups, `max_connections`, connection pooling, Multi-AZ vs. read replicas, snapshots and PITR, maintenance windows, encryption at rest; ElastiCache node types and eviction policies; Secrets Manager rotation.

**Read:** [RDS User Guide: connecting to PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ConnectToPostgreSQLInstance.html) · [What is Amazon ElastiCache?](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/WhatIs.html) · [Set up rotation for RDS/Aurora secrets](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotate-secrets_turn-on-for-db.html)

**Project:** A private RDS Postgres + Redis, reachable only from your ECS service, with credentials from a rotating secret — wired into `snip`, replacing the in-memory map from week 4.

**Day 1 — Write the `02-data` stack**

1. Add an `AWS::RDS::DBSubnetGroup` referencing your **two private** subnets (imported from `01`).
   *Check:* private subnets only. A DB subnet group containing public subnets is how databases end up internet-reachable.
2. Add a database security group whose only inbound rule is `5432` **from the task security group** (SG reference, not CIDR).
   *Check:* one inbound rule, source `sg-...`.
3. Declare credentials as `AWS::SecretsManager::Secret` with a `GenerateSecretString` block and `RecoveryWindowInDays: 0` — never a template Parameter.
   *Check:* no password appears in the template, in `deploy.sh`, or in your shell history. The zero recovery window is what lets you rebuild this stack tomorrow under the same secret name (week 3 Day 3's trap).
4. Add the `AWS::RDS::DBInstance`: `db.t4g.micro`, `20` GB, `StorageEncrypted: true`, `PubliclyAccessible: false`, `MultiAZ: false`, credentials via dynamic reference to the secret.
   *Check:* `cfn-lint` clean, and `PubliclyAccessible` is explicitly `false`.
5. Add an `AWS::SecretsManager::SecretTargetAttachment` linking the secret to the instance.
   *Check:* you understand it's what fills in host/port in the secret — without it your app gets credentials with no address.
6. Don't deploy yet. Read the template once more for cost: instance class, storage, Multi-AZ, backup retention.
   *Check:* every one of those is at its smallest setting.

**Day 2 — Deploy RDS and connect from a task**

1. Deploy `02-data`.
   *Check:* `CREATE_COMPLETE` (this takes ~10 minutes — expect it). Status `available` in the RDS console.
2. Try to connect from your laptop: `psql -h <endpoint> -U postgres`.
   *Check:* it **hangs, then times out**. Understand exactly why: private subnets, no public route, SG allows only the task SG. This is correct behavior.
3. Retrieve the secret and confirm it now contains host, port, username, password.
   *Check:* `aws secretsmanager get-secret-value --secret-id ... --profile sandbox | jq -r .SecretString` shows all four fields.
4. Wire the API to build its connection string from the injected secret, redeploy the service.
   *Check:* the task starts and `/healthz` reports database connectivity.
5. Shell into the running task with ECS Exec and connect to the database from there.
   *Check:* you get a `psql` prompt from inside the VPC. Same database, different network position — that contrast is the whole lesson.
6. Persist a link through the API and read it back after a task restart.
   *Check:* the row survives — you're no longer in-memory.

**Day 3 — Connection limits**

1. From inside a task, run `SHOW max_connections;`.
   *Check:* you have the number (on `db.t4g.micro` it's small — low hundreds).
2. Find how many your app opens: check your pool settings, and query `SELECT count(*) FROM pg_stat_activity;`.
   *Check:* you can state connections-per-task × desired-count and compare it to the limit.
3. Deliberately exhaust it: scale the service up, or open a loop of connections from a shell.
   *Check:* you see `FATAL: remaining connection slots are reserved for non-replication superuser connections`. Copy it verbatim.
4. Note what the failure looks like from the *outside*.
   *Check:* the ALB returns 5xx while every task is `healthy` and the database is `available` — nothing is "down", yet the app is broken. That's why this incident is confusing in real life.
5. Fix it by bounding the pool, then confirm recovery.
   *Check:* errors stop without restarting the database.
6. Write the runbook entry: symptom → `pg_stat_activity` → pool math → fix.
   *Check:* it includes the arithmetic, not just "use a pool".

**Day 4 — Secrets rotation**

1. Turn on rotation for the DB secret (Secrets Manager → Rotation → the RDS rotation Lambda), interval 30 days.
   *Check:* rotation shows as enabled and the rotation function was created.
2. Trigger a rotation immediately: `aws secretsmanager rotate-secret --secret-id ... --profile sandbox`.
   *Check:* the secret's `VersionStages` show a new `AWSCURRENT` and the previous version as `AWSPREVIOUS`.
3. Watch your **already-running** task while this happens.
   *Check:* existing connections keep working (they authenticated already), but a task that restarts now picks up the new password. Confirm both halves.
4. Force the failure: make the app cache credentials at boot and never re-read them, then rotate twice (so `AWSPREVIOUS` is invalidated too).
   *Check:* new connections fail with an auth error while the task is otherwise healthy.
5. Write the two mitigations in `runbook.md`: re-read the secret on connection failure, or have the pipeline force a service restart after rotation.
   *Check:* you can say which one a deploy pipeline can do and which one only the app can do.

**Day 5 — Redis, snapshots, teardown**

1. Add ElastiCache (`AWS::ElastiCache::SubnetGroup` + `CacheCluster`, `cache.t4g.micro`, single node) with an SG allowing `6379` from the task SG only. Deploy.
   *Check:* status `available` and the endpoint appears in stack outputs.
2. Connect from a task with `redis-cli -h <endpoint>`.
   *Check:* `PING` → `PONG` from inside the VPC, and refused from your laptop.
3. Implement cache-aside on `GET /:code`: check Redis → miss → read Postgres → write to Redis with a TTL.
   *Check:* first request logs a miss, second logs a hit, and you can see the key with `redis-cli KEYS '*'`.
4. Take a manual RDS snapshot and restore it into a new instance.
   *Check:* the restored instance reaches `available` and contains your links. Then **delete the restored instance immediately** — it bills like any other.
5. Run `./teardown.sh`, including `02-data`.
   *Check:* all stacks gone.
6. Check for orphans: `aws rds describe-db-snapshots --snapshot-type manual --profile sandbox` and the EC2 → Elastic IPs page.
   *Check:* **zero manual snapshots**. Snapshots outlive their stacks and bill silently — this is the #1 way a sandbox quietly costs money.

**Done when:** "the app can't reach the database" is a 5-minute diagnosis: SG → subnet/route → credentials → connection limit → DNS.

#### Week 9 — Observability & the debugging loop

**This is the week that most directly serves your goal of debugging infrastructure problems.**

**Theory:** CloudWatch Logs, log groups/streams, retention; **Logs Insights query syntax**; metrics, dimensions, statistics; alarms and composite alarms; Container Insights; ALB access logs; structured logging.

**Read:** [CloudWatch Logs Insights query syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html)

**Project:** A dashboard + alarm set for `snip`, and a chaos drill log with 8 failures diagnosed from telemetry alone.

**Day 1 — Structured logs**

1. Redeploy `dev` end to end.
   *Check:* app serving through the ALB, database and cache connected.
2. Confirm the `awslogs` config on the task definition: log group, `awslogs-stream-prefix`, region.
   *Check:* in CloudWatch you can find a stream named `<prefix>/<container>/<task-id>` and map it back to a specific task.
3. Set `RetentionInDays: 3` on every log group in your templates.
   *Check:* no log group says "Never expire". Never-expire is a permanent, growing bill.
4. Change the API to log a single JSON object per request: timestamp, level, method, path, status, duration_ms, request_id.
   *Check:* raw log lines are valid JSON — paste one into `jq` and it parses.
5. Log the same `request_id` on every line for one request, including errors.
   *Check:* you can grep one id and see the full story of a request.

**Day 2 — Logs Insights**

1. Open Logs Insights on your API's log group and run the default query.
   *Check:* you get rows back. If not, your log group selection or time range is wrong before anything else can work.
2. Learn the six commands by writing one query using each: `fields`, `filter`, `parse`, `stats`, `sort`, `limit`.
   *Check:* six working queries, no syntax errors.
3. Write and **save** query 1 — errors by minute: `filter level="error" | stats count() by bin(1m)`.
   *Check:* it's in Saved queries with a name you'll recognize at 2am.
4. Save query 2 (p99 latency: `stats pct(duration_ms, 99) by bin(5m)`) and query 3 (5xx by path: `filter status >= 500 | stats count() by path`).
   *Check:* both return data when you generate traffic, and empty when you don't.
5. Save query 5 (DB connection errors: `filter @message like /connection/`).
   *Check:* it matches the connection-exhaustion errors you produced in week 8.
6. For query 4 — **task startup failures** — first understand why you can't just query for them: stopped-task reasons live in the **ECS API and EventBridge**, not in CloudWatch Logs. A task that dies before your code runs never writes a log line. Create an EventBridge rule matching `ECS Task State Change` events with a CloudWatch Logs target, then query *that* log group for `stoppedReason`.
   *Check:* kill a task and find its `stoppedReason` via Logs Insights. Five saved queries total. This is the gap that makes startup failures feel invisible — now they're searchable alongside everything else.
7. Time yourself answering "what was the slowest endpoint in the last hour?"
   *Check:* under 60 seconds using a saved query.

**Day 3 — Metrics, alarms, dashboard**

1. Create an SNS topic with your email subscription and **confirm the subscription email**.
   *Check:* the subscription status is `Confirmed`, not `PendingConfirmation`. Unconfirmed subscriptions are the reason "the alarm never fired".
2. Create an alarm on ALB `HTTPCode_Target_5XX_Count` > 5 in 5 minutes → SNS.
   *Check:* the alarm exists in `OK` state.
3. Create alarms on `UnHealthyHostCount` ≥ 1, `TargetResponseTime` p99, and ECS service CPU/memory utilization.
   *Check:* four alarms, each with a threshold you can justify out loud.
4. Force one alarm into `ALARM` for real (break the health endpoint for two minutes).
   *Check:* the state goes to `ALARM` **and the email arrives**. Both halves, or it doesn't count.
5. Build one dashboard with: request rate, 5xx count, p99 latency, healthy host count, CPU/memory, and the DB connection count.
   *Check:* one screen answers "is it up, is it fast, is it healthy".
6. Add the dashboard and alarms to your CloudFormation templates.
   *Check:* they survive a teardown/redeploy cycle.

**Day 4 — Chaos day**

Rules: break it, then **diagnose starting from CloudWatch and the console only** — no looking at what you just changed. Time each one. Restore before the next.

1. **OOM-killed task** — set task memory absurdly low.
   *Check:* you found exit code `137` in the stopped-task detail.
2. **Port mismatch** — task definition port ≠ app's listening port.
   *Check:* targets unhealthy, app logs clean, ALB 502/503.
3. **Missing secret** — point the `secrets` block at a nonexistent ARN.
   *Check:* `ResourceInitializationError` before any app log line exists.
4. **IAM denial at runtime** — strip an S3/Secrets permission from the task role.
   *Check:* running task, `AccessDenied` in app logs, principal ARN names the task role.
5. **DB unreachable** — remove the task-SG rule from the database SG.
   *Check:* connection timeout (not auth failure) in app logs — timeout means network, auth error means credentials.
6. **Failing health check** — make `/healthz` slow (30s) with a 10s health check timeout.
   *Check:* targets flap between healthy and unhealthy; you can name the grace period and timeout settings involved.
7. **Image pull failure** — deploy a tag that doesn't exist.
   *Check:* `CannotPullContainerError`, and the circuit breaker rolls the deploy back.
8. **Exhausted DB connections** — replay week 8 day 3.
   *Check:* `remaining connection slots are reserved`, everything "healthy".
   *Overall check:* all eight diagnosed from telemetry, each with a recorded time-to-diagnosis. Anything over 10 minutes is the entry that needs the most runbook work.

**Day 5 — The Debugging Playbook**

1. For each of the eight, write the Section 6 block: symptom → where it shows up → first check → likely causes in order → commands → fix → prevention.
   *Check:* eight complete blocks, no missing fields.
2. Make sure every entry has the **verbatim** error string you actually saw.
   *Check:* you could `Ctrl-F` an error message from a live incident and land on the right entry.
3. Add the *first command you'd run* to each entry.
   *Check:* eight commands, all copy-pasteable, all using `--profile sandbox`.
4. Build the top-level triage table at the head of the playbook: "task never started / started then died / running but erroring / can't reach it at all" → which entries to check.
   *Check:* the four branches route to distinct entries.
5. Re-run two chaos scenarios cold, using only the playbook.
   *Check:* the playbook alone got you there. Anywhere you had to improvise, fix the playbook — that gap *is* today's real work.
6. Tear down and commit.
   *Check:* zero resources; playbook committed.

**Done when:** you can go from "the site is down" to a named root cause using only CloudWatch, in under 10 minutes, for the eight scenarios above.

---

### PHASE 6 — DELIVERY (Weeks 10–11)

#### Week 10 — CircleCI

**Theory:** `config.yml` anatomy — jobs, steps, executors, workflows, filters; contexts and secrets; OIDC auth to AWS (vs. long-lived keys); caching; approval jobs; branch/tag filters; the promotion path.

**Read:** [CircleCI configuration reference](https://circleci.com/docs/reference/configuration-reference/) · [Using OpenID Connect tokens in jobs](https://circleci.com/docs/openid-connect-tokens/)

**Project:** A working pipeline in your repo: build → test → push to ECR → deploy to `dev` → **manual approval** → deploy to `stage`.

**Day 1 — The `config.yml` model**

1. Connect your GitHub repo to CircleCI and commit a `.circleci/config.yml` whose only job runs `echo hello`.
   *Check:* a green pipeline on CircleCI. **Get this trivial one green before anything else** — it proves the repo wiring, which is the most common day-1 blocker.
2. In `runbook.md`, define the four nouns in your own words: **job**, **step**, **executor**, **workflow**.
   *Check:* you can say which one is the unit of parallelism (jobs) and which is just a shell command (step).
3. Add a second job and a workflow that runs them in sequence with `requires`.
   *Check:* the CircleCI graph shows them chained, not parallel.
4. Add a branch filter so one job only runs on `main`.
   *Check:* push to a feature branch — that job is skipped; merge to `main` — it runs.
5. Map each job you'll eventually need onto your week-1 delivery diagram: build → test → push → deploy-dev → approve → deploy-stage.
   *Check:* six named jobs on the diagram, in order.

**Day 2 — Build and push to ECR**

1. Add a `build` job using a Docker executor with `setup_remote_docker`, doing checkout + `docker build`.
   *Check:* green, and the build log shows your Dockerfile steps.
2. Store temporary AWS credentials as a CircleCI **context** (you'll replace these with OIDC tomorrow — this is deliberately the throwaway version).
   *Check:* the job can run `aws sts get-caller-identity` and it prints your account.
3. Add ECR login + tag with `${CIRCLE_SHA1}` + push.
   *Check:* the image appears in ECR under the commit SHA. That SHA is now the link between a git commit and a running container.
4. Push a second commit.
   *Check:* two images in ECR with different SHA tags, and you can trace each back to its commit.
5. Confirm no image is tagged `latest` anywhere.
   *Check:* ECR shows only SHA tags.

**Day 3 — Tests, caching, and OIDC**

1. Add a `test` job that runs your unit tests, and make `build` require it.
   *Check:* break a test on purpose — the pipeline stops before building. Fix it; it proceeds.
2. Add dependency caching (`save_cache`/`restore_cache`) keyed on your lockfile's checksum.
   *Check:* second run logs a cache hit and is measurably faster.
3. In AWS, create an IAM **OIDC identity provider** for `oidc.circleci.com/org/<your-org-id>`.
   *Check:* the provider appears in IAM → Identity providers.
4. Create a `circleci-deploy` IAM role trusting that provider, with a condition on `aud` (your org id) and `sub` (your project).
   *Check:* the trust policy's condition is present. Without the `sub` condition, *any* project in your org could assume this role.
5. Replace the stored access keys with the CircleCI OIDC orb/token flow assuming that role, and **delete the long-lived keys**.
   *Check:* `aws sts get-caller-identity` in CI now returns `assumed-role/circleci-deploy/...`, and no AWS keys remain in CircleCI env vars.
6. Scope the role's permissions to only what the pipeline does (ECR push, S3 template upload, CloudFormation, `iam:PassRole` for your task roles).
   *Check:* remove one needed permission and watch the pipeline fail with a precise `AccessDenied` — then put it back.

**Day 4 — Environment promotion**

1. Parameterize a `deploy` job with an `env` parameter that runs your `deploy.sh` with `EnvName=<env>`.
   *Check:* one job definition, two invocations.
2. Add a step uploading your templates to the `00-bootstrap` S3 bucket before deploying.
   *Check:* the objects appear in S3 with the commit SHA in the key.
3. Wire `deploy-dev` into the workflow after `build`.
   *Check:* a push to `main` deploys to `dev` and the new SHA is actually running (`aws ecs describe-services` shows the new task definition).
4. Add a `type: approval` job, then `deploy-stage` requiring it.
   *Check:* the workflow **pauses** and shows a clickable approval button; nothing reaches stage until you click.
5. Approve it.
   *Check:* stage deploys from the identical templates and the identical image SHA. Same artifact promoted — not rebuilt.
6. Verify both environments are running the same SHA and are independently addressable.
   *Check:* two ALB DNS names, one image tag.

**Day 5 — Break the pipeline on purpose**

1. Remove the context from a job (or point it at a nonexistent one).
   *Check:* fails in the **CI log** at credential setup, before AWS is ever contacted.
2. Strip one IAM permission from the `circleci-deploy` role.
   *Check:* fails in the **CI log** with `AccessDenied` naming the assumed-role ARN and the exact action.
3. Break the cache key (change it to a constant) and note the effect.
   *Check:* stale dependencies get restored and the build behaves inconsistently between runs — the worst kind of CI bug because it's invisible in the log.
4. Push a new image but *don't* update the task definition's image tag.
   *Check:* the pipeline is **green** and the old code is still serving. Nothing failed — that's why this one is dangerous. Add a verification step that asserts the running task definition matches `CIRCLE_SHA1`.
5. Make a CloudFormation-level failure (bad property) reach the deploy job.
   *Check:* the CI log shows only "deploy failed"; the real reason is in **CFN Events**. Note that hop in your runbook.
6. Write the four-column table: failure → does CI go red? → where the real error lives → first command.
   *Check:* at least one row where CI is green but the deploy is wrong.

**Done when:** you can add a new service to the pipeline and promote it through environments unsupervised.

#### Week 11 — Step Functions, EventBridge & lifecycle workflows

**Theory:** Amazon States Language; Task/Choice/Parallel/Map/Wait states; retries, catchers, and error names; service integrations (CloudFormation, ECS, Lambda); execution history; EventBridge rules vs. EventBridge Scheduler.

**Read:** [Amazon States Language](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-amazon-states-language.html) · [EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html)

**Project:** A state machine that deploys a CloudFormation stack, waits for completion, and rolls back on failure — a miniature deployment orchestrator.

**Day 1 — ASL basics**

1. In Workflow Studio, build a three-state machine: `Pass` → `Choice` → two `Pass` outcomes. Run it.
   *Check:* a successful execution with a green graph, and you can see which branch it took.
2. Read the generated ASL JSON and identify `StartAt`, each state's `Type`, and `Next`/`End`.
   *Check:* you can trace the whole flow by reading `Next` pointers alone.
3. Change the input JSON so the `Choice` takes the other branch.
   *Check:* the graph shows the other path. Input shape drives control flow — that's the model.
4. Rewrite the same machine as `AWS::StepFunctions::StateMachine` in CloudFormation and deploy it.
   *Check:* the CFN-created machine produces an identical execution result to the console-built one.
5. Delete the console-built one.
   *Check:* only the template-managed machine remains — from here, everything is IaC.

**Day 2 — Retries and catchers**

1. Add a `Task` state invoking something that can fail (a small Lambda, or an SDK integration with a bad parameter). Run it.
   *Check:* the execution fails and the graph shows the failing state in red.
2. Open the execution's **Events** view and find the exact error name (e.g. `States.TaskFailed`) and cause.
   *Check:* you can read the input and output of every individual state — this view is the state machine's stack trace.
3. Add `Retry` with `IntervalSeconds`, `BackoffRate`, `MaxAttempts` on a specific error name.
   *Check:* the event history shows multiple attempts with widening gaps.
4. Add `Catch` routing that error to a `Fail` state with a useful message.
   *Check:* the execution ends in your named failure state, not an unhandled crash.
5. Write down the distinction between retrying `States.TaskFailed` and retrying a specific application error.
   *Check:* you can say why blanket-retrying everything is dangerous for a deploy.

**Day 3 — Deploying a stack from the state machine**

1. Add a state that uploads/references your template in the `00-bootstrap` S3 bucket and calls CloudFormation `CreateStack`/`UpdateStack` via the AWS SDK integration.
   *Check:* a stack actually starts creating when you run an execution.
2. Give the state machine's IAM role only the CloudFormation, S3, and `iam:PassRole` permissions it needs.
   *Check:* an execution fails cleanly with `AccessDenied` if you remove one — and you can tell which.
3. Add a wait loop: `DescribeStacks` → `Choice` on status → `Wait 30s` → loop, exiting on a terminal status.
   *Check:* the execution stays running until the stack finishes, then completes. **The SDK call returns immediately** — without this loop the machine reports success while the stack is still creating, which is the subtle bug here.
4. Handle the `UPDATE_COMPLETE` / `CREATE_COMPLETE` / `*_FAILED` / `*_ROLLBACK_COMPLETE` statuses explicitly.
   *Check:* run it against a template you know will fail — the machine detects failure rather than looping forever.
5. Add a `Wait` cap or `MaxAttempts` so a hung stack can't loop indefinitely.
   *Check:* you can state the maximum wall-clock time an execution can take.

**Day 4 — Rollback branch and re-runs**

1. Add a failure branch: on a failed stack status, publish to your SNS topic with the stack name and the failure reason.
   *Check:* you receive the email with the actual `ResourceStatusReason`, not a generic message.
2. Add a rollback action on that branch (`ContinueUpdateRollback`, or delete a failed `CREATE`).
   *Check:* the stack ends in a recoverable state after a deliberately failed execution.
3. Re-run the same execution input on an already-succeeded stack.
   *Check:* it succeeds with no changes ("No updates are to be performed" handled gracefully, not treated as failure). That's idempotency — verify it, don't assume it.
4. In `runbook.md`, list each state as idempotent or not, and what a mid-execution retry would do at each point.
   *Check:* you identified at least one state where a blind retry would be wrong.
5. Kill an execution halfway and restart it.
   *Check:* you know what got left behind and how you'd clean it up — that's the "safely re-run a failed execution" skill.

**Day 5 — Scheduled job, properly**

1. Move the week-5 EventBridge schedule into CloudFormation with a `FlexibleTimeWindow` and its own IAM role.
   *Check:* the schedule deploys from the template and shows a next-invocation time.
2. Add an SQS **dead-letter queue** to the schedule's target config.
   *Check:* the DLQ exists and is referenced by the schedule.
3. Break the target (bad task definition ARN) and let it fire.
   *Check:* a message lands in the DLQ. Without this you'd have a job that just silently stops running.
4. Add a CloudWatch alarm on DLQ `ApproximateNumberOfMessagesVisible` > 0 → SNS.
   *Check:* the alarm fires and you get the email.
5. Fix the target and confirm a clean scheduled run.
   *Check:* the job runs on schedule, logs, exits 0, DLQ empty.
6. `./teardown.sh`, then check for orphans (queues, schedules, log groups, snapshots).
   *Check:* zero of each.

**Done when:** a failed lifecycle workflow execution is something you can read, explain, and safely re-run.

---

### PHASE 7 — EDGE, IDENTITY & CAPSTONE (Week 12)

#### Week 12 — Edge/security + capstone

**Theory:** Route 53 hosted zones and record types; ACM certificate issuance and DNS validation; ALB HTTPS listeners and redirects; WAFv2 web ACLs, managed rule groups, rate limits; OIDC/OAuth basics and how an identity provider fits in front of an API.

**Read:** [ACM DNS validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html) · [AWS WAF Developer Guide](https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html)

**Project:** **Capstone** — `snip` as a complete miniature platform, deployed only by pipeline, on a real domain over HTTPS.

**Day 1 — Route 53 + ACM + HTTPS**

1. Confirm the domain you registered during week 11 (see Section 3) is active, with a hosted zone.
   *Check:* `dig NS yourdomain.com` returns the AWS nameservers. **If it doesn't, stop** — nothing else today can work, and registration is not something you can rush. If you skipped the week-11 prerequisite, register now and do Day 2 (WAF, which needs no domain) while you wait.
2. Request an ACM certificate for `yourdomain.com` + `*.yourdomain.com` with **DNS validation**, in the **same region as your ALB**.
   *Check:* status `Pending validation` with CNAME records shown. (A cert in the wrong region can't attach to your ALB — this catches people.)
3. Create the validation CNAME records in the hosted zone.
   *Check:* the certificate flips to `Issued` (usually minutes).
4. Add an HTTPS listener on `:443` to the ALB with the cert, forwarding to your target group.
   *Check:* `curl https://app.yourdomain.com/healthz` returns 200 with a valid chain — no `-k` needed.
5. Change the `:80` listener to a **redirect** action to `:443` (301).
   *Check:* `curl -I http://app.yourdomain.com` returns `301` with an `https://` Location.
6. Add an alias A record pointing your subdomain at the ALB.
   *Check:* the domain resolves to the ALB and serves your app.

**Day 2 — WAFv2**

1. Create a WebACL (`AWS::WAFv2::WebACL`, scope `REGIONAL`) with the `AWSManagedRulesCommonRuleSet` managed group in **count** mode first.
   *Check:* it deploys and associates with the ALB without blocking your own traffic.
2. Send a request that trips a managed rule (e.g. an obvious SQL-injection string in a query parameter).
   *Check:* the request still succeeds (count mode) but the rule shows a match in the WAF metrics.
3. Switch the managed group to **block**.
   *Check:* the same request now returns `403` from the ALB, before it ever reaches your task — confirm your app logs show nothing.
4. Add a rate-limit rule (e.g. 100 requests per 5 minutes per IP).
   *Check:* a `for` loop of curls eventually gets 403s, then recovers after the window.
5. Enable WAF logging to CloudWatch Logs and find your own blocked request.
   *Check:* you can see the matched rule name and the offending field in the log entry.
6. Confirm normal traffic is unaffected.
   *Check:* your app still works from a browser. **Ship WAF in count mode first, always** — that's the runbook note.

**Day 3 — Identity concepts**

1. Sketch the OIDC flow end to end: user → identity provider → redirect with code → token exchange → token presented to your API.
   *Check:* every arrow labeled; you can name what travels on each.
2. Draw where the identity provider sits relative to the ALB and your API, and mark which component validates the token.
   *Check:* you can say what changes if the ALB validates it versus if your app does.
3. Write what "the token is invalid" means at each hop: expired, wrong audience, wrong issuer, bad signature, clock skew.
   *Check:* five distinct causes with a different fix each.
4. *(Optional, if time)* Add a Cognito user pool and put one endpoint behind ALB authentication.
   *Check:* an unauthenticated request redirects to the hosted login; an authenticated one reaches the API.
5. Add the sketch to `runbook.md`.
   *Check:* committed.

**Day 4 — Capstone: full deploy from scratch, by pipeline only**

1. Tear everything down so you start from an empty account.
   *Check:* zero stacks, zero ALBs, zero databases.
2. Trigger the pipeline from a **fresh commit** and let it build `00 → 01 → 02 → 03` for `dev`.
   *Check:* the whole environment comes up **without you running a single AWS CLI command by hand**. Any manual step you had to take is a bug — fix it in the templates or the pipeline and re-run.
3. Approve the gate and let it deploy `stage`.
   *Check:* two environments, same templates, same image SHA.
4. Verify the checklist below item by item against the running system.
   *Check:* every box ticked from observation, not from memory.
5. Run your eight chaos scenarios cold against `dev`, timing each with only the playbook.
   *Check:* 8/8 diagnosed. Any that took over 10 minutes gets its runbook entry rewritten tonight.

**Day 5 — Writeup and teardown**

1. Write `README.md`: what the platform is, both architecture diagrams, how to deploy it, how to tear it down.
   *Check:* someone who's never seen the repo could deploy it into their own account from the README alone.
2. Clean up the runbook: consistent formatting, 25–40 entries, every entry with a verbatim error string and a first command.
   *Check:* count them.
3. Add a short "what I'd do differently / what's deliberately out of scope" section.
   *Check:* it names Kubernetes, Terraform (week 13), and multi-account — showing the omissions were choices.
4. Run `./teardown.sh` and verify zero billable resources, including snapshots, Elastic IPs, and log groups.
   *Check:* Cost Explorer trends to ~$0 over the following days (domain registration aside).
5. Make the repo public and re-read it as a stranger would.
   *Check:* the front page shows diagrams, not a wall of YAML.

**Capstone definition of done** — a single sandbox environment, created only from templates in your repo and deployed only by CircleCI, containing:

- [ ] Layered stacks named `00-bootstrap` / `01-network-edge` / `02-data` / `03-compute`
- [ ] VPC with public + private subnets, ALB with HTTPS + WAF, and VPC endpoints giving private tasks egress with no NAT
- [ ] `snip` on Fargate in private subnets, reading a secret and querying private RDS Postgres
- [ ] Redis on ElastiCache used for one cached endpoint
- [ ] The Python job as a scheduled ECS task
- [ ] Pipeline: build → ECR → templates to S3 → Step Function deploys the stack
- [ ] Two environments from the same templates, with an approval gate between them
- [ ] Dashboard + at least 4 alarms
- [ ] A `runbook.md` covering all eight chaos scenarios
- [ ] A `teardown.sh` that leaves zero billable resources
- [ ] A `README.md` with both architecture diagrams — this is the front page of your portfolio piece

---

### Weeks 13–14 (optional) — Consolidation & marketability

| Week | Focus |
|---|---|
| 13 | **Terraform crossover.** Re-implement your `01-network-edge` stack in Terraform. Learn state, providers, modules, `plan`/`apply`, and how it differs from CFN change sets. You now have the same platform in *both* IaC tools — a strong interview signal and the most requested IaC skill on the market. |
| 14 | **Cost, hardening, and gaps.** Cost Explorer by service; right-sizing Fargate tasks; log retention policies; least-privilege review of every role. Re-run your Week 9 chaos drills cold and time yourself. Write a short blog post / repo writeup — "I built and debugged an AWS container platform from scratch" — as the capstone of the portfolio. |

---

## 6. The runbook you're building

Create `runbook.md` on Day 1 and append to it daily. Structure:

```
## <Symptom, exactly as a user or alarm would report it>
**Where it shows up:** (CI log / CFN events / ECS events / ALB metrics / app logs)
**First check:**
**Likely causes, in order:**
**Commands:**
**Fix:**
**How to prevent:**
```

By week 12 this should have 25–40 entries. It is worth more than any certificate — it's the document that turns "I did a course" into "I can operate this stack," and it's the thing an interviewer will actually be impressed by.

---

## 7. Debugging playbook — the eight scenarios to master

Master these and you cover the overwhelming majority of real incidents on this kind of stack.

| # | Symptom | Where to look first | Usual causes |
|---|---|---|---|
| 1 | Task never starts (`CannotPullContainerError`) | ECS stopped-task reason | Execution role missing ECR perms; no NAT/VPC endpoint from private subnet; bad image tag |
| 2 | Task starts then immediately exits | CloudWatch app logs; exit code | Missing env var/secret; crash on boot; wrong command; OOM (code 137) |
| 3 | ALB 503 | Target group health | No healthy targets; task not registered; SG blocks ALB→task |
| 4 | ALB 502 | Target group + app logs | App bound to `127.0.0.1` not `0.0.0.0`; port mismatch; app crashed mid-request |
| 5 | Health check flapping | Target group settings + app | Grace period too short; health path slow or requires auth; app slow to warm |
| 6 | App can't reach Postgres | SG rules, then app logs | Task SG not allowed on RDS SG; wrong subnet/route; rotated credentials; connection limit exhausted |
| 7 | `AccessDenied` at runtime | The error's own principal ARN | Task role (not execution role) missing the action; resource ARN too narrow; missing condition key |
| 8 | Deploy fails / stack stuck | CFN Events, bottom-up, first failure | Invalid property; name collision; export in use; resource requiring replacement; `UPDATE_ROLLBACK_FAILED` |

For each, your runbook should contain the *exact* CLI command you'd run first.

---

## 8. Concept → project map

Use this to connect every week's theory back to something you build yourself.

| What you build | What you learn from it | Covered in |
|---|---|---|
| `00-bootstrap` stack | Account/S3/ECR/IAM prerequisites; why bootstrap is separate | Week 6 |
| `01-network-edge` stack | VPC, subnets, ALB, WAFv2, Route 53, ACM, CloudWatch | Weeks 2, 12 |
| `02-data` stack | RDS, subnet groups, Secrets Manager | Week 8 |
| `03-compute` stack | ECS cluster, task definitions, services, roles, log config | Weeks 3, 5 |
| Step Functions deploy machine | Lifecycle workflows that deploy a stack and roll back | Week 11 |
| `.circleci/config.yml` | Build, ECR push, template sync, promotion, approvals, OIDC | Week 10 |
| `docker-compose.yml` | Local Postgres + Redis + API topology | Week 4 |
| Multi-stage `Dockerfile` | Small, reproducible container builds | Week 4 |
| Terraform re-implementation | Second IaC tool for marketability | Week 13 |

---

## 9. Milestones

| After | You can... | Self-test |
|---|---|---|
| Week 3 | Reason about network paths and IAM failures | Diagnose a 503 and an `AccessDenied` from logs alone |
| Week 5 | Deploy a container to Fargate behind an ALB | Ship a new service end-to-end in one hour |
| Week 7 | Own CloudFormation changes safely | Recover a stack from `UPDATE_ROLLBACK_FAILED` unaided |
| Week 9 | Debug production-style incidents | 8/8 chaos scenarios diagnosed from telemetry |
| Week 11 | Operate the delivery pipeline | Promote a change dev → stage with approval; re-run a failed state machine |
| Week 12 | Deploy and support the platform | Capstone complete, torn down cleanly, and public on GitHub |

---

## 10. Cost guardrails (check every Friday)

- Budget alert at $20/month; review Cost Explorer by service weekly.
- Biggest sandbox cost traps, in order: **NAT Gateway**, **RDS left running**, **ALB left running**, **ElastiCache**, **unretained CloudWatch logs**, **orphaned EBS/snapshots/Elastic IPs**.
- Prefer: `db.t4g.micro`, smallest Fargate task sizes, single AZ in sandbox, VPC endpoints instead of NAT where possible, 3-day log retention.
- `teardown.sh` every Friday, then verify in the console that nothing survived.

---

## 11. Sources — stick to primary docs

Every week above has its own **Read:** line linking straight to the pages for that week. This table is the same links, gathered in one place by topic, in case you want to look something up out of order or a link above goes stale (search the bolded title on `docs.aws.amazon.com` / the vendor's own docs site and you'll find wherever it moved to).

| Topic | Read |
|---|---|
| VPC networking | [VPC CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html) · [Security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html) |
| IAM | [Policies and permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html) · [IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html) · [ARN format](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html) |
| ECS / Fargate | [ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html) · [Task execution role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html) · [Task role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html) · [Rolling deployments & circuit breaker](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-ecs.html) · [ECS Exec](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html) |
| CloudFormation | [User Guide](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html) · [Intrinsic functions](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference.html) · [Resource & property types reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-template-resource-type-ref.html) · [Change sets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html) · [Continue rolling back an update](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-continueupdaterollback.html) · [`DeletionPolicy`](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-deletionpolicy.html) · [Drift detection](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html) |
| RDS / ElastiCache / Secrets | [Connecting to RDS PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ConnectToPostgreSQLInstance.html) · [What is ElastiCache?](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/WhatIs.html) · [Rotate RDS/Aurora secrets](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotate-secrets_turn-on-for-db.html) |
| CloudWatch | [Logs Insights query syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html) |
| Step Functions / EventBridge | [Amazon States Language](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-amazon-states-language.html) · [EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html) |
| Route 53 / ACM / WAF | [ACM DNS validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html) · [AWS WAF Developer Guide](https://docs.aws.amazon.com/waf/latest/developerguide/waf-chapter.html) |
| CircleCI | [Configuration reference](https://circleci.com/docs/reference/configuration-reference/) · [OpenID Connect tokens](https://circleci.com/docs/openid-connect-tokens/) |
| Docker | [Dockerfile best practices](https://docs.docker.com/build/building/best-practices/) |
| AWS Well-Architected | [Operational Excellence pillar](https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html) |

Avoid tutorial aggregators and video courses for this stack — they'll teach you Kubernetes and Terraform-first workflows, which aren't the focus here. (Come back to Terraform deliberately in week 13.)
