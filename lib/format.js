import { basename } from 'path'

const COMPLEXITY_EMOJI = { Green: '🟢', Yellow: '🟡', Red: '🔴' }

export function toMarkdown(result, inputFile) {
  const e = result.explanation
  const lines = []

  const title = inputFile
    ? `Business Logic Explainer: ${basename(inputFile)}`
    : 'Business Logic Explainer'
  lines.push(`# ${title}`, '')

  if (e.complexity) {
    const emoji = COMPLEXITY_EMOJI[e.complexity.rating] ?? ''
    lines.push(`**Complexity:** ${emoji} ${e.complexity.rating} — ${e.complexity.reason}`, '')
  }

  if (e.summary) {
    lines.push('## Summary', '', e.summary, '')
  }

  if (e.business_rules?.length) {
    lines.push('## Business Rules', '')
    e.business_rules.forEach((rule, i) => lines.push(`${i + 1}. ${rule}`))
    lines.push('')
  }

  if (e.dependencies) {
    const d = e.dependencies
    lines.push('## Dependencies', '')
    if (d.reads_from?.length) lines.push(`**Reads from:** ${d.reads_from.join(', ')}`)
    if (d.writes_to?.length)  lines.push(`**Writes to:** ${d.writes_to.join(', ')}`)
    if (d.external?.length) {
      lines.push('', '**External:**')
      d.external.forEach(ext => lines.push(`- ${ext}`))
    }
    lines.push('')
  }

  if (e.migration_risks?.length) {
    lines.push('## Migration Risks', '')
    e.migration_risks.forEach(risk => lines.push(`- ⚠ ${risk}`))
    lines.push('')
  }

  return lines.join('\n')
}

export function toSql(result) {
  const m = result.dbt_model
  const parts = []
  if (m.header_comment) parts.push(m.header_comment)
  if (m.sql) parts.push(m.sql)
  return parts.join('\n\n') + '\n'
}
