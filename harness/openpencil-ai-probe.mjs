// Exercises the SAME code path OpenPencil's AI uses: createOpenAI from
// @ai-sdk/openai with a custom baseURL, which is what
// createOpenAICompatibleAdapter() in src/app/ai/providers/compatible.ts calls.
// Building their Vue SPA to prove this would test the bundler, not the seam.
import { createOpenAI } from '@ai-sdk/openai'
import { generateText } from 'ai'

const provider = createOpenAI({
  apiKey: 'not-needed',
  baseURL: process.env.CONTRACT_BASE_URL,
})
const { text } = await generateText({
  model: provider.chat(process.env.CONTRACT_ROLE),
  prompt: 'Reply with exactly: OPENPENCIL OK',
  maxOutputTokens: 900,
})
console.log(text.trim())
