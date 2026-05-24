import { SYSTEM_PROMPT } from './prompt.js'

export async function analyze(sql, dialect, apiKey, model = 'anthropic/claude-sonnet-4-5') {
  const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://github.com/grabowskit/code-collab',
      'X-Title': 'CodeCollab SQL Migration Explainer',
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: `Dialect: ${dialect}\n\n${sql}` },
      ],
    }),
  })

  if (!response.ok) {
    const text = await response.text()
    throw new Error(`OpenRouter API error ${response.status}: ${text}`)
  }

  const data = await response.json()
  const content = data.choices[0].message.content
  const stripped = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()

  try {
    return JSON.parse(stripped)
  } catch {
    throw new Error(`AI response could not be parsed as JSON.\n\nRaw response:\n${content}`)
  }
}
