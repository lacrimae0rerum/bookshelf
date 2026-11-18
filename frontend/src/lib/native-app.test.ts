import { afterEach, describe, expect, it, vi } from 'vitest';
import { chooseFilesInApp, inNativeApp } from './native-app';

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('native-app', () => {
  it('does nothing on the server or in a browser', () => {
    expect(inNativeApp()).toBe(false);
    vi.stubGlobal('window', {});
    expect(inNativeApp()).toBe(false);
    expect(chooseFilesInApp('paper')).toBe(false);
  });

  it('asks the app for its file panel, with the chosen genre', () => {
    const postMessage = vi.fn();
    vi.stubGlobal('window', { webkit: { messageHandlers: { bookshelf: { postMessage } } } });
    expect(inNativeApp()).toBe(true);
    expect(chooseFilesInApp('paper')).toBe(true);
    expect(postMessage).toHaveBeenLastCalledWith({ action: 'addFiles', genre: 'paper' });
    chooseFilesInApp(null);
    expect(postMessage).toHaveBeenLastCalledWith({ action: 'addFiles' });
  });
});
