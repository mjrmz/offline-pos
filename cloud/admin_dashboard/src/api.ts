const base = import.meta.env.PROD ? '' :
  (import.meta.env.VITE_LICENSE_API_URL ?? 'http://localhost:3000');

export class ApiError extends Error {
  constructor(message: string, public status?: number) { super(message); }
}

export async function api<T = any>(path: string, method = 'GET', body?: unknown): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${base}${path}`, {
      method,
      credentials: 'include',
      headers: {'Content-Type': 'application/json'},
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (cause) {
    console.error('License API request failed', {method, path, cause});
    throw new ApiError('The License API is unavailable.');
  }
  const contentType = response.headers.get('content-type') ?? '';
  const raw = await response.text();
  let parsed: unknown;
  if (raw && contentType.includes('application/json')) {
    try { parsed = JSON.parse(raw); }
    catch (cause) {
      console.error('Invalid License API JSON', {method, path, status: response.status, cause});
      throw new ApiError('The License API returned an unexpected response.', response.status);
    }
  }
  if (!response.ok) {
    console.error('License API error', {method, path, status: response.status, contentType});
    const detail = parsed && typeof parsed === 'object' && 'error' in parsed && typeof parsed.error === 'string' ? parsed.error : '';
    const friendly = response.status === 404 && path === '/admin/activity'
      ? 'Activity endpoint was not found.'
      : response.status === 404 ? 'The requested License API endpoint was not found.'
      : response.status === 401 ? 'Admin session expired. Please log in again.'
      : response.status >= 500 ? 'The License API is temporarily unavailable.'
      : detail || `License API request failed (HTTP ${response.status}).`;
    throw new ApiError(friendly, response.status);
  }
  if (raw && !contentType.includes('application/json')) {
    console.error('Unexpected License API content type', {method, path, status: response.status, contentType});
    throw new ApiError('The License API returned an unexpected response.', response.status);
  }
  return parsed as T;
}
