# Third-party notices

Tether's own code is under the MIT License (see `LICENSE`). It depends on the components below, which are **not** included in this repository. `npm install` downloads them from the npm registry, and each stays under its own terms.

| Component | Version | License / terms | Source |
|---|---|---|---|
| Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`), including the Claude Code program it bundles | 0.3.289 | Proprietary. © Anthropic PBC, all rights reserved. Use is subject to Anthropic's legal agreements: https://code.claude.com/docs/en/legal-and-compliance | https://github.com/anthropics/claude-agent-sdk-typescript |
| `qrcode-terminal` | 0.12.0 | Apache License 2.0 | https://github.com/gtanner/qrcode-terminal |

The Agent SDK brings further packages of its own (for example the Anthropic TypeScript SDK and OpenTelemetry API); run `npm ls --all` in `server/` for the full list and see each package's license.

The iOS app uses only Apple frameworks (SwiftUI, ActivityKit, WidgetKit, Charts, PhotosUI).

"Claude", "Claude Code" and "Anthropic" are trademarks of Anthropic, PBC. Tether is not affiliated with or endorsed by Anthropic.
