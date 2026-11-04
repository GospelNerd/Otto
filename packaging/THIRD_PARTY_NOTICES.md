# Third-party notices

## SwiftTerm

Otto includes SwiftTerm 1.15.0: <https://github.com/migueldeicaza/SwiftTerm>

Copyright (c) 2019-2022 Miguel de Icaza  
Copyright (c) 2017-2019, The xterm.js authors  
Copyright (c) 2014-2016, SourceLair Private Company  
Copyright (c) 2012-2013, Christopher Jeffrey

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Simple Icons

Otto includes Claude, OpenAI, Cursor, Kimi, and OpenCode provider glyph data from Simple Icons:
<https://github.com/simple-icons/simple-icons>

The Simple Icons data is made available under CC0 1.0 Universal. Brand names and logos remain
trademarks of their respective owners.

The Hermes Agent provider mark is sourced from the official Nous Research Hermes Agent site.
Hermes Agent and its mark belong to Nous Research.

## Thinking Orbs

Otto includes a native adaptation of the Thinking Orbs composing animation:
<https://github.com/JakubAntalik/thinking-orbs>

Copyright (c) 2026 Jakub Antalik

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Inter

Inter typeface by Rasmus Andersson (https://rsms.me/inter/), version 4.1, bundled as
`Resources/Fonts/InterVariable.ttf`. Licensed under the SIL Open Font License 1.1; the full
licence text ships alongside the font as `Resources/Fonts/Inter-LICENSE.txt`.

## Mermaid

Otto bundles Mermaid 11.16.0 (`Resources/DiagramRenderer/mermaid.min.js`):
<https://github.com/mermaid-js/mermaid>

Copyright (c) 2014-2024 Knut Sveidqvist. Licensed under the MIT License (same terms as the
SwiftTerm notice above).

## Cult UI agent skills

The repository vendors the `frontend-design` and `components-build` agent skills from Cult UI:
<https://github.com/nolly-studio/cult-ui> (`.agents/skills/frontend-design`, `.agents/skills/components-build`).
They are development-time instructions for coding agents and are not included in the Otto app.

Copyright (c) 2023 Jordan-Gilliam

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Superdesign agent skill

The repository vendors the `superdesign` agent skill: <https://github.com/superdesigndev/superdesign-skill>
(`.agents/skills/superdesign`). It is a development-time instruction set for coding agents and is not
included in the Otto app.

Copyright (c) 2026 Superdesign (superdesign.dev)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Swift packages

Otto depends on these Swift packages, fetched by SwiftPM at build time and linked into
the app. Their full license texts are in each package's repository.

Apache License 2.0:
- apple/swift-algorithms, swift-argument-parser, swift-asn1, swift-async-algorithms,
  swift-atomics, swift-certificates, swift-collections, swift-configuration, swift-crypto,
  swift-distributed-tracing, swift-http-structured-headers, swift-http-types, swift-log,
  swift-metrics, swift-nio, swift-nio-extras, swift-nio-http2, swift-nio-ssl,
  swift-nio-transport-services, swift-numerics, swift-service-context, swift-system
- swift-server/async-http-client and swift-service-lifecycle
- hummingbird-project/hummingbird, hummingbird-websocket and swift-websocket
- adam-fowler/compress-nio
- livekit/livekit-wakeword

swift-nio-ssl and swift-crypto include BoringSSL, which is covered by the OpenSSL and ISC
licenses.

MIT License:
- migueldeicaza/SwiftTerm (see above)
- microsoft/onnxruntime-swift-package-manager (ONNX Runtime)

## Photon messaging bridge

The optional messaging bridge (`Sources/OttoServices/Resources/PhotonBridge`) installs
spectrum-ts and the @photon-ai packages from npm at runtime. They are not redistributed in
this repository.

## Brand marks

Otto shows the logos of the AI providers and apps it connects to (`Resources/PluginLogos`,
`Resources/ProviderLogos` and the Simple Icons glyphs above) only to identify those
services. Every brand name and logo belongs to its owner, and their use doesn't imply
endorsement.
