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

  app.post('/feature-request', async (req, res) => {
    const { title, problem, solution, context, files, github_username, ai_review } = req.body ?? {}

    if (!title?.trim() || !problem?.trim() || !solution?.trim()) {
      return res.status(400).json({ error: 'title, problem, and solution are required' })
    }

    const githubToken = process.env.GITHUB_TOKEN
    if (!githubToken) {
      return res.status(500).json({ error: 'GITHUB_TOKEN is not configured on the server' })
    }

    const repo = process.env.GITHUB_REPO || 'grabowskit/code-collab'
    const [owner, repoName] = repo.split('/')
    const username = github_username?.trim() || 'code-collab-web'

    const ghHeaders = {
      Authorization:  `Bearer ${githubToken}`,
      Accept:         'application/vnd.github.v3+json',
      'Content-Type': 'application/json',
      'User-Agent':   'CodeCollab/1.0',
    }

    // Build issue body
    const filesSection = files?.length
      ? '**Attached Files**\n\n' + files.map(f =>
          `<details>\n<summary>📄 ${f.name}</summary>\n\n\`\`\`sql\n${f.content}\n\`\`\`\n</details>`
        ).join('\n\n')
      : ''

    const aiSection = ai_review?.trim()
      ? `<details>\n<summary>🤖 AI Review</summary>\n\n${ai_review.trim()}\n\n</details>`
      : ''

    const bodyParts = [
      '## 🚀 Feature Request',
      '',
      '### Problem',
      problem.trim(),
      '',
      '### Proposed Solution',
      solution.trim(),
      context?.trim() ? `\n### Additional Context\n${context.trim()}` : null,
      filesSection    ? `\n---\n\n${filesSection}` : null,
      aiSection       ? `\n---\n\n${aiSection}`    : null,
      '',
      '---',
      `*Submitted via [CodeCollab](https://github.com/grabowskit/code-collab) · @${username}*`,
    ]

    const body = bodyParts.filter(p => p !== null).join('\n')

    // Ensure the "feature request" label exists (ignore 422 = already exists)
    await fetch(`https://api.github.com/repos/${owner}/${repoName}/labels`, {
      method: 'POST', headers: ghHeaders,
      body: JSON.stringify({ name: 'feature request', color: '0075ca', description: 'New feature or request' }),
    }).catch(() => {})

    try {
      const issueRes = await fetch(`https://api.github.com/repos/${owner}/${repoName}/issues`, {
        method: 'POST', headers: ghHeaders,
        body: JSON.stringify({ title: title.trim(), body, labels: ['feature request'] }),
      })

      if (!issueRes.ok) {
        const err = await issueRes.json()
        return res.status(issueRes.status).json({ error: err.message || 'GitHub API error' })
      }

      const issue = await issueRes.json()
      res.json({ issue_url: issue.html_url, issue_number: issue.number })
    } catch (err) {
      res.status(500).json({ error: err.message })
    }
  })

  app.listen(port, () => {
    console.log(`\nCodeCollab API server listening on http://localhost:${port}`)
    console.log(`  POST /analyze          { sql, dialect?, model? }`)
    console.log(`  POST /feature-request  { title, problem, solution, context?, files?, github_username?, ai_review? }`)
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
