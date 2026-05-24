import { useState, useEffect, useRef } from 'react'
import { SYSTEM_PROMPT, FEATURE_REQUEST_REVIEW_PROMPT } from '../lib/prompt.js'

const DEMO_PROCEDURES = {
  'T-SQL': `CREATE PROCEDURE usp_calculate_order_status AS
BEGIN
    IF OBJECT_ID('tempdb..#order_base') IS NOT NULL DROP TABLE #order_base;

    SELECT
        o.order_id,
        o.customer_id,
        o.order_date,
        o.total_amount,
        o.status,
        NULL AS risk_flag,
        NULL AS lifetime_value_tier
    INTO #order_base
    FROM dbo.orders o
    WHERE o.order_date >= DATEADD(month, -3, GETDATE());

    UPDATE #order_base
    SET risk_flag = 'HIGH'
    WHERE total_amount > 10000
       OR customer_id IN (
           SELECT customer_id FROM dbo.fraud_watchlist WHERE active = 1
       );

    UPDATE #order_base
    SET risk_flag = 'LOW'
    WHERE risk_flag IS NULL;

    UPDATE o
    SET o.lifetime_value_tier =
        CASE
            WHEN ch.total_lifetime_value >= 50000 THEN 'PLATINUM'
            WHEN ch.total_lifetime_value >= 10000 THEN 'GOLD'
            WHEN ch.total_lifetime_value >= 1000  THEN 'SILVER'
            ELSE 'BRONZE'
        END
    FROM #order_base o
    JOIN dbo.customer_history ch ON o.customer_id = ch.customer_id;

    INSERT INTO dbo.enriched_orders SELECT * FROM #order_base;
END`,

  'PL/SQL': `CREATE OR REPLACE PROCEDURE usp_enrich_order_summary IS
    CURSOR c_orders IS
        SELECT o.order_id, o.customer_id, o.order_date,
               o.total_amount, o.status
        FROM orders o
        WHERE o.order_date >= ADD_MONTHS(SYSDATE, -3);

    v_risk_flag       VARCHAR2(10);
    v_lifetime_tier   VARCHAR2(10);
    v_lifetime_value  NUMBER;
    v_watchlist_count NUMBER;
BEGIN
    FOR rec IN c_orders LOOP
        SELECT COUNT(*) INTO v_watchlist_count
        FROM fraud_watchlist fw
        WHERE fw.customer_id = rec.customer_id AND fw.active = 1;

        IF rec.total_amount > 10000 OR v_watchlist_count > 0 THEN
            v_risk_flag := 'HIGH';
        ELSE
            v_risk_flag := 'LOW';
        END IF;

        SELECT NVL(total_lifetime_value, 0) INTO v_lifetime_value
        FROM customer_history
        WHERE customer_id = rec.customer_id;

        IF v_lifetime_value >= 50000 THEN
            v_lifetime_tier := 'PLATINUM';
        ELSIF v_lifetime_value >= 10000 THEN
            v_lifetime_tier := 'GOLD';
        ELSIF v_lifetime_value >= 1000 THEN
            v_lifetime_tier := 'SILVER';
        ELSE
            v_lifetime_tier := 'BRONZE';
        END IF;

        INSERT INTO enriched_orders (
            order_id, customer_id, order_date,
            total_amount, status, risk_flag, lifetime_value_tier
        ) VALUES (
            rec.order_id, rec.customer_id, rec.order_date,
            rec.total_amount, rec.status, v_risk_flag, v_lifetime_tier
        );
    END LOOP;

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END usp_enrich_order_summary;`,

  'Other SQL': `CREATE OR REPLACE PROCEDURE calculate_churn_risk()
LANGUAGE plpgsql
AS $$
DECLARE
    v_cutoff_date DATE := CURRENT_DATE - INTERVAL '90 days';
BEGIN
    DROP TABLE IF EXISTS staging_churn_candidates;

    CREATE TEMP TABLE staging_churn_candidates AS
    SELECT
        c.customer_id,
        c.email,
        c.created_at,
        MAX(o.order_date)              AS last_order_date,
        COUNT(o.order_id)              AS total_orders,
        COALESCE(SUM(o.total_amount), 0) AS total_spend
    FROM customers c
    LEFT JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY c.customer_id, c.email, c.created_at;

    INSERT INTO churn_risk_scores (
        customer_id, email, churn_score, risk_band, scored_at
    )
    SELECT
        s.customer_id,
        s.email,
        CASE
            WHEN s.last_order_date < v_cutoff_date AND s.total_orders > 3 THEN 0.85
            WHEN s.last_order_date < v_cutoff_date                        THEN 0.60
            WHEN s.total_spend < 100                                       THEN 0.40
            ELSE 0.15
        END AS churn_score,
        CASE
            WHEN s.last_order_date < v_cutoff_date AND s.total_orders > 3 THEN 'HIGH'
            WHEN s.last_order_date < v_cutoff_date                        THEN 'MEDIUM'
            WHEN s.total_spend < 100                                       THEN 'LOW'
            ELSE 'MINIMAL'
        END AS risk_band,
        NOW()
    FROM staging_churn_candidates s
    ON CONFLICT (customer_id) DO UPDATE
        SET churn_score = EXCLUDED.churn_score,
            risk_band   = EXCLUDED.risk_band,
            scored_at   = EXCLUDED.scored_at;
END;
$$;`,
}


const LOADING_MESSAGES = [
  'Reading procedure...',
  'Identifying business rules...',
  'Mapping dependencies...',
  'Assessing migration complexity...',
  'Building CodeCollab SQL model...',
  'Annotating translation decisions...',
]

// Load all example SQL files at build time via Vite glob import
const EXAMPLE_MODULES = import.meta.glob('../examples/**/*.sql', { query: '?raw', import: 'default', eager: true })

const FOLDER_TO_DIALECT = { tsql: 'T-SQL', plsql: 'PL/SQL', postgresql: 'Other SQL' }

function formatExampleLabel(filename) {
  return filename
    .replace('.sql', '')
    .replace(/^(tsql|plsql|pg)_\d+_/, '')
    .split('_')
    .map(w => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ')
}

const EXAMPLES = Object.entries(EXAMPLE_MODULES)
  .map(([path, content]) => {
    const parts = path.split('/')
    const folder = parts[parts.length - 2]
    const filename = parts[parts.length - 1]
    return {
      path,
      content,
      dialect: FOLDER_TO_DIALECT[folder] || 'T-SQL',
      folder,
      filename,
      label: formatExampleLabel(filename),
    }
  })
  .sort((a, b) => a.filename.localeCompare(b.filename))

function detectDialect(sql) {
  // PostgreSQL: most distinctive markers
  if (/LANGUAGE\s+PLPGSQL/i.test(sql) || /\$\$/.test(sql) ||
      /\bGENERATE_SERIES\b/i.test(sql) || /\bJSONB\b/i.test(sql) ||
      /ON CONFLICT/i.test(sql)) return 'Other SQL'
  // Oracle PL/SQL
  const u = sql.toUpperCase()
  if (['SYSDATE', 'DBMS_', 'UTL_FILE', 'SYS_CONTEXT', '%ROWTYPE',
       'CONNECT BY', 'PRAGMA ', 'ADD_MONTHS', 'MONTHS_BETWEEN',
       'BULK COLLECT', 'FORALL', 'NVL(', 'DECODE('].some(k => u.includes(k)) ||
      /\bDUAL\b/.test(u)) return 'PL/SQL'
  return 'T-SQL'
}

const COMPLEXITY_STYLES = {
  Green: { bg: '#dcfce7', text: '#166534' },
  Yellow: { bg: '#fef9c3', text: '#854d0e' },
  Red: { bg: '#fee2e2', text: '#991b1b' },
}

function GitHubIcon() {
  return (
    <svg height="20" width="20" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  )
}

function Header({ onFeatureRequest }) {
  return (
    <header style={{ backgroundColor: '#0d1117' }} className="px-6 py-4">
      <div className="max-w-7xl mx-auto flex items-center justify-between">
        <div className="flex items-center gap-3">
          <img src="/favicon.svg" alt="CodeCollab logo" width="32" height="32" />
          <div>
            <span className="text-white font-semibold text-xl tracking-tight">CodeCollab</span>
            <p className="text-gray-400 text-xs mt-0.5">AI Migration Pipeline — Phase 1 Preview</p>
          </div>
        </div>
        <div className="flex items-center gap-5">
          <button
            onClick={onFeatureRequest}
            className="text-gray-300 hover:text-white transition-colors text-sm font-medium"
          >
            Feature Requests
          </button>
          <a
            href="https://github.com/grabowskit/code-collab"
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-2 text-gray-300 hover:text-white transition-colors text-sm"
          >
            <GitHubIcon />
            <span>View on GitHub</span>
          </a>
        </div>
      </div>
    </header>
  )
}

const STEP_LABELS = ['Title', 'Problem', 'Solution', 'Review & Submit']

function FeatureRequestModal({ onClose }) {
  const [step, setStep]           = useState(1)
  const [title, setTitle]         = useState('')
  const [problem, setProblem]     = useState('')
  const [solution, setSolution]   = useState('')
  const [context, setContext]     = useState('')
  const [files, setFiles]         = useState([])
  const [username, setUsername]   = useState('')
  const [aiReview, setAiReview]   = useState('')
  const [reviewing, setReviewing] = useState(false)
  const [reviewError, setReviewError] = useState(null)
  const [submitting, setSubmitting]   = useState(false)
  const [submitted, setSubmitted]     = useState(null)
  const [submitError, setSubmitError] = useState(null)
  const fileInputRef  = useRef(null)
  const reviewRanRef  = useRef(false)

  const apiKey = import.meta.env.VITE_OPENROUTER_API_KEY
  const model  = import.meta.env.VITE_OPENROUTER_MODEL || 'anthropic/claude-sonnet-4-5'
  const apiUrl = import.meta.env.VITE_API_URL || 'http://localhost:3001'

  // Escape to close
  useEffect(() => {
    function onKey(e) { if (e.key === 'Escape' && !submitting) onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [submitting])

  // Auto-run AI review the first time step 4 loads
  useEffect(() => {
    if (step !== 4 || reviewRanRef.current) return
    reviewRanRef.current = true
    runReview()
  }, [step])

  async function runReview() {
    if (!apiKey) { setReviewError('No OpenRouter API key configured.'); return }
    setReviewing(true)
    setReviewError(null)
    setAiReview('')
    try {
      const prompt = FEATURE_REQUEST_REVIEW_PROMPT
        .replace('{{title}}',    title)
        .replace('{{problem}}',  problem)
        .replace('{{solution}}', solution)
        .replace('{{context}}',  context.trim() || 'None provided')
      const res  = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          Authorization:  `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://github.com/grabowskit/code-collab',
          'X-Title':      'CodeCollab Feature Request Review',
        },
        body: JSON.stringify({ model, messages: [{ role: 'user', content: prompt }] }),
      })
      const data = await res.json()
      setAiReview(data.choices[0].message.content)
    } catch {
      setReviewError('AI review unavailable. You can still submit without it.')
    } finally {
      setReviewing(false)
    }
  }

  function rerunReview() {
    reviewRanRef.current = false
    runReview()
    reviewRanRef.current = true
  }

  function handleFileAdd(e) {
    Array.from(e.target.files).forEach(file => {
      const reader = new FileReader()
      reader.onload = ev =>
        setFiles(prev => [...prev, { name: file.name, content: ev.target.result }])
      reader.readAsText(file)
    })
    e.target.value = ''
  }

  async function handleSubmit() {
    setSubmitting(true)
    setSubmitError(null)
    try {
      const res = await fetch(`${apiUrl}/feature-request`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title, problem, solution, context,
          files,
          github_username: username.trim() || 'code-collab-web',
          ai_review: aiReview,
        }),
      })
      if (!res.ok) {
        const err = await res.json()
        throw new Error(err.error || 'Failed to create issue')
      }
      setSubmitted(await res.json())
    } catch (err) {
      setSubmitError(err.message)
    } finally {
      setSubmitting(false)
    }
  }

  const canAdvance = step === 1 ? title.trim().length > 0
                   : step === 2 ? problem.trim().length > 0
                   : step === 3 ? solution.trim().length > 0
                   : true

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      style={{ backgroundColor: 'rgba(0,0,0,0.65)' }}
      onClick={e => { if (e.target === e.currentTarget && !submitting) onClose() }}
    >
      <div
        className="bg-white rounded-lg border border-gray-200 w-full shadow-2xl flex flex-col"
        style={{ maxWidth: '540px', maxHeight: '92vh' }}
      >
        {/* Modal header */}
        <div className="px-6 py-4 border-b border-gray-100 flex items-center justify-between flex-shrink-0">
          <h2 className="font-semibold text-gray-900">Feature Request</h2>
          {!submitted && (
            <button
              onClick={onClose}
              disabled={submitting}
              className="text-gray-400 hover:text-gray-600 transition-colors text-lg leading-none"
              aria-label="Close"
            >✕</button>
          )}
        </div>

        {/* Step progress */}
        {!submitted && (
          <div className="px-6 pt-5 pb-2 flex-shrink-0">
            <div className="flex items-start">
              {STEP_LABELS.map((label, i) => {
                const s       = i + 1
                const done    = s < step
                const current = s === step
                return (
                  <div key={s} className={`flex items-center ${i < STEP_LABELS.length - 1 ? 'flex-1' : ''}`}>
                    <div className="flex flex-col items-center">
                      <div className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-semibold border-2 transition-all ${
                        done    ? 'bg-blue-600 border-blue-600 text-white'
                               : current ? 'border-blue-600 text-blue-600 bg-white'
                                         : 'border-gray-200 text-gray-400 bg-white'
                      }`}>
                        {done ? '✓' : s}
                      </div>
                      <span className={`text-xs mt-1 whitespace-nowrap ${current ? 'text-blue-600 font-medium' : 'text-gray-400'}`}>
                        {label}
                      </span>
                    </div>
                    {i < STEP_LABELS.length - 1 && (
                      <div className={`flex-1 h-0.5 mx-2 mb-5 transition-colors ${done ? 'bg-blue-600' : 'bg-gray-200'}`} />
                    )}
                  </div>
                )
              })}
            </div>
          </div>
        )}

        {/* Body */}
        <div className="px-6 py-5 overflow-y-auto flex-1 font-sans">

          {submitted ? (
            <div className="text-center py-8">
              <div className="w-14 h-14 rounded-full bg-green-100 flex items-center justify-center mx-auto mb-4">
                <span className="text-green-600 text-2xl">✓</span>
              </div>
              <h3 className="font-semibold text-gray-900 text-lg mb-1">Issue #{submitted.issue_number} created!</h3>
              <p className="text-sm text-gray-500 mb-6">Your feature request has been submitted to GitHub.</p>
              <a
                href={submitted.issue_url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg text-sm font-medium text-white"
                style={{ backgroundColor: '#2563eb' }}
              >
                View on GitHub →
              </a>
            </div>

          ) : step === 1 ? (
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1.5">
                What would you like to request?
              </label>
              <p className="text-xs text-gray-400 mb-3">Give your feature a short, descriptive title.</p>
              <input
                type="text"
                value={title}
                onChange={e => setTitle(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter' && canAdvance) setStep(2) }}
                placeholder="e.g. Batch processing for multiple SQL files"
                autoFocus
                className="w-full border border-gray-200 rounded-md px-3 py-2.5 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
              />
            </div>

          ) : step === 2 ? (
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1.5">
                What problem does this solve?
              </label>
              <p className="text-xs text-gray-400 mb-3">Describe the pain point or limitation you're experiencing.</p>
              <textarea
                value={problem}
                onChange={e => setProblem(e.target.value)}
                placeholder="e.g. I have 50+ stored procedures to migrate. Running the tool one file at a time is tedious and slow..."
                rows={6}
                autoFocus
                className="w-full border border-gray-200 rounded-md px-3 py-2.5 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-y"
              />
            </div>

          ) : step === 3 ? (
            <div className="space-y-5">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1.5">
                  How should it work?
                </label>
                <p className="text-xs text-gray-400 mb-3">Describe your ideal solution.</p>
                <textarea
                  value={solution}
                  onChange={e => setSolution(e.target.value)}
                  placeholder="e.g. Add a --batch flag to the CLI that accepts a directory path and processes all .sql files inside it..."
                  rows={4}
                  autoFocus
                  className="w-full border border-gray-200 rounded-md px-3 py-2.5 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-y"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1.5">
                  Additional context <span className="text-gray-400 font-normal">(optional)</span>
                </label>
                <textarea
                  value={context}
                  onChange={e => setContext(e.target.value)}
                  placeholder="Links, examples, or anything else that would help..."
                  rows={2}
                  className="w-full border border-gray-200 rounded-md px-3 py-2.5 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-y"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Attach files <span className="text-gray-400 font-normal">(optional)</span>
                </label>
                <p className="text-xs text-gray-400 mb-2">SQL files will be included as code blocks in the issue.</p>
                {files.length > 0 && (
                  <ul className="mb-2 space-y-1">
                    {files.map((f, i) => (
                      <li key={i} className="flex items-center justify-between px-3 py-1.5 bg-gray-50 rounded border border-gray-200 text-xs">
                        <span className="text-gray-700 font-mono truncate">📄 {f.name}</span>
                        <button
                          onClick={() => setFiles(prev => prev.filter((_, j) => j !== i))}
                          className="text-gray-400 hover:text-red-500 ml-2 flex-shrink-0"
                        >✕</button>
                      </li>
                    ))}
                  </ul>
                )}
                <button
                  onClick={() => fileInputRef.current.click()}
                  className="text-sm text-blue-600 hover:text-blue-700 font-medium"
                >+ Add file</button>
                <input
                  ref={fileInputRef}
                  type="file"
                  multiple
                  accept=".sql,.txt,.pls,.prc,.pkb"
                  style={{ display: 'none' }}
                  onChange={handleFileAdd}
                />
              </div>
            </div>

          ) : (
            /* Step 4 — AI Review & Submit */
            <div className="space-y-5">
              <div>
                <div className="flex items-center justify-between mb-1.5">
                  <label className="text-sm font-medium text-gray-700">🤖 AI Review</label>
                  {!reviewing && (
                    <button
                      onClick={rerunReview}
                      className="text-xs text-blue-600 hover:text-blue-700 font-medium"
                    >Re-run</button>
                  )}
                </div>
                <p className="text-xs text-gray-400 mb-2">Review is editable — adjust before submitting.</p>

                {reviewing ? (
                  <div className="flex items-center gap-3 py-5 px-4 bg-gray-50 rounded-md border border-gray-200">
                    <div className="flex gap-1">
                      {[0, 1, 2].map(i => (
                        <div
                          key={i}
                          className="w-1.5 h-1.5 rounded-full bg-blue-500 animate-bounce"
                          style={{ animationDelay: `${i * 150}ms` }}
                        />
                      ))}
                    </div>
                    <span className="text-sm text-gray-500">Reviewing your request with AI...</span>
                  </div>
                ) : reviewError ? (
                  <div className="px-3 py-2.5 bg-amber-50 border border-amber-200 rounded-md">
                    <p className="text-xs text-amber-700">{reviewError}</p>
                  </div>
                ) : (
                  <textarea
                    value={aiReview}
                    onChange={e => setAiReview(e.target.value)}
                    rows={9}
                    className="w-full border border-gray-200 rounded-md px-3 py-2.5 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 font-mono resize-y"
                    placeholder="AI review will appear here..."
                  />
                )}
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1.5">
                  Your GitHub username <span className="text-gray-400 font-normal">(optional)</span>
                </label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 text-sm select-none">@</span>
                  <input
                    type="text"
                    value={username}
                    onChange={e => setUsername(e.target.value)}
                    placeholder="your-github-handle"
                    className="w-full border border-gray-200 rounded-md pl-7 pr-3 py-2.5 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  />
                </div>
                <p className="text-xs text-gray-400 mt-1">Defaults to @code-collab-web if left blank.</p>
              </div>

              {submitError && (
                <div className="px-3 py-2.5 bg-red-50 border border-red-200 rounded-md">
                  <p className="text-xs text-red-700">{submitError}</p>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer nav */}
        {!submitted ? (
          <div className="px-6 py-4 border-t border-gray-100 flex items-center justify-between flex-shrink-0">
            <button
              onClick={() => step > 1 ? setStep(s => s - 1) : onClose()}
              disabled={submitting}
              className="px-4 py-2 text-sm font-medium text-gray-600 hover:text-gray-800 transition-colors disabled:opacity-50"
            >
              {step === 1 ? 'Cancel' : '← Back'}
            </button>
            {step < 4 ? (
              <button
                onClick={() => setStep(s => s + 1)}
                disabled={!canAdvance}
                className="px-5 py-2 rounded-lg text-sm font-medium text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                style={{ backgroundColor: '#2563eb' }}
              >
                Next →
              </button>
            ) : (
              <button
                onClick={handleSubmit}
                disabled={submitting || reviewing}
                className="px-5 py-2 rounded-lg text-sm font-medium text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                style={{ backgroundColor: '#2563eb' }}
              >
                {submitting ? 'Submitting...' : 'Submit to GitHub ↗'}
              </button>
            )}
          </div>
        ) : (
          <div className="px-6 py-4 border-t border-gray-100 flex justify-end flex-shrink-0">
            <button
              onClick={onClose}
              className="px-4 py-2 text-sm font-medium text-gray-600 hover:text-gray-800 transition-colors"
            >
              Close
            </button>
          </div>
        )}
      </div>
    </div>
  )
}

function Footer() {
  return (
    <footer className="text-center py-6 text-gray-400 text-xs border-t border-gray-200 mt-12">
      © CodeCollab · AI-powered SQL migration · Phase 1 Preview · Powered by OpenRouter
    </footer>
  )
}

function ComplexityBadge({ rating }) {
  const style = COMPLEXITY_STYLES[rating] || COMPLEXITY_STYLES['Green']
  return (
    <span
      className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium"
      style={{ backgroundColor: style.bg, color: style.text }}
    >
      {rating}
    </span>
  )
}

function ExplanationPanel({ data, visible }) {
  const [visibleRules, setVisibleRules] = useState(0)

  useEffect(() => {
    if (!visible || !data) return
    setVisibleRules(0)
    const total = data.business_rules?.length || 0
    let i = 0
    const interval = setInterval(() => {
      i++
      setVisibleRules(i)
      if (i >= total) clearInterval(interval)
    }, 100)
    return () => clearInterval(interval)
  }, [data, visible])

  if (!data) return null

  return (
    <div className="bg-white rounded-lg border border-gray-200 overflow-hidden">
      <div className="px-5 py-4 border-b border-gray-100">
        <h2 className="font-semibold text-gray-900 text-sm uppercase tracking-wide">Business Logic Explainer</h2>
      </div>
      <div className="px-5 py-4 space-y-5 font-sans text-sm">
        {/* Summary */}
        <div>
          <h3 className="font-semibold text-gray-700 mb-1.5">Summary</h3>
          <p className="text-gray-600 leading-relaxed">{data.summary}</p>
        </div>

        {/* Business Rules */}
        {data.business_rules?.length > 0 && (
          <div>
            <h3 className="font-semibold text-gray-700 mb-2">Business Rules</h3>
            <ul className="space-y-1.5">
              {data.business_rules.map((rule, i) =>
                i < visibleRules ? (
                  <li
                    key={i}
                    className="rule-item flex items-start gap-2"
                    style={{ animationDelay: '0ms' }}
                  >
                    <span className="mt-0.5 flex-shrink-0 w-4 h-4 rounded-full bg-blue-100 text-blue-700 text-xs flex items-center justify-center font-medium">
                      {i + 1}
                    </span>
                    <span className="text-gray-600 leading-snug">{rule}</span>
                  </li>
                ) : null
              )}
            </ul>
          </div>
        )}

        {/* Dependencies */}
        {data.dependencies && (
          <div>
            <h3 className="font-semibold text-gray-700 mb-2">Dependencies</h3>
            <div className="space-y-2">
              {data.dependencies.reads_from?.length > 0 && (
                <div>
                  <span className="text-xs font-medium text-gray-500 uppercase tracking-wide">Reads from</span>
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {data.dependencies.reads_from.map((t, i) => (
                      <code key={i} className="bg-gray-100 text-gray-700 px-2 py-0.5 rounded text-xs font-mono">{t}</code>
                    ))}
                  </div>
                </div>
              )}
              {data.dependencies.writes_to?.length > 0 && (
                <div>
                  <span className="text-xs font-medium text-gray-500 uppercase tracking-wide">Writes to</span>
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {data.dependencies.writes_to.map((t, i) => (
                      <code key={i} className="bg-orange-50 text-orange-700 px-2 py-0.5 rounded text-xs font-mono">{t}</code>
                    ))}
                  </div>
                </div>
              )}
              {data.dependencies.external?.length > 0 && (
                <div>
                  <span className="text-xs font-medium text-gray-500 uppercase tracking-wide">External</span>
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {data.dependencies.external.map((t, i) => (
                      <code key={i} className="bg-purple-50 text-purple-700 px-2 py-0.5 rounded text-xs font-mono">{t}</code>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Migration Risks */}
        {data.migration_risks?.length > 0 && (
          <div>
            <h3 className="font-semibold text-gray-700 mb-2">Migration Risks</h3>
            <ul className="space-y-1.5">
              {data.migration_risks.map((risk, i) => (
                <li key={i} className="flex items-start gap-2">
                  <span className="mt-0.5 text-amber-500 flex-shrink-0">⚠</span>
                  <span className="text-gray-600 leading-snug">{risk}</span>
                </li>
              ))}
            </ul>
          </div>
        )}

        {/* Complexity */}
        {data.complexity && (
          <div>
            <h3 className="font-semibold text-gray-700 mb-2">Complexity</h3>
            <div className="flex items-center gap-2">
              <ComplexityBadge rating={data.complexity.rating} />
              <span className="text-gray-600 text-sm">{data.complexity.reason}</span>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function SqlPanel({ data }) {
  const codeRef = useRef(null)

  useEffect(() => {
    if (codeRef.current && data?.sql && window.hljs) {
      codeRef.current.removeAttribute('data-highlighted')
      window.hljs.highlightElement(codeRef.current)
    }
  }, [data?.sql])

  if (!data) return null

  return (
    <div style={{ backgroundColor: '#161b22' }} className="rounded-lg border border-gray-700 overflow-hidden">
      <div className="px-5 py-4 border-b border-gray-700 flex items-center justify-between">
        <h2 className="font-semibold text-gray-200 text-sm uppercase tracking-wide">CodeCollab SQL Model</h2>
        {data.filename && (
          <code style={{ color: '#e6edf3' }} className="text-xs font-mono bg-gray-700 px-2 py-0.5 rounded">
            {data.filename}
          </code>
        )}
      </div>
      <div className="p-5">
        {data.header_comment && (
          <div className="mb-4 p-3 rounded border border-gray-600 bg-gray-800/50">
            <p className="text-xs font-mono leading-relaxed whitespace-pre-wrap" style={{ color: '#8b949e' }}>
              {data.header_comment}
            </p>
          </div>
        )}
        <pre className="overflow-x-auto">
          <code ref={codeRef} className="language-sql text-sm" style={{ color: '#e6edf3', fontFamily: '"JetBrains Mono", monospace' }}>
            {data.sql}
          </code>
        </pre>
      </div>
    </div>
  )
}

function DagPanel({ dependencies, modelName, summary }) {
  const [tooltip, setTooltip] = useState(null)

  if (!dependencies) return null
  const { reads_from = [], writes_to = [], external = [] } = dependencies
  if (!reads_from.length && !writes_to.length && !external.length) return null

  const NH = 38, NW = 165, GAP = 14, EGAP = 26, PAD = 36, SVG_W = 800

  const readsH = reads_from.length * NH + Math.max(reads_from.length - 1, 0) * GAP
  const extH = external.length * NH + Math.max(external.length - 1, 0) * GAP
  const rightH = writes_to.length * NH + Math.max(writes_to.length - 1, 0) * GAP

  const topPad = PAD + Math.max(readsH, rightH, NH) / 2
  const botPad = PAD + Math.max(
    readsH / 2 + (external.length > 0 ? EGAP + extH : 0),
    rightH / 2,
    NH / 2
  )
  const SVG_H = topPad + botPad
  const midY = topPad

  const leftX = 20, rightX = SVG_W - 20 - NW, centerX = (SVG_W - NW) / 2
  const modelY = midY - NH / 2
  const readsStartY = midY - readsH / 2
  const extStartY = readsStartY + readsH + EGAP
  const rightStartY = midY - rightH / 2

  const COLORS = {
    reads:    { fill: '#eff6ff', stroke: '#93c5fd', text: '#1e40af' },
    writes:   { fill: '#fff7ed', stroke: '#fed7aa', text: '#c2410c' },
    external: { fill: '#f5f3ff', stroke: '#c4b5fd', text: '#6d28d9' },
    model:    { fill: '#161b22', stroke: '#30363d', text: '#e6edf3' },
  }

  function trunc(s, n) { return s.length > n ? s.slice(0, n - 1) + '…' : s }

  function bezierPath(x1, y1, x2, y2) {
    const cx = Math.abs(x2 - x1) * 0.5
    return `M${x1},${y1} C${x1 + cx},${y1} ${x2 - cx},${y2} ${x2},${y2}`
  }

  const readNodes = reads_from.map((name, i) => ({
    x: leftX, y: readsStartY + i * (NH + GAP),
    label: trunc(name, 21), type: 'reads', fullLabel: name,
    tip: 'Source table — read as input by this procedure.',
  }))

  const extNodes = external.map((desc, i) => {
    const dash = desc.indexOf(' - ')
    const name = dash >= 0 ? desc.slice(0, dash) : desc
    const detail = dash >= 0 ? desc.slice(dash + 3) : desc
    return {
      x: leftX, y: extStartY + i * (NH + GAP),
      label: trunc(name, 21), type: 'external', fullLabel: name,
      tip: detail,
    }
  })

  const writeNodes = writes_to.map((name, i) => ({
    x: rightX, y: rightStartY + i * (NH + GAP),
    label: trunc(name, 21), type: 'writes', fullLabel: name,
    tip: 'Output table — enriched records are written here.',
  }))

  const modelNode = {
    x: centerX, y: modelY, label: trunc(modelName || 'dbt model', 21),
    type: 'model', fullLabel: modelName || 'dbt model', tip: summary || '',
  }

  const allNodes = [...readNodes, ...extNodes, modelNode, ...writeNodes]

  const edges = [
    ...readNodes.map(n => ({ d: bezierPath(n.x + NW, n.y + NH / 2, centerX, modelY + NH / 2), dashed: false })),
    ...extNodes.map(n => ({ d: bezierPath(n.x + NW, n.y + NH / 2, centerX, modelY + NH / 2), dashed: true })),
    ...writeNodes.map(n => ({ d: bezierPath(centerX + NW, modelY + NH / 2, n.x, n.y + NH / 2), dashed: false })),
  ]

  const LEGEND = [
    { type: 'reads', label: 'Source' },
    { type: 'writes', label: 'Target' },
    { type: 'external', label: 'External' },
  ]

  return (
    <div className="bg-white rounded-lg border border-gray-200">
      <div className="px-5 py-4 border-b border-gray-100 flex items-center justify-between flex-wrap gap-3">
        <h2 className="font-semibold text-gray-900 text-sm uppercase tracking-wide">Dependency Graph</h2>
        <div className="flex items-center gap-4 text-xs text-gray-400">
          {LEGEND.map(({ type, label }) => {
            const c = COLORS[type]
            return (
              <span key={type} className="flex items-center gap-1.5">
                <span className="inline-block w-3 h-3 rounded-sm border" style={{ background: c.fill, borderColor: c.stroke }} />
                {label}
              </span>
            )
          })}
          <span className="flex items-center gap-1.5">
            <span className="inline-block w-5 border-t border-dashed border-gray-400" style={{ verticalAlign: 'middle' }} />
            Indirect
          </span>
        </div>
      </div>
      <div className="px-5 py-5">
        <svg width="100%" viewBox={`0 0 ${SVG_W} ${SVG_H}`} style={{ display: 'block', overflow: 'visible' }}>
          <defs>
            <marker id="dag-arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
              <polygon points="0 0, 10 3.5, 0 7" fill="#94a3b8" />
            </marker>
          </defs>

          {/* Column labels */}
          {reads_from.length > 0 && (
            <text x={leftX + NW / 2} y={18} textAnchor="middle" fontSize={9.5} fill="#9ca3af" fontFamily="system-ui" fontWeight={600} letterSpacing="0.06em">
              READS FROM
            </text>
          )}
          <text x={centerX + NW / 2} y={18} textAnchor="middle" fontSize={9.5} fill="#9ca3af" fontFamily="system-ui" fontWeight={600} letterSpacing="0.06em">
            MODEL
          </text>
          {writes_to.length > 0 && (
            <text x={rightX + NW / 2} y={18} textAnchor="middle" fontSize={9.5} fill="#9ca3af" fontFamily="system-ui" fontWeight={600} letterSpacing="0.06em">
              WRITES TO
            </text>
          )}
          {extNodes.length > 0 && (
            <text x={leftX + NW / 2} y={extStartY - 8} textAnchor="middle" fontSize={9} fill="#a78bfa" fontFamily="system-ui" fontWeight={500} letterSpacing="0.04em">
              EXTERNAL
            </text>
          )}

          {/* Edges */}
          {edges.map((edge, i) => (
            <path
              key={i} d={edge.d}
              fill="none" stroke="#94a3b8" strokeWidth={1.5}
              strokeDasharray={edge.dashed ? '5 4' : undefined}
              markerEnd="url(#dag-arrow)"
            />
          ))}

          {/* Nodes */}
          {allNodes.map((node, i) => {
            const c = COLORS[node.type]
            return (
              <g
                key={i} style={{ cursor: 'default' }}
                onMouseEnter={e => setTooltip({ x: e.clientX, y: e.clientY, node })}
                onMouseMove={e => setTooltip(prev => prev ? { ...prev, x: e.clientX, y: e.clientY } : null)}
                onMouseLeave={() => setTooltip(null)}
              >
                <rect x={node.x} y={node.y} width={NW} height={NH} rx={7}
                  fill={c.fill} stroke={c.stroke} strokeWidth={1.5} />
                <text
                  x={node.x + NW / 2} y={node.y + NH / 2}
                  textAnchor="middle" dominantBaseline="middle"
                  fill={c.text} fontSize={11.5} fontWeight={node.type === 'model' ? 600 : 500}
                  fontFamily="'JetBrains Mono', ui-monospace, monospace"
                >
                  {node.label}
                </text>
              </g>
            )
          })}
        </svg>
      </div>

      {tooltip && (
        <div
          style={{ position: 'fixed', left: tooltip.x + 14, top: tooltip.y + 14, zIndex: 9999, pointerEvents: 'none', maxWidth: 300 }}
          className="bg-gray-900 text-white text-xs rounded-lg shadow-xl px-3 py-2.5"
        >
          <div className="font-mono font-semibold mb-1">{tooltip.node.fullLabel}</div>
          {tooltip.node.tip && <div className="text-gray-300 leading-relaxed">{tooltip.node.tip}</div>}
        </div>
      )}
    </div>
  )
}

function LoadingOverlay({ message }) {
  return (
    <div className="col-span-2 flex flex-col items-center justify-center py-20 gap-4">
      <div className="flex gap-1.5">
        {[0, 1, 2].map(i => (
          <div
            key={i}
            className="w-2 h-2 rounded-full bg-blue-500 animate-bounce"
            style={{ animationDelay: `${i * 150}ms` }}
          />
        ))}
      </div>
      <p className="text-gray-500 text-sm font-medium">{message}</p>
    </div>
  )
}

export default function App() {
  const [sql, setSql] = useState(DEMO_PROCEDURES['T-SQL'])
  const [dialect, setDialect] = useState('T-SQL')
  const [loading, setLoading] = useState(false)
  const [loadingMsg, setLoadingMsg] = useState('')
  const [result, setResult] = useState(null)
  const [error, setError] = useState(null)
  const [rawError, setRawError] = useState(null)
  const [sqlError, setSqlError] = useState(false)
  const [showRaw, setShowRaw] = useState(false)
  const [panelVisible, setPanelVisible] = useState(false)
  const [selectedFile, setSelectedFile] = useState('')
  const [featureModalOpen, setFeatureModalOpen] = useState(false)
  const loadingIntervalRef = useRef(null)
  const fileInputRef = useRef(null)
  const apiKey = import.meta.env.VITE_OPENROUTER_API_KEY
  const model = import.meta.env.VITE_OPENROUTER_MODEL || 'anthropic/claude-sonnet-4-5'

  useEffect(() => {
    return () => {
      if (loadingIntervalRef.current) clearInterval(loadingIntervalRef.current)
    }
  }, [])

  function startLoadingCycle() {
    let idx = 0
    setLoadingMsg(LOADING_MESSAGES[0])
    loadingIntervalRef.current = setInterval(() => {
      idx = (idx + 1) % LOADING_MESSAGES.length
      setLoadingMsg(LOADING_MESSAGES[idx])
    }, 1500)
  }

  function stopLoadingCycle() {
    if (loadingIntervalRef.current) {
      clearInterval(loadingIntervalRef.current)
      loadingIntervalRef.current = null
    }
  }

  function clearResults() {
    setResult(null)
    setError(null)
    setRawError(null)
    setPanelVisible(false)
  }

  function handleFileSelect(e) {
    const val = e.target.value
    if (!val) return
    if (val === '__upload__') {
      fileInputRef.current.click()
      setSelectedFile('')
      return
    }
    const example = EXAMPLES.find(ex => ex.path === val)
    if (example) {
      setSql(example.content)
      setDialect(example.dialect)
      setSelectedFile(val)
      clearResults()
    }
  }

  function handleFileUpload(e) {
    const file = e.target.files[0]
    if (!file) return
    const reader = new FileReader()
    reader.onload = ev => {
      const content = ev.target.result
      setSql(content)
      setDialect(detectDialect(content))
      setSelectedFile('')
      clearResults()
    }
    reader.readAsText(file)
    e.target.value = ''
  }

  async function handleAnalyze() {
    if (!sql.trim()) {
      setSqlError(true)
      return
    }
    setSqlError(false)
    setError(null)
    setRawError(null)
    setResult(null)
    setPanelVisible(false)
    setLoading(true)
    startLoadingCycle()

    try {
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
            {
              role: 'user',
              content: `Dialect: ${dialect}\n\n${sql}`,
            },
          ],
        }),
      })

      if (!response.ok) {
        const text = await response.text()
        throw new Error(`API error ${response.status}: ${text}`)
      }

      const data = await response.json()
      const content = data.choices[0].message.content

      let parsed
      try {
        const stripped = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
        parsed = JSON.parse(stripped)
      } catch {
        stopLoadingCycle()
        setLoading(false)
        setError('The AI returned a response that could not be parsed as JSON.')
        setRawError(content)
        return
      }

      setResult(parsed)
      setPanelVisible(true)
    } catch (err) {
      setError(err.message || 'An unexpected error occurred.')
    } finally {
      stopLoadingCycle()
      setLoading(false)
    }
  }

  return (
    <div className="min-h-screen flex flex-col" style={{ backgroundColor: '#f6f8fa' }}>
      <Header onFeatureRequest={() => setFeatureModalOpen(true)} />
      {featureModalOpen && <FeatureRequestModal onClose={() => setFeatureModalOpen(false)} />}

      <main className="flex-1 max-w-7xl mx-auto w-full px-6 py-8">
        {/* Missing API key warning */}
        {!apiKey && (
          <div className="mb-6 px-4 py-3 bg-amber-50 border border-amber-200 rounded-lg flex items-start gap-3">
            <span className="text-amber-500 mt-0.5 flex-shrink-0">⚠</span>
            <div className="text-sm text-amber-800">
              <strong>Missing API key:</strong> Set <code className="bg-amber-100 px-1 rounded font-mono">VITE_OPENROUTER_API_KEY</code> in your <code className="bg-amber-100 px-1 rounded font-mono">.env</code> file to enable analysis.
            </div>
          </div>
        )}

        {/* Input section */}
        <div className="bg-white rounded-lg border border-gray-200 overflow-hidden mb-6">
          <div className="px-5 py-4 border-b border-gray-100 flex items-center justify-between flex-wrap gap-3">
            <h1 className="font-semibold text-gray-900">SQL Migration Explainer</h1>
            <div className="flex items-center gap-4 flex-wrap">
              {/* File selector */}
              <div className="flex items-center gap-2">
                <label className="text-sm font-medium text-gray-600">File:</label>
                <select
                  value={selectedFile}
                  onChange={handleFileSelect}
                  className="text-sm border border-gray-200 rounded-md px-3 py-1.5 bg-white text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  style={{ maxWidth: '220px' }}
                >
                  <option value="">Select a file...</option>
                  <option value="__upload__">⬆ Upload your own...</option>
                  {['tsql', 'plsql', 'postgresql'].map(folder => {
                    const group = EXAMPLES.filter(e => e.folder === folder)
                    if (!group.length) return null
                    return (
                      <optgroup key={folder} label={FOLDER_TO_DIALECT[folder]}>
                        {group.map(ex => (
                          <option key={ex.path} value={ex.path}>{ex.label}</option>
                        ))}
                      </optgroup>
                    )
                  })}
                </select>
              </div>
              {/* Dialect selector */}
              <div className="flex items-center gap-2">
                <label className="text-sm font-medium text-gray-600">Dialect:</label>
                <select
                  value={dialect}
                  onChange={e => {
                    const next = e.target.value
                    setDialect(next)
                    setSelectedFile('')
                    if (Object.values(DEMO_PROCEDURES).includes(sql)) {
                      setSql(DEMO_PROCEDURES[next])
                    }
                    clearResults()
                  }}
                  className="text-sm border border-gray-200 rounded-md px-3 py-1.5 bg-white text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                >
                  <option value="T-SQL">T-SQL</option>
                  <option value="PL/SQL">PL/SQL</option>
                  <option value="Other SQL">Other SQL</option>
                </select>
              </div>
            </div>
          </div>
          {/* Hidden file input for uploads */}
          <input
            ref={fileInputRef}
            type="file"
            accept=".sql,.txt,.pls,.prc,.pkb"
            style={{ display: 'none' }}
            onChange={handleFileUpload}
          />
          <div className="p-5">
            <textarea
              value={sql}
              onChange={e => { setSql(e.target.value); if (sqlError) setSqlError(false); if (selectedFile) setSelectedFile('') }}
              placeholder="Paste your stored procedure here..."
              rows={16}
              className={`w-full font-mono text-sm resize-y rounded-md border bg-gray-50 px-4 py-3 text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-colors ${sqlError ? 'border-red-400 bg-red-50' : 'border-gray-200'}`}
              style={{ fontFamily: '"JetBrains Mono", monospace', fontSize: '0.8125rem', lineHeight: '1.6' }}
            />
            {sqlError && (
              <p className="mt-1.5 text-sm text-red-600">Please paste a stored procedure before analyzing.</p>
            )}
            <div className="mt-4 flex items-center justify-between">
              <p className="text-xs text-gray-400">
                Model: <code className="bg-gray-100 px-1 rounded font-mono">{model}</code>
              </p>
              <button
                onClick={handleAnalyze}
                disabled={loading || !apiKey}
                className="px-5 py-2.5 rounded-lg text-sm font-medium text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                style={{ backgroundColor: loading || !apiKey ? '#6b7280' : '#2563eb' }}
                onMouseEnter={e => { if (!loading && apiKey) e.target.style.backgroundColor = '#1d4ed8' }}
                onMouseLeave={e => { if (!loading && apiKey) e.target.style.backgroundColor = '#2563eb' }}
              >
                {loading ? 'Analyzing...' : 'Analyze & Convert'}
              </button>
            </div>
          </div>
        </div>

        {/* Error state */}
        {error && !loading && (
          <div className="mb-6 px-4 py-4 bg-red-50 border border-red-200 rounded-lg">
            <div className="flex items-start justify-between gap-4">
              <div className="flex items-start gap-3">
                <span className="text-red-500 flex-shrink-0 mt-0.5">✕</span>
                <div>
                  <p className="text-sm font-medium text-red-800">Analysis failed</p>
                  <p className="text-sm text-red-700 mt-0.5">{error}</p>
                </div>
              </div>
              <button
                onClick={handleAnalyze}
                className="flex-shrink-0 px-3 py-1.5 text-xs font-medium text-white rounded-md"
                style={{ backgroundColor: '#2563eb' }}
                onMouseEnter={e => (e.target.style.backgroundColor = '#1d4ed8')}
                onMouseLeave={e => (e.target.style.backgroundColor = '#2563eb')}
              >
                Retry
              </button>
            </div>
            {rawError && (
              <details className="mt-3" open={showRaw}>
                <summary
                  className="text-xs font-medium text-red-600 cursor-pointer select-none"
                  onClick={() => setShowRaw(v => !v)}
                >
                  Raw response
                </summary>
                <pre className="mt-2 text-xs font-mono text-red-700 bg-red-100 rounded p-3 overflow-x-auto whitespace-pre-wrap">
                  {rawError}
                </pre>
              </details>
            )}
          </div>
        )}

        {/* Output panels */}
        {(loading || result) && (
          <div className="space-y-6">
            {!loading && result && (
              <DagPanel
                dependencies={result?.explanation?.dependencies}
                modelName={result?.dbt_model?.filename}
                summary={result?.explanation?.summary}
              />
            )}
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              {loading ? (
                <LoadingOverlay message={loadingMsg} />
              ) : (
                <>
                  <ExplanationPanel data={result?.explanation} visible={panelVisible} />
                  <SqlPanel data={result?.dbt_model} />
                </>
              )}
            </div>
          </div>
        )}
      </main>

      <Footer />
    </div>
  )
}
