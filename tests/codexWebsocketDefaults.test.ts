import { describe, expect, test } from 'bun:test';
import { readAuthFileWebsockets } from '../src/features/authFiles/constants';

describe('Codex OAuth WebSocket defaults', () => {
  test('defaults missing Codex flags to enabled', () => {
    expect(readAuthFileWebsockets({ type: 'codex' })).toBe(true);
    expect(readAuthFileWebsockets({}, 'codex')).toBe(true);
  });
  test('preserves an explicit opt-out, including legacy flags', () => {
    expect(readAuthFileWebsockets({ type: 'codex', websockets: false })).toBe(false);
    expect(readAuthFileWebsockets({ type: 'codex', websocket: 'false' })).toBe(false);
    expect(readAuthFileWebsockets({ type: 'codex', websockets: false, websocket: true })).toBe(
      false
    );
  });
  test('keeps other provider defaults and explicit opt-ins', () => {
    expect(readAuthFileWebsockets({ type: 'xai' })).toBe(false);
    expect(readAuthFileWebsockets({ type: 'xai', websockets: true })).toBe(true);
  });
});
