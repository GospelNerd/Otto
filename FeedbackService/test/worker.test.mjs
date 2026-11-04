import test from 'node:test';
import assert from 'node:assert/strict';
import worker, {issueBody, issueTitle, limits, sanitizeMarkdown, screenshotPath, validate} from '../worker.mjs';

const installID = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
const token = 'github_pat_TESTTOKEN_never_in_output';
const pngBytes = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(32, 7)]);
const jpegBytes = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(32, 3)]);
const environment = {appVersion: '0.2.0', build: '42', macOS: '26.1', architecture: 'arm64', model: 'Mac15,6'};

function report(overrides = {}) {
  return {kind: 'bug', title: 'Sidebar freezes', description: 'The sidebar stops scrolling after a minute.', installID, ...overrides};
}

function limiter(success = true) {
  const keys = [];
  return {keys, async limit({key}) { keys.push(key); return {success}; }};
}

function makeEnv(overrides = {}) {
  return {IP_LIMIT: limiter(), INSTALL_LIMIT: limiter(), GLOBAL_LIMIT: limiter(), GITHUB_TOKEN: token, GITHUB_REPO: 'maxtrigify/Otto', ...overrides};
}

/** Replaces global fetch with a scripted GitHub. Returns the recorded calls. */
function mockGitHub(t, handlers = {}) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const call = {url: String(url), method: init.method || 'GET', headers: init.headers || {}, body: init.body ? JSON.parse(init.body) : undefined};
    calls.push(call);
    const path = new URL(call.url).pathname;
    if (call.method === 'GET' && path.includes('/branches/')) return handlers.branch?.(call) ?? new Response('{}', {status: 200});
    if (call.method === 'PUT' && path.includes('/contents/')) return handlers.upload?.(call) ?? new Response('{}', {status: 201});
    if (call.method === 'POST' && path.endsWith('/issues'))
      return handlers.issue?.(call) ?? Response.json({number: 17, html_url: 'https://github.com/maxtrigify/Otto/issues/17'}, {status: 201});
    return new Response('unexpected', {status: 500});
  };
  t.after(() => { globalThis.fetch = original; });
  return calls;
}

function post(body, headers = {}) {
  return new Request('https://feedback.openotto.io/v1/feedback', {
    method: 'POST',
    headers: {'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.9', ...headers},
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

test('health and method routing', async () => {
  const env = makeEnv();
  const health = await worker.fetch(new Request('https://feedback.openotto.io/health'), env);
  assert.equal(health.status, 200);
  assert.equal(await health.text(), 'ok');
  for (const method of ['GET', 'OPTIONS', 'PUT', 'DELETE']) {
    const response = await worker.fetch(new Request('https://feedback.openotto.io/v1/feedback', {method}), env);
    assert.equal(response.status, 405, method);
  }
  assert.equal((await worker.fetch(new Request('https://feedback.openotto.io/other', {method: 'POST'}), env)).status, 404);
});

test('validation accepts a good report and rejects bad fields', () => {
  const ok = validate(report({environment, screenshot: {mediaType: 'image/png', base64: pngBytes.toString('base64')}}));
  assert.equal(ok.kind, 'bug');
  assert.equal(ok.screenshot.extension, 'png');
  assert.deepEqual(ok.environment, environment);

  const bad = [
    report({kind: 'question'}),
    report({kind: '__proto__'}),
    report({kind: ['bug']}),
    report({description: 'too short'}),
    report({description: 'x'.repeat(5001)}),
    report({title: 'x'.repeat(121)}),
    report({title: 7}),
    report({installID: 'not-a-uuid'}),
    report({extra: true}),
    report({screenshot: {mediaType: 'image/gif', base64: pngBytes.toString('base64')}}),
    report({screenshot: {mediaType: 'image/png', base64: jpegBytes.toString('base64')}}),
    report({screenshot: {mediaType: 'image/jpeg', base64: pngBytes.toString('base64')}}),
    report({screenshot: {mediaType: 'image/png', base64: 'not base64!'}}),
    report({screenshot: {mediaType: 'image/png', base64: Buffer.concat([pngBytes, Buffer.alloc(3 * 1024 * 1024)]).toString('base64')}}),
    report({environment: {...environment, macOS: '/Users/max'}}),
    report({environment: {...environment, user: 'max'}}),
    report({environment: {...environment, architecture: 'arm64; rm -rf'}}),
    report({environment: {appVersion: '0.2.0'}}),
    [],
    null,
  ];
  for (const body of bad) assert.throws(() => validate(body), {name: 'Error'}, JSON.stringify(body)?.slice(0, 80));
  assert.equal(validate(report({kind: 'idea'})).kind, 'idea');
  assert.equal(validate(report({screenshot: {mediaType: 'image/jpeg', base64: jpegBytes.toString('base64')}})).screenshot.extension, 'jpg');
});

test('request validation errors are 400 with a short message', async (t) => {
  const calls = mockGitHub(t);
  const env = makeEnv();
  const response = await worker.fetch(post(report({description: 'short'})), env);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /at least 10/);
  assert.equal((await worker.fetch(post('{not json'), env)).status, 400);
  assert.equal((await worker.fetch(post(report(), {'Content-Type': 'text/plain'}), env)).status, 415);
  const huge = post(report({description: 'x'.repeat(4 * 1024 * 1024 + 10)}));
  assert.equal((await worker.fetch(huge, env)).status, 413);
  assert.equal(calls.length, 0);
});

test('sanitization neutralizes mentions, HTML and images but keeps links', () => {
  const text = sanitizeMarkdown('Hi @maxtrigify and @org/team <img src=x onerror=alert(1)><b>bold</b> <!-- hidden -->\r\n![pic](https://evil.example/x.png) see https://openotto.io and [docs](https://openotto.io/docs)\n\n\n\n\n\nend <script>');
  assert.ok(!/@[A-Za-z]/.test(text), text);
  assert.ok(text.includes('@‍maxtrigify'));
  assert.ok(!text.includes('<img') && !text.includes('<b>') && !text.includes('<script') && !text.includes('hidden'));
  assert.ok(!text.includes('!['));
  assert.ok(text.includes('!\\[pic]'));
  assert.ok(text.includes('[docs](https://openotto.io/docs)') && text.includes('https://openotto.io'));
  assert.ok(!text.includes('\n\n\n\n'));
  assert.ok(!text.includes('\r'));
  assert.equal(sanitizeMarkdown('a < b'), 'a &lt; b');
});

test('titles are prefixed, single-line and capped', () => {
  assert.equal(issueTitle(validate(report())), '[Bug] Sidebar freezes');
  assert.equal(issueTitle(validate(report({kind: 'idea', title: '', description: '\n\nDark mode for docs\nplease and thanks'}))), '[Idea] Dark mode for docs');
  const long = issueTitle(validate(report({title: 'word '.repeat(22)})));
  // The cap covers the full title GitHub shows, the `[Bug] ` prefix included — the bound the
  // README and the function's doc comment both promise.
  assert.ok([...long].length <= limits.issueTitle);
  assert.ok(long.endsWith('…'));
  assert.equal(issueTitle(validate(report({title: 'ping @maxtrigify <b>x</b>'}))), '[Bug] ping @‍maxtrigify x');
});

test('creates an issue with labels, details and footer and no install ID, IP or token', async (t) => {
  const calls = mockGitHub(t);
  const env = makeEnv();
  const response = await worker.fetch(post(report({environment})), env);
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), {issueNumber: 17, issueURL: 'https://github.com/maxtrigify/Otto/issues/17'});
  assert.equal(calls.length, 1);
  const [issue] = calls;
  assert.equal(issue.url, 'https://api.github.com/repos/maxtrigify/Otto/issues');
  assert.equal(issue.headers.Authorization, `Bearer ${token}`);
  assert.ok(issue.headers['User-Agent']);
  assert.deepEqual(issue.body.labels, ['bug', 'from-app']);
  assert.equal(issue.body.title, '[Bug] Sidebar freezes');
  assert.match(issue.body.body, /### Details/);
  assert.match(issue.body.body, /Otto: 0\.2\.0 \(build 42\)/);
  assert.match(issue.body.body, /Sent from the Otto app/);
  const serialized = JSON.stringify(issue.body);
  for (const secret of [installID, '203.0.113.9', token]) assert.ok(!serialized.includes(secret), secret);
  assert.deepEqual(env.IP_LIMIT.keys, ['203.0.113.9']);
  assert.deepEqual(env.INSTALL_LIMIT.keys, [installID]);
});

test('idea without environment has no details section', () => {
  const body = issueBody(validate(report({kind: 'idea'})), null);
  assert.ok(!body.includes('### Details'));
  assert.ok(body.endsWith('<sub>Sent from the Otto app.</sub>'));
});

test('screenshot is uploaded to the screenshots branch and embedded by raw URL', async (t) => {
  const calls = mockGitHub(t);
  const base64 = pngBytes.toString('base64');
  const response = await worker.fetch(post(report({screenshot: {mediaType: 'image/png', base64}})), makeEnv());
  assert.equal(response.status, 201);
  assert.deepEqual(calls.map((call) => call.method), ['GET', 'PUT', 'POST']);
  assert.equal(calls[0].url, 'https://api.github.com/repos/maxtrigify/Otto/branches/feedback-screenshots');
  const upload = calls[1];
  const match = upload.url.match(/\/repos\/maxtrigify\/Otto\/contents\/(screenshots\/\d{4}-\d{2}\/[0-9a-f-]{36}\.png)$/);
  assert.ok(match, upload.url);
  assert.equal(upload.body.branch, 'feedback-screenshots');
  assert.equal(upload.body.content, base64);
  assert.ok(!JSON.stringify(upload.body).includes(installID));
  assert.ok(calls[2].body.body.includes(`https://raw.githubusercontent.com/maxtrigify/Otto/feedback-screenshots/${match[1]}`));
  assert.match(screenshotPath('jpg', new Date(Date.UTC(2026, 0, 5)), 'abc'), /^screenshots\/2026-01\/abc\.jpg$/);
});

test('a missing screenshots branch is a 503 configuration error', async (t) => {
  const calls = mockGitHub(t, {branch: () => new Response('{}', {status: 404})});
  const response = await worker.fetch(post(report({screenshot: {mediaType: 'image/png', base64: pngBytes.toString('base64')}})), makeEnv());
  assert.equal(response.status, 503);
  assert.equal(calls.length, 1);
});

test('rate limits return 429 before GitHub is called', async (t) => {
  const calls = mockGitHub(t);
  for (const name of ['IP_LIMIT', 'INSTALL_LIMIT', 'GLOBAL_LIMIT']) {
    const response = await worker.fetch(post(report()), makeEnv({[name]: limiter(false)}));
    assert.equal(response.status, 429, name);
    assert.ok(response.headers.get('Retry-After'));
  }
  assert.equal(calls.length, 0);
  assert.equal((await worker.fetch(post(report()), makeEnv({IP_LIMIT: undefined}))).status, 503);
});

test('GitHub failures are 502 and only the status is logged', async (t) => {
  const logs = [];
  const log = console.log;
  console.log = (...args) => logs.push(args.join(' '));
  t.after(() => { console.log = log; });
  mockGitHub(t, {issue: () => new Response(JSON.stringify({message: 'secret body detail'}), {status: 422})});
  const response = await worker.fetch(post(report()), makeEnv());
  assert.equal(response.status, 502);
  const text = await response.text();
  assert.ok(!text.includes(token) && !text.includes('secret body detail'));
  assert.equal(logs.length, 1);
  assert.match(logs[0], /422/);
  assert.ok(!logs[0].includes('secret body detail') && !logs[0].includes(token) && !logs[0].includes(installID));

  globalThis.fetch = async () => { throw new TypeError('network down'); };
  assert.equal((await worker.fetch(post(report()), makeEnv())).status, 502);
});

test('missing token is a 503', async (t) => {
  const calls = mockGitHub(t);
  assert.equal((await worker.fetch(post(report()), makeEnv({GITHUB_TOKEN: undefined}))).status, 503);
  assert.equal(calls.length, 0);
});
