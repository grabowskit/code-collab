import express from 'express'
import { analyze } from '../lib/analyze.js'
import { toMarkdown, toSql } from '../lib/format.js'

export function startServer(port = 3001) {
  const app = express()
  app.use(express.json({ limit: '1mb' }))

  const apiKey = process.env.OPENROUTER_API_KEY ?? process.env.VITE_OPENROUTER_API_KEY
  const defaultModel =
    process.env.OPENROUTER_MODEL ?? process.env.VITE_OPENROUTER_MODEL ?? 'anthropic/claude-sonnet-4-5'

  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', model: defaultModel, hasApiKey: Boolean(apiKey) })
  })

  app.post('/analyze', async (req, res) => {
    const { sql, dialect = 'T-SQL', model = defaultModel } = req.body ?? {}

    if (!sql?.trim()) {
      return res.status(400).json({ error: '"sql" field is required' })
    }

    if (!apiKey) {
      return res.status(500).json({ error: 'OPENROUTER_API_KEY is not configured on the server' })
    }

    try {
      const result = await analyze(sql, dialect, apiKey, model)
      res.json({
        result,
        explanation_md: toMarkdown(result),
        dbt_sql: toSql(result),
        dbt_filename: result.dbt_model?.filename,
      })
    } catch (err) {
      res.status(500).json({ error: err.message })
    }
  })

  app.listen(port, () => {
    console.log(`\nCodeCollab API server listening on http://localhost:${port}`)
    console.log(`  POST /analyze   { sql, dialect?, model? }`)
    console.log(`  GET  /health\n`)
  })

  return app
}

// Allow running directly: node server/index.js
if (process.argv[1].endsWith('server/index.js')) {
  const { default: dotenv } = await import('dotenv')
  dotenv.config()
  startServer(parseInt(process.env.PORT ?? '3001', 10))
}
