#!/usr/bin/env node
import 'dotenv/config'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs'
import { resolve, basename, extname, join } from 'path'
import { Command } from 'commander'
import { analyze } from '../lib/analyze.js'
import { toMarkdown, toSql } from '../lib/format.js'

const program = new Command()

program
  .name('codecollab')
  .description('AI-powered SQL migration tool — analyze stored procedures and generate dbt models')
  .version('0.1.0')

program
  .command('analyze <file>')
  .description('Analyze a stored procedure and output a business logic explainer + dbt model')
  .option('-d, --dialect <dialect>', 'SQL dialect: T-SQL, PL/SQL, or Other SQL', 'T-SQL')
  .option('-o, --out <dir>', 'Output directory (default: same directory as input file)')
  .option('-m, --model <model>', 'OpenRouter model ID to use')
  .action(async (file, opts) => {
    const apiKey = process.env.OPENROUTER_API_KEY ?? process.env.VITE_OPENROUTER_API_KEY
    if (!apiKey) {
      console.error('Error: OPENROUTER_API_KEY is not set. Add it to your .env file or environment.')
      process.exit(1)
    }

    const model = opts.model
      ?? process.env.OPENROUTER_MODEL
      ?? process.env.VITE_OPENROUTER_MODEL
      ?? 'anthropic/claude-sonnet-4-5'

    const inputPath = resolve(file)
    if (!existsSync(inputPath)) {
      console.error(`Error: File not found: ${inputPath}`)
      process.exit(1)
    }

    const sql = readFileSync(inputPath, 'utf8')
    const baseName = basename(inputPath, extname(inputPath))
    const outDir = resolve(opts.out ?? inputPath.slice(0, inputPath.length - basename(inputPath).length))

    if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true })

    console.log(`\nAnalyzing ${basename(inputPath)} [${opts.dialect}]...`)
    const start = Date.now()

    try {
      const result = await analyze(sql, opts.dialect, apiKey, model)

      const mdPath = join(outDir, `${baseName}_explanation.md`)
      writeFileSync(mdPath, toMarkdown(result, inputPath))

      const sqlFilename = result.dbt_model?.filename ?? `${baseName}_dbt.sql`
      const sqlPath = join(outDir, sqlFilename)
      writeFileSync(sqlPath, toSql(result))

      const elapsed = ((Date.now() - start) / 1000).toFixed(1)
      console.log(`\n✓ Done in ${elapsed}s\n`)
      console.log(`  Business logic: ${mdPath}`)
      console.log(`  dbt model:      ${sqlPath}\n`)
    } catch (err) {
      console.error(`\nAnalysis failed: ${err.message}`)
      process.exit(1)
    }
  })

program
  .command('serve')
  .description('Start the CodeCollab REST API server')
  .option('-p, --port <port>', 'Port to listen on', '3001')
  .action(async (opts) => {
    const { startServer } = await import('../server/index.js')
    startServer(parseInt(opts.port, 10))
  })

program.parse()
