# Why We Adopted Scion Instead of Building Our Own Agent Orchestrator

*A plain-language summary for non-technical readers. One page, no jargon.*

## What we are trying to do

We want to run **many AI coding assistants at the same time** - for a whole team, in the cloud, safely, with people able to step in and guide them. Picture a workshop where dozens of AI "workers" each pick up a task, work in their own isolated space, and report back, while managers keep oversight and control.

## The tempting shortcut, and why it falls short

The obvious idea is: "Capable AI coding tools already exist - like Claude Code. Let's just run a lot of them."

The catch is that those tools are built for **one person, on one laptop, doing one thing at a time.** On their own they have no notion of:

- multiple users, and who is allowed to do what;
- running safely side by side without interfering with each other;
- remembering where things stood if a machine restarts;
- messaging between an AI and a human, or between AIs;
- monitoring what the whole fleet is doing;
- recovering on its own when something crashes.

## The hard, invisible part

To turn "a local AI tool" into "a platform our whole team uses in the cloud," someone has to build all of the above: a central system that manages identities, permissions, isolation, communication, monitoring, and recovery across the entire fleet of agents.

This is the genuinely hard, months-long engineering work. And, crucially, **it has almost nothing to do with which AI you use.** It is shared infrastructure that every serious team needs, no matter the vendor.

## What Scion already is

Scion is exactly that platform, ready-made. Out of the box it provides:

- **Multi-user access** with team roles and permissions;
- **Isolated cloud execution** - each agent in its own protected space;
- **Coordination and human-in-the-loop** - including chat through Telegram;
- **Monitoring and logs** across all agents at once;
- **Automatic recovery** when an agent or its machine fails.

In short, the expensive plumbing is already solved.

## Not locked to one AI vendor

Scion treats the AI tool itself as a **replaceable part.** Claude is only one of several it supports (Gemini, Codex, and others). If a better model appears tomorrow, we swap it in - we are not betting the entire platform on a single vendor.

## The honest trade-offs

Scion is early-stage (alpha), and some capabilities are still maturing - for example, automatic quality-scoring of agent output, high-availability database options, and lowering the cost of idle agents. But these are **known items on its roadmap**, not dead ends. Building our own would mean first re-solving everything Scion already does, and then still facing the very same remaining items.

## Bottom line

Adopting Scion lets us **get the hard platform layer for free, plug in whichever AI we prefer, and spend our time on our actual product** instead of rebuilding cloud infrastructure that thousands of other teams also need. Building from scratch would cost months, duplicate already-solved work, and tie us to one vendor - for no real advantage.
