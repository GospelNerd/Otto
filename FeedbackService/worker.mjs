// Otto in-app feedback relay. Accepts a small JSON report from the Otto app and files it as a
// public GitHub issue. The worker holds the only credential (the GITHUB_TOKEN secret); the app
// sends nothing that identifies the person beyond an anonymous install ID used for rate limiting,
// and that ID and the client IP never reach GitHub or the logs.

export const limits = {
  maxBodyBytes: 4 * 1024 * 1024,
  maxScreenshotBytes: 3 * 1024 * 1024,
  minDescription: 10,
  maxDescription: 5000,
  maxTitle: 120,
  issueTitle: 80,
};

export const screenshotBranch = 'feedback-screenshots';
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const repoPattern = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/;
const base64Pattern = /^[A-Za-z0-9+/]+={0,2}$/;
const environmentPatterns = {
  appVersion: /^[0-9A-Za-z.+-]{1,32}$/,
  build: /^[0-9A-Za-z.-]{1,32}$/,
  macOS: /^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$/,
  architecture: /^(arm64|x86_64)$/,
  model: /^[A-Za-z]{1,24}[0-9]{1,3},[0-9]{1,3}$/,
};
const mediaTypes = {'image/png': 'png', 'image/jpeg': 'jpg'};
const kinds = {bug: {prefix: '[Bug]', label: 'bug'}, idea: {prefix: '[Idea]', label: 'enhancement'}};
const headers = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
};

const json = (status, value, extra = {}) =>
  new Response(JSON.stringify(value), {status, headers: {...headers, ...extra}});
const fail = (status, message, extra) => json(status, {error: message}, extra);

export class ValidationError extends Error {}

/** Strict validation of the app's request body. Returns a normalized report or throws. */
export function validate(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new ValidationError('Expected a JSON object.');
  const allowed = new Set(['kind', 'title', 'description', 'screenshot', 'environment', 'installID']);
  for (const key of Object.keys(body)) if (!allowed.has(key)) throw new ValidationError(`Unexpected field: ${key.slice(0, 40)}.`);
  if (typeof body.kind !== 'string' || !Object.hasOwn(kinds, body.kind)) throw new ValidationError('kind must be "bug" or "idea".');
  if (typeof body.installID !== 'string' || !uuidPattern.test(body.installID)) throw new ValidationError('installID must be a UUID.');
  if (typeof body.description !== 'string') throw new ValidationError('description is required.');
  const description = body.description.trim();
  const length = [...description].length;
  if (length < limits.minDescription) throw new ValidationError(`description must be at least ${limits.minDescription} characters.`);
  if (length > limits.maxDescription) throw new ValidationError(`description must be at most ${limits.maxDescription} characters.`);
  let title = '';
  if (body.title !== undefined && body.title !== null) {
    if (typeof body.title !== 'string') throw new ValidationError('title must be a string.');
    title = body.title.trim();
    if ([...title].length > limits.maxTitle) throw new ValidationError(`title must be at most ${limits.maxTitle} characters.`);
  }
  let screenshot = null;
  if (body.screenshot !== undefined && body.screenshot !== null) screenshot = validateScreenshot(body.screenshot);
  let environment = null;
  if (body.environment !== undefined && body.environment !== null) environment = validateEnvironment(body.environment);
  return {kind: body.kind, title, description, screenshot, environment, installID: body.installID.toLowerCase()};
}

function validateScreenshot(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ValidationError('screenshot must be an object.');
  for (const key of Object.keys(value)) if (key !== 'mediaType' && key !== 'base64') throw new ValidationError('Unexpected screenshot field.');
  const extension = mediaTypes[value.mediaType];
  if (!extension || !Object.hasOwn(mediaTypes, value.mediaType)) throw new ValidationError('screenshot must be a PNG or JPEG.');
  if (typeof value.base64 !== 'string' || !base64Pattern.test(value.base64) || value.base64.length % 4 !== 0)
    throw new ValidationError('screenshot is not valid base64.');
  if (value.base64.length > Math.ceil(limits.maxScreenshotBytes / 3) * 4) throw new ValidationError('screenshot is larger than 3 MB.');
  const bytes = decodeBase64(value.base64);
  if (bytes.length > limits.maxScreenshotBytes) throw new ValidationError('screenshot is larger than 3 MB.');
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  const jpeg = [0xff, 0xd8, 0xff];
  const magic = extension === 'png' ? png : jpeg;
  if (bytes.length < magic.length + 4 || magic.some((byte, index) => bytes[index] !== byte))
    throw new ValidationError('screenshot content does not match its type.');
  return {mediaType: value.mediaType, extension, base64: value.base64, size: bytes.length};
}

function validateEnvironment(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ValidationError('environment must be an object.');
  const result = {};
  for (const [key, field] of Object.entries(value)) {
    const pattern = environmentPatterns[key];
    if (!pattern) throw new ValidationError('Unexpected environment field.');
    if (typeof field !== 'string' || !pattern.test(field)) throw new ValidationError(`environment.${key} is not valid.`);
    result[key] = field;
  }
  for (const key of ['appVersion', 'build', 'macOS', 'architecture'])
    if (!result[key]) throw new ValidationError(`environment.${key} is required.`);
  return result;
}

function decodeBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

/**
 * Makes untrusted text safe to post as GitHub markdown: no HTML, no @mentions that notify
 * people, no inline or reference images (only the worker embeds an image), no runaway blank
 * lines. Plain links stay as written.
 */
export function sanitizeMarkdown(text) {
  return text
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f‪-‮⁦-⁩]/g, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<\/?[A-Za-z][^>]*>/g, '')
    .replace(/</g, '&lt;')
    .replace(/@(?=[A-Za-z0-9_-])/g, '@‍')
    .replace(/!\[/g, '!\\[')
    .replace(/\n{4,}/g, '\n\n\n')
    .trim();
}

/** A one-line, mention-free issue title of at most `limits.issueTitle` characters. */
export function issueTitle(report) {
  const source = report.title || report.description.split('\n').find((line) => line.trim()) || '';
  let line = sanitizeMarkdown(source.replace(/[\r\n]+/g, ' ')).replace(/\s+/g, ' ').replace(/^#+\s*/, '').trim();
  // The cap covers the title GitHub shows, prefix included: capping only the body and appending
  // `[Bug] ` afterwards let 80-character titles reach 86.
  const prefixed = `${kinds[report.kind].prefix} ${line || 'Feedback from the Otto app'}`;
  const characters = [...prefixed];
  if (characters.length > limits.issueTitle) return characters.slice(0, limits.issueTitle - 1).join('').trimEnd() + '…';
  return prefixed;
}

/** The issue body. Never includes the install ID or anything about the sender's network. */
export function issueBody(report, screenshotURL) {
  const parts = [sanitizeMarkdown(report.description)];
  if (screenshotURL) parts.push(`### Screenshot\n\n![Screenshot from the Otto app](${screenshotURL})`);
  const environment = report.environment;
  if (environment) {
    const mac = environment.model ? `${environment.model} (${environment.architecture})` : environment.architecture;
    parts.push(
      [
        '### Details',
        '',
        `- Otto: ${environment.appVersion} (build ${environment.build})`,
        `- macOS: ${environment.macOS}`,
        `- Mac: ${mac}`,
      ].join('\n'),
    );
  }
  parts.push('---\n<sub>Sent from the Otto app.</sub>');
  return parts.join('\n\n');
}

export function screenshotPath(extension, now = new Date(), id = crypto.randomUUID()) {
  const month = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
  return `screenshots/${month}/${id}.${extension}`;
}

class GitHubError extends Error {
  constructor(step, status) {
    super(`${step} ${status}`);
    this.step = step;
    this.status = status;
  }
}

class ConfigurationError extends Error {}

async function github(env, method, path, body) {
  return fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      'User-Agent': 'otto-feedback-worker',
      'X-GitHub-Api-Version': '2022-11-28',
      ...(body ? {'Content-Type': 'application/json'} : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

async function uploadScreenshot(env, repo, screenshot) {
  const branch = await github(env, 'GET', `/repos/${repo}/branches/${screenshotBranch}`);
  if (branch.status === 404) throw new ConfigurationError(`missing branch ${screenshotBranch}`);
  if (!branch.ok) throw new GitHubError('branch lookup', branch.status);
  const path = screenshotPath(screenshot.extension);
  const response = await github(env, 'PUT', `/repos/${repo}/contents/${path}`, {
    message: 'Add feedback screenshot',
    content: screenshot.base64,
    branch: screenshotBranch,
  });
  if (!response.ok) throw new GitHubError('screenshot upload', response.status);
  return `https://raw.githubusercontent.com/${repo}/${screenshotBranch}/${path}`;
}

async function createIssue(env, repo, report, screenshotURL) {
  const response = await github(env, 'POST', `/repos/${repo}/issues`, {
    title: issueTitle(report),
    body: issueBody(report, screenshotURL),
    labels: [kinds[report.kind].label, 'from-app'],
  });
  if (!response.ok) throw new GitHubError('issue create', response.status);
  const issue = await response.json();
  if (!Number.isInteger(issue?.number) || typeof issue?.html_url !== 'string') throw new GitHubError('issue response', response.status);
  return {issueNumber: issue.number, issueURL: issue.html_url};
}

async function allowed(binding, key) {
  const result = await binding.limit({key});
  return result.success === true;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') {
      if (request.method !== 'GET' && request.method !== 'HEAD') return fail(405, 'Method not allowed.', {Allow: 'GET, HEAD'});
      return new Response('ok', {status: 200, headers: {'Content-Type': 'text/plain', 'Cache-Control': 'no-store'}});
    }
    if (url.pathname !== '/v1/feedback') return fail(404, 'Not found.');
    if (request.method !== 'POST') return fail(405, 'Method not allowed.', {Allow: 'POST'});

    if (!env.IP_LIMIT || !env.INSTALL_LIMIT || !env.GLOBAL_LIMIT) return fail(503, 'Feedback is not configured.');
    const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
    if (!(await allowed(env.IP_LIMIT, ip))) return fail(429, 'Too many reports. Please try again later.', {'Retry-After': '60'});

    const type = (request.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/json') return fail(415, 'Expected application/json.');
    const declared = Number(request.headers.get('Content-Length') || '0');
    if (declared > limits.maxBodyBytes) return fail(413, 'Report is too large.');
    let body;
    try {
      const raw = await request.arrayBuffer();
      if (raw.byteLength > limits.maxBodyBytes) return fail(413, 'Report is too large.');
      body = JSON.parse(new TextDecoder().decode(raw));
    } catch {
      return fail(400, 'Body is not valid JSON.');
    }
    let report;
    try {
      report = validate(body);
    } catch (error) {
      if (error instanceof ValidationError) return fail(400, error.message);
      throw error;
    }

    if (!(await allowed(env.INSTALL_LIMIT, report.installID))) return fail(429, 'Too many reports. Please try again later.', {'Retry-After': '60'});
    if (!(await allowed(env.GLOBAL_LIMIT, 'feedback'))) return fail(429, 'Feedback is busy. Please try again later.', {'Retry-After': '60'});

    const repo = env.GITHUB_REPO || 'maxtrigify/Otto';
    if (!env.GITHUB_TOKEN || !repoPattern.test(repo)) return fail(503, 'Feedback is not configured.');
    try {
      const screenshotURL = report.screenshot ? await uploadScreenshot(env, repo, report.screenshot) : null;
      return json(201, await createIssue(env, repo, report, screenshotURL));
    } catch (error) {
      if (error instanceof ConfigurationError) {
        console.log('feedback configuration error:', error.message);
        return fail(503, 'Screenshots are not configured yet. Try again without one.');
      }
      if (error instanceof GitHubError) {
        // Status only: never the response body, request body or token.
        console.log('github request failed:', error.step, error.status);
        return fail(502, 'GitHub did not accept the report. Please try again later.');
      }
      console.log('feedback failed:', error?.name || 'Error');
      return fail(502, 'GitHub could not be reached. Please try again later.');
    }
  },
};
