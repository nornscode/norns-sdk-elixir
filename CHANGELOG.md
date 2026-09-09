# Changelog

All notable changes to `norns_sdk` are documented in this file.

## [Unreleased]

### Added
- Worker-side rendering for the opaque-content protocol (norns "Content is
  opaque", 2026-09-09). `NornsSdk.Format.compose_system_prompt/1` builds the
  prompt from the def's prompt plus the `summary` and `date` in the task
  envelope; `render_message/1` turns kinded messages (`timer_completed`,
  `tool_denied`, `subagent_*`, `list_agents`, `inherited_context`) into the
  text the model used to see; `elide_old_tool_results/1` caps results older
  than the last two turns; `final_output/2` keeps the last substantive text
  when the final turn is empty. The worker reports `final_output` on every
  LLM result.
- Human-in-the-loop support. `NornsSdk.WaitingFor` carries the question a run is
  parked on; `RunResponse` and `MessageResult` gain a `waiting_for` field and a
  `waiting?/1` helper.
- `NornsSdk.Client.reply/3` — answer a run parked on an `ask_human` question.
  Sending the agent a normal message does the same thing; `reply/3` is for
  answering one specific run.

### Fixed
- `send_message/4` with `wait: true` now stops on the `"waiting"` run status
  instead of polling until timeout. A parked agent is waiting on the caller, so
  it returns with the question rather than hanging.

## [0.1.0] - 2026-07-20

### Added
- Initial Elixir SDK structure (`NornsSdk.Agent`, `NornsSdk.Tool`, `NornsSdk.Worker`, `NornsSdk.Client`)
- Provider-neutral wire format handling via `NornsSdk.Format`
- Multi-provider LLM support via ReqLLM (Anthropic, OpenAI, Google, Mistral, and more)
- Automatic provider inference from model name (e.g. `"claude-sonnet-4-20250514"` → Anthropic)
- Typed response structs for all client reads: `NornsSdk.RunResponse`,
  `NornsSdk.EventResponse`, `NornsSdk.AgentResponse`, `NornsSdk.ConversationResponse`,
  `NornsSdk.MessageResult`, and `NornsSdk.StreamEvent`, each with a `from_map/1`
  constructor. Read functions return these structs — access fields with dot syntax
  (e.g. `run.status`, `agent.id`).
- `NornsSdk.Client.stream/4` — streams a run's events to a subscriber process via
  `NornsSdk.StreamClient` (delivers `{:norns_event, pid, %StreamEvent{}}` messages,
  plus `{:norns_closed, pid, reason}` if the socket closes before a terminal event).
- CI pipeline (test, credo, security)
- Integration tests against live Norns server
- Release checklist docs
- README badges and usage examples

### Notes
- This is an early v0.1 release focused on core worker/client flows.
- API contracts will continue to harden alongside Norns runtime releases.
