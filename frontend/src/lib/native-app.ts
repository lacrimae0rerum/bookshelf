/**
 * Bookshelf.app (macos/) shows this site in a web view and listens for a few requests
 * only the app can do, on `window.webkit.messageHandlers.bookshelf`. In a browser that
 * handler does not exist and these helpers do nothing.
 */
import type { Genre } from './api/types/documents';

interface MessageHandler {
  postMessage(message: unknown): void;
}

interface WithWebKit {
  webkit?: { messageHandlers?: { bookshelf?: MessageHandler } };
}

function handler(): MessageHandler | null {
  if (typeof window === 'undefined') return null;
  return (window as unknown as WithWebKit).webkit?.messageHandlers?.bookshelf ?? null;
}

/** Whether the page runs inside Bookshelf.app. */
export function inNativeApp(): boolean {
  return handler() !== null;
}

/**
 * Opens the Mac's file panel; the app copies the chosen files into `library/inbox` and
 * adds them to the shelf as `genre` (null: detected). False outside the app.
 */
export function chooseFilesInApp(genre: Genre | null): boolean {
  const target = handler();
  if (!target) return false;
  target.postMessage(genre ? { action: 'addFiles', genre } : { action: 'addFiles' });
  return true;
}
