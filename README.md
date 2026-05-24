# CodeCollab SQL Migration Explainer

> **Phase 1 Prototype** — AI-powered SQL migration pipeline

## What is CodeCollab?

CodeCollab is an AI-powered data engineering tool designed to help enterprise teams understand, document, and migrate legacy database code. The platform automates the most time-consuming parts of SQL migration projects: reverse-engineering business logic from stored procedures, mapping data dependencies, and generating modern dbt-compatible SQL models.

## What this prototype demonstrates

This Phase 1 prototype demonstrates the core analysis loop:

1. **Paste a legacy stored procedure** (T-SQL, PL/SQL, or other SQL dialects)
2. **Click "Analyze & Convert"** — the AI reads the procedure and extracts:
   - A plain-English summary of what the procedure does
   - Specific business rules with actual thresholds, conditions, and column values
   - Data dependency mapping (reads from / writes to / external dependencies)
   - Migration risks flagged for engineers
   - Complexity rating (Green / Yellow / Red)
3. **Get a dbt SQL model** — a fully annotated, named-CTE dbt model ready for review and refinement

## Setup

### Prerequisites

- Node.js 18+ and npm
- An [OpenRouter](https://openrouter.ai) account and API key

### Install and run

```bash
# Clone the repo
git clone https://github.com/grabowskit/code-collab.git
cd code-collab

# Install dependencies
npm install

# Set up environment variables
cp .env.example .env
# Edit .env and add your VITE_OPENROUTER_API_KEY

# Start the dev server
npm run dev
```

Then open [http://localhost:5173](http://localhost:5173) in your browser.

### Environment variables

| Variable | Description | Default |
|---|---|---|
| `VITE_OPENROUTER_API_KEY` | Your OpenRouter API key (required) | — |
| `VITE_OPENROUTER_MODEL` | The model to use for analysis | `anthropic/claude-sonnet-4-5` |

## Supported models

Set `VITE_OPENROUTER_MODEL` in your `.env` to any of these OpenRouter model IDs:

| Model | ID |
|---|---|
| Claude Sonnet 4.5 (default) | `anthropic/claude-sonnet-4-5` |
| Claude Opus 4 | `anthropic/claude-opus-4` |
| GPT-4o | `openai/gpt-4o` |
| Gemini 2.5 Pro | `google/gemini-2.5-pro` |

## Tech stack

- **Vite + React** — frontend framework
- **Tailwind CSS** — styling
- **highlight.js** — SQL syntax highlighting (github-dark theme)
- **OpenRouter** — unified AI model gateway
- **Google Fonts** — Inter (UI) + JetBrains Mono (code)

## What's NOT in this prototype

This Phase 1 prototype intentionally excludes: file upload, batch processing, save/export, user accounts, database connections, mobile optimization, and multi-step pipeline UI. These are planned for future phases.

---

*Phase 1 Preview · Powered by OpenRouter*
