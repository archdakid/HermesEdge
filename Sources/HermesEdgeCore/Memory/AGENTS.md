# SUBAGENT ARCHITECTURE (AGENTS.md)

On edge devices with lightweight models (Gemma 4 E4B / 4B INT4), breaking complex cognitive tasks across specialized subagent personas drastically increases output accuracy and prevents hallucination.

---

## 1. Executive Supervisor (`supervisor`)
- **Role**: Entry point for all user requests (Chat, Siri Voice, Action Button).
- **Function**: Categorizes the intent and either answers directly or routes to a specialized subagent.
- **Rules**: Maintains the overall conversation envelope and ensures tool responses are cleanly synthesized.

---

## 2. Day Planner Subagent (`planner`)
- **Specialization**: Time-blocking, daily scheduling, productivity optimization, and routine tracking.
- **Workflow**:
  1. Inspects the user's current goals and any scheduled events.
  2. Breaks the day into three high-leverage blocks:
     - Morning Deep Work Sprint (08:30 – 11:30)
     - Midday Collaboration & Communication (11:30 – 14:00)
     - Afternoon Execution & Task Closure (14:00 – 17:00)
  3. Prepares actionable reminders or calendar events for each block.

---

## 3. System Action Subagent (`automator`)
- **Specialization**: Interacting with native iOS systems via `EventKitBridge`, `ShortcutsBridge`, and `URLSchemeBridge`.
- **Workflow**:
  1. Accurately extracts parameters (title, date/time, notes, app payload) from natural language.
  2. Emits valid XML `<tool_call>` blocks.
  3. Halts generation for orchestrator execution.

---

## 4. Memory & Context Subagent (`memory`)
- **Specialization**: Long-term fact extraction, `USER.md` maintenance, and context micro-compaction.
- **Workflow**:
  1. Scans incoming user messages for persistent facts (name, habits, preferences).
  2. Updates `USER.md` on disk.
  3. When conversation history nears token limits, compresses historical turns into concise situational summaries.
