# Contributing

Thanks for looking at ScrollTax. Bug reports, ideas and pull requests are welcome.

**About the license.** ScrollTax is source available under the PolyForm Noncommercial License 1.0.0 (see `LICENSE`). Contributions are accepted only if you agree that Abozar Alizadeh may relicense them, including for commercial use. By opening a pull request you confirm that you wrote the change (or have the right to submit it) and that you agree to this.

## Before you open a pull request

- Keep the change small and say what it fixes.
- Run the tests: `cd backend && npm test && npm run typecheck`, and `cd ios/Packages/ScrollTaxCore && swift test`.
- Backend TypeScript stays "erasable": no enums, no constructor parameter properties, `import type` for types, and `.ts` in import paths.
- Every Apple dependency stays behind its interface (`AppleServices` on the backend, `Blocking` and `Purchasing` in the app) with a fake. Tests use the fakes.
- Payments stay in sandbox or test mode. Don't add real keys or secrets to any file. Use `.env.example`.
- Don't describe the app as a treatment or cure for anything.
- Plain, human wording in code comments and docs.

## Commercial use

Commercial use needs written permission. Ask by opening an issue on this repo.
