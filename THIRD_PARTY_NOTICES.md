# Third party notices

ScrollTax itself is under the PolyForm Noncommercial License 1.0.0 (see LICENSE). The software below is not copied into this repository. The backend downloads it with `npm install`, and each package keeps its own license, which comes with the package in `node_modules`.

## Backend packages (npm)

Direct dependencies: fastify, typescript (development), @types/node (development). The rest are what those pull in.

| Package | Version | License |
| --- | --- | --- |
| @fastify/ajv-compiler | 4.0.7 | MIT |
| @fastify/deepmerge | 3.2.4 | MIT |
| @fastify/error | 4.2.1 | MIT |
| @fastify/fast-json-stringify-compiler | 5.1.1 | MIT |
| @fastify/forwarded | 3.1.2 | MIT |
| @fastify/merge-json-schemas | 0.2.2 | MIT |
| @fastify/proxy-addr | 5.1.2 | MIT |
| @pinojs/redact | 0.4.0 | MIT |
| @types/node (direct) | 24.19.2 | MIT |
| abstract-logging | 2.0.1 | MIT |
| ajv | 8.20.0 | MIT |
| ajv-formats | 3.0.1 | MIT |
| atomic-sleep | 1.0.0 | MIT |
| avvio | 9.3.1 | MIT |
| cookie | 2.0.1 | MIT |
| dequal | 2.0.3 | MIT |
| fast-decode-uri-component | 1.0.1 | MIT |
| fast-deep-equal | 3.1.3 | MIT |
| fast-json-stringify | 7.2.1 | MIT |
| fast-querystring | 1.1.2 | MIT |
| fast-uri | 4.2.3 | BSD-3-Clause |
| fastify (direct) | 5.12.7 | MIT |
| fastq | 1.20.3 | ISC |
| find-my-way | 9.10.0 | MIT |
| ipaddr.js | 2.5.0 | MIT |
| json-schema-ref-resolver | 3.0.1 | MIT |
| json-schema-traverse | 1.0.0 | MIT |
| light-my-request | 6.8.0 | BSD-3-Clause |
| on-exit-leak-free | 2.1.2 | MIT |
| pino | 10.4.0 | MIT |
| pino-abstract-transport | 3.0.0 | MIT |
| pino-std-serializers | 7.1.0 | MIT |
| process-warning | 5.1.1 | MIT |
| quick-format-unescaped | 4.0.4 | MIT |
| real-require | 1.0.0 | MIT |
| require-from-string | 2.0.2 | MIT |
| ret | 0.5.1 | MIT |
| reusify | 1.1.0 | MIT |
| rfdc | 1.4.1 | MIT |
| safe-regex2 | 5.1.2 | MIT |
| safe-stable-stringify | 2.5.0 | MIT |
| secure-json-parse | 4.1.1 | BSD-3-Clause |
| semver | 7.8.5 | ISC |
| set-cookie-parser | 3.2.2 | MIT |
| sonic-boom | 4.2.1 | MIT |
| split2 | 4.2.0 | ISC |
| thread-stream | 4.2.0 | MIT |
| toad-cache | 3.7.4 | MIT |
| typescript (direct) | 5.9.3 | Apache-2.0 |
| undici-types | 7.24.6 | MIT |

## iPhone app

No outside Swift packages. The app uses Apple frameworks (SwiftUI, StoreKit, FamilyControls, ManagedSettings, DeviceActivity, AuthenticationServices) under Apple's own terms.

## Tools, not included

XcodeGen (MIT) makes the Xcode project from `ios/project.yml`. It is not part of this repository.

## Site and media

The site in `site/` loads two fonts from Google Fonts, Bricolage Grotesque and Instrument Sans. Both are under the SIL Open Font License 1.1. Nothing else is loaded from outside. The screenshots, the demo video and the GIF are recordings of the app running in the iOS Simulator in demo mode. No AI-made images are used.
