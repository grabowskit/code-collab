<p align="center">
  <img src="public/favicon.svg" width="72" height="72" alt="CodeCollab">
</p>

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
| `VITE_OPENROUTER_API_KEY` | Your OpenRouter API key (required by the web UI) | — |
| `VITE_OPENROUTER_MODEL` | Model used by the web UI | `anthropic/claude-sonnet-4-5` |
| `OPENROUTER_API_KEY` | Your OpenRouter API key (used by the CLI and API server) | Falls back to `VITE_OPENROUTER_API_KEY` |
| `OPENROUTER_MODEL` | Model used by the CLI and API server | Falls back to `VITE_OPENROUTER_MODEL` |

Any model available on [OpenRouter](https://openrouter.ai/models) can be used — results will vary by model.

## CLI

Analyze a stored procedure from the command line and write two output files: a Markdown business logic explainer and a `.sql` dbt model.

```bash
# Analyze a file — outputs to the same directory as the input by default
node bin/codecollab.js analyze examples/tsql/tsql_01_process_sales_order.sql

# Specify dialect and output directory
node bin/codecollab.js analyze procedure.sql --dialect PL/SQL --out ./output

# Use a different model
node bin/codecollab.js analyze procedure.sql --model openai/gpt-4o
```

**Options**

| Flag | Description | Default |
|---|---|---|
| `--dialect` | SQL dialect: `T-SQL`, `PL/SQL`, or `Other SQL` | `T-SQL` |
| `--out` | Output directory for generated files | Same directory as input file |
| `--model` | OpenRouter model ID | Value of `OPENROUTER_MODEL` env var |

**Output files**

- `{filename}_explanation.md` — plain-English summary, business rules, dependencies, migration risks, and complexity rating
- `{model_name}.sql` — fully annotated dbt model with named CTEs (filename suggested by the AI)

```
✓ Done in 9.1s

  Business logic: ./output/tsql_01_process_sales_order_explanation.md
  dbt model:      ./output/process_sales_order.sql
```

## REST API

Run a local API server to integrate CodeCollab analysis into your own tooling.

```bash
# Start the server (default port 3001)
node bin/codecollab.js serve

# Or specify a port
node bin/codecollab.js serve --port 8080

# Or run the server file directly
node server/index.js
```

### `POST /analyze`

Analyze a stored procedure and return structured results.

**Request**

```json
{
  "sql": "CREATE PROCEDURE usp_example AS BEGIN ... END",
  "dialect": "T-SQL",
  "model": "anthropic/claude-sonnet-4-5"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `sql` | string | yes | The stored procedure or SQL script to analyze |
| `dialect` | string | no | `T-SQL`, `PL/SQL`, or `Other SQL` (default: `T-SQL`) |
| `model` | string | no | OpenRouter model ID (default: `OPENROUTER_MODEL` env var) |

**Response**

```json
{
  "result": { ... },
  "explanation_md": "# Business Logic Explainer\n...",
  "dbt_sql": "{{ config(...) }}\n\nwith ...",
  "dbt_filename": "process_sales_order.sql"
}
```

| Field | Description |
|---|---|
| `result` | Full structured JSON — explanation, business rules, dependencies, risks, complexity, and dbt model |
| `explanation_md` | The business logic explainer rendered as a Markdown string |
| `dbt_sql` | The dbt model SQL including the header comment block |
| `dbt_filename` | Suggested filename for the dbt model |

**Example**

```bash
curl -X POST http://localhost:3001/analyze \
  -H 'Content-Type: application/json' \
  -d '{
    "sql": "CREATE PROCEDURE usp_example AS BEGIN SELECT 1 END",
    "dialect": "T-SQL"
  }'
```

### `GET /health`

Returns server status and configured model.

```bash
curl http://localhost:3001/health
# { "status": "ok", "model": "anthropic/claude-sonnet-4-5", "hasApiKey": true }
```

## Example procedures

The `examples/` directory contains 30 real-world stored procedures for testing, organized by dialect:

```
examples/
  tsql/         10 T-SQL (SQL Server) procedures
  plsql/        10 PL/SQL (Oracle) procedures and triggers
  postgresql/   10 PostgreSQL plpgsql procedures
```

Domains covered: order processing, payroll, inventory management, financial close, CRM lead scoring, sales commissions, AR aging, SLA monitoring, data archival, pricing engine, GL journal posting, HR headcount, revenue recognition, credit scoring, AP payment runs, SOX audit logging, ETL staging, A/B testing, cohort analysis, and GDPR data retention.

To run a batch of examples through the CLI:

```bash
for f in examples/tsql/*.sql; do
  node bin/codecollab.js analyze "$f" --dialect T-SQL --out ./output/tsql
done
```

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
