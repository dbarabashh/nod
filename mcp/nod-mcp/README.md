# @nod/mcp

> **Legacy connector.** New installations move to the official hosted ChatGPT
> and Claude connectors at [hellonod.app/connectors](https://hellonod.app/connectors).
> Existing `nod_pat_` credentials remain usable during the published 90-day
> migration window and can still be revoked in Nod Settings.

Connect your **Nod** meetings, recaps and transcripts to **Claude**, **ChatGPT**,
**Gemini**, and any other MCP-capable client — so you can ask your AI about a
meeting instead of copy-pasting transcripts into it.

It's a thin [Model Context Protocol](https://modelcontextprotocol.io) server. All
data access, authentication and per-user scoping happen server-side in Nod's
`connect` API; this process only formats results. Access is **read-only** and
**revocable**.

## Tools

| Tool | What it does |
|------|--------------|
| `list_meetings` | Most recent meetings (titles, dates, ids) |
| `get_meeting` | One meeting's recap/summary by id |
| `get_transcript` | A meeting's full speaker-labelled transcript by id |
| `search_meetings` | Search meetings by title/summary |

## Easiest: connect from the Nod app

**Settings → Connections → pick your client → Connect.** For Claude Desktop and
the Gemini CLI, Nod writes the config for you (token included) — just restart the
client. No terminal, no paths. This is the path for non-technical users.

This PAT-based setup is retained for existing installations only. The official
hosted connectors use OAuth 2.1, require no copied token, expose the same
read-only meeting data, and can be revoked at
[hellonod.app/oauth/authorized-apps](https://hellonod.app/oauth/authorized-apps).

## Manual setup

The server is published to npm, so no build or absolute paths are needed — it
runs via `npx`. It reads two env vars:

- `NOD_MCP_TOKEN` — **required**, your `nod_pat_…` token (Settings → Connections).
- `NOD_CONNECT_URL` — optional, override the API endpoint (the sandbox URL for a
  Debug build). Defaults to production.

### Claude Code

```sh
claude mcp add nod --env NOD_MCP_TOKEN=nod_pat_xxx -- npx -y @nod/mcp
```

### Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "nod": {
      "command": "npx",
      "args": ["-y", "@nod/mcp"],
      "env": { "NOD_MCP_TOKEN": "nod_pat_xxx" }
    }
  }
}
```

### ChatGPT (desktop, Developer Mode)

Enable **Settings → Connectors → Advanced → Developer mode**, then add a local
MCP server with command `npx`, args `-y @nod/mcp`, and the `NOD_MCP_TOKEN` env var.

### Gemini CLI

`~/.gemini/settings.json` — same `mcpServers.nod` block as Claude Desktop above.

## Local development

Working on the server itself? Build and link it so `npx`/clients resolve your
local copy instead of the published package:

```sh
cd mcp/nod-mcp
npm install
npm run build      # → dist/index.js
npm link           # makes `@nod/mcp` resolvable locally
```

To publish a new version: `npm publish --access public`.

## Use it

> "List my latest Nod meetings."
> "Summarise the transcript of my standup from yesterday."

## Revoke

Revoke a token any time in **Settings → Connections**. The next request with it
returns `401`.
